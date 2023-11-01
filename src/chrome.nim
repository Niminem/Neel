import std/[strutils, os, sequtils, osproc]

type BrowserNotFound = object of CatchableError

proc findChromeMac: string =
    const defaultPath :string = r"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    const name = "Google Chrome.app"

    try:
        if fileExists(absolutePath(defaultPath)):
            result = defaultPath.replace(" ", r"\ ")
        else:
            var alternateDirs = execProcess("mdfind", args = [name], options = {poUsePath}).split("\n")
            alternateDirs.keepItIf(it.contains(name))
        
            if alternateDirs != @[]:
                result = alternateDirs[0] & "/Contents/MacOS/Google Chrome"
            else:
                raise newException(BrowserNotFound, "could not find Chrome using `mdfind`")

    except:
        raise newException(BrowserNotFound, "could not find Chrome in Applications directory")


when defined(Windows):
    import std/registry

proc findChromeWindows: string =
    const defaultPath = r"\Program Files (x86)\Google\Chrome\Application\chrome.exe"
    const backupPath = r"\Program Files\Google\Chrome\Application\chrome.exe"
    if fileExists(absolutePath(defaultPath)):
        result = defaultPath
    elif fileExists(absolutePath(backupPath)):
        result = backupPath
    else:
        when defined(Windows):
            result = getUnicodeValue(
                path = r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
                key = "", handle = HKEY_LOCAL_MACHINE)
        discard

    if result.len == 0:
        raise newException(BrowserNotFound, "could not find Chrome")


proc findChromeLinux: string =
    const chromeNames = ["google-chrome", "google-chrome-stable", "chromium-browser", "chromium"]
    for name in chromeNames:
        if execCmd("which " & name) == 0:
            return name
    raise newException(BrowserNotFound, "could not find Chrome")


proc findPath: string =
    when hostOS == "macosx":
        result = findChromeMac()
    elif hostOS == "windows":
        result = findChromeWindows()
    elif hostOS == "linux":
        result = findChromeLinux()
    else:
        raise newException(BrowserNotFound, "unkown OS in findPath() for neel.nim")


proc openChrome*(portNo: int, chromeFlags: seq[string]) =
    var command = " --app=http://localhost:" & portNo.intToStr & "/ --disable-http-cache"
    if chromeFlags != @[""]:
        for flag in chromeFlags:
            command = command & " " & flag.strip
    let finalCommand = findPath() & command
    if execCmd(finalCommand) != 0:
        raise newException(BrowserNotFound, "could not open Chrome browser")