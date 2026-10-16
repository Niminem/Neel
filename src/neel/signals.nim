## signals.nim - stop-signal handlers for serve mode.
##
## `startApp` installs these for the duration of a serve-mode run and removes
## them before it returns; local mode never installs them. A handler only asks
## the window module to stop (`window.requestStop`, one atomic exchange):
## `quitApp` takes a lock and signals a condition variable, neither of which
## is safe in a signal handler. The serve-mode wait notices the request
## within its `IdleTickMs` bound and returns `erQuit`.
##
## - POSIX: `SIGINT` and `SIGTERM` through `sigaction`. A second signal while
##   a stop is already requested calls `_exit(130)` (`SIGINT`) or
##   `_exit(143)` (`SIGTERM`), so a hung shutdown can always be interrupted.
##   `removeStopHandlers` restores the exact previous `sigaction` of both,
##   which for `SIGINT` is normally Nim's own handler (installed at program
##   start, replaced by `setControlCHook`). On Linux, glibc adds
##   `SA_RESTORER` to the flags of any action it installs, so a restored
##   never-touched `SIGTERM` reads back with that bit set; the action itself
##   is unchanged.
## - Windows: `SetConsoleCtrlHandler`. Handlers run on a thread the system
##   creates, last registered first; returning `TRUE` stops the chain, so
##   while ours is registered the C runtime's handler (which runs Nim's
##   `SIGINT` handler, or a `setControlCHook` hook) is not reached, and
##   removing ours brings it back unchanged. Ctrl-C and Ctrl-Break request a
##   stop and return. Close, logoff, and shutdown request a stop and then
##   wait, at most `ShutdownWaitMs`, for `reportShutdownFinished`, because
##   Windows terminates the process as soon as the handler returns. That
##   wait is on a manual-reset kernel event: created once, never closed (a
##   handler still waiting after `startApp` returned holds a valid handle),
##   reset by `installStopHandlers`, set by `reportShutdownFinished`.
##
## Handlers take no lock, allocate nothing, do no I/O, and never raise; they
## are compiled without stack-trace frames, so they touch no thread-local
## state either (the Windows handler runs on a thread Nim did not create).
## `installStopHandlers`, `reportShutdownFinished`, and `removeStopHandlers`
## run on the thread that runs `startApp`.

import std/[atomics, oserrors]
from ./window import requestStop

when defined(windows):
  from std/winlean import DWORD, WINBOOL, Handle, createEvent, setEvent,
    waitForSingleObject

  type
    CtrlHandler = proc (ctrlType: DWORD): WINBOOL {.stdcall, gcsafe, raises: [].}

  proc setConsoleCtrlHandler(handler: CtrlHandler; add: WINBOOL): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "SetConsoleCtrlHandler".}
  proc resetEvent(hEvent: Handle): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "ResetEvent".}

  const
    CtrlCEvent* = DWORD(0)
      ## `CTRL_C_EVENT`.
    CtrlBreakEvent* = DWORD(1)
      ## `CTRL_BREAK_EVENT`.
    CtrlCloseEvent* = DWORD(2)
      ## `CTRL_CLOSE_EVENT`: the console window is being closed.
    CtrlLogoffEvent* = DWORD(5)
      ## `CTRL_LOGOFF_EVENT`.
    CtrlShutdownEvent* = DWORD(6)
      ## `CTRL_SHUTDOWN_EVENT`.
    ShutdownWaitMs* = 4000
      ## How long the close / logoff / shutdown handler waits for
      ## `reportShutdownFinished`. Windows terminates the process about 5 s
      ## after the event whatever the handler does.

  var shutdownEvent: Handle
    ## Written once, before the handler is first registered; read by the
    ## handler thread; never closed.
else:
  import std/posix

var installed: Atomic[bool]
  ## Written by the thread running `startApp`; read from any thread
  ## (`stopHandlersInstalled`). Handlers never touch it.

when defined(windows):
  {.push stackTrace: off.}
  proc onConsoleCtrl*(ctrlType: DWORD): WINBOOL {.stdcall, gcsafe, raises: [].} =
    ## The console control handler. Exported for tests, which call it the way
    ## Windows does (on a thread of their own); `nimble test` cannot send
    ## console events without hitting every process on the console. Returns
    ## `TRUE` for the five events above, `FALSE` (next handler) otherwise.
    case ctrlType
    of CtrlCEvent, CtrlBreakEvent:
      discard requestStop()
      1
    of CtrlCloseEvent, CtrlLogoffEvent, CtrlShutdownEvent:
      discard requestStop()
      discard waitForSingleObject(shutdownEvent, ShutdownWaitMs)
      1
    else:
      0
  {.pop.}

  proc installImpl() =
    if shutdownEvent == 0:
      shutdownEvent = createEvent(nil, 1, 0, nil)
      if shutdownEvent == 0:
        raiseOSError(osLastError(), "neel: could not create the shutdown event")
    discard resetEvent(shutdownEvent)
    if setConsoleCtrlHandler(onConsoleCtrl, 1) == 0:
      raiseOSError(osLastError(), "neel: could not install the console control handler")

  proc reportImpl() =
    if shutdownEvent != 0:
      discard setEvent(shutdownEvent)

  proc removeImpl() =
    discard setConsoleCtrlHandler(onConsoleCtrl, 0)

else:
  var savedInt, savedTerm: Sigaction
    ## The actions `installStopHandlers` replaced. Thread running `startApp`
    ## only; the handler never reads them.

  {.push stackTrace: off.}
  proc onStopSignal(sig: cint) {.noconv, gcsafe, raises: [].} =
    if requestStop():
      exitnow(if sig == SIGINT: 130 else: 143)
  {.pop.}

  proc installImpl() =
    var act: Sigaction
    act.sa_handler = onStopSignal
    discard sigemptyset(act.sa_mask)
    act.sa_flags = SA_RESTART
    if sigaction(SIGINT, act, addr savedInt) != 0:
      raiseOSError(osLastError(), "neel: could not install the SIGINT handler")
    if sigaction(SIGTERM, act, addr savedTerm) != 0:
      let err = osLastError()
      discard sigaction(SIGINT, savedInt)
      raiseOSError(err, "neel: could not install the SIGTERM handler")

  proc reportImpl() =
    discard

  proc removeImpl() =
    discard sigaction(SIGTERM, savedTerm)
    discard sigaction(SIGINT, savedInt)

proc installStopHandlers*() =
  ## Installs the stop handlers, remembering what they replace. Call after
  ## `initWindows` (which clears the stop request) and pair with
  ## `removeStopHandlers` in a `finally`. Raises `OSError` if the OS refuses,
  ## leaving nothing installed.
  doAssert not installed.load, "installStopHandlers called twice"
  installImpl()
  installed.store(true)

proc reportShutdownFinished*() =
  ## Releases a Windows close / logoff / shutdown handler waiting for the
  ## server to be shut down (Windows then ends the process). Call after
  ## `shutdown`, before `removeStopHandlers`. A no-op on POSIX.
  reportImpl()

proc removeStopHandlers*() =
  ## Restores what `installStopHandlers` replaced. A no-op when nothing is
  ## installed.
  if installed.load:
    removeImpl()
    installed.store(false)

proc stopHandlersInstalled*(): bool =
  ## Whether the stop handlers are installed; callable from any thread. For
  ## tests and diagnostics.
  installed.load
