## browser.nim - `Browser` enum, per-browser spec table, discovery, and launch.
##
## Discovery walks an ordered preference list (`seq[Browser]`) against a
## `BrowserSpec` table: macOS bundle paths with an `mdfind` fallback, Windows
## Program Files candidates plus registry App Paths, Linux executable names via
## `findExe`, and a `supportsAppMode` flag. An explicit `browserPath` override
## skips discovery. For 2.0 only `Chrome`, `Chromium`, and `Default` have
## populated specs; `Edge`, `Brave`, `Opera`, and `Vivaldi` exist in the enum
## and table with empty specs.
##
## Launch uses `startProcess` with an args array, never a shell string:
## `--app=<url>`, `--user-data-dir=<dir>`, `--window-size`, `--window-position`,
## `--disable-http-cache`, plus user-provided flags. The process handle is kept
## for `window.nim`. `fallback = true` opens the app in a default-browser tab;
## `fallback = false` opens a default-browser tab at a Neel error page listing
## the browsers searched.
##
## Implemented in Task 11.
