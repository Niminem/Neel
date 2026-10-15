## t_signals.nim - stop-signal handlers: install / remove bookkeeping, exact
## restoration of the previous handlers, and the stop request they make.
##
## POSIX: real `SIGTERM` / `SIGINT` sent to this process while the handlers
## are installed over a serve-mode window table; the previous `sigaction` of
## both signals (Nim's own `SIGINT` handler, a `setControlCHook` hook, a
## custom `SIGTERM` handler) is compared before and after. Windows: console
## events cannot be sent without reaching every process on the console, so
## the handler is called directly, on a thread of its own as Windows does.
## Every wait is bounded.

import std/[unittest, monotimes, times]
import neel/[window, signals, protocol, browser, server]
when defined(windows):
  import std/[os, typedthreads]

const
  Base = "http://127.0.0.1:1234"

proc noClose(conn: ConnId; code: int; reason: string): bool {.gcsafe.} = true

proc elapsedMs(t0: MonoTime): int =
  int((getMonoTime() - t0).inMilliseconds)

template withServeWindows(body: untyped) =
  ## A serve-mode window table, as `startApp` has it when the handlers go in.
  initWindows(noClose, newPendingTable(), Base, BrowserSearch(),
              launcher = noLaunch, serve = true)
  try:
    discard openVirtualWindow("/")
    body
  finally:
    teardownWindows()

suite "signals: bookkeeping":
  test "install and remove toggle the state; remove without install is a no-op":
    check not stopHandlersInstalled()
    removeStopHandlers()
    check not stopHandlersInstalled()
    installStopHandlers()
    try:
      check stopHandlersInstalled()
      expect AssertionDefect:
        installStopHandlers()
      check stopHandlersInstalled()
    finally:
      removeStopHandlers()
    check not stopHandlersInstalled()
    removeStopHandlers()
    check not stopHandlersInstalled()

  test "installing does not request a stop":
    withServeWindows:
      installStopHandlers()
      try:
        check not requestStop()
      finally:
        removeStopHandlers()

when defined(posix):
  import std/posix

  proc sigactionQuery(sig: cint; act, old: ptr Sigaction): cint
    {.importc: "sigaction", header: "<signal.h>".}

  type Action = tuple[handler: pointer; flags: cint]

  proc actionOf(sig: cint): Action =
    var old: Sigaction
    doAssert sigactionQuery(sig, nil, addr old) == 0
    (cast[pointer](old.sa_handler), old.sa_flags)

  proc fullAction(sig: cint): Sigaction =
    doAssert sigactionQuery(sig, nil, addr result) == 0

  var termsSeen {.volatile.}: int
  proc countTerm(sig: cint) {.noconv.} =
    inc termsSeen
  proc ctrlCHook() {.noconv.} =
    discard

  suite "signals: POSIX":
    test "SIGINT and SIGTERM are replaced while installed and restored exactly":
      let intBefore = actionOf(SIGINT)
      let termBefore = actionOf(SIGTERM)
      # Nim installs its own SIGINT handler at program start.
      check intBefore.handler != nil
      installStopHandlers()
      try:
        let intDuring = actionOf(SIGINT)
        let termDuring = actionOf(SIGTERM)
        check intDuring.handler != intBefore.handler
        check termDuring.handler != termBefore.handler
        check intDuring.handler == termDuring.handler
        check (intDuring.flags and SA_RESTART) != 0
      finally:
        removeStopHandlers()
      check actionOf(SIGINT) == intBefore
      check actionOf(SIGTERM) == termBefore

    test "a setControlCHook hook and a custom SIGTERM handler come back and still work":
      let origInt = fullAction(SIGINT)
      let origTerm = fullAction(SIGTERM)
      try:
        setControlCHook(ctrlCHook)
        var custom: Sigaction
        custom.sa_handler = countTerm
        discard sigemptyset(custom.sa_mask)
        doAssert sigaction(SIGTERM, custom) == 0
        let intBefore = actionOf(SIGINT)
        let termBefore = actionOf(SIGTERM)
        check intBefore.handler == cast[pointer](ctrlCHook)
        check termBefore.handler == cast[pointer](countTerm)
        installStopHandlers()
        removeStopHandlers()
        check actionOf(SIGINT) == intBefore
        check actionOf(SIGTERM) == termBefore
        termsSeen = 0
        discard `raise`(SIGTERM) # this thread only
        check termsSeen == 1
      finally:
        var i = origInt
        var t = origTerm
        discard sigaction(SIGINT, i)
        discard sigaction(SIGTERM, t)

    for (name, sig) in [("SIGTERM", SIGTERM), ("SIGINT", SIGINT)]:
      test name & " sent to the process ends the serve wait with erQuit":
        let before = (actionOf(SIGINT), actionOf(SIGTERM))
        withServeWindows:
          installStopHandlers()
          try:
            let t0 = getMonoTime()
            check kill(getpid(), sig) == 0
            check waitForAppExit() == erQuit
            check elapsedMs(t0) < 1000 + 500
            # The handler made the request; a second one would `_exit`.
            check requestStop()
          finally:
            removeStopHandlers()
        check (actionOf(SIGINT), actionOf(SIGTERM)) == before

when defined(windows):
  type CtrlCall = object
    event: int32        # a `DWORD` control type
    returned: int32
    tookMs: int

  proc callHandler(c: ptr CtrlCall) {.thread.} =
    let t0 = getMonoTime()
    c.returned = onConsoleCtrl(c.event)
    c.tookMs = elapsedMs(t0)

  proc reportLater(delayMs: int) {.thread.} =
    sleep(delayMs)
    reportShutdownFinished()

  suite "signals: Windows (handler called directly)":
    test "Ctrl-C and Ctrl-Break request a stop and return TRUE; other events are passed on":
      for ev in [CtrlCEvent, CtrlBreakEvent]:
        withServeWindows:
          let t0 = getMonoTime()
          check onConsoleCtrl(ev) == 1
          check elapsedMs(t0) < 100
          check waitForAppExit() == erQuit
          check requestStop()
      withServeWindows:
        for ev in [3'i32, 4, 7, 100]:
          check onConsoleCtrl(ev) == 0
        check not requestStop()

    test "close, logoff, shutdown: return once shutdown is reported":
      withServeWindows:
        installStopHandlers()
        try:
          var c = CtrlCall(event: CtrlCloseEvent)
          var th: Thread[ptr CtrlCall]
          var reporter: Thread[int]
          createThread(th, callHandler, addr c)
          check waitForAppExit() == erQuit # the handler requested the stop
          createThread(reporter, reportLater, 300)
          joinThread(reporter)
          joinThread(th)
          check c.returned == 1
          check c.tookMs >= 300 - 50
          check c.tookMs < 300 + 1000 + 500
          # Already reported: logoff and shutdown return at once.
          for ev in [CtrlLogoffEvent, CtrlShutdownEvent]:
            let t0 = getMonoTime()
            check onConsoleCtrl(ev) == 1
            check elapsedMs(t0) < 100
        finally:
          removeStopHandlers()

    test "close without a report gives up after ShutdownWaitMs":
      withServeWindows:
        installStopHandlers() # resets the event a previous run set
        try:
          let t0 = getMonoTime()
          check onConsoleCtrl(CtrlCloseEvent) == 1
          let took = elapsedMs(t0)
          check took >= ShutdownWaitMs - 100
          check took < ShutdownWaitMs + 1000
          check requestStop()
        finally:
          removeStopHandlers()
