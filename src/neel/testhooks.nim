## testhooks.nim - test-only replacements for the browser launch and the
## exit-time profile sweep.
##
## `nimble test` must not start a browser, so `tests/t_neel.nim` runs the real
## `startApp` with a fake launcher and a recording sweep installed here. `neel`
## does not re-export this module, so applications never see these hooks.
## Set them on the thread that calls `startApp`, before calling it; `runApp`
## reads them once at start. `nil` (the default) means the real launch and
## the real sweep.

from ./window import Launcher

type
  ProfileSweep* = proc() {.gcsafe.}
    ## What `runApp` runs at exit to delete abandoned profile dirs; `nil`
    ## means `sweepProfiles()`.

var
  launcherHook: Launcher
  sweepHook: ProfileSweep

proc setTestLauncher*(launcher: Launcher) =
  ## Replaces the browser launch of every later `startApp`; `nil` restores
  ## the real one.
  launcherHook = launcher

proc setTestProfileSweep*(sweep: ProfileSweep) =
  ## Replaces the exit-time profile sweep of every later `startApp`; `nil`
  ## restores the real one.
  sweepHook = sweep

proc testLauncher*(): Launcher =
  ## The installed launcher, or `nil`.
  launcherHook

proc testProfileSweep*(): ProfileSweep =
  ## The installed sweep, or `nil`.
  sweepHook
