## t_browser.nim - spec table, discovery with injected probes, launch args,
## opener commands, and the no-browser page URL.
##
## Nothing here launches a browser or depends on an installed one: every
## probe goes through a canned `Discovery` and the launch side is exercised
## through the pure `buildLaunchArgs` / `defaultBrowserCommand` only. The
## profile sweep runs on canned `ProfileProbes`, plus one real-filesystem
## case in a private temp dir whose "dead app" is a short `nim --version`.

import std/[unittest, options, strutils, sequtils, sets, tables, os, osproc,
            monotimes, times]
import neel/browser

const
  ChromeMac = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  ChromeMacHome = "/Users/me/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  ChromiumMac = "/Applications/Chromium.app/Contents/MacOS/Chromium"
  ChromeWin = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
  ChromeWinX86 = r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
  ChromeWinLocal = r"C:\Users\me\AppData\Local\Google\Chrome\Application\chrome.exe"
  ChromiumWin = r"C:\Program Files\Chromium\Application\chrome.exe"
  EdgeMac = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
  EdgeWin = r"C:\Program Files\Microsoft\Edge\Application\msedge.exe"
  EdgeWinX86 = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
  EdgeFlags = @["--disable-sync", "--disable-extensions",
                "--disable-features=msImplicitSignin", "--no-service-autorun",
                "--edge-skip-compat-layer-relaunch"]

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
  test "Chrome, Chromium, Edge, Default are supported; the rest are reserved":
    check Chrome.isSupported
    check Chromium.isSupported
    check Edge.isSupported
    check Default.isSupported
    for b in [Brave, Opera, Vivaldi]:
      check b.isReserved
      check not b.isSupported
    check not Chrome.isReserved
    check not Edge.isReserved
    check not Default.isReserved

  test "populated entries have candidates on every OS and app-mode support":
    for b in [Chrome, Chromium, Edge]:
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
    for b in [Brave, Opera, Vivaldi]:
      let spec = BrowserSpecs[b]
      check spec.name.len > 0
      check not spec.supportsAppMode
      check spec.macAppPaths.len == 0
      check spec.macBundleIds.len == 0
      check spec.macExecutable.len == 0
      check spec.windowsRelativePaths.len == 0
      check spec.windowsAppPathsKeys.len == 0
      check spec.linuxExecutables.len == 0
      check spec.launchFlags.len == 0
      for os in HostOs:
        check not spec.hasCandidates(os)

  test "only Edge has browser-specific launch flags":
    check BrowserSpecs[Edge].launchFlags == EdgeFlags
    check BrowserSpecs[Chrome].launchFlags.len == 0
    check BrowserSpecs[Chromium].launchFlags.len == 0
    check BrowserSpecs[Default].launchFlags.len == 0

  test "display names and expected supportsAppMode values":
    check Chrome.displayName == "Google Chrome"
    check Chromium.displayName == "Chromium"
    check Edge.displayName == "Microsoft Edge"
    check BrowserSpecs[Chrome].supportsAppMode
    check BrowserSpecs[Chromium].supportsAppMode
    check BrowserSpecs[Edge].supportsAppMode
    check not BrowserSpecs[Default].supportsAppMode
    check not BrowserSpecs[Brave].supportsAppMode

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

  test "macOS: Edge bundle path, then mdfind by com.microsoft.edgemac":
    block:
      let f = fake(files = [EdgeMac])
      let r = probeBrowser(Edge, f.discovery, hoMacos)
      check r.path == EdgeMac
      check r.candidates == @[EdgeMac]
    block:
      let app = "/Volumes/Apps/Microsoft Edge.app"
      let exe = app & "/Contents/MacOS/Microsoft Edge"
      let f = fake(files = [exe], bundles = {"com.microsoft.edgemac": @[app]})
      let r = probeBrowser(Edge, f.discovery, hoMacos)
      check r.path == exe
      check r.candidates == @[EdgeMac, exe]
      check "mdfind com.microsoft.Edge" notin f.asked

  test "macOS: Edge falls back to the com.microsoft.Edge bundle id":
    let app = "/Volumes/Apps/Microsoft Edge.app"
    let exe = app & "/Contents/MacOS/Microsoft Edge"
    let f = fake(files = [exe], bundles = {"com.microsoft.Edge": @[app]})
    let r = probeBrowser(Edge, f.discovery, hoMacos)
    check r.path == exe
    check r.candidates == @[EdgeMac,
      "mdfind kMDItemCFBundleIdentifier == 'com.microsoft.edgemac'", exe]

  test "Windows: Edge under Program Files (x86), registry msedge.exe last":
    let env = {"ProgramFiles": r"C:\Program Files",
               "ProgramFiles(x86)": r"C:\Program Files (x86)"}
    block:
      let f = fake(files = [EdgeWinX86], env = env)
      let r = probeBrowser(Edge, f.discovery, hoWindows)
      check r.path == EdgeWinX86
      check r.candidates == @[EdgeWin, EdgeWinX86]
      check "registry msedge.exe" notin f.asked
    block:
      let f = fake(files = [r"D:\Edge\msedge.exe"], env = env,
                   registry = {"msedge.exe": r"D:\Edge\msedge.exe"})
      let r = probeBrowser(Edge, f.discovery, hoWindows)
      check r.path == r"D:\Edge\msedge.exe"
      check r.candidates == @[EdgeWin, EdgeWinX86, r"D:\Edge\msedge.exe"]
      check "registry chrome.exe" notin f.asked

  test "Linux: Edge executables tried in order via findExe":
    let f = fake(exes = {"microsoft-edge-stable": "/usr/bin/microsoft-edge-stable"})
    let r = probeBrowser(Edge, f.discovery, hoLinux)
    check r.path == "/usr/bin/microsoft-edge-stable"
    check f.asked == @["findExe microsoft-edge", "findExe microsoft-edge-stable"]

  test "probing Default or a reserved member is a usage error":
    let f = fake()
    expect AssertionDefect:
      discard probeBrowser(Default, f.discovery, hoLinux)
    expect AssertionDefect:
      discard probeBrowser(Brave, f.discovery, hoLinux)

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

  test "Chrome and Chromium missing on Windows: Edge is found third":
    let f = fake(files = [EdgeWinX86],
                 env = {"ProgramFiles": r"C:\Program Files",
                        "ProgramFiles(x86)": r"C:\Program Files (x86)"})
    let s = findBrowser(@[Chrome, Chromium, Edge], discovery = f.discovery,
                        hostOs = hoWindows)
    check s.found.isSome
    check s.found.get.browser == Edge
    check s.found.get.path == EdgeWinX86
    check s.searchedNames == @["Google Chrome", "Chromium", "Microsoft Edge"]

  test "reserved members are skipped and recorded":
    let f = fake(exes = {"chromium": "/usr/bin/chromium"})
    let s = findBrowser(@[Brave, Chrome, Vivaldi, Chromium, Opera],
                        discovery = f.discovery, hostOs = hoLinux)
    check s.found.isSome
    check s.found.get.browser == Chromium
    check s.skipped == @[Brave, Vivaldi]
    check s.probed.len == 2
    for q in f.asked:
      check "brave" notin q.toLowerAscii
      check "vivaldi" notin q.toLowerAscii

  test "only reserved members: nothing found, all skipped":
    let f = fake()
    let s = findBrowser(@[Brave, Opera], discovery = f.discovery, hostOs = hoMacos)
    check s.found.isNone
    check s.probed.len == 0
    check s.skipped == @[Brave, Opera]
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
    let s = findBrowser(@[Brave, Chrome], discovery = f.discovery, hostOs = hoMacos)
    let lines = s.describeSearch
    check lines.len == 2
    check lines[0] == "Google Chrome: " & ChromeMac & ", " & ChromeMacHome &
      ", mdfind kMDItemCFBundleIdentifier == 'com.google.Chrome'"
    check lines[1] == "Brave: reserved, not supported in this release"

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
    let s = findBrowser(@[Vivaldi], discovery = f.discovery, hostOs = hoLinux)
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

  test "Edge gets its sign-in, sync, background, and relaunch flags before the user's flags":
    let args = buildLaunchArgs(Edge, Url, Dir, LaunchOptions(extraFlags: @["--x"]))
    check args == @["--app=" & Url, "--user-data-dir=" & Dir] & Fixed &
                  EdgeFlags & @["--x"]
    check buildLaunchArgs(Edge, Url, Dir) ==
      @["--app=" & Url, "--user-data-dir=" & Dir] & Fixed & EdgeFlags

  test "Chrome and Chromium get no browser-specific flags":
    let opts = LaunchOptions(size: some((640, 480)), extraFlags: @["--x"])
    for b in [Chrome, Chromium]:
      check buildLaunchArgs(b, Url, Dir, opts) == buildLaunchArgs(Url, Dir, opts)

  test "per-browser argv for Default or a reserved member is a usage error":
    expect AssertionDefect:
      discard buildLaunchArgs(Default, Url, Dir)
    expect AssertionDefect:
      discard buildLaunchArgs(Brave, Url, Dir)

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
    check userDataDirFor(1, pid = 4242, tempDir = "/tmp") == "/tmp" / "neel-4242-1"
    check userDataDirFor(7, pid = 4242, tempDir = "/tmp/") == "/tmp" / "neel-4242-7"
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
    check args[1] == "--user-data-dir=" & ("/t" / "neel-1-9")

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

# --- abandoned profiles ------------------------------------------------------------

type
  ProfileFake = ref object
    ## Canned temp dir and process table plus a log of the probes asked.
    names: seq[string]
    alive: HashSet[int]
    held: HashSet[string]       # dirs a live browser holds
    existing: HashSet[string]   # for dirExists
    failList: bool
    failRemove: HashSet[string]
    failPid: HashSet[int]
    failLock: HashSet[string]
    askedPids: seq[int]
    askedLocks: seq[string]
    removed: seq[string]
    clockMs: int
    removeCostMs: int           # the fake clock advances this much per removeDir

proc probes(f: ProfileFake): ProfileProbes =
  ProfileProbes(
    listDirs: proc(dir: string): seq[string] =
      if f.failList:
        raise newException(OSError, "listing failed")
      f.names,
    dirExists: proc(dir: string): bool = dir in f.existing,
    pidAlive: proc(pid: int): bool =
      f.askedPids.add pid
      if pid in f.failPid:
        raise newException(OSError, "pid check failed")
      pid in f.alive,
    profileInUse: proc(dir: string): bool =
      f.askedLocks.add dir
      if dir in f.failLock:
        raise newException(OSError, "lock check failed")
      dir in f.held,
    removeDir: proc(dir: string) =
      f.clockMs += f.removeCostMs
      if dir in f.failRemove:
        raise newException(OSError, "cannot remove " & dir)
      f.removed.add dir
      f.existing.excl(dir),
    now: proc(): MonoTime = MonoTime() + initDuration(milliseconds = f.clockMs))

const
  Root = "/tmp"
  OwnPid = 500

proc sweep(f: ProfileFake; budgetMs = SweepBudgetMs): int =
  sweepProfiles(Root, ownPid = OwnPid, budgetMs = budgetMs, probes = f.probes)

suite "browser: abandoned profile sweep":
  test "names: only neel-<pid>-<windowId> with plain positive decimals parse":
    check parseUserDataDirName("neel-1-1") == (1, 1)
    check parseUserDataDirName("neel-4242-17") == (4242, 17)
    check parseUserDataDirName("neel-2147483647-3") == (2147483647, 3)
    check parseUserDataDirName(extractFilename(
      userDataDirFor(3, pid = 99, tempDir = "/tmp"))) == (99, 3)
    for bad in ["", "neel", "neel-", "neel-1", "neel-1-", "neel--1", "neel-1--2",
                "neel-+1-2", "neel--1-2", "neel-1-+2", "neel-1_000-2", "neel-0-1",
                "neel-1-0", "neel-01-2", "neel-1-02", "neel-1-2-3", "neel-1-2 ",
                " neel-1-2", "Neel-1-2", "NEEL-1-2", "neel-1-2x", "neel-a-b",
                "neel-1.5-2", "neel-2147483648-1", "neel-99999999999-1",
                "neel_1_2", "neel-1-2.old", "chrome-1-2", "other"]:
      check parseUserDataDirName(bad) == (0, 0)

  test "SingletonLock target: the pid after the last dash":
    check singletonLockPid("myhost-1234") == 1234
    check singletonLockPid("my-host.local-77") == 77
    for bad in ["", "nohost", "host-", "host-12a", "host--", "host-0", "host-+5"]:
      check singletonLockPid(bad) == 0

  test "garbage and unrelated names are ignored without any probe":
    let f = ProfileFake(names: @["other", "neel-x-1", "neel-1", "neel-7-1-2",
                                 "neel_7_1", "Neel-7-1", "neel-07-1"])
    check f.sweep() == 0
    check f.askedPids.len == 0
    check f.askedLocks.len == 0
    check f.removed.len == 0

  test "a live owner is skipped before its lock is looked at":
    let f = ProfileFake(names: @["neel-10-1"], alive: toHashSet([10]))
    check f.sweep() == 0
    check f.askedPids == @[10]
    check f.askedLocks.len == 0
    check f.removed.len == 0

  test "our own pid is never touched, whatever the probes say":
    let f = ProfileFake(names: @["neel-" & $OwnPid & "-1", "neel-" & $OwnPid & "-2"])
    check f.sweep() == 0
    check f.askedPids.len == 0
    check f.removed.len == 0

  test "a dead owner whose browser still holds the profile is skipped":
    let f = ProfileFake(names: @["neel-10-1"], held: toHashSet([Root / "neel-10-1"]))
    check f.sweep() == 0
    check f.askedLocks == @[Root / "neel-10-1"]
    check f.removed.len == 0

  test "a dead owner with no browser lock is deleted; the rest is left alone":
    let f = ProfileFake(
      names: @["neel-10-1", "other", "neel-11-2", "neel-12-1", "neel-13-1",
               "neel-" & $OwnPid & "-1"],
      alive: toHashSet([12]), held: toHashSet([Root / "neel-13-1"]))
    check f.sweep() == 2
    check f.removed == @[Root / "neel-10-1", Root / "neel-11-2"]

  test "the time budget stops the sweep part-way; the next sweep goes on":
    let f = ProfileFake(names: @["neel-1-1", "neel-2-1", "neel-3-1", "neel-4-1",
                                 "neel-5-1"],
                        removeCostMs: 1000)
    check f.sweep(budgetMs = 2000) == 2
    check f.removed == @[Root / "neel-1-1", Root / "neel-2-1"]
    check f.askedPids == @[1, 2]
    f.names = f.names[2 .. ^1]
    check f.sweep(budgetMs = 2000) == 2
    check f.removed.len == 4
    check ProfileFake(names: @["neel-1-1"]).sweep(budgetMs = 0) == 0

  test "the sweep never raises: listing, checks, and removal may all fail":
    let f = ProfileFake(failList: true)
    check f.sweep() == 0
    let g = ProfileFake(
      names: @["neel-1-1", "neel-2-1", "neel-3-1", "neel-4-1"],
      failRemove: toHashSet([Root / "neel-1-1"]), failPid: toHashSet([2]),
      failLock: toHashSet([Root / "neel-3-1"]))
    check g.sweep() == 1
    check g.removed == @[Root / "neel-4-1"]
    check g.askedPids == @[1, 2, 3, 4]

  test "incomplete probes are a usage error":
    var p = ProfileFake().probes
    p.now = nil
    expect AssertionDefect:
      discard sweepProfiles(Root, probes = p)
    expect AssertionDefect:
      clearStaleUserDataDir(Root / "neel-1-1", p)

  test "a stale dir with our pid is deleted before launch; nothing else is done":
    let dir = userDataDirFor(4, pid = OwnPid, tempDir = Root)
    let f = ProfileFake(existing: toHashSet([dir]))
    clearStaleUserDataDir(dir, f.probes)
    check f.removed == @[dir]
    check dir notin f.existing
    let g = ProfileFake()
    clearStaleUserDataDir(dir, g.probes)
    check g.removed.len == 0
    let h = ProfileFake(existing: toHashSet([dir]), failRemove: toHashSet([dir]))
    clearStaleUserDataDir(dir, h.probes) # in use: ignored, the launch goes on
    check dir in h.existing

  test "real filesystem: only the dead app's free profile is deleted":
    const NimExe = getCurrentCompilerExe()
    let root = getTempDir() / ("neel_t_browser_sweep_" & $getCurrentProcessId())
    let own = getCurrentProcessId()
    removeDir(root)
    createDir(root)
    # A process that has exited is our dead app. The `Process` stays open
    # until the end so Windows cannot hand its pid to someone else.
    let p = startProcess(NimExe, args = ["--version"])
    defer: p.close()
    check p.waitForExit() == 0
    let dead = p.processID
    let real = systemProfileProbes()
    check not real.pidAlive(dead)
    check real.pidAlive(own)
    let free = root / ("neel-" & $dead & "-1")
    let held = root / ("neel-" & $dead & "-2")
    let mine = root / ("neel-" & $own & "-1")
    let garbage = root / ("neel-" & $dead & "-x")
    let unrelated = root / ("notes-" & $dead & "-1")
    let plainFile = root / ("neel-" & $dead & "-3")
    for d in [free / "Default", held, mine, garbage, unrelated]:
      createDir(d)
    writeFile(free / "Default" / "Preferences", "{}")
    writeFile(mine / "Preferences", "{}")
    writeFile(plainFile, "not a dir")
    when defined(windows):
      # Chromium keeps `lockfile` open without delete sharing; so does fopen.
      var lock = open(held / "lockfile", fmWrite)
    else:
      createSymlink("somehost-" & $own, held / "SingletonLock")
      let target = root / "target"
      createDir(target)
      writeFile(target / "keep", "x")
      createSymlink(target, root / ("neel-" & $dead & "-4"))
    try:
      check sweepProfiles(root, ownPid = own) == 1
      check not dirExists(free)
      check dirExists(held)
      check dirExists(mine)
      check fileExists(mine / "Preferences")
      check dirExists(garbage)
      check dirExists(unrelated)
      check fileExists(plainFile)
      when not defined(windows):
        check fileExists(root / "target" / "keep")
        check symlinkExists(root / ("neel-" & $dead & "-4"))
      # The pre-launch check on a real dir.
      clearStaleUserDataDir(mine)
      check not dirExists(mine)
      clearStaleUserDataDir(mine)
    finally:
      when defined(windows):
        lock.close()
      removeDir(root)
