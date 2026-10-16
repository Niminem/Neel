## testhooks.nim - test-only replacements for the browser launch and the
## exit-time profile sweep, and an observer for the server settings.
##
## `nimble test` must not start a browser, so `tests/t_neel.nim` runs the real
## `startApp` with a fake launcher and a recording sweep installed here. `neel`
## does not re-export this module, so applications never see these hooks.
## Set them on the thread that calls `startApp`, before calling it; `runApp`
## reads them once at start. `nil` (the default) means the real launch and
## the real sweep, and no observer.

from ./window import Launcher

type
  ProfileSweep* = proc() {.gcsafe.}
    ## What `runApp` runs at exit to delete abandoned profile dirs; `nil`
    ## means `sweepProfiles()`.
  PingObserver* = proc(pingIntervalMs: int) {.gcsafe.}
    ## Called by `runApp`, in every mode, with the keep-alive ping interval
    ## of the server it created. Changes nothing.

var
  launcherHook: Launcher
  sweepHook: ProfileSweep
  pingHook: PingObserver

proc setTestLauncher*(launcher: Launcher) =
  ## Replaces the browser launch of every later `startApp`; `nil` restores
  ## the real one.
  launcherHook = launcher

proc setTestProfileSweep*(sweep: ProfileSweep) =
  ## Replaces the exit-time profile sweep of every later `startApp`; `nil`
  ## restores the real one.
  sweepHook = sweep

proc setTestPingObserver*(observer: PingObserver) =
  ## Reports the ping interval of every later `startApp`'s server to
  ## `observer`; `nil` removes it.
  pingHook = observer

proc testLauncher*(): Launcher =
  ## The installed launcher, or `nil`.
  launcherHook

proc testProfileSweep*(): ProfileSweep =
  ## The installed sweep, or `nil`.
  sweepHook

proc testPingObserver*(): PingObserver =
  ## The installed ping observer, or `nil`.
  pingHook
