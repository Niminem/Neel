## serve.nim - serve mode: the app runs as a persistent server for one user
## and is opened from any of their devices, through an SSH port forward or a
## tunnel. No browser is launched.
##
## What it shows:
## - `startApp(serve = true, port = ..., allowedOrigins = ...)`: the app runs
##   until "Stop server" on the page (`quitApp()`) or a stop signal (Ctrl-C,
##   `SIGTERM`, closing the console window on Windows), and prints the
##   startup line `neel: serving http://127.0.0.1:5359 (allowed origins: ...)`.
## - One shared note, held in Nim memory under a `Lock`. The page asks for it
##   with `neel.getNote()` on load and after every reconnect, so an edit
##   saved on another device shows up when this one takes the session back.
## - The server's pid and start time, so a page can tell a server restart
##   from a reconnect.
## - What a page sees in serve mode (`web/main.js`): connected, reconnecting,
##   dormant (the shim gave up and waits for the page to become visible or
##   the network to come back), displaced by another device (close code
##   4000, with a button to take the session back), and the reload recipe
##   after the server stopped or restarted.
##
## How to run (from any directory; the paths below are relative to the repo):
##
##   nim c -r examples/serve/serve.nim
##       debug build: `web/` is served from disk. Open
##       http://127.0.0.1:5359 in any browser on this machine.
##
##   nim c -d:release examples/serve/serve.nim
##   ./examples/serve/serve --port=8080 https://notes.example.com
##       release build: `web/` is embedded. Every positional argument is an
##       allowed origin (the public URL of a tunnel or proxy, without a path
##       or a trailing `/`); `--port=N` replaces the default port 5359.
##
## From another device:
##
## - SSH port forward (no allowed origin needed): on the device, run
##   `ssh -L 5359:127.0.0.1:5359 <user>@<this machine>` and open
##   http://127.0.0.1:5359 there. Use the same port on both sides and the
##   address 127.0.0.1: `http://localhost:5359`, or another local port, is
##   refused with a 403 unless that origin is passed as an argument
##   (`./examples/serve/serve http://localhost:5359`).
## - cloudflared quick tunnel (not yet verified): first run
##   `cloudflared tunnel --url http://127.0.0.1:5359` and note the
##   https://<name>.trycloudflare.com URL it prints (it is new every time
##   cloudflared starts), then start the app with that URL as an argument
##   and open it on the device. cloudflared answers 502 until the app is up.
##   A quick tunnel is public: anyone who learns the URL can use the app.
##
## Opening the app on a second device (or in a second tab) displaces the
## first one, which shows "opened on another device".

import std/[locks, os, parseopt, strutils, times]
import neel # also brings std/json and std/options

const
  DefaultPort = 5359
  Usage = "usage: serve [--port=N] [allowed origin ...]\n" &
          "  e.g. serve --port=8080 https://notes.example.com"

type
  Note = object
    ## The shared note and when it was last saved (Unix time in ms, 0 when
    ## it never was).
    text: string
    savedMs: int64

  ServerInfo = object
    ## Changes only when the server restarts.
    pid: int
    startedMs: int64

proc unixMs(): int64 =
  int64(epochTime() * 1000)

let
  pid = getCurrentProcessId()
  startedMs = unixMs()

var
  noteLock: Lock
  note: Note # guarded by noteLock

initLock noteLock

proc getNote(): Note {.expose.} =
  ## The shared note. Pages ask for it on load and after every reconnect:
  ## `onWindowOpen` fires only once in serve mode, so it cannot tell a page
  ## that another device changed the note in the meantime.
  withLock noteLock:
    {.cast(gcsafe).}: # `note` is only touched under `noteLock`
      result = note

proc saveNote(text: string): Note {.expose.} =
  ## Replaces the shared note and returns it with its new save time.
  withLock noteLock:
    {.cast(gcsafe).}: # `note` is only touched under `noteLock`
      note = Note(text: text, savedMs: unixMs())
      result = note

proc serverInfo(): ServerInfo {.expose.} =
  ServerInfo(pid: pid, startedMs: startedMs)

proc stopServer() {.expose.} =
  quitApp() # only signals; startApp returns erQuit on the main thread

var port = DefaultPort
var origins: seq[string]
for kind, key, val in getopt():
  case kind
  of cmdArgument:
    origins.add key
  of cmdLongOption, cmdShortOption:
    if key != "port":
      quit("serve: unknown option " & key & "\n" & Usage)
    try:
      port = parseInt(val)
    except ValueError:
      quit("serve: --port expects a number, got " & escape(val) & "\n" & Usage)
    if port notin 1 .. 65535:
      quit("serve: --port must be 1-65535\n" & Usage)
  of cmdEnd:
    discard

try:
  let reason = startApp(serve = true, port = port, allowedOrigins = origins)
  echo "serve exited: ", reason
except ValueError, OSError:
  # A malformed origin, or a port another program already listens on.
  let e = getCurrentException()
  quit($e.name & ": " & e.msg)
