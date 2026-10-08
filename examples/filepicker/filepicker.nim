## filepicker.nim - the "hello world" of Neel 2.0: one exposed proc, one page.
##
## The page asks for a directory (relative to your home directory, or
## absolute); Nim picks a random entry from it and the page shows the name. A
## missing or empty directory is reported as a structured error, so the page
## can show the Nim exception name and message.
##
## How to run (from any directory; the paths below are relative to the repo):
##
##   nim c -r examples/filepicker/filepicker.nim
##       debug build: `web/` is served from disk, so edits to the page show
##       up on refresh; the app exits 3 s after the window is closed.
##
##   nim c -d:release examples/filepicker/filepicker.nim
##   ./examples/filepicker/filepicker
##       release build: `web/` is embedded into the binary at compile time,
##       so the binary can be moved anywhere; the grace period is 10 s.
##
## Chrome or Chromium is opened in app mode; with neither installed the page
## opens in a tab of the default browser instead. Expect Chromium's own
## stderr noise in the terminal (the browser inherits stdio).

import std/[os, random]
import neel

type
  MissingDirectoryError = object of CatchableError
    ## The directory does not exist (shown in the page as `e.name`).
  EmptyDirectoryError = object of CatchableError
    ## The directory exists but has no entries.

proc filePicker(directory: string): string {.expose.} =
  ## Returns the name of a random entry of `directory`, resolved against the
  ## home directory unless absolute. Exposed procs run on worker threads, so
  ## a per-call `Rand` is used instead of the global random state.
  let dir = absolutePath(directory, root = getHomeDir())
  if not dirExists(dir):
    raise newException(MissingDirectoryError, "no such directory: " & dir)
  var names: seq[string]
  for _, path in walkDir(dir):
    names.add path.extractFilename
  if names.len == 0:
    raise newException(EmptyDirectoryError, "the directory is empty: " & dir)
  var rng = initRand()
  rng.sample(names)

startApp()
