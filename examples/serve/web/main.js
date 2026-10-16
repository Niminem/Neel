// main.js - the serve-mode example page: a shared note, and every connection
// state a serve-mode page can be in.

"use strict";

const CLOSE_DISPLACED = 4000; // neel.onclose's code when another device took over
const POLL_MS = 2000;

const byId = (id) => document.getElementById(id);
const status = byId("status");
const takeBack = byId("take-back");
const editor = byId("editor");
const error = byId("error");

let state = "connecting";
let wokeWhileDormant = false; // a wake event arrived while the shim was dormant
let waiting = false;          // polling the server, to reload once it answers
let savedText = "";           // the note as last loaded or saved
let reconnects = 0;

byId("loaded-at").textContent = new Date().toLocaleTimeString();

function show(newState, text) {
  state = newState;
  status.dataset.state = newState;
  status.textContent = text;
  takeBack.hidden = newState !== "displaced";
}

function showError(e) {
  error.textContent = e.name + ": " + e.message;
}

function showNote(note) {
  if (editor.value === savedText) editor.value = note.text; // keeps unsaved edits
  savedText = note.text;
  byId("saved-at").textContent = note.savedMs === 0
    ? "never saved"
    : "saved " + new Date(note.savedMs).toLocaleString();
}

// Serve mode fires onWindowOpen only once, ever, so the page asks for its
// state itself: on the first connection and after every reconnect. That is
// also how an edit saved on another device shows up here.
async function load() {
  try {
    const [note, info] = await Promise.all([neel.getNote(), neel.serverInfo()]);
    showNote(note);
    byId("pid").textContent = String(info.pid);
    byId("started-at").textContent = new Date(info.startedMs).toLocaleString();
  } catch (e) {
    showError(e);
  }
}

function connected() {
  wokeWhileDormant = false;
  waiting = false;
  error.textContent = "";
  show("connected", "connected");
  load();
}

// After the server stopped (1001) or restarted (a wake that failed), wait
// until it answers again, then reload: a restarted server has a new launch
// token, which only a fresh /neel.js carries. A redirect counts as an answer
// (an auth proxy sending the browser to its login page); network errors and
// 5xx (a tunnel or proxy whose app is down) mean keep waiting.
async function reloadWhenServerIsBack(text) {
  show("waiting", text + " Waiting for the server; this page reloads when it answers.");
  if (waiting) return;
  waiting = true;
  while (waiting) {
    await new Promise((resolve) => setTimeout(resolve, POLL_MS));
    try {
      const r = await fetch(location.href, { cache: "no-store", redirect: "manual" });
      if (waiting && (r.ok || r.type === "opaqueredirect")) {
        location.reload();
        return;
      }
    } catch (e) {
      // still unreachable
    }
  }
}

neel.ready.then(connected, () => {}); // a failure is reported through onclose

neel.onreconnect(() => {
  reconnects += 1;
  byId("reconnects").textContent = String(reconnects);
  connected();
});

neel.onclose((code, reconnecting) => {
  if (reconnecting) {
    show("reconnecting", "connection lost (close code " + code + "), reconnecting");
  } else if (code === CLOSE_DISPLACED) {
    // Final, and never followed by an automatic reload: two devices would
    // take the session from each other forever.
    show("displaced", "opened on another device");
  } else if (code === 1001) {
    reloadWhenServerIsBack("The server stopped.");
  } else if (code === 1000) {
    show("closed", "closed");
  } else if (wokeWhileDormant) {
    reloadWhenServerIsBack("The server refused the reconnect (it may have restarted).");
  } else {
    show("dormant", "not connected; reconnects when this page becomes visible again " +
                    "or the network comes back (or switch tabs and back, or reload)");
  }
});

// The shim reconnects on these events by itself. The flag marks the
// attempts that follow as a wake: if they fail too, the server is probably
// a new one, which only a reload can reach.
function noteWake() {
  if (state === "dormant") wokeWhileDormant = true;
}
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") noteWake();
});
window.addEventListener("online", noteWake);

takeBack.addEventListener("click", () => location.reload());

byId("save").addEventListener("click", async (ev) => {
  ev.target.disabled = true;
  error.textContent = "";
  try {
    showNote(await neel.saveNote(editor.value));
  } catch (e) {
    showError(e);
  } finally {
    ev.target.disabled = false;
  }
});

byId("stop").addEventListener("click", () => {
  if (confirm("Stop the server? The app is unavailable until it is started again.")) {
    neel.stopServer.send(); // the server's 1001 close arrives through onclose
  }
});
