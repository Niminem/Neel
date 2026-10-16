# Neel 2.1 guide

The complete reference. For an introduction and a first app, start with the
[README](../README.md).

Neel is a Nim library for desktop applications whose user interface is HTML,
CSS, and JavaScript. The Nim program runs a small HTTP/WebSocket server on
`127.0.0.1`, opens Chrome, Chromium, or Edge in app mode on it, and bridges the two
sides: a Nim proc marked `{.expose.}` becomes `neel.<name>(...)` in the page
and returns a Promise; a JS function registered with `neel.expose` becomes
`js.<name>(...)` in Nim, with `js.wait.<name>(...)` when a return value is
needed. Neel is inspired by Python's [Eel](https://github.com/python-eel/Eel).
In [serve mode](#serve-mode) the same app runs as a persistent server for one
user instead: no browser is launched, and the app is opened from any of the
user's devices through an SSH port forward, a tunnel, or a reverse proxy.

Requirements: Nim >= 2.2.12, no external packages. Supported browsers in this
release: Google Chrome, Chromium, and Microsoft Edge (app mode), or a tab in
the OS default browser.

Platforms: Fully verified on macOS, Windows, and Linux (Ubuntu). Edge is verified on Windows only as it is an edge-case browser on non-Windows platforms.

Contents

- [Installation](#installation)
- [Running the examples](#running-the-examples)
- [Quick start](#quick-start)
- [Exposing Nim procs to the page](#exposing-nim-procs-to-the-page)
- [Calling the page from Nim: `js`](#calling-the-page-from-nim-js)
- [The `neel.js` API](#the-neeljs-api)
- [Multiple windows](#multiple-windows)
- [Browsers and fallback](#browsers-and-fallback)
- [Lifecycle](#lifecycle)
- [Assets and build modes](#assets-and-build-modes)
- [Threading model](#threading-model)
- [`startApp` parameters](#startapp-parameters)
- [Security](#security)
- [Serve mode](#serve-mode)
- [Caveats](#caveats)
- [The examples](#the-examples)
- [Migrating from Neel 1.x](#migrating-from-neel-1x)
- [License](#license)

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
`NeelVersion` holds the library version as a string.

## Running the examples

From a fresh clone, no setup is needed — the repository's `config.nims` adds
`src/` to the compiler's path automatically:

```
git clone https://github.com/Niminem/Neel.git
cd Neel
```

Then, from the repository root:

```
nim c -r examples/filepicker/filepicker.nim
nim c -r examples/roundtrip/roundtrip.nim
nim c -r examples/stresstest/stresstest.nim
nim c -r examples/serve/serve.nim
```

`serve` is a [serve-mode](#serve-mode) app: it opens no browser, prints
`neel: serving http://127.0.0.1:5359 (allowed origins: none)`, and runs
until you stop it (its page has a "Stop server" button, or press Ctrl-C);
open that URL yourself. Its header comment shows how to reach it from
another device. The rest of this section is about the other three.

These are debug builds: the example's `web/` directory is served from disk,
so edits to the page show up on refresh, and the app exits 3 s after its last
window closes. A release build embeds `web/` into the binary at compile time,
so the binary can be moved anywhere (the grace period is 10 s there, except
in `stresstest`, which sets 3 s for both builds):

```
nim c -d:release examples/filepicker/filepicker.nim
./examples/filepicker/filepicker      # Windows: .\examples\filepicker\filepicker.exe
```

The browser inherits the application's stdio (a pipe nobody reads would
eventually stall it), so on macOS expect Chromium's own stderr noise in the
terminal. On Windows Chrome does not log to the console, so the terminal shows
only your app's output.

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
- The JS name is the proc name exactly as spelled in its definition. Nim
  treats `filePicker` and `file_picker` as the same name; JS does not, so
  `proc file_picker` is `neel.file_picker`, not `neel.filePicker`.
- `startApp` must come after every `{.expose.}` proc in the module and after
  the imports of modules that contain exposed procs. It may sit inside
  `proc main()`. A proc exposed after the `startApp` call is left out of the
  dispatcher and of `/neel.js`, so the page cannot call it.
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

Defects (`IndexDefect`, `AssertionDefect`, ...) are bugs and are not caught:
one raised in an exposed proc escapes the worker thread and terminates the
app.

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

Name collisions: `js.foo(...)` reaches the page only when no Nim proc in
scope accepts `js` as its first argument. If one does, Nim calls that proc
instead, with no error and no message to the page. `js.echo("x")` calls Nim's
`echo`, `js.repr()` calls `repr`, `js.wait(...)` is the blocking form above,
and so would one of your own procs that accepts any type (`proc log[T](x:
T)` captures `js.log(...)`). Names whose Nim procs take other types, such as
`js.len()`, `js.add(...)`, `js.close()`, `js.open()`, and `js.alert(...)`,
reach the page as intended. `js.console.log(...)` does not compile.

Escape hatch: `js.foo(...)` is sugar for `jsSend(js, "foo", @[...])` and
`js.wait.foo(...)` for `jsCallWait(js.wait, "foo", @[...])`; both take the
name as a `string` and the arguments as a `seq[JsonNode]`, and never collide.
Use them for colliding names and for dynamic names.

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
| `neel.ready` | Promise resolved on the first successful connection; rejected with `NeelDisconnectedError` if the shim gives up or is closed before ever connecting (nobody has to await it). In serve mode a rejected `ready` does not mean the shim has stopped: it may still connect later (see `neel.onreconnect`) |
| `neel.windowId` | the window's id (a positive number) |
| `neel.connected` | `true` while the WebSocket is open |
| `neel.onclose(fn)` | `fn(code, reconnecting)` is called after every close, including each failed reconnect attempt: `code` is the WebSocket close code (1006 lost, 1000 `neel.close()` / `closeWindow`, 1001 shutdown, 4000 `CloseDisplaced`: another tab or device took this window over), `reconnecting` is `true` when another attempt follows and `false` on the last call |
| `neel.onreconnect(fn)` | `fn()` is called after every successful connection except the one that resolves `neel.ready` (in local mode: every one but the first; in serve mode it also fires when a shim that never connected wakes up and connects) |
| `neel.close()` | closes the connection with code 1000 and makes every later call reject; the shim does not reconnect |

`Object.keys(neel)` is exactly this list plus the exposed names. Loading
`neel.js` twice is a no-op with a console warning.

Rejections carry an `Error` whose `name` and `kind` are both the wire kind and
whose `message` is the wire message, so `catch (e) { if (e.name ===
"ValueError") ... }` works. Besides the kinds listed under
[Exposing Nim procs](#exposing-nim-procs-to-the-page), the shim itself rejects
with `NeelDisconnectedError` when a pending call's connection closes for any
reason (`neel: connection lost (close code 1006)`), when a call is made after
the shim has terminated (`neel: connection is closed`), when queued calls
are dropped because the retries ran out (`neel: gave up reconnecting after 5
attempts`), and, in serve mode only, when a call is made while the shim is
dormant (`neel: not connected; reconnects when the page becomes visible or
goes online`, see [Reconnecting](#reconnecting-dormant-pages-and-server-restarts)).
A call in flight when the server closes the connection for good (1000,
1001, or 4000) rejects like any other lost call (`neel: connection lost
(close code 4000)`), and every later call with `neel: connection is closed`.

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

Reconnect: on a close with any code other than 1000, 1001, or 4000 that was
not caused by `neel.close()`, in-flight Promises are rejected with
`NeelDisconnectedError` and the shim reconnects up to 5 times with delays of
250, 500, 1000, 2000, and 4000 ms (7.75 s in total), presenting the same token
and window id. A successful open resets the counter and flushes the queue.
After the fifth failure the shim terminates: queued Promises are rejected,
every later call rejects at once, and `neel.ready` is rejected if it never
resolved. (In serve mode it goes dormant instead and tries again when the
page becomes visible or the browser goes back online; see
[Reconnecting](#reconnecting-dormant-pages-and-server-restarts).) A close
with 1000, 1001, or 4000 (Neel's `closeWindow`, shutdown, and a displaced
connection) is final immediately, in both modes. Terminated is permanent for
the page; a refresh loads a fresh shim.

Wire format, for reference (JSON text frames, identical in both directions;
a `call` without an `id` is fire-and-forget):

```json
{"t":"call", "id":17, "name":"add", "args":[1, 2]}
{"t":"ret",  "id":17, "value":3}
{"t":"err",  "id":17, "error":{"kind":"ValueError", "msg":"..."}}
{"t":"call", "name":"logThis", "args":["hi"]}
```

Messages from the page larger than `maxMessageSize` (default 16 MiB,
configurable in `startApp`) are refused (the server closes with 1009 and the shim reconnects).

## Multiple windows

Each browser window is a `Window` handle: a copyable object with an `id`
(positive, unique for the life of the app, never reused) and a `js` field
(`win.js.foo(...)`). The first window is opened by `startApp` at `startPath`.

| Proc | Description |
|---|---|
| `openWindow(path = "/", size = none(WindowSize), position = none(WindowPosition), extraFlags: seq[string] = @[]): Window` | opens a new browser window at `path` (relative to the web root; a query or fragment is kept) and returns its handle; `size` / `position` override the `startApp` defaults, `extraFlags` are appended. Raises `NeelBrowserError` if no browser can be launched, `ValueError` for a non-positive size. Blocks only for the process launch itself. In serve mode it raises `NeelServeModeError` (`openWindow is not available in serve mode: the app has one window, created by startApp`). |
| `closeWindow(w)` | sends a 1000 close to the page (the shim does not reconnect), terminates the browser process, removes its profile directory, fires `onWindowClose`. Idempotent; a no-op for an unknown id. Blocks for the process to exit (about 100 ms, up to 3 s if the browser does not exit when asked). In serve mode it raises `NeelServeModeError` for any id. |
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
thread), when a window is retired because its connection has been gone for a
grace period or because it never connected within `startupTimeoutMs` (on the
main thread, inside `startApp`), or during teardown for windows still open
when the app quits (main thread). Hooks run on whichever thread
observes the event and may call `w.js` / `windows()`, except that a hook called
during teardown sees an empty `windows()` and `w.js` raises
`NeelNoWindowError`; guard `js` calls in `onWindowClose` with `try`/`except`
(see [Caveats](#caveats) for where an escaping exception ends up).
`onWindowOpen` fires as soon as the shim connects, which can be before the
page's own scripts have registered their `neel.expose` functions; a page
that needs initial data should ask for it with a `neel.<name>()` call
rather than wait for a push from the hook. In serve mode the single window
is never closed or retired, so `onWindowOpen` fires once ever (the first
connection to window 1, not for later devices, refreshes, or reconnects)
and `onWindowClose` once, at teardown (see [Serve mode](#serve-mode)).

How a page learns its window: the launch URL is
`http://127.0.0.1:<port><path>?window=<id>`. The page's `<script
src="/neel.js">` request carries that URL in its `Referer` header, and the
server renders the shim for the id in the `window=` query. A page whose URL
names no window gets the single open window when there is exactly one and a
404 otherwise; a page whose URL names a window that is no longer open (a tab
left behind by `closeWindow` in a default-browser setup, then refreshed)
always gets a 404, so it can never take over another window.
Consequences: do not use a `window` query parameter of your own, do not
set a `no-referrer` referrer policy (`<meta name="referrer"
content="no-referrer">` breaks every window but the first), and open additional
pages with `openWindow`, not with `window.open` from the page. A page that
navigates within its window (a plain link, `location.href = "/other.html"`)
drops `?window=<id>` from its URL; the new page gets its shim only while it is
the single open window. In a multi-window app, carry the query along
(`"/other.html" + location.search`) or keep each window on one page.

Each window is its own browser process with a private profile directory
(`<tmpdir>/neel-<pid>-<id>`, created by the browser, removed by Neel when the
window closes). If the app or the browser is killed or crashes, the directory
stays behind; the next Neel app to exit normally deletes it, once neither the
app nor a browser is still using it (see [Lifecycle](#lifecycle)). This costs a full browser instance per window but makes the
process handle reliable: terminating it closes exactly that window. Closing a
window with the OS close button is detected through its WebSocket closing; the
window is retired (and `onWindowClose` fired) after the grace period, since a
refresh or the shim's reconnect looks the same at first.

## Browsers and fallback

```nim
startApp(browsers = @[Chrome, Chromium, Edge], fallback = true, browserPath = "",
         size = some((1100, 800)), position = some((80, 80)),
         extraFlags = @["--force-dark-mode"])
```

- `browsers: seq[Browser]` is the preference list, tried in order. The enum is
  `Chrome, Chromium, Edge, Brave, Opera, Vivaldi, Default`. Default list:
  `@[Chrome, Chromium, Edge]` on every OS, so a Windows machine without Chrome
  still gets an app window from the preinstalled Edge.
- `Default` means a tab in the OS default browser (`open` on macOS,
  `xdg-open` on Linux and other POSIX systems, `rundll32.exe
  url.dll,FileProtocolHandler` on Windows). It always "succeeds" and stops the
  search, so `@[Default]` forces a tab. No app mode, no size or position, no
  process handle: closing the tab is detected through the WebSocket only.
- `Brave`, `Opera`, `Vivaldi` are reserved for a later release: they are
  skipped, and the no-browser page lists them as "reserved, not supported in
  this release".
- Where Neel looks: macOS `/Applications/Google Chrome.app` and
  `~/Applications/Google Chrome.app` (likewise `Chromium.app` and
  `Microsoft Edge.app`), then `mdfind` by bundle id (`com.google.Chrome`,
  `org.chromium.Chromium`, `com.microsoft.edgemac` then `com.microsoft.Edge`); Windows
  `%ProgramFiles%`, `%ProgramFiles(x86)%`, `%LocalAppData%` +
  `Google\Chrome\Application\chrome.exe` / `Chromium\Application\chrome.exe` /
  `Microsoft\Edge\Application\msedge.exe`, then the registry `App Paths` key
  (`chrome.exe` for Chrome, `msedge.exe` for Edge; none for Chromium); Linux
  and BSD `google-chrome`, `google-chrome-stable`, `chrome`, `chromium`,
  `chromium-browser`, `microsoft-edge`, `microsoft-edge-stable` on `PATH`.
- `browserPath` overrides discovery with an explicit executable, launched in
  app mode with the browser flags (below) of the first app-mode browser in
  `browsers`; with the default list that is Chrome, which has none. For an
  Edge executable also pass `browsers = @[Edge]`. The path must exist,
  otherwise `startApp` raises `NeelBrowserError` before anything is bound.
- `fallback = true` (default): when nothing in the list is found, the app
  opens in a default-browser tab. `fallback = false`: a default-browser tab is
  opened at the built-in page `/neel/no-browser` listing every location that
  was searched and how to fix it (install Chrome, Chromium, or Edge, pass
  `browserPath`, or set `fallback = true`); the server stays up for
  `gracePeriodMs` so the page can load, then `startApp` raises
  `NeelBrowserError` (its `searched` field lists the browsers probed).
- `size`, `position`, and `extraFlags` apply only to app-mode launches. The
  argument vector is exactly `--app=<url> --user-data-dir=<dir>
  [--window-size=W,H] [--window-position=X,Y] --disable-http-cache
  --no-first-run --no-default-browser-check [browser flags] <extraFlags...>`,
  one argv element each; no shell is involved. A non-positive size is a
  `ValueError`; negative positions are allowed. Passing your own
  `--user-data-dir` in `extraFlags` breaks per-window process tracking
  (Chromium takes the last one).
- Browser flags: Edge always gets `--disable-sync --disable-extensions
  --disable-features=msImplicitSignin --no-service-autorun
  --edge-skip-compat-layer-relaunch`. Without them a
  fresh Edge profile signs itself in with the Microsoft account Windows is
  signed into, shows a sync prompt over the app window, and installs that
  account's extensions, whose welcome tabs open in a separate Edge window;
  `--no-service-autorun` stops Edge's background processes; and on Windows
  Edge may relaunch itself under a new process, so `closeWindow` and
  `quitApp` could not close the window or delete its profile. As a
  consequence, extensions (`--load-extension`) do not work in Edge app
  windows. Chromium keeps only the last `--disable-features`, so passing your
  own in `extraFlags` turns implicit sign-in back on: include
  `msImplicitSignin` in your list
  (`--disable-features=msImplicitSignin,YourFeature`). Chrome and Chromium get
  no extra flags.
- The browser inherits the application's stdout/stderr, so Chromium's own log
  lines appear in the terminal. Redirect stderr if that bothers you.

## Lifecycle

`startApp` blocks the calling thread and returns an `ExitReason` (the result
is discardable):

| `ExitReason` | When |
|---|---|
| `erLastWindowClosed` | the WebSocket connection count stayed at 0 for `gracePeriodMs` (local mode only) |
| `erQuit` | `quitApp()` was called (from any thread, including inside an exposed proc; it only signals); in serve mode also a stop signal such as Ctrl-C or `SIGTERM` (see [Stopping a server](#stopping-a-server)) |
| `erStartupTimeout` | no window ever connected within `startupTimeoutMs` (30 s) of starting, e.g. the browser never loaded the page (local mode only) |

Before returning, `startApp` sends a 1001 close to every window, waits for
every in-flight hook, terminates the browser processes it started, removes the
profile directories, and tears everything down. Last, it deletes profile
directories that killed or crashed Neel apps left in the temp directory:
only `neel-<pid>-<id>` directories whose app is no longer running and that no
browser still uses, never anything else, and for at most about 2 seconds
(whatever is left waits for the next exit). Usually there is nothing to
delete. A `startApp` can be called again afterwards in the same process.
In serve mode there are no browser processes and no profile directories, so
teardown is the 1001 close, the hooks, and the threads, and the sweep of
abandoned profiles is skipped.

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
that like a closed window (retired after the grace period). In serve mode
nothing is retired and there is no grace period: the window stays open for
the next connection, and only `quitApp()` or a stop signal ends the app.

## Assets and build modes

The `webDir` argument (default `"web"`) is resolved against the directory of
the source file that calls `startApp`, in both asset modes, so `nim c -r
examples/x/x.nim` works from any working directory. An absolute `webDir` is
used as is.

`embedAssets` is a compile-time switch whose default is `defined(release)`:

- `false` (debug builds): files are read from disk on every request. Edit a
  page and refresh. A missing directory makes `startApp` raise `OSError`
  before any window opens.
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

In serve mode two routes differ. `GET` and `HEAD /` answer `302` with
`Location: <startPath>` when the path part of `startPath` (before any `?`
or `#`) is not `/`; a `startPath` such as `/?tab=2` is not redirected to
(the browser would land on `/` again), so `/` serves `index.html` then.
`/neel/no-browser` is a 404.

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
- Hooks run on the thread that observes the event (see [Multiple windows](#multiple-windows)).
- Sizing `workers`: every `js.wait` and every slow exposed proc occupies a
  worker for its duration; `workers` is the number of such calls that can be
  in flight at once. The page's replies to `js.wait` are themselves handled
  on the pool, so if every worker is blocked in `js.wait`, no worker is left
  to deliver the replies and the waits end in `NeelTimeoutError`. Keep the
  number of simultaneous `js.wait`s below `workers`. The default 64 handles
  the stress test's 500 concurrent 50 ms calls in under half a second; raise
  it for apps that block many workers on long `js.wait`s, lower it for small
  tools. When the queue is full, the IO thread stops reading from the
  connections whose messages it cannot queue (TCP back-pressure); nothing is
  dropped.

## `startApp` parameters

`startApp` is a macro. All arguments are keyword arguments; the one exception
is that `webDir` may be given positionally (`startApp("web", port = 8000)`).

| Parameter | Default | Meaning |
|---|---|---|
| `webDir` | `"web"` | web directory, relative to the calling source file unless absolute; a constant when embedding |
| `embedAssets` | `defined(release)` | compile-time constant: embed `webDir` into the binary (`true`) or serve from disk (`false`) |
| `startPath` | `"/"` | the page the first window opens (an `openWindow` path); in serve mode, where `/` redirects |
| `port` | `0` | TCP port on `127.0.0.1`; 0 picks an ephemeral port (serve mode needs a fixed one) |
| `serve` | `false` | [serve mode](#serve-mode): no browser, no idle exit, one window shared by whichever device connected last; runs until `quitApp()` or a stop signal |
| `allowedOrigins` | `@[]` | serve mode only: extra origins the app may be loaded from, each `http://host[:port]` or `https://host[:port]` (e.g. `"https://myapp.example.com"`) |
| `workers` | `DefaultWorkers` (64) | pool threads running exposed procs and hooks |
| `queueCapacity` | `DefaultQueueCapacity` (1024) | bounded task queue in front of the pool |
| `callTimeoutMs` | `DefaultCallTimeoutMs` (10 000) | default timeout of `js.wait.*` |
| `maxMessageSize` | `DefaultMaxMessageSize` (16 777 216 = 16 MiB) | largest single WebSocket message the server will accept; the peer receives a 1009 close for anything larger |
| `gracePeriodMs` | `DefaultGracePeriodMs` (3 000 debug / 10 000 release) | exit this long after the last connection closes; at least `MinGracePeriodMs` (250) (ignored in serve mode) |
| `startupTimeoutMs` | `DefaultStartupTimeoutMs` (30 000) | how long a window may take to connect before it is given up (ignored in serve mode) |
| `browsers` | `@[Chrome, Chromium, Edge]` | preference list (ignored in serve mode) |
| `fallback` | `true` | open the app in a default-browser tab when nothing is found (`false`: show `/neel/no-browser` and raise) (ignored in serve mode) |
| `browserPath` | `""` | explicit browser executable; must exist (ignored in serve mode) |
| `size` | `none(WindowSize)` | `some((width, height))` for app-mode windows (ignored in serve mode) |
| `position` | `none(WindowPosition)` | `some((x, y))` for app-mode windows (ignored in serve mode) |
| `extraFlags` | `@[]` | extra command-line flags for app-mode windows (ignored in serve mode) |
| `onWindowOpen` | `nil` | `WindowHook` fired when a window's page first connects (serve mode: once, on the first connection ever) |
| `onWindowClose` | `nil` | `WindowHook` fired when a window is closed or retired (serve mode: once, at teardown) |

`startApp` raises `NeelBrowserError` (no browser and `fallback = false`, or a
bad `browserPath`), `OSError` (the port is taken, or the web directory does
not exist in a debug build), or `ValueError` (a
non-positive size; and, before anything is bound, `serve = true` with
`port = 0`, `allowedOrigins` without `serve = true`, or a malformed
`allowedOrigins` entry, see [Starting a server](#starting-a-server));
everything has been torn down when the exception leaves.

Compile-time errors from the macro point at your `startApp(...)` line: a
non-constant `embedAssets`, a positional argument other than `webDir`, or a
missing web directory when embedding.

## Security

The server listens on `127.0.0.1` only, so other machines cannot reach it
(unless you put a tunnel or proxy in front of it in serve mode, which has
its own [security model](#security-in-serve-mode)).
Each start generates a random token that a page must present to open its
WebSocket, and every request is checked before it is served:

- the `Host` header must be `127.0.0.1:<port>`, which defeats DNS rebinding
  (in serve mode the host of an allowed origin is accepted too);
- a request marked `Sec-Fetch-Site: cross-site` is refused, so another
  website cannot load `/neel.js` (which carries the token) (in serve mode
  top-level page loads pass, so that links and login redirects work);
- the WebSocket upgrade must come from a page at `http://127.0.0.1:<port>`
  (its `Origin`), so the token is useless to any other website (in serve
  mode an allowed origin is accepted too).

A refused request gets a 403. This keeps other websites open in the user's
browser away from your app. It also means the app works only at the URL Neel
opens: `http://localhost:<port>` typed by hand is refused. (In serve mode it
also works at the origins in `allowedOrigins`; see
[Security in serve mode](#security-in-serve-mode).)

Neel trusts the local machine. Other programs and users on the same computer
can send any headers, fetch `/neel.js`, and read the browser's command line,
so they can reach your exposed procs. An exposed proc can do anything your
app can: treat its arguments as untrusted input, and do not expose procs that
run arbitrary commands or touch arbitrary paths without checking them.

## Serve mode

Serve mode runs an app as a persistent server for one user. No browser is
launched and the app does not exit when its page closes; the user opens it
from whichever device they are on, through an SSH port forward, a tunnel,
or a reverse proxy in front of `127.0.0.1`. It suits a tool that lives on a
home server or a VM and is used from a laptop one day and a phone the next.
The programming model does not change: `{.expose.}`, `neel.foo()`,
`js.foo()`, and `js.wait.foo()` work as in local mode.

```nim
startApp(serve = true, port = 8080,
         allowedOrigins = @["https://myapp.example.com"])
```

Not part of serve mode: users, sessions, or authentication (that is the job
of the tunnel or proxy, see [Security in serve mode](#security-in-serve-mode)),
TLS (the proxy terminates it; the shim connects with `wss:` by itself when
its page was served over `https:`), listening on anything but `127.0.0.1`,
and more than one window.

[`examples/serve`](../examples/serve) is a complete serve-mode app.

### Starting a server

- `serve = true` needs a fixed `port`; `port = 0` raises `ValueError`
  (`neel: serve mode needs a fixed port (port = 0 picks a random one, which
  a tunnel or proxy cannot reach)`).
- `allowedOrigins` lists the origins the page may be loaded from besides
  `http://127.0.0.1:<port>`: the public URL of your tunnel or proxy, as the
  browser's address bar shows it, without a path. An SSH forward to
  `http://127.0.0.1:<port>` needs none. Passing `allowedOrigins` without
  `serve = true` raises `ValueError` (`neel: allowedOrigins requires serve =
  true`).
- Each entry must be `http://host[:port]` or `https://host[:port]`. A host is
  ASCII letters, digits, `-`, `.`, and `_`, or a bracketed IPv6 literal
  (`[::1]`); a port is 1-65535. Anything else raises `ValueError` naming the
  entry and the reason: a path (a trailing `/` counts as one), a query, a
  fragment, user info, a wildcard, another scheme, an empty host or port,
  surrounding whitespace (entries are not trimmed), or non-ASCII (write an
  internationalized host in its punycode `xn--` form, which is what browsers
  send). For example: `neel: allowedOrigins entry "https://myapp.example.com/"
  has a path (a trailing / counts as one); expected http://host[:port] or
  https://host[:port]`.
- Entries are normalized the way browsers send them: scheme and host
  lowercased, the port as a plain number, a default port (`:80` for `http`,
  `:443` for `https`) removed. `HTTPS://MyApp.Example.com:443` becomes
  `https://myapp.example.com`. Duplicates are kept once.
- All of this is checked before anything is bound, so a refused start
  leaves nothing running.

`browsers`, `fallback`, `browserPath`, `size`, `position`, `extraFlags`,
`gracePeriodMs`, and `startupTimeoutMs` are accepted and ignored: no browser
is discovered (so a stale `browserPath` raises nothing), and there is no
grace period and no startup timeout.

Once the server listens, its window exists, and the stop-signal handlers are
in place, `startApp` prints one line to stdout, in debug and release builds:

```
neel: serving http://127.0.0.1:8080 (allowed origins: https://myapp.example.com)
```

The origins are listed normalized and comma-separated, or as `(allowed
origins: none)`. A script or a service manager can wait for this line. When
there is no stdout to write to (`--app:gui` on Windows), the line is
dropped without an error.

Two routes differ from local mode (see [Assets](#assets-and-build-modes)):
`/` redirects to `startPath` when that names another page, and
`/neel/no-browser` is a 404. Pages need no `?window=` query: every page of
the web folder gets the shim of the single window, so plain links between
pages work.

### One window, many devices

A serve-mode app has exactly one window, window 1, created by `startApp` at
`startPath` without launching anything. It exists from the start and is
never retired: `windows()` always lists it, `isConnected` tells whether a
page is connected right now, and `requireWindow(1).js.foo(...)` reaches
whichever page is connected (`NeelNoWindowError` while none is). Inside an
exposed proc, `js` targets it as usual. `openWindow` and `closeWindow` raise
`NeelServeModeError`, a `CatchableError`, so an exposed proc that lets it
escape answers the page with `e.name === "NeelServeModeError"`.

Every new connection binds to window 1, whether it comes from another
device, another tab, a refresh, or the shim reconnecting, and the newest one
wins. The previous connection, if it is still open, is closed with code 4000
(`CloseDisplaced`, reason `displaced by another connection`). The shim
treats 4000 as final, like 1000 and 1001: `neel.onclose` reports `(4000,
false)`, later calls reject, and the page never reconnects on its own. Show
something like "Opened on another device" with a button that reloads the
page to take the session back. Never reload on 4000 automatically: two open
devices would then take the session from each other forever.

`js` resolves the window to its connection when the call is made, so an
exposed proc started by the displaced device that calls `js.foo(...)`
afterwards reaches the new device.

Hooks: `onWindowOpen` fires once, when the first connection ever binds to
window 1. Later devices, refreshes, and reconnects do not fire it; the
server cannot tell them apart. `onWindowClose` fires once, during teardown.
A page should therefore request its initial state with a `neel.<name>()`
call when it loads and again in `neel.onreconnect`, not wait for a push from
a hook; that is also how a change made on another device shows up.

### Stopping a server

A serve-mode app ends when an exposed proc (or any thread) calls
`quitApp()`, or when the process receives a stop signal. Both make
`startApp` return `erQuit`; `ExitReason` has no separate member for signals.
Shutdown is the same either way: the connected page receives a 1001 close,
`onWindowClose` runs, and Neel's threads are joined. A signal is noticed
within about a second.

The signal handlers are installed only while a serve-mode `startApp` runs,
and the previous handlers are back in place when it returns. Local mode
installs none: Ctrl-C ends a local-mode app the default way, without
Neel's shutdown (on Windows, a debug build crashes there; see
[Caveats](#caveats)).

- Linux and macOS: `SIGINT` (Ctrl-C) and `SIGTERM` (`kill`, `systemctl
  stop`, `docker stop`). A second signal while the shutdown is still running
  exits at once, with status 130 for `SIGINT` and 143 for `SIGTERM`, so a
  hung shutdown can always be interrupted. The `SIGINT` handler that was in
  place before (Nim's own, or one installed with `setControlCHook`) is
  restored afterwards.
- Windows: Ctrl-C, Ctrl-Break, closing the console window, logoff, and
  shutdown.
  - Ctrl-C and Ctrl-Break stop the app cleanly. There is no second-signal
    exit; to end a hung shutdown, close the console window.
  - Closing the console window, logoff, and shutdown: Windows ends the
    process as soon as Neel's handler returns. The handler waits, at most
    4 s, for the shutdown to finish, so the page gets its 1001 and
    `onWindowClose` runs, but code after `startApp` may not run.
  - Windows delivers logoff and shutdown events only to console programs
    that have not loaded `user32.dll` or `gdi32.dll`. Neel loads neither; an
    app that does (through a GUI library, for example) is killed at logoff
    or shutdown without a clean stop.
  - Windows disables Ctrl-C for a process started with
    `CREATE_NEW_PROCESS_GROUP`; such a process only receives Ctrl-Break. A
    launcher that stops the app with Ctrl-C must not use that flag.
  - Running as a Windows service is not supported.

### Keep-alive pings

Proxies and tunnels close WebSockets that carry no data for a while (nginx
after 60 s by default, Cloudflare after about 100 s). In serve mode Neel
sends a WebSocket ping on every connection that has neither sent nor
received anything for 30 s. The browser answers with a pong by itself; no
page code is involved, and any traffic restarts the 30 s. A connection that
never answers is not closed for it; the next connection replaces it. A
proxy whose idle timeout is shorter than 30 s still closes idle
connections, and the shim then reconnects. Local mode sends no pings.

### Reconnecting: dormant pages and server restarts

The shim reconnects in serve mode exactly as in local mode (see "Reconnect"
in [The `neel.js` API](#the-neeljs-api)): after an unexpected close, up to 5
attempts over 7.75 s, with calls queued meanwhile. What differs is what
happens when the attempts run out, which in serve mode is routine: a phone
locks its screen, a laptop sleeps, a tunnel restarts.

- **Dormant, not terminated.** Pending and queued calls reject (`neel: gave
  up reconnecting after 5 attempts`) and `neel.onclose(code, false)` fires,
  as in local mode, but the shim does not stop for good: it goes dormant.
  A call made while dormant rejects at once with `NeelDisconnectedError`
  and `neel: not connected; reconnects when the page becomes visible or goes
  online`. A call does not wake the shim.
- **Waking up.** A dormant shim wakes when the page becomes visible
  (`visibilitychange` to `"visible"`: the user returns to the tab or unlocks
  the phone) or the browser fires `online`. A wake starts a new round of
  attempts: the first at once, then the usual backoff (6 attempts, about
  7.75 s). Calls made during the round are queued. On success the page goes
  on as after any reconnect: `neel.onreconnect` fires and calls work again.
  If the round fails, it ends like the first give-up (each failed attempt
  fires `onclose(code, true)`, the last one `onclose(code, false)`, queued
  calls reject), and the shim is dormant again until the next event.
- Wake events matter only while the shim is dormant. While it is connected,
  reconnecting, or terminated they do nothing, so a burst of events starts
  one round, and a page becoming hidden never does anything.
- A page that goes dormant while it is visible and online (the tunnel was
  down for more than about 8 s while the user watched) stays dormant until
  a tab switch, a network change, or a reload.
- Deliberate closes end the shim for good, as in local mode: 1000
  (`neel.close()`), 1001 (the server stopped), and 4000 (displaced).
  `neel.close()` while dormant also ends it and fires `onclose(1000,
  false)`.
- `neel.ready` is a Promise and cannot settle twice: once rejected (the
  server was unreachable when the page loaded), it stays rejected, even
  though the shim may connect later. Use `neel.onreconnect` to learn that
  the page is connected again: it fires after every successful connection
  except the one that resolves `neel.ready`, so also when a shim that never
  connected wakes up and connects.

In page code: an `onclose(code, false)` whose code is not 1000, 1001, or
4000 means the shim went dormant.

A server restart is different. Every start generates a new launch token,
and the token is baked into the page's `/neel.js`. A connected page receives
1001 when the server stops, which ends its shim; a dormant page's wake
attempts are refused by the new server (403) and fail. Either way only a
reload, which fetches a fresh `/neel.js`, connects again.

### Reloading after a server restart

Reload the page when:

- the connection closed with 1001 (the server stopped), or
- the shim gave up right after a wake event (a failed wake): the server is
  reachable but no longer accepts the page's token, or is still down.

Never reload on 4000, for the reason given in
[One window, many devices](#one-window-many-devices).

Do not reload at once either: the server may not be back yet, and a reload
would leave the user on the browser's error page or the proxy's 502, from
which nothing recovers. Poll the page's own URL every 2 s instead and reload
once it answers with a 2xx or with a redirect (an authenticating proxy
sending the browser to its login page, which `redirect: "manual"` reports as
`type === "opaqueredirect"`). Network errors and 5xx (a tunnel or proxy
answers 502 while the app is down) mean keep waiting.

```js
const CLOSE_DISPLACED = 4000;
let dormant = false;          // the shim gave up and waits for a wake event
let wokeWhileDormant = false; // a wake event arrived while it was dormant
let waiting = false;          // polling, to reload once the server answers

function noteWake() {
  if (dormant) wokeWhileDormant = true;
}
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") noteWake();
});
window.addEventListener("online", noteWake);

neel.onreconnect(() => {
  dormant = false;
  wokeWhileDormant = false;
  waiting = false;
});

neel.onclose((code, reconnecting) => {
  dormant = false;
  if (reconnecting || code === CLOSE_DISPLACED || code === 1000) return;
  if (code === 1001 || wokeWhileDormant) reloadWhenServerIsBack();
  else dormant = true;
});

async function reloadWhenServerIsBack() {
  if (waiting) return;
  waiting = true; // show "waiting for the server" here
  while (waiting) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    try {
      const r = await fetch(location.href, { cache: "no-store", redirect: "manual" });
      if (waiting && (r.ok || r.type === "opaqueredirect")) {
        location.reload();
        return;
      }
    } catch (e) {
      // network error: the server or the tunnel is still down
    }
  }
}
```

- The flag marks the round of attempts that follows a wake event. The shim
  adds its own `visibilitychange` and `online` listeners when `/neel.js`
  runs, before the page's scripts, so on the same event the shim's wake has
  already started when the page's listener runs; a call made there is
  queued, not rejected as dormant.
- The first poll comes after 2 s, not at once: right after a 1001 the old
  server may still be answering for a moment.
- `cache: "no-store"` makes every poll reach the server, not the browser's
  cache.
- A wake can also fail because the network is still down (a phone in a
  tunnel). The poll then reloads as soon as the server is reachable, which
  does no harm, and stops if the shim reconnects first.
- A restart that the page first notices through an ordinary reconnect
  round, not a wake (a phone whose connection died unnoticed while it was
  locked, so it never saw the 1001), ends that round dormant; the next wake
  event then fails and reloads.
- A reload loses whatever lives only in the page (an unsaved draft); keep
  such state in `sessionStorage`, or on the server, if it matters.

`examples/serve` uses this recipe and shows the state on the page.

### Security in serve mode

In serve mode, Neel trusts whoever can reach the server. Put it behind a
private tunnel (Tailscale, WireGuard, an SSH port forward) or an
authenticating proxy (Cloudflare Access, Authelia, oauth2-proxy). Neel's own
checks keep other websites in the user's browser out: the WebSocket only
accepts the exact origins you list, `/neel.js` (which carries the token) is
not served to other sites, and the app cannot be framed by another site.
They do not authenticate the user.

- Only list origins you control; never a shared or wildcard domain.
- Cross-site top-level navigations are allowed so that links and login
  redirects work (an auth proxy's login page redirects back from another
  site, which makes the browser mark the request cross-site). Pages should
  therefore not perform actions based on URL parameters alone
  (`/?action=delete`) without user confirmation. Frames, scripts, and
  fetches from other sites are still refused.
- Another site can open the app in a new tab, which displaces the user's
  current page. It cannot read or control that tab. This is accepted as low
  risk.
- The HTTP server has request size limits (16 KiB of headers, 1 MiB of
  body) but no idle timeout for plain HTTP connections. Always put a real
  proxy or tunnel in front; never expose the port directly, for example
  with a plain TCP forward open to the network.
- The proxy must forward WebSocket upgrades on `/ws` (some proxies need
  explicit configuration for that, such as passing the `Upgrade` and
  `Connection` headers) and pass the browser's `Origin` through. `Host` may
  be rewritten to `127.0.0.1:<port>` or forwarded as the public host; both
  are accepted.
- Cloudflare quick tunnels (`trycloudflare.com`) get a new hostname every
  run, so they need a matching `allowedOrigins` entry each time. A quick
  tunnel is public and has no authentication: anyone who learns the URL can
  use the app.

### Setups

Three setups are documented so far. Other tunnels and reverse proxies should
work the same way when they meet the requirements above; they will be
documented here once verified.

**SSH port forward.** The simplest private setup, and it needs no allowed
origins: SSH authenticates the user, and the browser loads the app at Neel's
own origin.

```
# on the server
./myapp                                   # startApp(serve = true, port = 8080)

# on the laptop
ssh -N -L 8080:127.0.0.1:8080 user@server
```

Then open `http://127.0.0.1:8080` on the laptop. The local port must equal
the server's port, and the address must be `127.0.0.1`: `http://localhost:8080`,
or a different local port, sends another `Host` and `Origin` and is refused
with a 403 (`neel: refused: the Host header must be 127.0.0.1:8080`), unless
that origin is in `allowedOrigins` (`allowedOrigins =
@["http://localhost:8080"]`).

**cloudflared quick tunnel.** A way to try serve mode from a phone without
an account or a domain. Start the tunnel first, since its hostname is new
every run:

```
cloudflared tunnel --url http://127.0.0.1:8080
```

It prints a `https://<name>.trycloudflare.com` URL. Then start the app with
that URL as an allowed origin (cloudflared answers 502 until the app is up),
for example with `examples/serve`:

```
./examples/serve/serve --port=8080 https://<name>.trycloudflare.com
```

and open the URL on the phone. When cloudflared restarts, the hostname
changes: restart the app with the new origin and open the new URL. A quick
tunnel is public (see above), so use it only to try things out.

**Cloudflare Tunnel with Access.** For reaching the app from anywhere with a
login in front of it: a named tunnel gives the app a fixed hostname, and
Cloudflare Access authenticates the user before any request reaches Neel. It
needs a domain whose DNS Cloudflare runs and Zero Trust (both Free plans
work). With an Access application for `notes.example.com` (an Allow policy on
your e-mail address) and a tunnel whose `config.yml` sends that hostname to
`http://127.0.0.1:8080`:

```
cloudflared tunnel run myapp
./examples/serve/serve --port=8080 https://notes.example.com
```

The Access login redirects back from `<team>.cloudflareaccess.com`, which
makes the first page load cross-site; serve mode accepts that for top-level
navigations. With the reload recipe, a page whose login has expired reloads
into the login page when the app comes back; a reload that signs in silently
while the app is still down lands on Cloudflare's 502 page and needs a
manual reload. Step by step, including the dashboard, costs, and removal:
[Cloudflare Tunnel with Access](CLOUDFLARE_ACCESS.md).

## Caveats

- `Table[string, V]` and `HashSet` values come back to the page with keys in
  hash order, not insertion order (`OrderedTable` / `OrderedSet` keep order).
  Page code that compares objects should canonicalize key order.
- There is no ordering guarantee between messages on one connection
  (see [Threading model](#threading-model)).
- A blocking dialog (`prompt`, `alert`, `confirm`) inside a JS function that
  Nim called blocks that page's event loop, so other Nim -> JS calls to the
  same window wait behind it, and a `js.wait` on it can time out.
- An exposed proc that calls `quitApp()` returns normally, and its Promise
  usually resolves just before the 1001 close arrives. This is not
  guaranteed: if shutdown begins before the reply is on the wire, the reply
  is dropped and the call rejects with `NeelDisconnectedError` (`neel:
  connection lost (close code 1001)`). Either way a page cannot await "the
  app has exited"; later calls reject with `neel: connection is closed`, and
  `neel.onclose` fires when the close arrives.
- Chromium may discard a background tab or window (Memory Saver, memory
  pressure) and reload it only when the user returns to it. The discard closes
  the WebSocket, so to Neel it is a closed window: if the reload happens within
  `gracePeriodMs` it looks like a page refresh (same window id, `onWindowOpen`
  does not fire again, page-side state is gone); if it happens later the window
  has been retired and, if it was the last one, the app has exited. An app
  meant to sit in a background tab should raise `gracePeriodMs` (minutes rather
  than seconds). On `127.0.0.1` neither side closes an idle connection on its
  own, so local mode sends no keep-alive. Behind a proxy or tunnel that is no
  longer true; serve mode pings every connection that has been silent for
  30 s (see [Keep-alive pings](#keep-alive-pings)).
- `onWindowClose` fired during teardown (after `quitApp()`, for windows still
  open) runs with the window table already empty: `windows()` is `@[]` and
  `js` raises `NeelNoWindowError`. An exception escaping a hook is swallowed
  silently only when the hook ran on a pool worker (`onWindowOpen`); from
  `closeWindow` it propagates to the caller, and from the main thread
  (retirement, teardown) it escapes `startApp`. Catch inside the hook.
- Re-using a `Thread[T]` variable for a second run requires `joinThread` after
  the first finished; `examples/stresstest` shows the lock + flag pattern.
- A message from the page (a call, or a reply to `js.wait`, as JSON text)
  may be at most `maxMessageSize` (default 16 MiB, configurable in
  `startApp`); messages from Nim to the page are not limited. An HTTP
  request's header block may be at most 16 KiB.
- A page must not set a `no-referrer` referrer policy and should not use a
  `window` query parameter of its own (see [Multiple windows](#multiple-windows)).
- With `browsers = @[Default]` or after a fallback, the app runs in an
  ordinary browser tab: `size`, `position`, and `extraFlags` do not apply and
  the browser process is not tracked, so `closeWindow` disconnects the tab
  but cannot close it; refreshing that dead tab gets a 404 for `/neel.js`
  (its page scripts then fail with `neel is not defined`). Chromium
  suppresses `prompt` / `alert` / `confirm` in a background tab (`prompt`
  returns `null` at once).
- The launch token is new on every start and is baked into `/neel.js`, so a
  page left open from a previous run cannot reconnect. With the default
  ephemeral port the new run listens elsewhere, so refreshing the old page
  fails too. With a fixed `port`, refreshing it fetches a fresh shim and the
  page binds as the window its URL names, displacing the window the new run
  opened under that id (which then closes with 4000, `CloseDisplaced`, and
  does not reconnect). A second app started on a fixed port that another
  app already listens on fails at start with `OSError`, on every OS.
- `openWindow`, `closeWindow`, and `quitApp` require a running `startApp`;
  called before it starts or after it returns they fail an assertion.
  `windows()` is then empty, `window(id)` is `none`, and `js` raises
  `NeelNoWindowError`. Only one `startApp` may run at a time per process.
- On Windows, Ctrl-C crashes a debug build (one without `-d:release`)
  wherever Nim's own Ctrl-C handler runs, which includes every local-mode
  app. After a short pause the process ends with an access violation
  (`$LASTEXITCODE` is `-1073741819`, `0xC0000005`) instead of printing
  `SIGINT: Interrupted by Ctrl-C.` and exiting with 1. Windows runs the
  handler on a thread of its own, and in a debug build the handler
  allocates there to build a stack trace. Any Nim program built this way
  does it, with or without Neel. Nothing else is lost, since Ctrl-C ends
  a local-mode app without Neel's shutdown anyway, but expect the crash.
  To stop a local-mode app cleanly, close its windows or call `quitApp()`.
  Release builds are not affected, and neither is serve mode, which
  handles Ctrl-C itself.

## The examples

- [`examples/filepicker`](../examples/filepicker) - the hello world above: one
  exposed proc with a return value and two structured errors, `startApp()`
  with defaults.
- [`examples/roundtrip`](../examples/roundtrip) - return values in both
  directions (`neel.sum`, `askPage` through an async `neel.expose` target),
  a second window (`openWindow`, `requireWindow(id).js.wait(5000).ask(...)`,
  `closeWindow`, `windows()`), window hooks, and the four error kinds the
  first page can see (`PromptCancelled` forwarded from JS, `NeelTimeoutError`,
  `NeelDisconnectedError`, `NeelNoWindowError`). Primarily a test of the
  multi-window and bidirectional-return-value machinery, but also a compact
  reference for how communication flows between windows.
- [`examples/stresstest`](../examples/stresstest) - a manual test harness that
  exercises every feature in one page: every supported type, every error kind,
  500 concurrent calls, 2 MB payloads, pushes from a plain thread, multi-window
  broadcasts, lifecycle events, and more. Mainly for verifying Neel itself, but
  useful as a reference for how each API behaves under load and in edge cases.
- [`examples/serve`](../examples/serve) - [serve mode](#serve-mode): a
  shared note held in Nim memory under a `Lock`, served on port 5359 without
  a browser, `neel.getNote()` on load and after every reconnect, the
  server's pid and start time, and a "Stop server" button (`quitApp()`).
  The page handles every serve-mode connection state: connected,
  reconnecting, dormant, displaced by another device (4000, with a button
  that takes the session back), and the
  [reload recipe](#reloading-after-a-server-restart). Positional arguments
  are allowed origins and `--port=N` replaces the port
  (`./serve https://<name>.trycloudflare.com`).

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
| Chrome only | `browsers = @[Chrome, Chromium, Edge]` with `fallback` to the default browser and a `browserPath` override |
| one window | `openWindow`, `closeWindow`, `windows`, `window`, `requireWindow`, `currentWindow`, hooks |
| default parameter values unsupported | supported (positional) |
| exit roughly 3 s / 10 s after the socket closes | the same defaults, now `gracePeriodMs`, plus `quitApp()` and `startApp` returning an `ExitReason` |
| assets embedded in release builds | the same, now `embedAssets = defined(release)` and overridable |
| `--threads:on --mm:orc` on Nim 1.6 | Nim >= 2.2.12 required; no flags |
| re-exported `std/os`, `std/osproc`, `std/strutils`, `std/json`, `std/threadpool`, `std/browsers`, `std/jsonutils`, Mummy | re-exports only `std/json` and `std/options`; import the rest yourself; no external dependencies |

Unchanged: the page loads `/neel.js` before its own script, assets use
absolute paths and are served from the web directory at `/`, the default start
page is `index.html` (`startPath` picks another), and the server listens on
`127.0.0.1` only.

## License

MIT; see [`LICENSE`](../LICENSE).
