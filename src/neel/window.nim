## window.nim - `Window` type, connection <-> window mapping, and app lifecycle.
##
## A `Window` carries an id, the browser process handle from `browser.nim`,
## and a reference to its WebSocket connection. The mapping is established on
## upgrade from the window id that `neel.js` sends. Provides the multi-window
## API: `openWindow(path = "/", size, position, browsers, ...)`, `closeWindow`,
## `windows()`, `currentWindow()`, and open/close event hooks.
##
## Lifecycle is connection-count based: when the last connection closes a
## configurable grace period starts (3 s debug, 10 s release by default) and
## the app exits unless a window reconnects. `quit()` exits explicitly. On
## shutdown every pending Nim -> JS waiter fails cleanly.
##
## Implemented in Task 12.
