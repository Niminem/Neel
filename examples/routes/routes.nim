## routes.nim - custom routes: an app with no web directory at all. Every
## page is rendered in Nim, a form posts to a route, and a webhook pushes
## into the open page.
##
## What it shows:
## - `startApp(webDir = "", routes = @[...])`: no `web/` folder; `get`,
##   `post`, and path parameters (`/messages/@id`). (Leaving `webDir` out
##   works too, because there is no `web/` folder next to this file; `""`
##   says it explicitly.)
## - A page rendered by a route is a Neel page like any other as long as it
##   loads `/neel.js`: `neel.clearInbox()` below is an ordinary exposed proc.
## - A form submission (`POST /messages`, urlencoded body) answered with a
##   303 redirect back to the page.
## - A webhook (`POST /hooks/demo`, JSON body) that stores the message and
##   pushes it into the open page with `js.messageArrived(...)`. A route
##   handler has a current window when the request names one or, as here,
##   when only one window is open.
## - Shared state under a `Lock`: route handlers run on worker threads,
##   exactly like exposed procs.
##
## How to run (from any directory; the paths below are relative to the repo):
##
##   nim c -r examples/routes/routes.nim
##       opens the app window on the fixed port 5360. While it is open, send
##       the webhook from a terminal and watch the message appear:
##
##       curl -X POST http://127.0.0.1:5360/hooks/demo -H "Content-Type: application/json" -d "{\"text\":\"hello from curl\"}"
##
##       (Windows PowerShell: write `curl.exe`, and `'{\"text\":\"hi\"}'`
##       for the body.) `curl http://127.0.0.1:5360/api/messages` lists the
##       inbox as JSON.
##
##   nim c -r examples/routes/routes.nim --serve
##       the same routes in serve mode: no browser is launched; open
##       http://127.0.0.1:5360 yourself and stop the app with Ctrl-C.
##
## A real webhook (Slack, GitHub, ...) needs serve mode behind a tunnel or
## proxy, the tunnel's public origin in `allowedOrigins`, and a handler that
## verifies the sender's signature over `req.body` before trusting it: Neel
## lets any program that can reach the server call a route.

import std/[locks, os, strutils, uri]
import neel # also brings std/json and std/options

const Port = 5360

type
  Message = object
    id: int
    source: string # "form" or "webhook"
    text: string

var
  inboxLock: Lock
  inbox: seq[Message] # guarded by inboxLock
  lastId: int         # guarded by inboxLock

initLock inboxLock

proc addMessage(source, text: string): Message =
  withLock inboxLock:
    {.cast(gcsafe).}: # `inbox` and `lastId` are only touched under `inboxLock`
      inc lastId
      result = Message(id: lastId, source: source, text: text)
      inbox.add result

proc messages(): seq[Message] =
  withLock inboxLock:
    {.cast(gcsafe).}:
      result = inbox # a copy; safe to use after the lock is released

proc clearInbox(): int {.expose.} =
  ## Empties the inbox and returns how many messages it held.
  withLock inboxLock:
    {.cast(gcsafe).}:
      result = inbox.len
      inbox.setLen 0

# --- rendering -------------------------------------------------------------------

proc esc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc page(title, content: string): string =
  ## Every page loads `/neel.js`: that is what binds it to its window.
  "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n" &
  "<title>" & esc(title) & "</title>\n<link rel=\"icon\" href=\"data:,\">\n" &
  "<style>body{font:16px/1.5 system-ui,sans-serif;max-width:40em;margin:2em auto;" &
  "padding:0 1em}small{color:#777}input{font:inherit;width:60%}</style>\n" &
  "<script src=\"/neel.js\"></script>\n</head><body>\n<h1>" & esc(title) &
  "</h1>\n" & content & "</body></html>\n"

proc item(m: Message): string =
  "<li><a href=\"/messages/" & $m.id & "\">#" & $m.id & "</a> <small>" &
    esc(m.source) & "</small> " & esc(m.text) & "</li>\n"

const HomeScript = """
<script>
neel.expose(function messageArrived(m) {
  const li = document.createElement("li");
  li.textContent = "#" + m.id + " " + m.source + " " + m.text + " (pushed live)";
  document.getElementById("inbox").append(li);
});
document.getElementById("clear").onclick = async () => {
  await neel.clearInbox();
  location.reload();
};
</script>
"""

# --- routes ----------------------------------------------------------------------

proc home(req: HttpRequest): HttpResponse =
  var items = ""
  for m in messages():
    items.add item(m)
  htmlResponse(page("Inbox",
    "<ul id=\"inbox\">\n" & items & "</ul>\n" &
    "<form method=\"post\" action=\"/messages\">\n" &
    "<input name=\"text\" placeholder=\"a message\" autocomplete=\"off\" required>\n" &
    "<button>Add</button> <button id=\"clear\" type=\"button\">Clear</button>\n</form>\n" &
    HomeScript))

proc showMessage(req: HttpRequest): HttpResponse =
  for m in messages():
    if $m.id == req.param("id"):
      return htmlResponse(page("Message #" & $m.id,
        "<p>" & esc(m.text) & "</p>\n<p><small>from the " & esc(m.source) &
        "</small></p>\n<p><a href=\"/\">Back</a></p>\n"))
  htmlResponse(page("No such message", "<p><a href=\"/\">Back</a></p>\n"), 404)

proc postMessage(req: HttpRequest): HttpResponse =
  ## The form on the home page: `text=...`, urlencoded.
  for (key, value) in decodeQuery(req.body):
    if key == "text" and value.strip().len > 0:
      discard addMessage("form", value.strip())
  redirectResponse("/", 303) # the browser then loads `/` with GET

proc listMessages(req: HttpRequest): HttpResponse =
  jsonResponse(%messages())

proc demoHook(req: HttpRequest): HttpResponse =
  ## `{"text": "..."}` from any program. Answers at once; a slow job would
  ## be handed to another thread instead of making the sender wait.
  var text = ""
  try:
    text = parseJson(req.body){"text"}.getStr
  except JsonParsingError:
    discard
  if text.len == 0:
    return jsonResponse(%*{"ok": false, "error": "expected {\"text\": \"...\"}"}, 400)
  let m = addMessage("webhook", text)
  try:
    js.messageArrived(m) # the open page, when there is one
  except NeelNoWindowError:
    discard # nobody is looking; the message shows on the next page load
  jsonResponse(%*{"ok": true, "id": m.id}, 202)

let serve = "--serve" in commandLineParams()
let reason = startApp(webDir = "", port = Port, serve = serve, routes = @[
  get("/", home),
  get("/messages/@id", showMessage),
  post("/messages", postMessage),
  get("/api/messages", listMessages),
  post("/hooks/demo", demoHook)])
echo "routes exited: ", reason
