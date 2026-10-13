# Package

version       = "2.0.0"
author        = "Leon Lysak, Blane Lysak"
description   = "A Nim library for making lightweight Electron-like HTML/JS GUI apps, with full access to Nim capabilities."
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.12"

# Tests: nimble's built-in `nimble test` compiles and runs every `tests/t*.nim`
# (we name them `tests/t_<module>.nim`). Compiler flags for tests live in
# `tests/config.nims`.
