# Package

version       = "0.4.0"
author        = "Leon Lysak, Blane Lysak"
description   = "A Nim library for making lightweight Electron-like HTML/JS GUI apps, with full access to Nim capabilities."
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["neel"]

# Dependencies

requires "nim >= 1.2.2"
requires "jester >= 0.5.0"
requires "ws >= 0.4.2"