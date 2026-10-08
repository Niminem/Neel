## assets.nim - serving the application's web directory from disk or from
## compile-time embedded data.
##
## `startApp` takes `embedAssets: static bool = defined(release)`. In debug
## builds assets are read from disk on every request so edits show up on
## refresh; in release builds the whole web directory is `staticRead` into the
## binary. Both modes share the same lookup API, enforce path containment
## (no escaping the web root), and return real 404s for missing files. MIME
## types and `Range` handling come from `http.nim`.
##
## Implemented in Task 13.
