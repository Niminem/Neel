## frontend.nim - compile-time preparation of the browser-side shim.
##
## Reads `neel.js` (same directory) with `staticRead` and substitutes the
## placeholders `__NEEL_TOKEN__`, `__NEEL_WINDOW_ID__`, and `__NEEL_EXPOSED__`
## with the per-launch token, the window id, and the JSON list of exposed proc
## names, so that `/neel.js` can be served per window. Do not rename the
## placeholders without updating `neel.js`.
##
## Implemented in Task 10 together with `neel.js`.
