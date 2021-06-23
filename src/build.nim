import os, strutils

var plistFile = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>APP_BINARY</string>
  <key>CFBundleIconFile</key>
  <string>APP_LOGO</string>
  <key>CFBundleShortVersionString</key>
  <string>0.01</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>IFMajorVersion</key>
  <integer>0</integer>
  <key>IFMinorVersion</key>
  <integer>1</integer>
</dict>
</plist>"""

proc buildMac*(params: seq[TaintedString]) =
    let appName = params[1].replace("--app:","")
    let appBinary = params[2].replace("--bin:","")
    let icon = params[3].replace("--icon:","")
    let appDir = appName & ".app"

    createDir(appDir)
    createDir(appDir / "Contents")
    createDir(appDir / "Contents/Frameworks")
    createDir(appDir / "Contents/MacOs")
    createDir(appDir / "Contents/Resources")

    plistFile = plistFile.multiReplace([("APP_NAME",appName),
                                        ("APP_BINARY",appBinary),
                                        ("APP_LOGO",icon)])

    writeFile(appDir / "Contents/info.plist",plistFile)
    copyFile(getCurrentDir() / icon, appDir / "Contents/Resources" / icon)
    let res = execShellCmd("cp " & appBinary & " " & "\"" & appDir & "/Contents/MacOs/" & appBinary & "\"")
    if res != 0:
        raise OSError.newException("there was a problem moving the binary into the MacOs directory")