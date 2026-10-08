## neel.nim - public surface of Neel 2.0.
##
## This is the only module an application imports. It will provide `startApp`
## (web directory, embed mode, port, worker pool size, call timeout, grace
## period, browser preferences, fallback, window size/position, extra browser
## flags) and re-export the user-facing pieces of the internal modules under
## `neel/`: the `expose` pragma, the `js` proxy, the window API (`openWindow`,
## `closeWindow`, `windows`, `currentWindow`), the `Browser` enum, `quit`, and
## the `Neel*Error` exception types.
##
## `startApp` is a macro: it generates the dispatch `case` over every proc bound
## with `{.expose.}`, wires the server, protocol, window, and browser modules
## together, and blocks the main thread until the last window closes (plus the
## grace period) or `quit` is called. Everything else lives in `neel/*.nim`; see
## `PLAN.md` "Module layout" for the responsibility of each.
##
## Assembly happens in Task 13; until then this module only carries the version.

const
  NeelVersion* = "2.0.0"
    ## Library version string, kept in sync with `neel.nimble`.
