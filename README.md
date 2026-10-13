# Neel | HTML/JS GUI Library for Nim

Neel is a Nim library for making lightweight Electron-like HTML/JS GUI apps, with full access to Nim capabilities.

Write the user interface in HTML, CSS, and JavaScript and everything else in Nim. Mark a Nim proc with `{.expose.}` and the HTML page calls it as `neel.<name>(...)`, getting the return value back through a Promise; register a JS function with `neel.expose` and Nim calls it as `js.<name>(...)`, or as `js.wait.<name>(...)` when it needs the answer. Neel takes care of the server, the browser window, the JSON conversion, and the errors in between.

> Neel runs its own thread-based HTTP/WebSocket server on `127.0.0.1`, in the spirit of [Mummy](https://github.com/guzba/mummy): one IO thread owns the sockets, a pool of worker threads runs your procs, and there is no async anywhere. It opens Chrome, Chromium, or Edge in app mode on that server, so your app gets its own window without tabs or an address bar. When none of them is installed, or when you ask for it, the app opens in a tab of your default browser instead.

**This README gets you started and very well may be all you need. Every detail (the full type list, error messages, browser discovery, lifecycle, threading, and caveats) is in the [Neel 2.0 guide](docs/GUIDE.md).**

Features:

- Its own thread-based HTTP/WebSocket server, similar to Mummy: an IO thread plus a worker pool, no async
- Return values in both directions: Promises in JS, blocking `js.wait` calls with timeouts in Nim
- `{.expose.}` on any top-level proc, in any module of your app
- Automatic type conversion, including objects, `Option`, `Table`, and default parameter values
- Structured errors across the bridge: a Nim exception reaches JS as `e.name` / `e.message`, a JS error reaches Nim as `NeelRemoteError`
- Multiple windows, each addressable from Nim
- Browser discovery (Chrome, Chromium, Edge) with a default-browser fallback
- Frontend assets embedded into the binary in `release` builds
- Zero dependencies: the Nim standard library only
- Hardened against other websites open in the same browser

Neel was originally inspired by [Eel](https://github.com/python-eel/Eel), its Python cousin, and how now since grown far beyond it with our v2.0 release.

---



## Introduction

If you want to use HTML/JS as a GUI option for Nim you can expect a lot of boilerplate: a web server, a WebSocket protocol, JSON in and out of every call, and a browser to launch and clean up after.

The best visualization libraries that exist are in JavaScript, and the most powerful capabilities of software can be harnessed with Nim. The goal of Neel is to combine the two languages, write the glue for you, and help you create some killer applications.

## Requirements and Platforms

- Nim >= 2.2.12. Neel refuses to compile with older versions, whose allocators crash when memory is freed across threads.
- No Nimble dependencies, only the standard library.
- Google Chrome, Chromium, or Microsoft Edge for app-mode windows; without one of them, any default browser, in a tab.

Neel 2.0 is verified on macOS, Windows, and Linux (Ubuntu). Edge is verified on Windows only (as Edge is just edge-case browser on other OSs).

## Installation

Install from nimble:

```
nimble install neel
```

To try the examples, clone the repository and run them from its root (no setup needed):

```
git clone https://github.com/Niminem/Neel.git
cd Neel
nim c -r examples/filepicker/filepicker.nim
```



## Usage



### Directory Structure

A Neel application consists of Nim modules and a single folder of static web assets (HTML, CSS, JS, images, ...), which can be divided into more folders within it if necessary.

```
main.nim            <----\
database.nim        <-------- Nim files (exposed procs may live in any of them)
other.nim           <----/
web/                <-------- Web folder: "web" by default, any name via startApp's webDir
  index.html        <-------- The default start page ("/" serves index.html. startApp's startPath param can pick another)
  css/
    style.css
  js/
    main.js
```

- The web folder is resolved relative to the Nim source file that calls `startApp`, not the working directory, so the app runs from anywhere. An absolute path works too.
- The web folder is served at `/`. The first window opens `/`, which serves `index.html` from the root of the web folder; to start on another page, pass `startPath` (`startApp(startPath = "/app.html")`), and `index.html` is then not needed.
- Use absolute paths for assets in your pages: `<script src="/js/main.js">`, `<link rel="stylesheet" href="/css/style.css">`.



### Developing the Application



#### Nim / Backend

We begin with a complete example, [`examples/filepicker`](examples/filepicker): the page asks for a directory and Nim picks a random entry from it (something a browser alone cannot do). From there I'll explain each part in detail.

(filepicker.nim)

```nim
import std/[os, random]
import neel #1

type
  MissingDirectoryError = object of CatchableError
  EmptyDirectoryError = object of CatchableError

proc filePicker(directory: string): string {.expose.} = #2
  let dir = absolutePath(directory, root = getHomeDir())
  if not dirExists(dir):
    raise newException(MissingDirectoryError, "no such directory: " & dir)
  var names: seq[string]
  for _, path in walkDir(dir):
    names.add path.extractFilename
  if names.len == 0:
    raise newException(EmptyDirectoryError, "the directory is empty: " & dir)
  var rng = initRand() # exposed procs run on worker threads: no global random state
  rng.sample(names)

startApp() #4
```



##### #1 import neel

`import neel` is the only import Neel needs. Besides Neel's own API it re-exports `std/json` (`JsonNode`, `getStr`, `getInt`, `.to(T)`, `%*`) and `std/options` (`some`, `none`, `isSome`, `get`), because the API hands out values of those types. Nothing else is re-exported: import `std/os` and friends yourself, as above.

##### #2 {.expose.}

`{.expose.}` makes a proc callable from the page as `neel.<name>(...)`. Neel converts the JSON arguments to the parameter types, calls the proc, and sends the return value back. The rules:

- The proc must be top-level (in any module of your app) and GC-safe. It runs on a worker thread, concurrently with other calls (see [Before You Start](#before-you-start)).
- The JS name is spelled exactly like the Nim name: `proc file_picker` is `neel.file_picker`, not `neel.filePicker`, even though Nim treats the two as the same name. Exposed names must be unique across modules.
- Parameters and results may be `bool`, integers, floats, `string`, enums, `seq`, `array`, `set`, tuples, objects, `ref`, `Option`, `Table[string, V]`, `HashSet`, or `JsonNode`. Default parameter values work: the page may leave trailing arguments out. A proc without a result resolves the Promise with `null`.
- Errors cross the bridge: a `CatchableError` raised in the proc rejects the page's Promise with an `Error` whose `name` is the Nim exception type (`"MissingDirectoryError"`) and whose `message` is its `msg`. Wrong arguments reject with a `NeelArgumentError`.

The full rules, the type list, and every error message: [Exposing Nim procs to the page](docs/GUIDE.md#exposing-nim-procs-to-the-page).

##### #3 js and js.wait

The file picker never calls back into the page, so there is no `#3` above. When you need to, `js` calls a JS function the page registered with `neel.expose` (see [Calling JS from Nim](#calling-js-from-nim-neelexpose)) or a global function such as `alert`:

```nim
proc notify(text: string) {.expose.} =
  js.showToast(text)                    # fire-and-forget, returns nothing

proc askPage(question: string): string {.expose.} =
  let reply = js.wait.answer(question)  # blocks until the page answers (10 s timeout)
  "the page answered: " & reply.getStr

proc askQuickly(question: string): string {.expose.} =
  js.wait(500).answer(question).getStr  # explicit timeout in milliseconds
```

- `js.foo(...)` sends and returns at once. `js.wait.foo(...)` blocks the calling thread until the page replies and returns the result as a `JsonNode` (unpack it with `getStr`, `getInt`, or `.to(MyType)`). If the JS function throws, the call raises `NeelRemoteError`; no reply within the timeout raises `NeelTimeoutError`.
- `js` works only inside an exposed proc, where it targets the window whose page made the call. Anywhere else (the main thread, your own threads, window hooks) it raises `NeelNoWindowError`; use a window's handle instead: `win.js.foo(...)`, `win.js.wait.foo(...)` (see [Multiple Windows](#multiple-windows)).
- A name that a Nim proc in scope also accepts goes to Nim, silently: `js.echo("x")` calls Nim's `echo`. For such names, and for names known only at runtime, use `jsSend(js, "echo", @[%"x"])` or `jsCallWait(js.wait, "name", @[])`.

More: [Calling the page from Nim](docs/GUIDE.md#calling-the-page-from-nim-js).

##### #4 startApp

`startApp` finds a browser, starts the server, opens the first window, and blocks until the app ends: a few seconds after the last window closes (the grace period, see [Compilation](#compilation)), or as soon as an exposed proc calls `quitApp()`. It returns an `ExitReason`, which you may ignore.

`startApp` must come after every exposed proc and after the imports of modules that contain exposed procs; a proc exposed after it cannot be called from the page. It may sit inside `proc main()`.

All arguments are optional keyword arguments (the web folder may also be given positionally, `startApp("assets")`):

```nim
startApp(webDir = "web", size = some((1100, 800)), position = some((80, 80)),
         browsers = @[Chrome, Chromium, Edge], fallback = true)
```


| Parameter                       | Default                     | Meaning                                                                                                                |
| ------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `webDir`                        | `"web"`                     | the web folder, relative to this source file unless absolute                                                           |
| `startPath`                     | `"/"`                       | the page the first window opens (`"/"` serves `index.html`)                                                            |
| `port`                          | `0`                         | port on `127.0.0.1`; 0 picks a free one                                                                                |
| `size`, `position`              | none                        | `some((width, height))`, `some((x, y))` for app-mode windows                                                           |
| `browsers`                      | `@[Chrome, Chromium, Edge]` | browsers to try, in order; `@[Default]` always opens a default-browser tab                                             |
| `fallback`                      | `true`                      | open a default-browser tab when none of `browsers` is found (`false`: show an error page and raise `NeelBrowserError`) |
| `gracePeriodMs`                 | 3 000 debug, 10 000 release | how long the app stays up after the last window closes                                                                 |
| `onWindowOpen`, `onWindowClose` | `nil`                       | window hooks (see [Multiple Windows](#multiple-windows))                                                               |


Every parameter (workers, timeouts, message size, extra browser flags, `browserPath`, ...): [`startApp` parameters](docs/GUIDE.md#startapp-parameters).

#### JavaScript / Frontend

The page side of the file picker:

(web/index.html)

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Neel file picker</title>
  <link rel="icon" href="data:,">
  <link rel="stylesheet" href="/style.css">
  <script src="/neel.js"></script> <!-- LOAD THIS FIRST!!! -->
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

(web/main.js)

```javascript
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

- Load `/neel.js` with a classic `<script>` tag before your own scripts. Neel serves it for each window; it defines one global, `neel` (module scripts read it as `window.neel`).
- `neel.filePicker(...)` exists because the Nim proc is exposed. It returns a Promise that resolves with the return value or rejects with the Nim exception as `e.name` / `e.message`, which is how the page above shows `MissingDirectoryError: no such directory: ...`.
- `neel.filePicker.send(...)` is the fire-and-forget form: no Promise, no reply, and failures are not reported.
- `neel.ready` is a Promise resolved once the connection is up. Calls made before that are queued and sent on connect, so you rarely need it.
- `neel.onclose((code, reconnecting) => ...)` tells the page when the connection closes. After an unexpected drop the page reconnects by itself; `reconnecting` says whether another attempt follows.



##### Calling JS from Nim: neel.expose

The other direction, the page side of `#3` above: `neel.expose` registers JS functions that Nim calls with `js.<name>(...)` and `js.wait.<name>(...)`. A function may be plain or async. A plain function's return value goes straight back to Nim; a returned Promise is awaited first, so `js.wait` receives the resolved value. A throw (or a rejected Promise) reaches Nim as a `NeelRemoteError` carrying the JS error's name and message.

```javascript
neel.expose(function showToast(text) {          // plain: Nim's js.showToast(text)
  document.getElementById("toast").textContent = text;
});

neel.expose(async function answer(question) {   // async: Nim's js.wait.answer(question)
  return prompt(question);
});
```

`neel.expose(fn)` registers `fn` under `fn.name`, `neel.expose("name", fn)` under an explicit name, and `neel.expose({showToast, answer})` several at once. Nim can also call global functions such as `alert` without registering them.

The full API: [The `neel.js` API](docs/GUIDE.md#the-neeljs-api).

### Multiple Windows

Each browser window is a `Window` handle with an `id` and its own `js`. `startApp` opens the first window; open more from Nim with `openWindow`. From [`examples/roundtrip`](examples/roundtrip):

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

- `openWindow(path)` opens a window at a page of your web folder (`size` and `position` are optional) and returns its `Window`. `closeWindow(w)` closes it.
- `windows()` lists the open windows and `window(id)` returns an `Option[Window]`. `requireWindow(id)` returns the window or raises `NeelNoWindowError`, which reaches the page as a structured error instead of crashing the app. `currentWindow()` is the window whose call is running.
- `startApp(onWindowOpen = ..., onWindowClose = ...)` takes hooks of type `proc(w: Window) {.gcsafe.}`, called when a window's page first connects and when a window is closed.

Navigating within a window (a plain link or `location.href`) drops `?window=<id>` from the URL, which only works while that window is the only one open; in multi-window apps, carry the query along (`"/other.html" + location.search`) or keep each window on one page. Open extra windows with `openWindow`, not `window.open`, and don't set a `no-referrer` referrer policy.

Details, including when the hooks fire and on which thread: [Multiple windows](docs/GUIDE.md#multiple-windows).

## Compilation

During development, compile a debug build:

```
nim c -r main.nim
```

The web folder is read from disk on every request, so you can edit a page and refresh to see the change. The app exits about 3 seconds after its last window closes.

For distribution, compile a release build:

```
nim c -d:release main.nim
```

Every file in the web folder is embedded into the binary at compile time, so the binary no longer needs the folder and can be moved anywhere. The app exits about 10 seconds after its last window closes. The `embedAssets` parameter overrides the asset mode either way (see [Assets and build modes](docs/GUIDE.md#assets-and-build-modes)).

Add `--app:gui` to release builds to avoid a visible terminal window:
on Windows this suppresses the console window; on macOS it produces an
`.app` bundle that launches without a Terminal session. On Linux most
window managers already hide the terminal of a backgrounded process.

## Before You Start

Keep the following in mind when developing your Neel app:

- Exposed procs run concurrently on worker threads, even two calls from the same page issued back to back. Guard shared state with a `Lock`, an `Atomic`, or a channel.
- There is no ordering guarantee between messages on one connection: if one call must finish before the next starts, `await` it first.
- A Defect (`IndexDefect`, `AssertionDefect`, ...) raised in an exposed proc terminates the app; only `CatchableError`s become errors in the page.
- The grace period (3 s in debug builds, 10 s in release builds, `gracePeriodMs`) exists because a page refresh or a dropped connection looks like a closed window for a moment; the app exits only when no window comes back within it.
- Security: the server binds `127.0.0.1` only, and a per-launch token plus `Host` and `Origin` checks keep other websites in the user's browser out. The local machine is trusted, so treat the arguments of an exposed proc as untrusted input.

More in [Threading model](docs/GUIDE.md#threading-model), [Security](docs/GUIDE.md#security), and [Caveats](docs/GUIDE.md#caveats).

## Examples

Run them from the repository root with `nim c -r examples/<name>/<name>.nim`:

- [File picker](examples/filepicker): the example above, and the one to start with; one exposed proc with a return value and two structured errors.

The other two exist mostly for manual (and stress) testing of Neel itself, but they are interesting to read to see how Neel does things:

- [Round trip](examples/roundtrip): return values in both directions, a second window, window hooks, and the errors a page sees when the other window is slow, closed, or throws.
- [Stress test](examples/stresstest): exercises every feature in one page, under load and in edge cases (every supported type, every error kind, hundreds of concurrent calls, large payloads, pushes from a plain thread).



## What's New in 2.0 / Migrating from 1.x

Neel 2.0 is a ground-up rewrite: its own multi-threaded HTTP/WebSocket server replaces Mummy, calls return values in both directions, and an app can open several windows. Nothing from 1.x compiles unchanged; the main renames:


| 1.x                                                           | 2.0                                                                                             |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `exposeProcs:` block                                          | `{.expose.}` on each top-level proc, in any module                                              |
| `callJs("fn", a, b)`                                          | `js.fn(a, b)`, or `js.wait.fn(a, b)` for the return value                                       |
| `neel.callNim("proc", a, b)`                                  | `neel.proc(a, b)` (a Promise), or `neel.proc.send(a, b)`                                        |
| `startApp(webDirPath = ..., portNo = ..., chromeFlags = ...)` | `startApp(webDir = ..., port = ..., extraFlags = ...)`; `webDir` is relative to the source file |
| `size = [600, 600]`, `position = [500, 150]`                  | `size = some((600, 600))`, `position = some((500, 150))`                                        |
| `appMode = false`                                             | `browsers = @[Default]`                                                                         |
| `--threads:on --mm:orc` on Nim 1.6                            | Nim >= 2.2.12, no flags                                                                         |


Neel no longer re-exports `std/os`, `std/strutils`, and the rest; of the standard library it re-exports only `std/json` and `std/options`. The full table: [Migrating from Neel 1.x](docs/GUIDE.md#migrating-from-neel-1x).

## Future Work

The vision for this library is to eventually have it be as full-fledged as Electron for Nim. Next on the list:

- [ ] **Brave, Opera, and Vivaldi.** They are already members of the `Browser` enum, reserved and skipped during discovery for now.
- [ ] **Webview capabilities.** [Webview](https://github.com/webview/webview) is an MIT licensed cross-platform webview library for C/C++. Uses WebKit (GTK/Cocoa) and Edge WebView2 (Windows). Having a webview target will get us closer to a solid framework for shipping commercial builds.
- [ ] **Custom routes.** Let an app answer HTTP requests with its own Nim handlers next to the web folder, so pages can be rendered with template engines and the like.
- [ ] **Secure WebSockets (`wss:`).** The page side already switches to `wss:` when served over `https:`; the server does not speak TLS yet.



## License

MIT; see [`LICENSE`](LICENSE).