# Neel

Neel is a Nim library for desktop applications whose user interface is HTML,
CSS, and JavaScript. The Nim program runs a small HTTP/WebSocket server on
`127.0.0.1`, opens Chrome or Chromium in app mode on it, and bridges the two
sides: a Nim proc marked `{.expose.}` becomes `neel.<name>(...)` in the page
and returns a Promise; a JS function registered with `neel.expose` becomes
`js.<name>(...)` in Nim, with `js.wait.<name>(...)` when a return value is
needed. Neel 2.0 is inspired by Python's [Eel](https://github.com/python-eel/Eel).

Requirements: Nim >= 2.2.0, no external packages. Supported browsers in this
release: Google Chrome and Chromium (app mode), or a tab in the OS default
browser.

Contents

- [Installation](#installation)
- [Running the examples](#running-the-examples)
- [Quick start](#quick-start)
- [Exposing Nim procs to the page](#exposing-nim-procs-to-the-page)
- [Calling the page from Nim: `js`](#calling-the-page-from-nim-js)
- [The `neel.js` API](#the-neeljs-api)
- [Windows](#windows)
- [Browsers and fallback](#browsers-and-fallback)
- [Lifecycle](#lifecycle)
- [Assets and build modes](#assets-and-build-modes)
- [Threading model](#threading-model)
- [`startApp` parameters](#startapp-parameters)
- [Caveats](#caveats)
- [The examples](#the-examples)
- [Migrating from Neel 1.x](#migrating-from-neel-1x)

## Installation

```
nimble install neel
```

Neel depends on nothing but the Nim standard library (the SHA-1 needed for the
WebSocket handshake is hand-rolled). ORC and threads are the Nim 2 defaults;
no compiler flags are required.

`import neel` brings in everything an application needs, including `std/json`
(`JsonNode`, `getStr`, `getInt`, `.to(T)`, `%*`, `parseJson`) and
`std/options` (`some`, `none`, `isSome`, `get`), because the API hands out
`JsonNode` and `Option` values. Other standard modules (`std/os`,
`std/strutils`, ...) are not re-exported; import them yourself.

## Running the examples

From a fresh clone, no setup is needed — the repository's `config.nims` adds
`src/` to the compiler's path automatically:

```
git clone https://github.com/Niminem/Neel.git
cd Neel
```

Then, from any working directory inside the repo:

```
nim c -r examples/filepicker/filepicker.nim
nim c -r examples/roundtrip/roundtrip.nim
nim c -r examples/stresstest/stresstest.nim
```

These are debug builds: the example's `web/` directory is served from disk,
so edits to the page show up on refresh, and the app exits 3 s after its last
window closes. A release build embeds `web/` into the binary at compile time,
so the binary can be moved anywhere (the grace period is 10 s there):

```
nim c -d:release examples/filepicker/filepicker.nim && ./examples/filepicker/filepicker
```

Expect Chromium's own stderr noise in the terminal: the browser inherits the
application's stdio (a pipe nobody reads would eventually stall the browser).

The test suite runs with `nimble test`; it needs no browser.

## Quick start

This is `examples/filepicker`, complete. The layout is one Nim file next to a
`web/` directory:

```
filepicker/
  filepicker.nim
  web/
    index.html
    main.js
    style.css
```

`filepicker.nim`:

```nim
import std/[os, random]
import neel

type
  MissingDirectoryError = object of CatchableError
    ## The directory does not exist (shown in the page as `e.name`).
  EmptyDirectoryError = object of CatchableError
    ## The directory exists but has no entries.

proc filePicker(directory: string): string {.expose.} =
  ## Returns the name of a random entry of `directory`, resolved against the
  ## home directory unless absolute. Exposed procs run on worker threads, so
  ## a per-call `Rand` is used instead of the global random state.
  let dir = absolutePath(directory, root = getHomeDir())
  if not dirExists(dir):
    raise newException(MissingDirectoryError, "no such directory: " & dir)
  var names: seq[string]
  for _, path in walkDir(dir):
    names.add path.extractFilename
  if names.len == 0:
    raise newException(EmptyDirectoryError, "the directory is empty: " & dir)
  var rng = initRand()
  rng.sample(names)

startApp()
```

`web/index.html` (the `/neel.js` script must come before the app's own
script; asset paths are absolute because the web directory is served at `/`):

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Neel file picker</title>
  <link rel="icon" href="data:,">
  <link rel="stylesheet" href="/style.css">
  <script src="/neel.js"></script>
  <script src="/main.js" defer></script>
</head>
<body>
  <h1>File picker</h1>
  <p>
    Enter a directory (relative to your home directory, or absolute) and Nim
    picks a random entry from it.
  </p>
  <form id="form">
    <input id="directory" type="text" value="Desktop" autocomplete="off" spellcheck="false">
    <button id="pick" type="submit">Pick a random entry</button>
  </form>
  <p id="result" class="result"></p>
  <p id="error" class="error"></p>
</body>
</html>
```

`web/main.js`:

```js
"use strict";

const form = document.getElementById("form");
const input = document.getElementById("directory");
const button = document.getElementById("pick");
const result = document.getElementById("result");
const error = document.getElementById("error");

async function pick() {
  button.disabled = true;
  result.textContent = "";
  error.textContent = "";
  try {
    const name = await neel.filePicker(input.value);
    result.textContent = name;
  } catch (e) {
    error.textContent = e.name + ": " + e.message;
  } finally {
    button.disabled = false;
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  pick();
});
```

`nim c -r filepicker.nim` opens an app-mode Chrome window. Pressing the button
calls the Nim proc; its return value resolves the Promise; a raised
`MissingDirectoryError` rejects it with an `Error` whose `name` is
`"MissingDirectoryError"` and whose `message` is the Nim message. Closing the
window ends the program a few seconds later.

What happened: `startApp()` found a browser, bound an ephemeral port on
`127.0.0.1`, generated a random launch token, opened the browser at
`http://127.0.0.1:<port>/?window=1`, and served `web/index.html`. The page
loaded `/neel.js`, which is rendered per window with the token, the window id,
and the list of exposed proc names, and connected a WebSocket to `/ws`.
`startApp` returned when the connection count had been zero for the grace
period.

## Exposing Nim procs to the page

```nim
proc add(a, b: int): int {.expose.} =
  a + b
```

`{.expose.}` on a top-level `proc` or `func` generates a wrapper that converts
JSON arguments to the parameter types, calls the proc, and converts the result
back, and registers the name at compile time. `startApp` then generates the
dispatcher over every registered name, and `/neel.js` gets a `neel.add`
function.

Rules:

- The proc must be top-level, non-generic, and GC-safe (it runs on a worker
  thread; see [Threading model](#threading-model)). Overloads cannot share an
  exposed name. Operator names, templates, iterators, forward declarations,
  and `varargs` / `var` / `ptr` / `openArray` / `sink` / proc-typed
  parameters are rejected at compile time with a message at the parameter.
- Exposed names must be unique across all modules (they become `neel.<name>`);
  a duplicate is a compile error naming both locations.
- `startApp` must come after every `{.expose.}` proc in the module and after
  the imports of modules that contain exposed procs. It may sit inside
  `proc main()`. A proc exposed after the `startApp` call is not dispatched
  (the page gets `NeelUnknownProcError`).
- The names `call`, `send`, `expose`, `ready`, `windowId`, `close`,
  `connected`, `onclose`, `onreconnect` are reserved by the `neel` object; an
  exposed proc with one of those names is reachable only as
  `neel.call("name", ...)`.

Supported parameter and result types (conversion via `std/jsonutils`):
`bool`; integer types; float types (a JSON integer is accepted for a float
parameter); `string` (JSON `null` becomes `""`); enums (argument by name or
ordinal, result as the name); `seq`, `array`, `set` (from a JSON array);
tuples; objects (extra keys are ignored, missing keys are an error); `ref T`
(`null` <-> `nil`); `distinct` types; `Option[T]` (`null` <-> `none`);
`Table[string, V]` and `OrderedTable` (from a JSON object); `HashSet` and
`OrderedSet` (from an array); `JsonNode` (passed through). A user
`fromJsonHook` / `toJsonHook` is honoured; it must raise a `CatchableError`,
not `assert`.

Default parameter values work positionally: a JS call may pass only the
leading arguments.

```nim
proc withDefaults(a: int; b = 10; c = "default"): string {.expose.} =
  "a=" & $a & " b=" & $b & " c=" & c
```

`neel.withDefaults(1)`, `neel.withDefaults(1, 2)`, and
`neel.withDefaults(1, 2, "three")` are all valid; `neel.withDefaults()` is a
`NeelArgumentError`.

Return values: any supported type, or nothing (a `void` proc resolves the
Promise with `null`). A `JsonNode` result is sent as is (`nil` is `null`).

Errors the page sees, as the `name` / `message` of the rejection:

| `e.name` | `e.message` | When |
|---|---|---|
| `NeelArgumentError` | `add: expected 2 arguments, got 1` | wrong count (`expected 1 argument, got 0`, `expected 1 to 3 arguments, got 4`) |
| `NeelArgumentError` | `add: argument 'a' expects int, got string` | wrong type; the kind is one of `null`, `boolean`, `integer`, `float`, `string`, `array`, `object`, optionally followed by `: <detail>` (e.g. a missing object key or an invalid enum value) |
| `NeelUnknownProcError` | `no exposed proc named 'bogus'` | only reachable through `neel.call("bogus")` |
| the Nim exception type name | the exception's `msg` | any `CatchableError` raised by the proc (`ValueError`, your own types, ...) |
| the JS error name | the JS message | a `js.wait.*` call inside the proc failed on the JS side; the kind is forwarded unchanged |

Defects (`IndexDefect`, `AssertionDefect`, ...) are bugs and are not caught.

A fire-and-forget call (`neel.add.send(1, 2)`) never gets a reply, even on
failure. In debug builds a failing fire-and-forget call is written to stderr
as `neel: fire-and-forget call 'add' raised NeelArgumentError: ...`; release
builds print nothing.

## Calling the page from Nim: `js`

`js` is a global proxy value. A method call on it with any name sends a `call`
message to the page, where the shim looks the name up among the functions
registered with `neel.expose` and then on `globalThis`:

```nim
proc notify(text: string) {.expose.} =
  js.showToast(text)   # fire-and-forget, returns nothing
```

Three forms:

| Form | Returns | Behaviour |
|---|---|---|
| `js.foo(a, b)` | nothing (`void`) | sends and returns at once; no reply is ever expected; a closing connection swallows it silently |
| `js.wait.foo(a, b)` | `JsonNode` | sends with an id and blocks the calling thread until the reply, up to `callTimeoutMs` (default `DefaultCallTimeoutMs` = 10 000 ms) |
| `js.wait(500).foo(a, b)` | `JsonNode` | same with an explicit timeout in milliseconds (non-positive means the default) |

Arguments may be any expression of a type the result conversion supports
(the list above: scalars, `string`, enums as names, `seq`, objects, `Option`,
`Table[string, V]`, `JsonNode`, ...). `nil` has no type; pass `newJNull()`.

Unpack the `JsonNode` with `std/json` (re-exported by `neel`):

```nim
proc askPage(question: string): string {.expose.} =
  let reply = js.wait.answer(question)
  "the page answered: " & reply.getStr

proc reenter(): int {.expose.} =
  js.wait.callBackIntoNim().getInt
```

`js.wait.foo(...).to(MyObject)` converts into a typed value.

Which window: inside an exposed proc `js` targets the window whose page made
the call (a thread-local that the dispatcher sets around every call). Anywhere
else (the main thread, a thread you started, an `onWindowOpen` hook) there is
no current window and `js.*` raises `NeelNoWindowError`; target a window
explicitly through its `Window` handle instead:

```nim
proc broadcast(msg: string): int {.expose.} =
  for w in windows():
    try:
      w.js.onBroadcast(msg, currentWindowId())
      inc result
    except NeelNoWindowError:
      discard  # listed but not connected (loading, or closed by the user)
```

`win.js.foo(...)`, `win.js.wait.foo(...)`, and `win.js.wait(500).foo(...)` work
the same as the global forms; `requireWindow(id).js.wait(5000).ask("...")`
targets a window by id.

Exceptions (all `CatchableError`, so an exposed proc that lets one escape
answers the page with that kind):

| Exception | Raised when |
|---|---|
| `NeelNoWindowError` | no current window on this thread; the target window is unknown, closed, or not connected; Neel is not running |
| `NeelRemoteError` | the JS function threw or its promise rejected; `e.kind` is the JS error name (`"RangeError"`, a custom `e.name`), `e.msg` the JS message; `NeelUnknownFunctionError` when the page has no such function |
| `NeelTimeoutError` | no reply within the timeout: `no reply for id 3 on connection 7 within 5000 ms`; a late reply is dropped |
| `NeelDisconnectedError` | the connection closed before the reply (`connection 7 closed while waiting for id 3`), or the send itself failed because the connection was closing |

Fire-and-forget (`js.foo(...)`) raises only `NeelNoWindowError`.

Escape hatch: `js.foo(...)` is sugar for `jsSend(js, "foo", @[...])` and
`js.wait.foo(...)` for `jsCallWait(js.wait, "foo", @[...])`; both take the
name as a `string` and the arguments as a `seq[JsonNode]`. Use them for
dynamic names and for names that collide with Nim procs: Nim's method-call
syntax wins over the dot operator, so `js.echo("x")` calls Nim's `echo`,
`js.repr()` calls `repr`, and `js.console.log(...)` does not compile. (`js.len()`,
`js.add(...)`, `js.close()`, `js.open()`, `js.alert(...)` reach the page as
intended.)

```nim
proc jsEcho(text: string) {.expose.} =
  jsSend(js, "echo", @[%text])

proc describe(name: string): string {.expose.} =
  jsCallWait(js.wait(2000), name, @[]).getStr
```

## The `neel.js` API

`GET /neel.js` serves the browser shim rendered for one window: the launch
token, the window id, and the exposed proc names are substituted into it, and
it is sent with `Cache-Control: no-store`. Load it as a classic script before
the application's own scripts (`<script src="/neel.js"></script>`). It installs
one global, `neel`. Module scripts cannot `import` it; they read `window.neel`,
which exists once the classic script has run.

| Member | Description |
|---|---|
| `neel.<name>(...args)` | one function per exposed Nim proc; returns a Promise resolved with the return value (`null` for a `void` proc) or rejected with an `Error` |
| `neel.<name>.send(...args)` | fire-and-forget: returns `undefined`, never answered, failures are not reported |
| `neel.call(name, ...args)` | the Promise form for a name given as a string (reserved names, dynamic names); `TypeError` if `name` is not a string |
| `neel.send(name, ...args)` | the fire-and-forget form for a name given as a string |
| `neel.expose(fn)` | registers `fn` under `fn.name` as a target for Nim's `js.<name>`; `TypeError` for an anonymous function |
| `neel.expose(name, fn)` | registers `fn` under `name` |
| `neel.expose({name: fn, ...})` | registers every entry; `TypeError` if a value is not a function |
| `neel.ready` | Promise resolved on the first successful connection; rejected with `NeelDisconnectedError` if the shim gives up or is closed before ever connecting (nobody has to await it) |
| `neel.windowId` | the window's id (a positive number) |
| `neel.connected` | `true` while the WebSocket is open |
| `neel.onclose(fn)` | `fn(code, reconnecting)` is called exactly once per lost or closed connection: `code` is the WebSocket close code (1006 lost, 1000 `neel.close()` / `closeWindow`, 1001 shutdown; `null` only if the shim gave up without a socket event), `reconnecting` is `true` when a retry follows |
| `neel.onreconnect(fn)` | `fn()` is called after every successful connection except the first (which resolves `neel.ready`) |
| `neel.close()` | closes the connection with code 1000 and makes every later call reject; the shim does not reconnect |

`Object.keys(neel)` is exactly this list plus the exposed names. Loading
`neel.js` twice is a no-op with a console warning.

Rejections carry an `Error` whose `name` and `kind` are both the wire kind and
whose `message` is the wire message, so `catch (e) { if (e.name ===
"ValueError") ... }` works. Besides the kinds listed under
[Exposing Nim procs](#exposing-nim-procs-to-the-page), the shim itself rejects
with `NeelDisconnectedError` when a pending call's connection closes for any
reason (`neel: connection lost (close code 1006)`), when a call is made after
the shim has terminated (`neel: connection is closed`), and when queued calls
are dropped because the retries ran out (`neel: gave up reconnecting after 5
attempts`).

Nim -> JS calls: `js.foo(1, "x")` arrives as a call of `foo(1, "x")`. The shim
looks the name up in the `neel.expose` registry first, then as a function on
`globalThis` (so a Nim call to a global such as `alert` works). The result is
awaited if it is a thenable, `undefined` becomes `null`, and a reply is sent
only when the call had an id (`js.wait`). A thrown value is answered with
`kind` = `e.name` (or `"Error"` when the thrown value has no string `name`)
and `msg` = `String(e.message ?? e)`; an unknown name is answered with
`NeelUnknownFunctionError` and `no exposed JS function named 'foo'`. Without an
id, an unknown name or a throw is a `console.warn`.

Queueing: calls (both forms) made before the socket is open, or while it
reconnects, are queued and flushed in order on open. Replies to Nim are never
queued; they go only to the socket the call arrived on.

Reconnect: on a close with any code other than 1000 or 1001 that was not
caused by `neel.close()`, in-flight Promises are rejected with
`NeelDisconnectedError` and the shim reconnects up to 5 times with delays of
250, 500, 1000, 2000, and 4000 ms (7.75 s in total), presenting the same token
and window id. A successful open resets the counter and flushes the queue.
After the fifth failure the shim terminates: queued Promises are rejected,
every later call rejects at once, and `neel.ready` is rejected if it never
resolved. A close with 1000 or 1001 (Neel's `closeWindow` and shutdown) is
final immediately. Terminated is permanent for the page; a refresh loads a
fresh shim.

Wire format, for reference (JSON text frames, identical in both directions;
a `call` without an `id` is fire-and-forget):

```json
{"t":"call", "id":17, "name":"add", "args":[1, 2]}
{"t":"ret",  "id":17, "value":3}
{"t":"err",  "id":17, "error":{"kind":"ValueError", "msg":"..."}}
{"t":"call", "name":"logThis", "args":["hi"]}
```

Messages larger than `maxMessageSize` (default 16 MiB, configurable in
`startApp`) are refused (the server closes with 1009 and the shim reconnects).

## Windows

Each browser window is a `Window` handle: a copyable object with an `id`
(positive, unique for the life of the app, never reused) and a `js` field
(`win.js.foo(...)`). The first window is opened by `startApp` at `startPath`.

| Proc | Description |
|---|---|
| `openWindow(path = "/", size = none(WindowSize), position = none(WindowPosition), extraFlags: seq[string] = @[]): Window` | opens a new browser window at `path` (relative to the web root; a query or fragment is kept) and returns its handle; `size` / `position` override the `startApp` defaults, `extraFlags` are appended. Raises `NeelBrowserError` if no browser can be launched, `ValueError` for a non-positive size. Blocks only for the process launch itself. |
| `closeWindow(w)` | sends a 1000 close to the page (the shim does not reconnect), terminates the browser process, removes its profile directory, fires `onWindowClose`. Idempotent; a no-op for an unknown id. Blocks for the process to exit (about 100 ms, up to 3 s if the browser ignores SIGTERM). |
| `windows(): seq[Window]` | every window not yet closed, in id order, including windows still loading and windows whose connection dropped less than a grace period ago |
| `window(id): Option[Window]` | the open window with this id, or `none` |
| `requireWindow(id): Window` | the same, but raises `NeelNoWindowError` (`window 7 is not open`) for an unknown or closed id; use this in exposed procs so a stale id answers the page with a structured error instead of the `UnpackDefect` of `window(id).get` |
| `currentWindow(): Option[Window]` | the window whose exposed proc is running on this thread; `none` outside an exposed proc |
| `currentWindowId(): int` | its id, or `NoWindow` (0) |
| `isOpen(w)`, `isConnected(w)` | not closed; bound to a live WebSocket |
| `connectionCount(): int` | number of open WebSocket connections |

The two-window recipe from `examples/roundtrip`: the first page calls
`neel.openSecond()`, the second page registers a function with
`neel.expose`, and the first page asks it through Nim:

```nim
proc openSecond(): int {.expose.} =
  openWindow("/second.html").id

proc askSecond(id: int): string {.expose.} =
  requireWindow(id).js.wait(5000)
    .ask("Window 1 asks: what is your favourite number?").getStr

proc closeSecond(id: int) {.expose.} =
  let w = window(id)
  if w.isSome:
    closeWindow(w.get)
```

Hooks: `startApp(onWindowOpen = ..., onWindowClose = ...)` take a
`WindowHook = proc(w: Window) {.gcsafe.}`. `onWindowOpen` fires the first time
a connection bound to the window opens (a page refresh does not fire it again).
`onWindowClose` fires once per window: from `closeWindow` (on the caller's
thread), when a window whose connection has been gone for a grace period is
retired (on the main thread, inside `startApp`), or during teardown for windows
still open when the app quits (main thread). Hooks run on whichever thread
observes the event and may call `js` / `windows()`, except that a hook called
during teardown sees an empty `windows()` and `js` raises
`NeelNoWindowError`; guard `js` calls in `onWindowClose` with `try`/`except`
(see [Caveats](#caveats) for where an escaping exception ends up).

How a page learns its window: the launch URL is
`http://127.0.0.1:<port><path>?window=<id>`. The page's `<script
src="/neel.js">` request carries that URL in its `Referer` header, and the
server renders the shim for the id in the `window=` query (falling back to the
single open window when there is exactly one, and answering 404 when it cannot
tell). Consequences: do not use a `window` query parameter of your own, do not
set a `no-referrer` referrer policy (`<meta name="referrer"
content="no-referrer">` breaks every window but the first), and open additional
pages with `openWindow`, not with `window.open` from the page.

Each window is its own browser process with a private profile directory
(`<tmpdir>/neel-<pid>-<id>`, created by the browser, removed by Neel when the
window closes). This costs a full browser instance per window but makes the
process handle reliable: terminating it closes exactly that window. Closing a
window with the OS close button is detected through its WebSocket closing; the
window is retired (and `onWindowClose` fired) after the grace period, since a
refresh or the shim's reconnect looks the same at first.

## Browsers and fallback

```nim
startApp(browsers = @[Chrome, Chromium], fallback = true, browserPath = "",
         size = some((1100, 800)), position = some((80, 80)),
         extraFlags = @["--force-dark-mode"])
```

- `browsers: seq[Browser]` is the preference list, tried in order. The enum is
  `Chrome, Chromium, Edge, Brave, Opera, Vivaldi, Default`. Default list:
  `@[Chrome, Chromium]`.
- `Default` means a tab in the OS default browser (`open` on macOS,
  `xdg-open` on Linux and other POSIX systems, `rundll32.exe
  url.dll,FileProtocolHandler` on Windows). It always "succeeds" and stops the
  search, so `@[Default]` forces a tab. No app mode, no size or position, no
  process handle: closing the tab is detected through the WebSocket only.
- `Edge`, `Brave`, `Opera`, `Vivaldi` are reserved for a later release: they
  are skipped, and the no-browser page lists them as "reserved, not supported
  in this release".
- Where Neel looks: macOS `/Applications/Google Chrome.app` and
  `~/Applications/Google Chrome.app` (likewise `Chromium.app`), then `mdfind`
  by bundle id (`com.google.Chrome`, `org.chromium.Chromium`); Windows
  `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%LocalAppData%` +
  `Google\Chrome\Application\chrome.exe` / `Chromium\Application\chrome.exe`,
  then the registry `App Paths\chrome.exe` key (Chrome only); Linux and BSD
  `google-chrome`, `google-chrome-stable`, `chrome`, `chromium`,
  `chromium-browser` on `PATH`.
- `browserPath` overrides discovery with an explicit executable, launched with
  Chrome-style app-mode flags. The path must exist, otherwise `startApp`
  raises `NeelBrowserError` before anything is bound.
- `fallback = true` (default): when nothing in the list is found, the app
  opens in a default-browser tab. `fallback = false`: a default-browser tab is
  opened at the built-in page `/neel/no-browser` listing every location that
  was searched and how to fix it (install Chrome or Chromium, pass
  `browserPath`, or set `fallback = true`); the server stays up for
  `gracePeriodMs` so the page can load, then `startApp` raises
  `NeelBrowserError` (its `searched` field lists the browsers probed).
- `size`, `position`, and `extraFlags` apply only to app-mode launches. The
  argument vector is exactly `--app=<url> --user-data-dir=<dir>
  [--window-size=W,H] [--window-position=X,Y] --disable-http-cache
  --no-first-run --no-default-browser-check <extraFlags...>`, one argv element
  each; no shell is involved. A non-positive size is a `ValueError`; negative
  positions are allowed. Passing your own `--user-data-dir` in `extraFlags`
  breaks per-window process tracking (Chromium takes the last one).
- The browser inherits the application's stdout/stderr, so Chromium's own log
  lines appear in the terminal. Redirect stderr if that bothers you.

## Lifecycle

`startApp` blocks the calling thread and returns an `ExitReason` (the result
is discardable):

| `ExitReason` | When |
|---|---|
| `erLastWindowClosed` | the WebSocket connection count stayed at 0 for `gracePeriodMs` |
| `erQuit` | `quitApp()` was called (from any thread, including inside an exposed proc; it only signals) |
| `erStartupTimeout` | no window ever connected within `startupTimeoutMs` (30 s) of starting, e.g. the browser never loaded the page |

Before returning, `startApp` sends a 1001 close to every window, waits for
every in-flight hook, terminates the browser processes it started, removes the
profile directories, and tears everything down. A `startApp` can be called
again afterwards in the same process.

The grace period defaults to `DefaultGracePeriodMs`: 3 s in debug builds, 10 s
with `-d:release`. It exists because a page refresh, Chromium reloading a
background tab, and the shim's reconnect loop all look like a closed window
for a moment. The shim's first retry comes 250 ms after an abnormal close, so
`gracePeriodMs` must be at least `MinGracePeriodMs` (250); `startApp` asserts
that. A window opened less than `startupTimeoutMs` ago that has not connected
yet defers the exit (a second window launched while the first is being closed
does not kill the app).

```nim
proc exitApp() {.expose.} =
  quitApp() # only signals; startApp returns erQuit on the main thread

let reason = startApp()
echo "exited: ", reason
```

A page can close its own connection with `neel.close()`; the server treats
that like a closed window (retired after the grace period).

## Assets and build modes

The `webDir` argument (default `"web"`) is resolved against the directory of
the source file that calls `startApp`, in both asset modes, so `nim c -r
examples/x/x.nim` works from any working directory. An absolute `webDir` is
used as is.

`embedAssets` is a compile-time switch whose default is `defined(release)`:

- `false` (debug builds): files are read from disk on every request. Edit a
  page and refresh.
- `true` (release builds): the whole directory is walked at compile time and
  every file is embedded into the binary, which no longer needs the `web/`
  directory. `webDir` must be a constant then, and a missing directory is a
  compile error pointing at the `startApp` line.

Serving rules, identical in both modes: `GET` and `HEAD` only (anything else is
405 with `Allow: GET, HEAD`); `/` serves `index.html` and only `/` does
(`/sub/` is a 404, not `/sub/index.html`); directories are never listed; a
missing file is a real 404; paths containing `..` segments, backslashes, or
NUL are 404 regardless of where they would resolve; percent-encoding is
decoded (`/data%20file.json`). Single-range `Range` requests are honoured with
206 / 416 and every 200 carries `Accept-Ranges: bytes`, so `<video>` and
`<audio>` seek. The content type comes from `std/mimetypes` by extension, with
`.js` / `.mjs` as `application/javascript`, `.map` as `application/json`, and
unknown extensions as `application/octet-stream`; no `charset` is appended.
The reserved routes are `/neel.js`, `/ws`, and `/neel/no-browser`.

Add `--app:gui` to release builds to avoid a visible terminal window:
on Windows this suppresses the console window; on macOS it produces an
`.app` bundle that launches without a Terminal session. On Linux most
window managers already hide the terminal of a backgrounded process.

## Threading model

- The main thread blocks inside `startApp` until the app ends.
- One IO thread owns every socket. It never runs user code.
- A pool of worker threads (`workers`, default `DefaultWorkers` = 64, with a
  queue of `queueCapacity` = 1024 tasks) runs everything else: exposed procs,
  `onWindowOpen`, and the asset handler. **Exposed procs run concurrently**,
  including two calls from the same page issued back to back, so they must be
  `{.gcsafe.}` (the compiler enforces this; the error points at the proc) and
  must protect shared mutable state with a `Lock`, `Atomic`, or a channel.
  Module-level `var`s of GC'd types are not GC-safe to touch.
- There is no ordering guarantee between messages on one connection: a
  `neel.count()` issued right after `neel.increment.send()` may run before the
  increment. If order matters, await the first call or let the proc return
  what you need.
- `js.foo(...)` returns immediately. `js.wait.foo(...)` blocks the worker it
  runs on until the reply, the timeout, or the disconnect. While a worker
  waits, other workers keep serving messages, including from the same page,
  which is what makes re-entrant calls (page -> Nim -> page -> Nim) work.
- `js` has a current window only inside an exposed proc. From your own
  threads use `win.js` with a `Window` you obtained earlier (from
  `currentWindow()` inside an exposed proc, `windows()`, or `openWindow`);
  `Window` is a plain object and can be passed to a `Thread`. A `js` call to
  a window that has gone away raises `NeelNoWindowError`.
- Hooks run on the thread that observes the event (see [Windows](#windows)).
- Sizing `workers`: every `js.wait` and every slow exposed proc occupies a
  worker for its duration; `workers` is the number of such calls that can be
  in flight at once. The default 64 handles the stress test's 500 concurrent
  50 ms calls in under half a second; raise it for apps that block many
  workers on long `js.wait`s, lower it for small tools. When the queue is
  full, the IO thread stops reading from the connections whose messages it
  cannot queue (TCP back-pressure); nothing is dropped.

## `startApp` parameters

`startApp` is a macro. All arguments are keyword arguments; the one exception
is that `webDir` may be given positionally (`startApp("web", port = 8000)`).

| Parameter | Default | Meaning |
|---|---|---|
| `webDir` | `"web"` | web directory, relative to the calling source file unless absolute; a constant when embedding |
| `embedAssets` | `defined(release)` | compile-time constant: embed `webDir` into the binary (`true`) or serve from disk (`false`) |
| `startPath` | `"/"` | the page the first window opens (an `openWindow` path) |
| `port` | `0` | TCP port on `127.0.0.1`; 0 picks an ephemeral port |
| `workers` | `DefaultWorkers` (64) | pool threads running exposed procs and hooks |
| `queueCapacity` | `DefaultQueueCapacity` (1024) | bounded task queue in front of the pool |
| `callTimeoutMs` | `DefaultCallTimeoutMs` (10 000) | default timeout of `js.wait.*` |
| `maxMessageSize` | `DefaultMaxMessageSize` (16 777 216 = 16 MiB) | largest single WebSocket message the server will accept; the peer receives a 1009 close for anything larger |
| `gracePeriodMs` | `DefaultGracePeriodMs` (3 000 debug / 10 000 release) | exit this long after the last connection closes; at least `MinGracePeriodMs` (250) |
| `startupTimeoutMs` | `DefaultStartupTimeoutMs` (30 000) | how long a window may take to connect before it is given up |
| `browsers` | `@[Chrome, Chromium]` | preference list |
| `fallback` | `true` | open the app in a default-browser tab when nothing is found (`false`: show `/neel/no-browser` and raise) |
| `browserPath` | `""` | explicit browser executable; must exist |
| `size` | `none(WindowSize)` | `some((width, height))` for app-mode windows |
| `position` | `none(WindowPosition)` | `some((x, y))` for app-mode windows |
| `extraFlags` | `@[]` | extra command-line flags for app-mode windows |
| `onWindowOpen` | `nil` | `WindowHook` fired when a window's page first connects |
| `onWindowClose` | `nil` | `WindowHook` fired when a window is closed or retired |
| `launcher` | `nil` | test seam replacing the browser launch (`Launcher` type); tests inject a fake |

`startApp` raises `NeelBrowserError` (no browser and `fallback = false`, or a
bad `browserPath`), `OSError` (the port is taken), or `ValueError` (a
non-positive size); everything has been torn down when the exception leaves.
`runApp` is the ordinary proc behind the macro, for programs that build the
dispatcher and asset source themselves.

Compile-time errors from the macro point at your `startApp(...)` line: a
non-constant `embedAssets`, a positional argument other than `webDir`, a
missing web directory when embedding, or passing `assets` / `dispatch` /
`exposed` (which `startApp` sets itself).

## Caveats

- `Table[string, V]` and `HashSet` values come back to the page with keys in
  hash order, not insertion order (`OrderedTable` / `OrderedSet` keep order).
  Page code that compares objects should canonicalize key order.
- There is no ordering guarantee between messages on one connection
  (see [Threading model](#threading-model)).
- A blocking dialog (`prompt`, `alert`, `confirm`) inside a JS function that
  Nim called blocks that page's event loop, so other Nim -> JS calls to the
  same window wait behind it, and a `js.wait` on it can time out.
- An exposed proc that calls `quitApp()` returns normally and its Promise
  resolves before the 1001 close arrives, so a page cannot await "the app has
  exited"; later calls reject with `neel: connection is closed`.
  `neel.onclose` fires when the close does arrive.
- Chromium may discard and later reload a background tab or window. To Neel
  this looks like a page refresh: same window id, `onWindowOpen` does not fire
  again, page-side state is gone.
- `onWindowClose` fired during teardown (after `quitApp()`, for windows still
  open) runs with the window table already empty: `windows()` is `@[]` and
  `js` raises `NeelNoWindowError`. An exception escaping a hook is swallowed
  silently only when the hook ran on a pool worker (`onWindowOpen`); from
  `closeWindow` it propagates to the caller, and from the main thread
  (retirement, teardown) it escapes `startApp`. Catch inside the hook.
- Re-using a `Thread[T]` variable for a second run requires `joinThread` after
  the first finished; `examples/stresstest` shows the lock + flag pattern.
- One WebSocket message (a call or a reply, as JSON text) may be at most
  `maxMessageSize` (default 16 MiB, configurable in `startApp`); the request
  header block at most 16 KiB.
- A page must not set a `no-referrer` referrer policy and should not use a
  `window` query parameter of its own (see [Windows](#windows)).
- With `browsers = @[Default]` or after a fallback, the app runs in an
  ordinary browser tab: `size`, `position`, and `extraFlags` do not apply and
  the browser process is not tracked.
- The launch token is new on every start and is baked into `/neel.js`, so a
  page left open from a previous run cannot reconnect; refreshing it fetches a
  fresh shim.

## The examples

- [`examples/filepicker`](examples/filepicker) - the hello world above: one
  exposed proc with a return value and two structured errors, `startApp()`
  with defaults.
- [`examples/roundtrip`](examples/roundtrip) - return values in both
  directions (`neel.sum`, `askPage` through an async `neel.expose` target),
  a second window (`openWindow`, `requireWindow(id).js.wait(5000).ask(...)`,
  `closeWindow`, `windows()`), window hooks, and the four error kinds the
  first page can see (`PromptCancelled` forwarded from JS, `NeelTimeoutError`,
  `NeelDisconnectedError`, `NeelNoWindowError`). Primarily a test of the
  multi-window and bidirectional-return-value machinery, but also a compact
  reference for how communication flows between windows.
- [`examples/stresstest`](examples/stresstest) - a manual test harness that
  exercises every feature in one page: every supported type, every error kind,
  500 concurrent calls, 2 MB payloads, pushes from a plain thread, multi-window
  broadcasts, lifecycle events, and more. Mainly for verifying Neel itself, but
  useful as a reference for how each API behaves under load and in edge cases.

## Migrating from Neel 1.x

Neel 2.0 is a rewrite with a new API; nothing from 1.x compiles unchanged.

| 1.x | 2.0 |
|---|---|
| `exposeProcs:` block wrapping procs | `{.expose.}` pragma on each top-level proc; procs may live in any module |
| `callJs("fn", a, b)` | `js.fn(a, b)` (fire-and-forget) or `js.wait.fn(a, b)` (blocks, returns `JsonNode`); `win.js.fn(...)` for a specific window |
| `neel.callNim("proc", a, b)` | `neel.proc(a, b)` returns a Promise with the return value; `neel.proc.send(a, b)` is fire-and-forget |
| no return values | both directions return values; errors cross as `e.name` / `e.message` in JS and `NeelRemoteError` in Nim |
| JS functions found on `window` only | `neel.expose(fn)` / `neel.expose({name: fn})` registry, with `window[name]` as fallback |
| `startApp(webDirPath = "web")` | `startApp(webDir = "web")` or `startApp("web")`; the path is relative to the source file, not the working directory |
| `portNo = 5000` | `port = 0` (ephemeral) by default; pass `port = 5000` for a fixed one |
| `position = [500, 150]`, `size = [600, 600]` | `position = some((500, 150))`, `size = some((600, 600))`; no default size or position (the browser decides) |
| `chromeFlags = @[...]` | `extraFlags = @[...]` |
| `appMode = false` | `browsers = @[Default]` |
| Chrome only | `browsers = @[Chrome, Chromium]` with `fallback` to the default browser and a `browserPath` override |
| one window | `openWindow`, `closeWindow`, `windows`, `window`, `requireWindow`, `currentWindow`, hooks |
| default parameter values unsupported | supported (positional) |
| exit roughly 3 s / 10 s after the socket closes | the same defaults, now `gracePeriodMs`, plus `quitApp()` and `startApp` returning an `ExitReason` |
| assets embedded in release builds | the same, now `embedAssets = defined(release)` and overridable |
| `--threads:on --mm:orc` on Nim 1.6 | Nim >= 2.2 required; no flags |
| re-exported `std/os`, `std/osproc`, `std/strutils`, `std/json`, `std/threadpool`, `std/browsers`, `std/jsonutils`, Mummy | re-exports only `std/json` and `std/options`; import the rest yourself; no external dependencies |

Unchanged: the page loads `/neel.js` before its own script, assets use
absolute paths and are served from the web directory at `/`, the start page is
`index.html`, and the server listens on `127.0.0.1` only.
