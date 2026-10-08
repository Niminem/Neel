// stresstest.js - the page side of the stress test. Every section below is
// one `section(title, text, buttons)` call; each button gets the section's
// `log` and a reference to the section element.

"use strict";

const byId = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const tab = params.get("tab");

byId("window-id").textContent = String(neel.windowId);
byId("tab").textContent = tab === null ? "main" : "tab " + tab;
neel.ready.then(
  () => { byId("status").textContent = "connected"; },
  (e) => { byId("status").textContent = e.name; });

// --- helpers --------------------------------------------------------------------

let inflight = 0;

function track(promise) {
  // Counts a call from the moment it is made until it settles.
  inflight += 1;
  byId("inflight").textContent = String(inflight);
  return promise.finally(() => {
    inflight -= 1;
    byId("inflight").textContent = String(inflight);
  });
}

const t = track; // `await t(neel.foo(...))` everywhere below

function section(title, text, buttons) {
  const sec = document.createElement("section");
  const heading = document.createElement("h2");
  heading.textContent = title;
  const para = document.createElement("p");
  para.textContent = text;
  const row = document.createElement("div");
  row.className = "buttons";
  const pre = document.createElement("pre");
  pre.className = "log";
  const log = (line) => {
    pre.textContent += line + "\n";
    pre.scrollTop = pre.scrollHeight;
  };
  for (const [label, fn] of buttons) {
    const button = document.createElement("button");
    button.textContent = label;
    button.addEventListener("click", async () => {
      button.disabled = true;
      try {
        await fn(log, sec);
      } catch (e) {
        log("FAIL " + e.name + ": " + e.message);
      } finally {
        button.disabled = false;
      }
    });
    row.appendChild(button);
  }
  sec.append(heading, para, row, pre);
  byId("sections").appendChild(sec);
  return log;
}

async function expectError(log, label, promise, expectedName) {
  // Awaits a call that must reject with `expectedName`.
  try {
    const value = await promise;
    log(label + ": UNEXPECTED success -> " + JSON.stringify(value));
  } catch (e) {
    const verdict = e.name === expectedName ? "ok" : "WRONG NAME, expected " + expectedName;
    log(label + ": " + e.name + ": " + e.message + "  [" + verdict + "]");
  }
}

function canon(value) {
  // JSON with sorted object keys (a Nim Table has no fixed key order).
  if (Array.isArray(value)) return "[" + value.map(canon).join(",") + "]";
  if (value !== null && typeof value === "object") {
    return "{" + Object.keys(value).sort()
      .map((k) => JSON.stringify(k) + ":" + canon(value[k])).join(",") + "}";
  }
  return JSON.stringify(value);
}

function checksum(s) {
  // FNV-1a, 32 bit, over UTF-16 code units.
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const ok = (cond) => (cond ? "ok" : "FAIL");

// --- Nim -> JS targets -----------------------------------------------------------

let progressLog = null; // set by the "push" section
let windowsLog = null;  // set by the "windows" section

neel.expose({
  jsThrows() {
    throw new RangeError("out of range in JS");
  },
  jsNeverResolves() {
    return new Promise(() => {}); // never settles; Nim times out
  },
  async callBackIntoNim() {
    // Called by Nim's `reenter()` while that worker is blocked in js.wait;
    // this call must still be served by another worker.
    return (await t(neel.add(1, 2))) * 10;
  },
  progress(i) {
    if (progressLog && i % 10 === 0) progressLog("progress " + i + "/50");
    byId("progress-bar").value = i;
  },
  progressDone(stopped) {
    if (progressLog) progressLog(stopped ? "stopped by the Stop button" : "finished all 50 steps");
  },
  onBroadcast(message, fromId) {
    if (windowsLog) windowsLog("[broadcast] from window " + fromId + ": " + message);
  },
  windowEvent(kind, id) {
    if (windowsLog) windowsLog("[hook] window " + id + " " + kind + (kind === "open" ? "ed" : "d"));
  },
  slowAnswer() {
    if (windowsLog) windowsLog("slowAnswer() asked; answering in 10 s");
    return sleep(10000).then(() => "answer from window " + neel.windowId);
  },
});

// --- sections --------------------------------------------------------------------

section("Types",
  "An object with nested seq / Option / enum / Table / float / bool fields " +
  "round-trips unchanged; default parameters; a JsonNode result; a void result.",
  [
    ["roundTrip(object)", async (log) => {
      const payload = {
        name: "neel", tags: ["a", "b"], matrix: [[1, 2], [3]], maybe: 7,
        color: "green", counts: { x: 1, y: 2 }, ratio: 0.5, flag: true,
      };
      const back = await t(neel.roundTrip(payload));
      log("sent:     " + canon(payload));
      log("received: " + canon(back) + "  [" + ok(canon(back) === canon(payload)) + "]");
      const none = { ...payload, maybe: null, counts: {}, tags: [] };
      const back2 = await t(neel.roundTrip(none));
      log("maybe: null, empty table/seq -> " + canon(back2) +
          "  [" + ok(canon(back2) === canon(none)) + "]");
    }],
    ["withDefaults(1 / 2 / 3 args)", async (log) => {
      log("withDefaults(1)            -> " + await t(neel.withDefaults(1)));
      log("withDefaults(1, 2)         -> " + await t(neel.withDefaults(1, 2)));
      log("withDefaults(1, 2, 'three') -> " + await t(neel.withDefaults(1, 2, "three")));
    }],
    ["asJson()", async (log) => {
      log("asJson() -> " + JSON.stringify(await t(neel.asJson())));
    }],
    ["nothing()", async (log) => {
      const value = await t(neel.nothing());
      log("nothing() -> " + JSON.stringify(value) + "  [" + ok(value === null) + "]");
    }],
  ]);

section("Errors",
  "Every failure crossing the bridge is a rejection whose name is the Nim " +
  "exception kind (or the JS error name when a Nim -> JS call threw).",
  [
    ["failing()", (log) =>
      expectError(log, "failing()", t(neel.failing()), "ValueError")],
    ["add(1) / add('x', 2) / call('nope')", async (log) => {
      await expectError(log, "add(1)", t(neel.add(1)), "NeelArgumentError");
      await expectError(log, "add('x', 2)", t(neel.add("x", 2)), "NeelArgumentError");
      await expectError(log, "call('nope')", t(neel.call("nope")), "NeelUnknownProcError");
    }],
    ["callJsThatThrows()", (log) =>
      expectError(log, "callJsThatThrows()", t(neel.callJsThatThrows()), "RangeError")],
    ["callJsThatHangs()", (log) =>
      expectError(log, "callJsThatHangs() (300 ms)", t(neel.callJsThatHangs()), "NeelTimeoutError")],
    ["callMissingJs()", (log) =>
      expectError(log, "callMissingJs()", t(neel.callMissingJs()), "NeelUnknownFunctionError")],
  ]);

section("Concurrency",
  "500 concurrent slowAdd (50 ms each) must finish far below the 25 s a serial " +
  "server would need; 1000 fire-and-forget pings must all arrive (the counter " +
  "is polled because handlers on one connection run concurrently); reenter() " +
  "blocks a worker in js.wait while the page calls back into Nim.",
  [
    ["500 x slowAdd(i, 1)", async (log) => {
      const t0 = performance.now();
      const results = await Promise.all(
        Array.from({ length: 500 }, (_, i) => t(neel.slowAdd(i, 1))));
      const ms = Math.round(performance.now() - t0);
      const wrong = results.filter((v, i) => v !== i + 1).length;
      log("500 results, " + wrong + " wrong, " + ms + " ms  [" +
          ok(wrong === 0 && ms < 25000) + (ms < 5000 ? ", concurrent" : ", too slow?") + "]");
    }],
    ["1000 x ping.send()", async (log) => {
      await t(neel.resetPings());
      const t0 = performance.now();
      for (let i = 0; i < 1000; i++) neel.ping.send();
      let count = 0;
      while (count < 1000 && performance.now() - t0 < 5000) {
        await sleep(20);
        count = await t(neel.pingCount());
      }
      log("pingCount() = " + count + " after " + Math.round(performance.now() - t0) +
          " ms  [" + ok(count === 1000) + "]");
    }],
    ["reenter()", async (log) => {
      const value = await t(neel.reenter());
      log("reenter() -> " + value + "  [" + ok(value === 30) + "]");
    }],
  ]);

section("Payloads",
  "Large messages both ways (the limit is 16 MiB per message).",
  [
    ["2 MB string", async (log) => {
      const n = 2 * 1024 * 1024;
      const alphabet = "0123456789abcdefghijklmnopqrstuvwxyz";
      const s = alphabet.repeat(Math.ceil(n / alphabet.length)).slice(0, n - 4) + "\"\\\n\t";
      const t0 = performance.now();
      const back = await t(neel.echoString(s));
      const ms = Math.round(performance.now() - t0);
      log("sent " + s.length + " chars, checksum " + checksum(s) +
          "; got " + back.length + " chars, checksum " + checksum(back) +
          "; " + ms + " ms  [" + ok(back === s) + "]");
    }],
    ["seq[int] of 100k", async (log) => {
      const xs = Array.from({ length: 100000 }, (_, i) => i * 3 - 50000);
      const t0 = performance.now();
      const back = await t(neel.echoInts(xs));
      const ms = Math.round(performance.now() - t0);
      const same = back.length === xs.length && back.every((v, i) => v === xs[i]);
      log(back.length + " ints back in " + ms + " ms  [" + ok(same) + "]");
    }],
    ["nested object, depth 50", async (log) => {
      let obj = { leaf: true };
      for (let i = 0; i < 50; i++) obj = { level: i, next: obj };
      const back = await t(neel.echoJson(obj));
      let depth = 0;
      for (let o = back; o && o.next; o = o.next) depth++;
      log("depth " + depth + " back  [" + ok(depth === 50 && canon(back) === canon(obj)) + "]");
    }],
  ]);

progressLog = section("Push from Nim",
  "startProgress() starts a plain Nim thread that calls win.js.progress(i) " +
  "every 100 ms for 5 s from outside any exposed proc; Stop sets a flag the " +
  "thread checks.",
  [
    ["startProgress()", async (log) => {
      byId("progress-bar").value = 0;
      await t(neel.startProgress());
      log("thread started");
    }],
    ["stopProgress()", async (log) => {
      await t(neel.stopProgress());
      log("stop requested");
    }],
  ]);
{
  const bar = document.createElement("progress");
  bar.id = "progress-bar";
  bar.max = 50;
  bar.value = 0;
  byId("sections").lastElementChild.querySelector(".buttons").appendChild(bar);
}

let tabs = 0;
let lastOpened = 0;
windowsLog = section("Windows",
  "Open extra windows (each at index.html?tab=N), broadcast to all through " +
  "windows() + win.js, close one by id, and watch the hooks. askWindow targets " +
  "another window's slowAnswer() (10 s): close that window while the call is " +
  "pending to see NeelDisconnectedError.",
  [
    ["whoAmI()", async (log) => {
      const id = await t(neel.whoAmI());
      log("neel.windowId = " + neel.windowId + ", currentWindow().get.id = " + id +
          "  [" + ok(id === neel.windowId) + "]");
    }],
    ["openTab(n)", async (log) => {
      tabs += 1;
      lastOpened = await t(neel.openTab(tabs));
      log("openTab(" + tabs + ") -> window " + lastOpened);
    }],
    ["listWindows()", async (log) => {
      const list = await t(neel.listWindows());
      log("windows(): " + list.map((w) => w.id + (w.connected ? " connected" : " not connected")).join(", "));
    }],
    ["broadcast('hello')", async (log) => {
      const reached = await t(neel.broadcast("hello from window " + neel.windowId));
      log("broadcast reached " + reached + " window(s)");
    }],
    ["closeById(id)", async (log) => {
      const id = Number(prompt("window id to close", String(lastOpened || neel.windowId)));
      if (!Number.isInteger(id)) return;
      await expectOrValue(log, "closeById(" + id + ")", t(neel.closeById(id)));
    }],
    ["askWindow(id, 15000)", async (log) => {
      const id = Number(prompt("window id to ask (its page waits 10 s)", String(lastOpened || neel.windowId)));
      if (!Number.isInteger(id)) return;
      log("askWindow(" + id + ") waiting...");
      await expectOrValue(log, "askWindow(" + id + ")", t(neel.askWindow(id, 15000)));
    }],
  ]);

async function expectOrValue(log, label, promise) {
  // Logs either outcome; the user decides whether it was the expected one.
  try {
    log(label + " -> " + JSON.stringify(await promise));
  } catch (e) {
    log(label + " -> " + e.name + ": " + e.message);
  }
}

section("Assets",
  "Files from web/ through the asset server: an SVG image, a Range request " +
  "against a bundled binary (206 + Content-Range), a 404, and the built-in " +
  "/neel/no-browser page.",
  [
    ["<img src=/logo.svg>", async (log, sec) => {
      const res = await fetch("/logo.svg");
      log("GET /logo.svg -> " + res.status + " " + res.headers.get("Content-Type") +
          ", " + (await res.text()).length + " bytes");
      const img = document.createElement("img");
      img.alt = "Neel logo";
      img.src = "/logo.svg";
      img.addEventListener("load", () => log("img loaded, " + img.naturalWidth + "x" + img.naturalHeight));
      img.addEventListener("error", () => log("FAIL img did not load"));
      sec.appendChild(img);
    }],
    ["Range on /blob.bin", async (log) => {
      const res = await fetch("/blob.bin", { headers: { Range: "bytes=100-199" } });
      const bytes = new Uint8Array(await res.arrayBuffer());
      log("GET /blob.bin Range: bytes=100-199 -> " + res.status +
          ", Content-Range: " + res.headers.get("Content-Range") +
          ", Content-Length: " + res.headers.get("Content-Length") +
          ", first byte " + bytes[0] + ", last byte " + bytes[bytes.length - 1] +
          "  [" + ok(res.status === 206 && bytes.length === 100 && bytes[0] === 100 && bytes[99] === 199) + "]");
      const whole = await fetch("/blob.bin");
      log("GET /blob.bin -> " + whole.status + ", Accept-Ranges: " + whole.headers.get("Accept-Ranges") +
          ", " + (await whole.arrayBuffer()).byteLength + " bytes");
    }],
    ["fetch /missing", async (log) => {
      const res = await fetch("/does-not-exist.txt");
      log("GET /does-not-exist.txt -> " + res.status + "  [" + ok(res.status === 404) + "]");
    }],
    ["fetch /neel/no-browser", async (log) => {
      const res = await fetch("/neel/no-browser");
      const doc = new DOMParser().parseFromString(await res.text(), "text/html");
      log("GET /neel/no-browser -> " + res.status + ", <title> " + JSON.stringify(doc.title) +
          "  [" + ok(res.status === 200 && doc.title.length > 0) + "]");
    }],
  ]);

section("Lifecycle",
  "Quit asks Nim to call quitApp(): the terminal prints the ExitReason and the " +
  "process ends. neel.close() closes only this page's connection: later calls " +
  "reject, and the window is retired after the 3 s grace period.",
  [
    ["exitApp() (quit)", async (log) => {
      log("calling exitApp()...");
      await expectOrValue(log, "exitApp()", t(neel.exitApp()));
      byId("status").textContent = "quitting (server sends close 1001)";
    }],
    ["neel.close() (this window)", async (log) => {
      neel.close();
      byId("status").textContent = "closed by neel.close()";
      log("neel.close() called");
      await expectError(log, "whoAmI() after close", t(neel.whoAmI()), "NeelDisconnectedError");
    }],
  ]);
