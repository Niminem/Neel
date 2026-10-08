## t_browser.nim - spec table, discovery with injected probes, launch args,
## opener commands, and the no-browser page URL.
##
## Nothing here launches a process or depends on an installed browser: every
## probe goes through a canned `Discovery` and the launch side is exercised
## through the pure `buildLaunchArgs` / `defaultBrowserCommand` only.

import std/[unittest, options, strutils, sequtils, sets, tables, os]
import neel/browser

const
  ChromeMac = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  ChromeMacHome = "/Users/me/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  ChromiumMac = "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ChromeWin = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
  ChromeWinX86 = r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
  ChromeWinLocal = r"C:\Users\me\AppData\Local\Google\Chrome\Application\chrome.exe"
  ChromiumWin = r"C:\Program Files\Chromium\Application\chrome.exe"

type
  Fake = ref object
    ## Canned machine state plus a log of what discovery asked for.
    files: HashSet[string]
    exes: Table[string, string]
    env: Table[string, string]
    bundles: Table[string, seq[string]]
    registry: Table[string, string]
    asked: seq[string]

proc discovery(f: Fake): Discovery =
  Discovery(
    fileExists: proc(path: string): bool =
      f.asked.add "exists " & path
      path in f.files,
    findExe: proc(name: string): string =
      f.asked.add "findExe " & name
      f.exes.getOrDefault(name),
    getEnv: proc(name: string): string =
      f.asked.add "env " & name
      f.env.getOrDefault(name),
    mdfind: proc(id: string): seq[string] =
      f.asked.add "mdfind " & id
      f.bundles.getOrDefault(id),
    registryAppPath: proc(exe: string): string =
      f.asked.add "registry " & exe
      f.registry.getOrDefault(exe))

proc fake(files: openArray[string] = []; exes: openArray[(string, string)] = [];
          env: openArray[(string, string)] = [];
          bundles: openArray[(string, seq[string])] = [];
          registry: openArray[(string, string)] = []): Fake =
  Fake(files: files.toHashSet, exes: exes.toTable, env: env.toTable,
       bundles: bundles.toTable, registry: registry.toTable)

proc emptyFake(): Fake = fake()

suite "browser: spec table":
  test "Chrome, Chromium, Default are supported; the rest are reserved":
    check Chrome.isSupported
    check Chromium.isSupported
    check Default.isSupported
    for b in [Edge, Brave, Opera, Vivaldi]:
      check b.isReserved
      check not b.isSupported
    check not Chrome.isReserved
    check not Default.isReserved

  test "populated entries have candidates on every OS and app-mode support":
    for b in [Chrome, Chromium]:
      let spec = BrowserSpecs[b]
      check spec.supportsAppMode
      for os in HostOs:
        check spec.hasCandidates(os)
      check spec.macAppPaths.len >= 1
      check spec.macBundleIds.len >= 1
      check spec.macExecutable.len > 0
      check spec.windowsRelativePaths.len >= 1
      check spec.linuxExecutables.len >= 1

  test "Default has a name and no candidates anywhere":
    let spec = BrowserSpecs[Default]
    check spec.name == "Default browser"
    check not spec.supportsAppMode
    for os in HostOs:
      check not spec.hasCandidates(os)

  test "reserved members have a name only":
    for b in [Edge, Brave, Opera, Vivaldi]:
      let spec = BrowserSpecs[b]
      check spec.name.len > 0
      check not spec.supportsAppMode
      check spec.macAppPaths.len == 0
      check spec.macBundleIds.len == 0
      check spec.macExecutable.len == 0
      check spec.windowsRelativePaths.len == 0
      check spec.windowsAppPathsKeys.len == 0
      check spec.linuxExecutables.len == 0
      for os in HostOs:
        check not spec.hasCandidates(os)

  test "display names and expected supportsAppMode values":
    check Chrome.displayName == "Google Chrome"
    check Chromium.displayName == "Chromium"
    check Edge.displayName == "Microsoft Edge"
    check BrowserSpecs[Chrome].supportsAppMode
    check BrowserSpecs[Chromium].supportsAppMode
    check not BrowserSpecs[Default].supportsAppMode
    check not BrowserSpecs[Edge].supportsAppMode

  test "CurrentHostOs matches the compile target":
    when defined(macosx):
      check CurrentHostOs == hoMacos
    elif defined(windows):
      check CurrentHostOs == hoWindows
    else:
      check CurrentHostOs == hoLinux

suite "browser: probeBrowser per OS":
  test "macOS: fixed bundle path found first, nothing else asked":
    let f = fake(files = [ChromeMac])
    let r = probeBrowser(Chrome, f.discovery, hoMacos)
    check r.browser == Chrome
    check r.path == ChromeMac
    check r.candidates == @[ChromeMac]
    check f.asked == @["exists " & ChromeMac]

  test "macOS: ~/Applications is expanded with HOME":
    let f = fake(files = [ChromeMacHome], env = {"HOME": "/Users/me/"})
    let r = probeBrowser(Chrome, f.discovery, hoMacos)
    check r.path == ChromeMacHome
    check r.candidates == @[ChromeMac, ChromeMacHome]

  test "macOS: without HOME the ~ candidate is skipped, mdfind is the fallback":
    let app = "/Volumes/Apps/Google Chrome.app"
    let exe = app & "/Contents/MacOS/Google Chrome"
    let f = fake(files = [exe], bundles = {"com.google.Chrome": @[app & "/"]})
    let r = probeBrowser(Chrome, f.discovery, hoMacos)
    check r.path == exe
    check r.candidates == @[ChromeMac, exe]
    check "mdfind com.google.Chrome" in f.asked

  test "macOS: nothing found records every location including the mdfind query":
    let f = fake(env = {"HOME": "/Users/me"})
    let r = probeBrowser(Chromium, f.discovery, hoMacos)
    check r.path == ""
    check r.candidates == @[
      ChromiumMac,
      "/Users/me/Applications/Chromium.app/Contents/MacOS/Chromium",
      "mdfind kMDItemCFBundleIdentifier == 'org.chromium.Chromium'"]

  test "Windows: Program Files, then (x86), then LocalAppData":
    let env = {"ProgramFiles": r"C:\Program Files",
               "ProgramFiles(x86)": r"C:\Program Files (x86)",
               "LocalAppData": r"C:\Users\me\AppData\Local"}
    block:
      let f = fake(files = [ChromeWin, ChromeWinLocal], env = env)
      let r = probeBrowser(Chrome, f.discovery, hoWindows)
      check r.path == ChromeWin
      check r.candidates == @[ChromeWin]
    block:
      let f = fake(files = [ChromeWinLocal], env = env)
      let r = probeBrowser(Chrome, f.discovery, hoWindows)
      check r.path == ChromeWinLocal
      check r.candidates == @[ChromeWin, ChromeWinX86, ChromeWinLocal]
      check "registry chrome.exe" notin f.asked

  test "Windows: a trailing backslash on the root does not double up":
    let f = fake(files = [ChromeWin], env = {"ProgramFiles": "C:\\Program Files\\"})
    let r = probeBrowser(Chrome, f.discovery, hoWindows)
    check r.path == ChromeWin

  test "Windows: registry App Paths is the last resort and is checked for existence":
    let env = {"ProgramFiles": r"C:\Program Files"}
    block:
      let f = fake(files = [r"D:\Chrome\chrome.exe"], env = env,
                   registry = {"chrome.exe": r"D:\Chrome\chrome.exe"})
      let r = probeBrowser(Chrome, f.discovery, hoWindows)
      check r.path == r"D:\Chrome\chrome.exe"
      check r.candidates == @[ChromeWin, r"D:\Chrome\chrome.exe"]
    block:
      let f = fake(env = env, registry = {"chrome.exe": r"D:\Gone\chrome.exe"})
      let r = probeBrowser(Chrome, f.discovery, hoWindows)
      check r.path == ""
      check r.candidates == @[ChromeWin, r"D:\Gone\chrome.exe"]
    block:
      let f = fake(env = env)
      let r = probeBrowser(Chrome, f.discovery, hoWindows)
      check r.path == ""
      check r.candidates == @[ChromeWin, r"registry App Paths\chrome.exe"]

  test "Windows: Chromium does not consult the registry (would resolve to Chrome)":
    let f = fake(env = {"ProgramFiles": r"C:\Program Files"},
                 registry = {"chrome.exe": ChromeWin}, files = [ChromeWin])
    let r = probeBrowser(Chromium, f.discovery, hoWindows)
    check r.path == ""
    check r.candidates == @[ChromiumWin]
    for q in f.asked:
      check not q.startsWith("registry")

  test "Windows: unset roots are skipped":
    let f = fake()
    let r = probeBrowser(Chrome, f.discovery, hoWindows)
    check r.path == ""
    check r.candidates == @[r"registry App Paths\chrome.exe"]

  test "Linux: executables tried in order via findExe":
    block:
      let f = fake(exes = {"google-chrome-stable": "/usr/bin/google-chrome-stable"})
      let r = probeBrowser(Chrome, f.discovery, hoLinux)
      check r.path == "/usr/bin/google-chrome-stable"
      check r.candidates == @["google-chrome (on PATH)", "/usr/bin/google-chrome-stable"]
      check f.asked == @["findExe google-chrome", "findExe google-chrome-stable"]
    block:
      let f = fake()
      let r = probeBrowser(Chromium, f.discovery, hoLinux)
      check r.path == ""
      check r.candidates == @["chromium (on PATH)", "chromium-browser (on PATH)"]

  test "probing Default or a reserved member is a usage error":
    let f = fake()
    expect AssertionDefect:
      discard probeBrowser(Default, f.discovery, hoLinux)
    expect AssertionDefect:
      discard probeBrowser(Edge, f.discovery, hoLinux)

  test "a Discovery with a missing probe is rejected":
    var d = emptyFake().discovery
    d.mdfind = nil
    expect AssertionDefect:
      discard probeBrowser(Chrome, d, hoLinux)

suite "browser: findBrowser preference resolution":
  test "first preference found":
    let f = fake(files = [ChromeMac, ChromiumMac])
    let s = findBrowser(@[Chrome, Chromium], discovery = f.discovery, hostOs = hoMacos)
    check s.found.isSome
    check s.found.get.browser == Chrome
    check s.found.get.path == ChromeMac
    check not s.found.get.fromOverride
    check s.probed.len == 1
    check s.probed[0].browser == Chrome
    check s.skipped.len == 0
    # Chromium was never looked at.
    for q in f.asked:
      check "Chromium" notin q

  test "first preference missing, second found":
    let f = fake(exes = {"chromium": "/usr/bin/chromium"})
    let s = findBrowser(@[Chrome, Chromium], discovery = f.discovery, hostOs = hoLinux)
    check s.found.isSome
    check s.found.get.browser == Chromium
    check s.found.get.path == "/usr/bin/chromium"
    check s.probed.len == 2
    check s.probed[0].browser == Chrome
    check s.probed[0].path == ""
    check s.probed[1].browser == Chromium
    check s.searchedNames == @["Google Chrome", "Chromium"]

  test "nothing found: found is none and every browser is in probed":
    let f = fake()
    let s = findBrowser(@[Chrome, Chromium], discovery = f.discovery, hostOs = hoLinux)
    check s.found.isNone
    check s.probed.len == 2
    check s.searchedNames == @["Google Chrome", "Chromium"]
    check s.skipped.len == 0

  test "empty preference list: nothing found, nothing probed":
    let f = fake(files = [ChromeMac])
    let s = findBrowser(@[], discovery = f.discovery, hostOs = hoMacos)
    check s.found.isNone
    check s.probed.len == 0
    check f.asked.len == 0

  test "Default in the list is found immediately and stops the walk":
    block:
      let f = fake(files = [ChromeMac])
      let s = findBrowser(@[Default, Chrome], discovery = f.discovery, hostOs = hoMacos)
      check s.found.isSome
      check s.found.get.browser == Default
      check s.found.get.path == ""
      check s.probed.len == 0
      check f.asked.len == 0
    block:
      let f = fake()
      let s = findBrowser(@[Chrome, Default, Chromium], discovery = f.discovery,
                          hostOs = hoLinux)
      check s.found.isSome
      check s.found.get.browser == Default
      check s.probed.len == 1
      check s.probed[0].browser == Chrome
      check s.searchedNames == @["Google Chrome"]

  test "reserved members are skipped and recorded":
    let f = fake(exes = {"chromium": "/usr/bin/chromium"})
    let s = findBrowser(@[Edge, Brave, Chrome, Vivaldi, Chromium, Opera],
                        discovery = f.discovery, hostOs = hoLinux)
    check s.found.isSome
    check s.found.get.browser == Chromium
    check s.skipped == @[Edge, Brave, Vivaldi]
    check s.probed.len == 2
    for q in f.asked:
      check "edge" notin q.toLowerAscii
      check "brave" notin q.toLowerAscii

  test "only reserved members: nothing found, all skipped":
    let f = fake()
    let s = findBrowser(@[Edge, Opera], discovery = f.discovery, hostOs = hoMacos)
    check s.found.isNone
    check s.probed.len == 0
    check s.skipped == @[Edge, Opera]
    check f.asked.len == 0

  test "browserPath override that exists wins without probing":
    let f = fake(files = ["/opt/mybrowser"])
    let s = findBrowser(@[Chromium, Chrome], browserPath = "/opt/mybrowser",
                        discovery = f.discovery, hostOs = hoLinux)
    check s.found.isSome
    check s.found.get.path == "/opt/mybrowser"
    check s.found.get.fromOverride
    check s.found.get.browser == Chromium   # first app-mode preference
    check s.probed.len == 0
    check f.asked == @["exists /opt/mybrowser"]

  test "browserPath override with no app-mode preference launches as Chrome":
    let f = fake(files = ["/opt/mybrowser"])
    let s = findBrowser(@[Default], browserPath = "/opt/mybrowser",
                        discovery = f.discovery, hostOs = hoLinux)
    check s.found.get.browser == Chrome
    check s.found.get.fromOverride
    let s2 = findBrowser(@[], browserPath = "/opt/mybrowser",
                         discovery = f.discovery, hostOs = hoLinux)
    check s2.found.get.browser == Chrome

  test "browserPath override that does not exist raises NeelBrowserError":
    let f = fake(files = [ChromeMac])
    expect NeelBrowserError:
      discard findBrowser(@[Chrome], browserPath = "/nope/browser",
                          discovery = f.discovery, hostOs = hoMacos)
    try:
      discard findBrowser(@[Chrome], browserPath = "/nope/browser",
                          discovery = f.discovery, hostOs = hoMacos)
    except NeelBrowserError as e:
      check "/nope/browser" in e.msg
      check e.searched.len == 0
    # Discovery was not consulted beyond the override itself.
    check f.asked == @["exists /nope/browser", "exists /nope/browser"]

  test "the host OS defaults to the compile target":
    # Only shape: on this machine `CurrentHostOs` selects a branch that asks
    # at least one question for Chrome.
    let f = fake()
    discard findBrowser(@[Chrome], discovery = f.discovery)
    check f.asked.len > 0

suite "browser: search description and no-browser URL":
  test "describeSearch lists candidates per browser and the skipped members":
    let f = fake(env = {"HOME": "/Users/me"})
    let s = findBrowser(@[Edge, Chrome], discovery = f.discovery, hostOs = hoMacos)
    let lines = s.describeSearch
    check lines.len == 2
    check lines[0] == "Google Chrome: " & ChromeMac & ", " & ChromeMacHome &
      ", mdfind kMDItemCFBundleIdentifier == 'com.google.Chrome'"
    check lines[1] == "Microsoft Edge: reserved, not supported in this release"

  test "describeSearch is empty when nothing was probed or skipped":
    let f = fake()
    check findBrowser(@[Default], discovery = f.discovery, hostOs = hoLinux)
      .describeSearch.len == 0
    check findBrowser(@[], discovery = f.discovery, hostOs = hoLinux)
      .searchedNames.len == 0

  test "noBrowserPageUrl carries the route and the probed enum names":
    check NoBrowserPath == "/neel/no-browser"
    check NoBrowserQueryParam == "searched"
    let f = fake()
    let s = findBrowser(@[Chrome, Chromium], discovery = f.discovery, hostOs = hoLinux)
    check noBrowserPageUrl("http://127.0.0.1:54321", s) ==
      "http://127.0.0.1:54321/neel/no-browser?searched=Chrome,Chromium"
    # Trailing slash tolerated; names parse back as the enum.
    check noBrowserPageUrl("http://127.0.0.1:54321/", s) ==
      "http://127.0.0.1:54321/neel/no-browser?searched=Chrome,Chromium"
    let query = noBrowserPageUrl("http://h", s).split("=")[1]
    var back: seq[Browser]
    for n in query.split(","):
      back.add parseEnum[Browser](n)
    check back == @[Chrome, Chromium]

  test "noBrowserPageUrl without probes has no query":
    let f = fake()
    let s = findBrowser(@[Edge], discovery = f.discovery, hostOs = hoLinux)
    check noBrowserPageUrl("http://127.0.0.1:8000", s) ==
      "http://127.0.0.1:8000/neel/no-browser"

suite "browser: launch arguments":
  const
    Url = "http://127.0.0.1:54321/?window=1&x=a b"
    Dir = "/tmp/neel-123-1"
    Fixed = @["--disable-http-cache", "--no-first-run", "--no-default-browser-check"]

  test "full app-mode argv with size, position, and extra flags":
    let args = buildLaunchArgs(Url, Dir, some((1024, 768)), some((10, -20)),
                               ["--incognito", "--force-dark-mode"])
    check args == @["--app=" & Url, "--user-data-dir=" & Dir,
                    "--window-size=1024,768", "--window-position=10,-20"] &
                  Fixed & @["--incognito", "--force-dark-mode"]

  test "without size and position":
    let args = buildLaunchArgs(Url, Dir)
    check args == @["--app=" & Url, "--user-data-dir=" & Dir] & Fixed
    for a in args:
      check not a.startsWith("--window-size")
      check not a.startsWith("--window-position")

  test "size only / position only":
    check buildLaunchArgs(Url, Dir, size = some((800, 600))) ==
      @["--app=" & Url, "--user-data-dir=" & Dir, "--window-size=800,600"] & Fixed
    check buildLaunchArgs(Url, Dir, position = some((0, 0))) ==
      @["--app=" & Url, "--user-data-dir=" & Dir, "--window-position=0,0"] & Fixed

  test "the url is exactly one argument and is never quoted or escaped":
    let args = buildLaunchArgs(Url, "/tmp/dir with space")
    check args[0] == "--app=" & Url
    check args.count("--app=" & Url) == 1
    check args[1] == "--user-data-dir=/tmp/dir with space"
    for a in args:
      check '"' notin a
      check '\'' notin a
      check "%20" notin a
      check "\\ " notin a

  test "extra flags are appended verbatim, in order, after Neel's own flags":
    let extras = ["--z", "--a=1 2", "--z", "plain"]
    let args = buildLaunchArgs(Url, Dir, extraFlags = extras)
    check args[^4 .. ^1] == @extras
    check args[0 ..< args.len - 4] == @["--app=" & Url, "--user-data-dir=" & Dir] & Fixed

  test "LaunchOptions overload is equivalent":
    let opts = LaunchOptions(size: some((640, 480)), position: some((5, 6)),
                             extraFlags: @["--x"])
    check buildLaunchArgs(Url, Dir, opts) ==
      buildLaunchArgs(Url, Dir, some((640, 480)), some((5, 6)), ["--x"])
    check buildLaunchArgs(Url, Dir, LaunchOptions()) == buildLaunchArgs(Url, Dir)

  test "a non-positive size is a ValueError":
    expect ValueError:
      discard buildLaunchArgs(Url, Dir, size = some((0, 600)))
    expect ValueError:
      discard buildLaunchArgs(Url, Dir, size = some((800, -1)))

  test "empty url or user-data-dir is a usage error":
    expect AssertionDefect:
      discard buildLaunchArgs("", Dir)
    expect AssertionDefect:
      discard buildLaunchArgs(Url, "")

  test "user-data-dir policy: one private dir per window under the temp dir":
    check userDataDirFor(1, pid = 4242, tempDir = "/tmp") == "/tmp/neel-4242-1"
    check userDataDirFor(7, pid = 4242, tempDir = "/tmp/") == "/tmp/neel-4242-7"
    check userDataDirFor(1, pid = 4242, tempDir = "/tmp") !=
      userDataDirFor(2, pid = 4242, tempDir = "/tmp")
    check userDataDirFor(1, pid = 1, tempDir = "/tmp") !=
      userDataDirFor(1, pid = 2, tempDir = "/tmp")
    # Defaults: current pid and the real temp dir, but still nothing created.
    let d = userDataDirFor(3)
    check d.endsWith("neel-" & $getCurrentProcessId() & "-3")
    expect AssertionDefect:
      discard userDataDirFor(0)
    # The directory lands in the argv as the --user-data-dir flag.
    let args = buildLaunchArgs(Url, userDataDirFor(9, pid = 1, tempDir = "/t"))
    check args[1] == "--user-data-dir=/t/neel-1-9"

suite "browser: default-browser command":
  const Url = "http://127.0.0.1:54321/neel/no-browser?searched=Chrome,Chromium"

  test "macOS: open <url>":
    let c = defaultBrowserCommand(Url, hoMacos)
    check c.command == "open"
    check c.args == @[Url]

  test "Linux: xdg-open <url>":
    let c = defaultBrowserCommand(Url, hoLinux)
    check c.command == "xdg-open"
    check c.args == @[Url]

  test "Windows: rundll32.exe url.dll,FileProtocolHandler <url>":
    let c = defaultBrowserCommand(Url, hoWindows)
    check c.command == "rundll32.exe"
    check c.args == @["url.dll,FileProtocolHandler", Url]
    check "cmd" notin c.command
    for a in c.args:
      check "start" != a

  test "the url is a single unmodified argument on every OS":
    for os in HostOs:
      let c = defaultBrowserCommand(Url, os)
      check c.args[^1] == Url
      check c.args.count(Url) == 1
      for a in c.args:
        check '"' notin a

  test "defaults to the compile target":
    check defaultBrowserCommand(Url) == defaultBrowserCommand(Url, CurrentHostOs)

suite "browser: handle without a process":
  test "a nil or process-less handle is not running and is safe to query":
    var h: BrowserHandle
    check not h.isRunning
    check h.pid == 0
    check h.exitCode == -1
    check h.terminate()
    h.close()
    h.removeUserDataDir()
    let d = BrowserHandle(kind: lkDefaultBrowser, browser: Default,
                          path: "open", args: @["http://x"], url: "http://x")
    check not d.isRunning
    check d.pid == 0
    check d.terminate()
    d.close()
    d.removeUserDataDir()
    check d.kind == lkDefaultBrowser

  test "NeelBrowserError is a CatchableError with a searched list":
    var e = newException(NeelBrowserError, "x")
    e.searched = @["Google Chrome"]
    check e of CatchableError
    check e.searched == @["Google Chrome"]
