# Package

version       = "0.4.0"
author        = "Leon Lysak, Blane Lysak"
description   = "A Nim library for making lightweight Electron-like HTML/JS GUI apps, with full access to Nim capabilities."
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["neel"]
skipDirs      = @["examples","windows"]

# Dependencies

requires "nim >= 1.2.2"
requires "mummy"

import os

before install:
    when defined(Windows):
        try:
            mvFile(getCurrentDir() / "windows" / "rcedit-x86.exe", getHomeDir() / ".nimble" / "bin" / "rcedit-x86.exe")
        except:
            echo "could not move rcedit-x86.exe from neel into .nimble/bin directory"
            echo "in order for neel to bundle applications on Windows,"
            echo "rcedit-x86.exe must be downloaded and put in .nimble/bin or PATH"
            echo "reference: https://github.com/electron/rcedit/releases"
            
# can before uninstall be added to remove the rcedit binary?  
