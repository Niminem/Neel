## browser.nim - `Browser` enum, per-browser spec table, discovery, and launch.
##
## Discovery walks an ordered preference list (`seq[Browser]`) against the
## `BrowserSpecs` table: macOS bundle executable paths with an `mdfind`
## bundle-id fallback, Windows candidates under Program Files / Program Files
## (x86) / LocalAppData plus the registry `App Paths` key, Linux executable
## names via `findExe`, and a `supportsAppMode` flag. An explicit
## `browserPath` override wins and is used as-is. For 2.0 only `Chrome`,
## `Chromium`, and `Default` are supported; `Edge`, `Brave`, `Opera`, and
## `Vivaldi` are *reserved*: present in the enum and table with empty specs and
## skipped by discovery. Every filesystem, environment, `mdfind`, and registry
## probe goes through a `Discovery` record of procs so tests inject results and
## never touch the machine (`systemDiscovery()` is the real one).
##
## Launch uses `startProcess` with an args array, never a shell string:
## `--app=<url>`, `--user-data-dir=<dir>`, `--window-size`, `--window-position`,
## `--disable-http-cache`, `--no-first-run`, `--no-default-browser-check`, then
## user-provided flags verbatim (`buildLaunchArgs` is pure; `launchBrowser`
## starts the process). Each window gets its *own* user-data-dir
## (`userDataDirFor`): Chromium hands a second `--app` launch with the same
## profile dir to the already-running instance and the launcher exits at once,
## so a shared dir would leave every window but the first untracked. The
## `BrowserHandle` retains the `Process` for `window.nim` (`isRunning`,
## `terminate`, `close`, `removeUserDataDir`).
##
## Fallback: `openDefaultBrowser` runs `open` (macOS), `xdg-open` (Linux), or
## `rundll32.exe url.dll,FileProtocolHandler` (Windows). `launchWithFallback`
## ties it together: `fallback = true` opens the app URL in a default-browser
## tab; `fallback = false` opens the default browser at the Neel-served error
## page (`NoBrowserPath`, rendered by `startApp`) and raises `NeelBrowserError`
## carrying the list of browsers searched.

import std/[os, osproc, options, strutils, monotimes, times]

when defined(windows):
  import std/registry

type
  Browser* = enum
    ## Browsers Neel knows how to look for. `Default` means "whatever the OS
    ## opens URLs with", in a normal tab (no app mode).
    Chrome, Chromium, Edge, Brave, Opera, Vivaldi, Default

  HostOs* = enum
    ## The operating system whose search rules and opener command apply.
    ## `CurrentHostOs` is the compile target; tests pass the others.
    hoMacos, hoWindows, hoLinux

  BrowserSpec* = object
    ## Where one browser lives on each OS and how it may be launched. Every
    ## candidate list may be empty; `supported` tells discovery whether the
    ## entry is usable at all in this release.
    name*: string
      ## Display name used in error messages and the no-browser page.
    supported*: bool
      ## `false` for reserved enum members (empty spec, skipped by discovery).
    supportsAppMode*: bool
      ## `true` when the executable accepts `--app=<url>` and the Chromium
      ## window flags. `false` for `Default` and every reserved member.
    macAppPaths*: seq[string]
      ## Absolute executable paths inside app bundles; a leading `~/` is
      ## expanded with `HOME`.
    macBundleIds*: seq[string]
      ## `mdfind "kMDItemCFBundleIdentifier == '<id>'"` fallback queries.
    macExecutable*: string
      ## Executable path relative to a bundle returned by `mdfind`.
    windowsRelativePaths*: seq[string]
      ## Paths relative to `%ProgramFiles%`, `%ProgramFiles(x86)%`, and
      ## `%LocalAppData%` (tried in that order), backslash separated.
    windowsAppPathsKeys*: seq[string]
      ## Executable names looked up under
      ## `SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\` (HKCU, HKLM).
    linuxExecutables*: seq[string]
      ## Names resolved on `PATH` with `findExe`.

  Discovery* = object
    ## The probes `findBrowser` uses. Tests fill these with canned answers;
    ## `systemDiscovery()` returns the real ones. All procs must be `gcsafe`
    ## so discovery can run on a pool worker (`openWindow` from an exposed
    ## proc).
    fileExists*: proc(path: string): bool {.gcsafe.}
      ## Whether a regular file exists at `path`.
    findExe*: proc(name: string): string {.gcsafe.}
      ## Absolute path or `""` when `name` is not on `PATH`.
    getEnv*: proc(name: string): string {.gcsafe.}
      ## `""` when unset (`HOME`, `ProgramFiles`, `ProgramFiles(x86)`,
      ## `LocalAppData`).
    mdfind*: proc(bundleId: string): seq[string] {.gcsafe.}
      ## App bundle directories for a bundle id (macOS only; empty elsewhere).
    registryAppPath*: proc(exeName: string): string {.gcsafe.}
      ## The default value of the `App Paths\<exeName>` key or `""`.

  ProbeResult* = object
    ## What discovery looked at for one supported browser.
    browser*: Browser
      ## The browser probed.
    candidates*: seq[string]
      ## Every location examined, in order, for the no-browser page.
    path*: string
      ## The executable found, or `""`.

  FoundBrowser* = object
    ## The browser `findBrowser` settled on.
    browser*: Browser
      ## `Default` means open a default-browser tab (`path` is empty). With a
      ## `browserPath` override this is the first app-mode preference (or
      ## `Chrome` when there is none): the override is launched with that
      ## browser's app-mode flags.
    path*: string
      ## Executable to start; `""` only for `Default`.
    fromOverride*: bool
      ## `true` when `path` came from the `browserPath` argument.

  BrowserSearch* = object
    ## Result of `findBrowser`: the outcome plus everything that was probed,
    ## so the no-browser page can list it.
    found*: Option[FoundBrowser]
      ## The browser to launch, or `none` when nothing usable was found.
    probed*: seq[ProbeResult]
      ## Supported browsers probed, in preference order, including the one
      ## found (if any). Empty when an override was used.
    skipped*: seq[Browser]
      ## Reserved members that appeared in the preference list.

  WindowSize* = tuple[width, height: int]
    ## Pixels, both positive.
  WindowPosition* = tuple[x, y: int]
    ## Screen coordinates of the top-left corner; may be negative.

  LaunchOptions* = object
    ## Per-window launch parameters other than the URL and profile dir.
    size*: Option[WindowSize]
      ## `--window-size=W,H` when given.
    position*: Option[WindowPosition]
      ## `--window-position=X,Y` when given.
    extraFlags*: seq[string]
      ## Appended verbatim, in order, after Neel's own flags.

  LaunchKind* = enum
    ## How a window was opened, which decides what `BrowserHandle` tracks.
    lkAppWindow
      ## A browser process Neel started in `--app` mode; `process` is live.
    lkDefaultBrowser
      ## The URL was handed to the OS opener; nothing is tracked.

  BrowserHandle* = ref object
    ## What a launch produced. Not thread-safe: `window.nim` must guard it
    ## with its window-table lock. For `lkAppWindow` the handle owns the
    ## browser process: `isRunning`, `terminate`, `close`. Note (measured on
    ## macOS): a user closing the only app window leaves the Chrome process
    ## running, so "process alive" does not mean "window open"; the WebSocket
    ## connection is the source of truth for that, the process handle is for
    ## tearing the window down.
    kind*: LaunchKind
      ## App-mode process or default-browser hand-off.
    browser*: Browser
      ## The preference the launch resolved to.
    path*: string
      ## Executable started (`lkAppWindow`) or opener command
      ## (`lkDefaultBrowser`).
    args*: seq[string]
      ## Exact argument vector passed to `startProcess`.
    url*: string
      ## The page URL the window was opened at.
    userDataDir*: string
      ## The profile dir handed to the browser; `""` for `lkDefaultBrowser`.
    process: Process
      ## `nil` for `lkDefaultBrowser` and after `close`.

  OpenerCommand* = object
    ## Command and args that open a URL in the OS default browser.
    command*: string
      ## Executable name, resolved on `PATH` (`open`, `xdg-open`, `rundll32.exe`).
    args*: seq[string]
      ## Argument vector; the URL is always one element.

  NeelBrowserError* = object of CatchableError
    ## No usable browser was found and fallback is disabled, a `browserPath`
    ## override does not exist, or a `startProcess` failed.
    searched*: seq[string]
      ## Display names of the browsers probed (for the no-browser case).

const
  CurrentHostOs* =
    when defined(macosx): hoMacos
    elif defined(windows): hoWindows
    else: hoLinux
    ## The OS this binary targets. BSDs use the Linux rules (`findExe`,
    ## `xdg-open`).

  BrowserSpecs*: array[Browser, BrowserSpec] = [
    Chrome: BrowserSpec(
      name: "Google Chrome", supported: true, supportsAppMode: true,
      macAppPaths: @[
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"],
      macBundleIds: @["com.google.Chrome"],
      macExecutable: "Contents/MacOS/Google Chrome",
      windowsRelativePaths: @[r"Google\Chrome\Application\chrome.exe"],
      windowsAppPathsKeys: @["chrome.exe"],
      linuxExecutables: @["google-chrome", "google-chrome-stable", "chrome"]),
    Chromium: BrowserSpec(
      name: "Chromium", supported: true, supportsAppMode: true,
      macAppPaths: @[
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "~/Applications/Chromium.app/Contents/MacOS/Chromium"],
      macBundleIds: @["org.chromium.Chromium"],
      macExecutable: "Contents/MacOS/Chromium",
      windowsRelativePaths: @[r"Chromium\Application\chrome.exe"],
      # No App Paths key: Chromium builds register `chrome.exe` too, which
      # would make a Chromium preference resolve to Google Chrome.
      windowsAppPathsKeys: @[],
      linuxExecutables: @["chromium", "chromium-browser"]),
    Edge: BrowserSpec(name: "Microsoft Edge"),
    Brave: BrowserSpec(name: "Brave"),
    Opera: BrowserSpec(name: "Opera"),
    Vivaldi: BrowserSpec(name: "Vivaldi"),
    Default: BrowserSpec(name: "Default browser", supported: true)]
    ## The spec table. Reserved members (`Edge`, `Brave`, `Opera`, `Vivaldi`)
    ## carry only a display name; they are not supported in 2.0.

  NoBrowserPath* = "/neel/no-browser"
    ## Route of the error page `startApp` serves when no browser was found and
    ## `fallback = false`. The page lists the browsers searched.
  NoBrowserQueryParam* = "searched"
    ## Query parameter of `NoBrowserPath` carrying the probed `Browser` names
    ## comma-separated (`?searched=Chrome,Chromium`), so the page can render
    ## without server-side state (`parseEnum[Browser]` reads them back).

  WindowsProgramRoots = ["ProgramFiles", "ProgramFiles(x86)", "LocalAppData"]
    ## Environment variables holding the Windows install roots, in search order.
  WindowsAppPathsKey = r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\"
  OpenerWaitMs = 3000
    ## How long `openDefaultBrowser` waits for the opener to exit before
    ## giving up on reading its exit code.
  TerminateGraceMs* = 2000
    ## Default time `terminate` gives the browser between SIGTERM and SIGKILL.

proc isSupported*(b: Browser): bool =
  ## `true` for `Chrome`, `Chromium`, and `Default` in 2.0.
  BrowserSpecs[b].supported

proc isReserved*(b: Browser): bool =
  ## `true` for enum members that exist for forward compatibility only
  ## (`Edge`, `Brave`, `Opera`, `Vivaldi`); discovery skips them.
  not BrowserSpecs[b].supported

proc displayName*(b: Browser): string =
  ## `BrowserSpecs[b].name`.
  BrowserSpecs[b].name

proc hasCandidates*(spec: BrowserSpec; hostOs: HostOs): bool =
  ## Whether `spec` has at least one place to look on `hostOs`.
  case hostOs
  of hoMacos: spec.macAppPaths.len > 0 or spec.macBundleIds.len > 0
  of hoWindows:
    spec.windowsRelativePaths.len > 0 or spec.windowsAppPathsKeys.len > 0
  of hoLinux: spec.linuxExecutables.len > 0

proc hasAnyCandidates(spec: BrowserSpec): bool =
  for os in HostOs:
    if spec.hasCandidates(os):
      return true
  false

static:
  for b, spec in BrowserSpecs:
    doAssert spec.name.len > 0, $b & " needs a display name"
    if b == Default:
      doAssert spec.supported, "Default must be supported"
      doAssert not spec.supportsAppMode, "Default cannot use app mode"
      doAssert not spec.hasAnyCandidates, "Default has nothing to search for"
    elif spec.supported:
      doAssert spec.supportsAppMode, $b & " is supported but not app-mode capable"
      for os in HostOs:
        doAssert spec.hasCandidates(os), $b & " has no candidates on " & $os
      doAssert spec.macBundleIds.len == 0 or spec.macExecutable.len > 0,
        $b & " has mdfind bundle ids but no macExecutable"
      for rel in spec.windowsRelativePaths:
        doAssert '/' notin rel, $b & ": Windows paths use backslashes"
    else:
      doAssert not spec.supportsAppMode, $b & " is reserved: supportsAppMode must be false"
      doAssert not spec.hasAnyCandidates, $b & " is reserved: spec must be empty"
      doAssert spec.macExecutable.len == 0, $b & " is reserved: spec must be empty"

# --- Discovery ---------------------------------------------------------------

proc runMdfind(bundleId: string): seq[string] {.gcsafe.} =
  ## `mdfind` for a bundle id; one `.app` directory per line. Any failure
  ## (no `mdfind`, Spotlight disabled) is an empty result.
  when defined(macosx):
    try:
      let output = execProcess("mdfind",
        args = ["kMDItemCFBundleIdentifier == '" & bundleId & "'"],
        options = {poUsePath})
      for line in output.splitLines:
        let dir = line.strip
        if dir.len > 0:
          result.add dir
    except OSError, IOError:
      discard
  else:
    discard bundleId

proc readRegistryAppPath(exeName: string): string {.gcsafe.} =
  ## Default value of `App Paths\<exeName>` from HKCU, then HKLM; `""` when
  ## absent. Surrounding quotes are stripped.
  when defined(windows):
    for root in [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE]:
      try:
        let value = getUnicodeValue(WindowsAppPathsKey & exeName, "", root)
        if value.len > 0:
          return value.strip(chars = {'"', ' '})
      except OSError:
        discard
    ""
  else:
    discard exeName
    ""

proc systemDiscovery*(): Discovery =
  ## Probes that hit the real machine: `os.fileExists`, `os.findExe`,
  ## `os.getEnv`, `mdfind` via `execProcess` (macOS; empty elsewhere), and
  ## `std/registry` (Windows; empty elsewhere).
  Discovery(
    fileExists: proc(path: string): bool {.gcsafe.} = fileExists(path),
    findExe: proc(name: string): string {.gcsafe.} =
      findExe(name, followSymlinks = false),
    getEnv: proc(name: string): string {.gcsafe.} = getEnv(name),
    mdfind: runMdfind,
    registryAppPath: readRegistryAppPath)

proc checkDiscovery(d: Discovery) =
  doAssert d.fileExists != nil and d.findExe != nil and d.getEnv != nil and
    d.mdfind != nil and d.registryAppPath != nil,
    "Discovery: every probe must be set (use systemDiscovery() as a base)"

proc joinWindows(root, rel: string): string =
  ## `root\rel` without touching the host's path separator.
  root.strip(leading = false, chars = {'\\'}) & '\\' & rel

proc probeBrowser*(b: Browser; discovery: Discovery;
                   hostOs = CurrentHostOs): ProbeResult {.gcsafe.} =
  ## Looks for one supported, app-mode browser with the `hostOs` rules and
  ## records every location examined. `b` must be supported and not
  ## `Default`.
  doAssert b.isSupported and b != Default, "probeBrowser: " & $b & " is not probeable"
  checkDiscovery(discovery)
  let spec = BrowserSpecs[b]
  result = ProbeResult(browser: b)
  case hostOs
  of hoMacos:
    for p in spec.macAppPaths:
      var path = p
      if path.startsWith("~/"):
        let home = discovery.getEnv("HOME")
        if home.len == 0:
          continue
        path = home.strip(leading = false, chars = {'/'}) & path[1 .. ^1]
      result.candidates.add path
      if discovery.fileExists(path):
        result.path = path
        return
    for id in spec.macBundleIds:
      let dirs = discovery.mdfind(id)
      if dirs.len == 0:
        result.candidates.add "mdfind kMDItemCFBundleIdentifier == '" & id & "'"
      for dir in dirs:
        let path = dir.strip(leading = false, chars = {'/'}) & '/' & spec.macExecutable
        result.candidates.add path
        if discovery.fileExists(path):
          result.path = path
          return
  of hoWindows:
    for envName in WindowsProgramRoots:
      let root = discovery.getEnv(envName)
      if root.len == 0:
        continue
      for rel in spec.windowsRelativePaths:
        let path = joinWindows(root, rel)
        result.candidates.add path
        if discovery.fileExists(path):
          result.path = path
          return
    for key in spec.windowsAppPathsKeys:
      let value = discovery.registryAppPath(key)
      if value.len == 0:
        result.candidates.add "registry App Paths\\" & key
        continue
      result.candidates.add value
      if discovery.fileExists(value):
        result.path = value
        return
  of hoLinux:
    for name in spec.linuxExecutables:
      let path = discovery.findExe(name)
      if path.len > 0:
        result.candidates.add path
        result.path = path
        return
      result.candidates.add name & " (on PATH)"

proc firstAppModeBrowser(preferences: seq[Browser]): Browser =
  ## The browser whose launch rules an override uses.
  for b in preferences:
    if BrowserSpecs[b].supportsAppMode:
      return b
  Chrome

proc findBrowser*(preferences: seq[Browser]; browserPath = "";
                  discovery = systemDiscovery();
                  hostOs = CurrentHostOs): BrowserSearch {.gcsafe.} =
  ## Walks `preferences` in order and returns the first browser found with
  ## its executable path. `Default` in the list is always "found" (a
  ## default-browser tab), so anything after it is never probed. Reserved
  ## members are recorded in `skipped` and ignored. A non-empty `browserPath`
  ## wins without probing: it must exist (`NeelBrowserError` otherwise) and
  ## is launched as-is with app-mode flags. `found` is `none` when the whole
  ## list was probed without success (or the list is empty); `probed` then
  ## lists everything that was searched.
  checkDiscovery(discovery)
  if browserPath.len > 0:
    if not discovery.fileExists(browserPath):
      raise newException(NeelBrowserError,
        "browserPath '" & browserPath & "' does not exist")
    result.found = some FoundBrowser(
      browser: firstAppModeBrowser(preferences), path: browserPath,
      fromOverride: true)
    return
  for b in preferences:
    if b == Default:
      result.found = some FoundBrowser(browser: Default)
      return
    if b.isReserved:
      result.skipped.add b
      continue
    let probe = probeBrowser(b, discovery, hostOs)
    result.probed.add probe
    if probe.path.len > 0:
      result.found = some FoundBrowser(browser: b, path: probe.path)
      return

proc searchedNames*(s: BrowserSearch): seq[string] =
  ## Display names of the browsers probed, in order (for messages and the
  ## no-browser page).
  for p in s.probed:
    result.add p.browser.displayName

proc describeSearch*(s: BrowserSearch): seq[string] =
  ## One human-readable line per probed browser:
  ## `Google Chrome: <candidate>, <candidate>, ...`, followed by one line per
  ## skipped reserved member. Empty when nothing was probed or skipped.
  for p in s.probed:
    result.add p.browser.displayName & ": " & p.candidates.join(", ")
  for b in s.skipped:
    result.add b.displayName & ": reserved, not supported in this release"

proc noBrowserPageUrl*(baseUrl: string; s: BrowserSearch): string =
  ## `<baseUrl>/neel/no-browser?searched=Chrome,Chromium` (query omitted when
  ## nothing was probed). `baseUrl` is the server origin, e.g.
  ## `http://127.0.0.1:54321`; a trailing slash is tolerated.
  result = baseUrl.strip(leading = false, chars = {'/'}) & NoBrowserPath
  if s.probed.len > 0:
    var names: seq[string]
    for p in s.probed:
      names.add $p.browser
    result.add '?' & NoBrowserQueryParam & '=' & names.join(",")

# --- Launch ------------------------------------------------------------------

proc userDataDirFor*(windowId: int; pid = getCurrentProcessId();
                     tempDir = getTempDir()): string =
  ## `<tempDir>/neel-<pid>-<windowId>`: a profile directory private to one
  ## window of one app instance. Chromium creates it on first launch
  ## (`--no-first-run` suppresses the welcome flow); `removeUserDataDir`
  ## deletes it after the process is gone.
  doAssert windowId > 0, "userDataDirFor: window id must be positive"
  tempDir / ("neel-" & $pid & "-" & $windowId)

proc buildLaunchArgs*(url, userDataDir: string;
                      size = none(WindowSize); position = none(WindowPosition);
                      extraFlags: openArray[string] = []): seq[string] =
  ## The exact argument vector for an app-mode launch, in this order:
  ## `--app=<url>`, `--user-data-dir=<dir>`, `--window-size=W,H` (if
  ## `size`), `--window-position=X,Y` (if `position`),
  ## `--disable-http-cache`, `--no-first-run`, `--no-default-browser-check`,
  ## then `extraFlags` verbatim. Each element is one argv entry: nothing is
  ## quoted or escaped because no shell is involved. Pure. A non-positive
  ## width or height raises `ValueError`.
  doAssert url.len > 0, "buildLaunchArgs: url is empty"
  doAssert userDataDir.len > 0, "buildLaunchArgs: userDataDir is empty"
  result = @["--app=" & url, "--user-data-dir=" & userDataDir]
  if size.isSome:
    let (w, h) = size.get
    if w <= 0 or h <= 0:
      raise newException(ValueError,
        "window size must be positive, got " & $w & "x" & $h)
    result.add "--window-size=" & $w & "," & $h
  if position.isSome:
    let (x, y) = position.get
    result.add "--window-position=" & $x & "," & $y
  result.add "--disable-http-cache"
  result.add "--no-first-run"
  result.add "--no-default-browser-check"
  for flag in extraFlags:
    result.add flag

proc buildLaunchArgs*(url, userDataDir: string; opts: LaunchOptions): seq[string] =
  ## `buildLaunchArgs` over a `LaunchOptions` record.
  buildLaunchArgs(url, userDataDir, opts.size, opts.position, opts.extraFlags)

proc startBrowserProcess(path: string; args: seq[string]): Process {.gcsafe.} =
  ## `startProcess` with the browser's own stdio (a pipe nobody reads would
  ## eventually block Chromium's logging) and no console window on Windows.
  ## `path` is used as given, no `PATH` search.
  try:
    startProcess(path, args = args, options = {poParentStreams, poDaemon})
  except OSError as e:
    raise newException(NeelBrowserError,
      "could not start browser '" & path & "': " & e.msg, e)

proc launchBrowser*(found: FoundBrowser; url, userDataDir: string;
                    opts = LaunchOptions()): BrowserHandle {.gcsafe.} =
  ## Starts `found.path` in app mode with `buildLaunchArgs(url, userDataDir,
  ## opts)` and returns the handle owning the process. `found.browser` must
  ## not be `Default` (use `openDefaultBrowser`). Raises `NeelBrowserError`
  ## if the process cannot be started. The caller supplies `userDataDir`
  ## (normally `userDataDirFor(windowId)`); it must be unique per live window
  ## or the handle will not track the window (see the module header).
  doAssert found.browser != Default, "launchBrowser: Default has no executable"
  doAssert found.path.len > 0, "launchBrowser: empty executable path"
  let args = buildLaunchArgs(url, userDataDir, opts)
  BrowserHandle(kind: lkAppWindow, browser: found.browser, path: found.path,
                args: args, url: url, userDataDir: userDataDir,
                process: startBrowserProcess(found.path, args))

proc defaultBrowserCommand*(url: string; hostOs = CurrentHostOs): OpenerCommand =
  ## The OS opener invocation for `url`: `open <url>` (macOS), `xdg-open
  ## <url>` (Linux and other POSIX), `rundll32.exe url.dll,FileProtocolHandler
  ## <url>` (Windows). The URL is always a single argv element; no `cmd /c
  ## start`, no shell.
  doAssert url.len > 0, "defaultBrowserCommand: url is empty"
  case hostOs
  of hoMacos: OpenerCommand(command: "open", args: @[url])
  of hoLinux: OpenerCommand(command: "xdg-open", args: @[url])
  of hoWindows:
    OpenerCommand(command: "rundll32.exe",
                  args: @["url.dll,FileProtocolHandler", url])

proc openDefaultBrowser*(url: string): BrowserHandle {.gcsafe.} =
  ## Opens `url` in the OS default browser via `defaultBrowserCommand`. The
  ## opener normally exits within milliseconds; this waits up to
  ## `OpenerWaitMs` for it and raises `NeelBrowserError` if it cannot be
  ## started or exits non-zero (no URL handler). The returned handle has
  ## `kind == lkDefaultBrowser` and no process: a default-browser tab cannot
  ## be tracked or closed by Neel.
  let cmd = defaultBrowserCommand(url)
  var p: Process
  try:
    p = startProcess(cmd.command, args = cmd.args,
                     options = {poUsePath, poParentStreams, poDaemon})
  except OSError as e:
    raise newException(NeelBrowserError,
      "could not run '" & cmd.command & "' to open the default browser: " &
      e.msg, e)
  defer: p.close()
  # Poll instead of `waitForExit(timeout)`: on macOS/BSD the latter SIGKILLs
  # the child when the timeout expires.
  let deadline = getMonoTime() + initDuration(milliseconds = OpenerWaitMs)
  while p.running and getMonoTime() < deadline:
    sleep(10)
  if not p.running:
    let code = p.peekExitCode
    if code != 0:
      raise newException(NeelBrowserError,
        "'" & cmd.command & "' exited with code " & $code &
        " while opening " & url)
  BrowserHandle(kind: lkDefaultBrowser, browser: Default, path: cmd.command,
                args: cmd.args, url: url)

proc launchWithFallback*(search: BrowserSearch; url, errorPageUrl: string;
                         fallback: bool; userDataDir: string;
                         opts = LaunchOptions()): BrowserHandle {.gcsafe.} =
  ## Turns a `findBrowser` result into a window:
  ## - found with app mode -> `launchBrowser(found, url, userDataDir, opts)`;
  ## - found `Default` -> `openDefaultBrowser(url)`;
  ## - nothing found and `fallback` -> `openDefaultBrowser(url)`;
  ## - nothing found and not `fallback` -> `openDefaultBrowser(errorPageUrl)`
  ##   (best effort), then raises `NeelBrowserError` whose `searched` lists
  ##   the display names probed. The server must stay up long enough to serve
  ##   `errorPageUrl` (`noBrowserPageUrl`); that is the caller's job.
  if search.found.isSome:
    let found = search.found.get
    if found.browser == Default:
      return openDefaultBrowser(url)
    return launchBrowser(found, url, userDataDir, opts)
  if fallback:
    return openDefaultBrowser(url)
  var detail = ""
  try:
    discard openDefaultBrowser(errorPageUrl)
  except NeelBrowserError as e:
    detail = " (and the default browser could not be opened: " & e.msg & ")"
  let names = search.searchedNames
  var e = newException(NeelBrowserError,
    "no supported browser found (searched: " &
    (if names.len > 0: names.join(", ") else: "nothing") &
    ") and fallback is disabled" & detail)
  e.searched = names
  raise e

# --- Handle lifecycle --------------------------------------------------------

proc isRunning*(h: BrowserHandle): bool =
  ## `true` while the launched browser process is alive. Always `false` for
  ## `lkDefaultBrowser` and after `close`. On macOS a live process does not
  ## imply an open window (see `BrowserHandle`).
  h != nil and h.process != nil and h.process.running

proc pid*(h: BrowserHandle): int =
  ## OS process id of the browser process, `0` when none is tracked.
  if h != nil and h.process != nil: h.process.processID else: 0

proc exitCode*(h: BrowserHandle): int =
  ## Exit code once the process has exited; `-1` while running or when no
  ## process is tracked.
  if h == nil or h.process == nil or h.process.running: -1
  else: h.process.peekExitCode

proc terminate*(h: BrowserHandle; graceMs = TerminateGraceMs): bool =
  ## Asks the browser process to exit (SIGTERM / `TerminateProcess`), polls
  ## for up to `graceMs`, then kills it if it is still alive. Returns `true`
  ## if the process is gone afterwards (also when there was nothing to
  ## terminate). Measured on macOS: Chrome exits ~100 ms after SIGTERM with
  ## code 0, taking its helper processes with it; SIGKILL gives code 137.
  if h == nil or h.process == nil:
    return true
  if not h.process.running:
    return true
  h.process.terminate()
  let deadline = getMonoTime() + initDuration(milliseconds = max(graceMs, 0))
  while h.process.running and getMonoTime() < deadline:
    sleep(10)
  if h.process.running:
    h.process.kill()
    let hardDeadline = getMonoTime() + initDuration(milliseconds = 1000)
    while h.process.running and getMonoTime() < hardDeadline:
      sleep(10)
  not h.process.running

proc close*(h: BrowserHandle) =
  ## Releases the OS process handle (does not stop the process). Idempotent.
  ## Call after the process has exited or been `terminate`d.
  if h != nil and h.process != nil:
    h.process.close()
    h.process = nil

proc removeUserDataDir*(h: BrowserHandle) =
  ## Best-effort deletion of the window's profile directory. Only for
  ## `lkAppWindow` handles whose process is no longer running; a no-op
  ## otherwise and on any filesystem error.
  if h == nil or h.kind != lkAppWindow or h.userDataDir.len == 0:
    return
  if h.isRunning:
    return
  try:
    removeDir(h.userDataDir)
  except OSError:
    discard
