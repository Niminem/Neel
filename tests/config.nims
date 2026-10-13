# Compiler settings for every file under tests/.
# Puts src/ on the import path so tests can `import neel` and `import neel/<mod>`
# whether run through `nimble test` or directly with `nim c -r tests/t_x.nim`.
switch("path", "$projectDir/../src")
# Keep test output to the unittest report only.
switch("hints", "off")
switch("verbosity", "0")
