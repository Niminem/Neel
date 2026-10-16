// shim_harness.js - runs rendered copies of neel.js under a scripted fake
// browser and checks their connection behavior. Used by t_frontend when node
// is on PATH; plain Node, no packages.
//
//   node shim_harness.js <serve.js> <local.js> <reference.js> <report.txt>
//
// serve.js and local.js are the current shim rendered with the serve flag on
// and off; reference.js is the shim as it was before serve mode, rendered
// with the same token, window id, and exposed names. All three must expose
// the same `neel` keys. Local mode must leave exactly the same trace as the
// reference in every scenario (that is the proof local mode is unchanged),
// and serve mode the same one wherever it is not supposed to differ.
//
// Each scenario gets a fresh sandbox: a fake WebSocket whose sockets the
// scenario opens, drops, or feeds; a manual clock (setTimeout only fires on
// advance); and a document plus window that record listeners and fire
// visibilitychange / online on demand. Everything observable goes into a
// trace: sockets created, frames sent, timers set, close calls, onclose and
// onreconnect, call results, and warnings. The report is "ok <n> checks" or
// the failures, one per line; the exit code is 0 only when nothing failed.

"use strict";

const fs = require("fs");
const vm = require("vm");

const [servePath, localPath, referencePath, reportPath] = process.argv.slice(2);
if (!reportPath) {
  console.error("usage: node shim_harness.js <serve.js> <local.js> <reference.js> <report.txt>");
  process.exit(2);
}
const SOURCES = {
  serve: fs.readFileSync(servePath, "utf8"),
  local: fs.readFileSync(localPath, "utf8"),
  reference: fs.readFileSync(referencePath, "utf8"),
};

const DELAYS = [250, 500, 1000, 2000, 4000]; // the shim's backoff
const GAVE_UP = "neel: gave up reconnecting after 5 attempts";
const DORMANT = "neel: not connected; reconnects when the page becomes visible or goes online";
const CLOSED = "neel: connection is closed";
const MAX_FAILURES = 60;

const failures = [];
let checks = 0;

function check(cond, scenario, what) {
  checks += 1;
  if (!cond && failures.length < MAX_FAILURES) failures.push(scenario + ": " + what);
}

function same(a, b) {
  return JSON.stringify(a) === JSON.stringify(b);
}

function settle() {
  // The sandbox shares this process's microtask queue; one macrotask turn
  // drains every promise reaction the last action queued.
  return new Promise((resolve) => setImmediate(resolve));
}

function makeEnv(flavor) {
  const env = {
    flavor,
    trace: [],
    sockets: [],
    docListeners: [],
    winListeners: [],
  };

  let now = 0;
  let seq = 0;
  const timers = new Map();
  function fakeSetTimeout(fn, ms) {
    const id = ++seq;
    timers.set(id, { id, due: now + ms, fn });
    env.trace.push(["timer", ms]);
    return id;
  }
  function fakeClearTimeout(id) {
    timers.delete(id);
  }

  class FakeWebSocket {
    constructor(url) {
      this.url = url;
      this.readyState = FakeWebSocket.CONNECTING;
      this.onopen = this.onmessage = this.onclose = this.onerror = null;
      env.sockets.push(this);
      env.trace.push(["socket", env.sockets.length, url]);
    }
    send(data) {
      if (this.readyState !== FakeWebSocket.OPEN) throw new Error("send on a socket that is not open");
      env.trace.push(["sent", data]);
    }
    close(code, reason) {
      this.readyState = FakeWebSocket.CLOSING;
      env.trace.push(["wsclose", code, reason]);
    }
  }
  FakeWebSocket.CONNECTING = 0;
  FakeWebSocket.OPEN = 1;
  FakeWebSocket.CLOSING = 2;
  FakeWebSocket.CLOSED = 3;

  const doc = {
    visibilityState: "visible",
    addEventListener(type, fn) { env.docListeners.push([type, fn]); },
  };

  const sandbox = {
    WebSocket: FakeWebSocket,
    location: { protocol: "http:", host: "127.0.0.1:8080" },
    setTimeout: fakeSetTimeout,
    clearTimeout: fakeClearTimeout,
    document: doc,
    addEventListener(type, fn) { env.winListeners.push([type, fn]); },
    console: {
      warn: (...args) => env.trace.push(["warn", args.map(String).join(" ")]),
      log: (...args) => env.trace.push(["log", args.map(String).join(" ")]),
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(SOURCES[flavor], sandbox, { filename: flavor + ".js" });
  env.neel = sandbox.neel;
  env.neel.onclose((code, reconnecting) => env.trace.push(["onclose", code, reconnecting]));
  env.neel.onreconnect(() => env.trace.push(["onreconnect"]));

  env.socket = () => env.sockets[env.sockets.length - 1];
  env.mark = (label) => env.trace.push(["mark", label]);
  env.track = (label, promise) => {
    promise.then(
      (value) => env.trace.push(["resolve", label, value]),
      (e) => env.trace.push(["reject", label, e.name, e.message]));
  };
  env.call = (label, ...args) => env.track(label, env.neel.add(...args));
  env.open = () => {
    const ws = env.socket();
    ws.readyState = FakeWebSocket.OPEN;
    ws.onopen({});
    return settle();
  };
  env.drop = (code) => {
    const ws = env.socket();
    ws.readyState = FakeWebSocket.CLOSED;
    ws.onclose({ code });
    return settle();
  };
  env.receive = (msg) => {
    env.socket().onmessage({ data: JSON.stringify(msg) });
    return settle();
  };
  env.advance = (ms) => {
    const end = now + ms;
    for (;;) {
      let next = null;
      for (const t of timers.values()) {
        if (t.due <= end && (next === null || t.due < next.due)) next = t;
      }
      if (next === null) break;
      timers.delete(next.id);
      now = next.due;
      next.fn();
    }
    now = end;
    return settle();
  };
  env.pendingTimers = () => timers.size;
  function fire(listeners, type) {
    for (const [t, fn] of listeners) if (t === type) fn({ type });
  }
  env.setVisibility = (state) => {
    doc.visibilityState = state;
    fire(env.docListeners, "visibilitychange");
    return settle();
  };
  env.online = () => {
    fire(env.winListeners, "online");
    return settle();
  };
  env.wakeEvents = async () => {
    await env.setVisibility("hidden");
    await env.setVisibility("visible");
    await env.online();
  };
  env.failRound = async (firstImmediate) => {
    // One full round of failed attempts: the initial connect (already
    // created) fails, then every backoff retry fails.
    if (!firstImmediate) throw new Error("failRound expects an outstanding socket");
    await env.drop(1006);
    for (const ms of DELAYS) {
      await env.advance(ms);
      await env.drop(1006);
    }
  };
  return env;
}

// --- scenarios every flavor must play out identically --------------------

const COMMON = {
  async "first open flushes the queue; replies resolve and reject"(env) {
    env.track("ready", env.neel.ready);
    env.call("a", 1, 2);
    env.neel.add.send(9);
    await settle();
    await env.open();
    await env.receive({ t: "ret", id: 1, value: 3 });
    env.call("b", 2, 2);
    await settle();
    await env.receive({ t: "err", id: 2, error: { kind: "ValueError", msg: "bad" } });
    await env.receive({ t: "ret", id: 99, value: 0 });
    await env.receive({ t: "nonsense" });
  },

  async "a JS function exposed to Nim answers on its socket"(env) {
    env.neel.expose("double", (x) => x * 2);
    await env.open();
    await env.receive({ t: "call", id: 1, name: "double", args: [21] });
    await env.receive({ t: "call", id: 2, name: "missing", args: [] });
  },

  async "a drop rejects in-flight calls, retries after 250 ms, and onreconnect fires"(env) {
    await env.open();
    env.call("inflight", 1, 1);
    await settle();
    await env.drop(1006);
    env.call("queued", 2, 2);
    await settle();
    await env.wakeEvents(); // mid-reconnect: ignored
    await env.advance(249);
    await env.advance(1);
    await env.open();
    await env.receive({ t: "ret", id: 1, value: 4 });
    await env.wakeEvents(); // connected: ignored
  },

  async "a first connect that fails and later succeeds resolves ready, no onreconnect"(env) {
    env.track("ready", env.neel.ready);
    await env.drop(1006);
    await env.advance(250);
    await env.drop(1006);
    await env.advance(500);
    await env.open();
  },

  async "neel.close() while open is final"(env) {
    await env.open();
    env.call("inflight", 1, 1);
    await settle();
    env.neel.close();
    await settle();
    env.call("after", 2, 2);
    env.neel.close();
    await settle();
    await env.wakeEvents();
    await env.advance(60000);
  },

  async "neel.close() during the backoff is final"(env) {
    env.track("ready", env.neel.ready);
    await env.open();
    await env.drop(1006);
    env.call("queued", 1, 1);
    await settle();
    env.neel.close();
    await settle();
    await env.advance(60000);
    await env.wakeEvents();
    await env.advance(60000);
  },

  async "neel.close() before the first open rejects ready"(env) {
    env.track("ready", env.neel.ready);
    env.neel.close();
    await settle();
  },
};

for (const code of [1000, 1001, 4000]) {
  COMMON["close code " + code + " is final: no retry, later calls and wake events do nothing"] =
    async (env) => {
      env.track("ready", env.neel.ready);
      await env.open();
      env.call("inflight", 1, 1);
      await settle();
      await env.drop(code);
      env.call("after", 2, 2);
      await settle();
      await env.advance(60000);
      await env.wakeEvents();
      await env.advance(60000);
      env.call("later", 3, 3);
      await settle();
    };
}

// --- running out of attempts ---------------------------------------------

async function giveUpAfterOpen(env) {
  env.track("ready", env.neel.ready);
  await env.open();
  env.call("inflight", 1, 2);
  await settle();
  await env.drop(1006);
  env.call("queued", 3, 4);
  await settle();
  for (const ms of DELAYS) {
    await env.advance(ms);
    await env.drop(1006);
  }
  env.mark("gave up");
  env.call("after", 5, 6);
  await settle();
}

async function giveUpBeforeOpen(env) {
  env.track("ready", env.neel.ready);
  env.call("queued", 1, 1);
  await settle();
  await env.failRound(true);
  env.mark("gave up");
}

const LOCAL_ONLY = {
  async "giving up after an open is final; wake events do nothing"(env) {
    await giveUpAfterOpen(env);
    await env.advance(60000);
    await env.wakeEvents();
    await env.advance(60000);
    env.call("later", 7, 8);
    await settle();
  },

  async "giving up before any open is final and rejects ready"(env) {
    await giveUpBeforeOpen(env);
    await env.wakeEvents();
    await env.advance(60000);
  },
};

// --- helpers for serve-mode assertions -----------------------------------

function entries(env, kind) {
  return env.trace.filter((e) => e[0] === kind);
}

function since(env, start) {
  return env.trace.slice(start);
}

function result(env, label) {
  return env.trace.find((e) => (e[0] === "resolve" || e[0] === "reject") && e[1] === label);
}

async function quiet(env, name, what, action) {
  // `action` must leave no trace at all: no socket, timer, close, or call.
  const start = env.trace.length;
  await action();
  check(since(env, start).length === 0, name, what + " left " + JSON.stringify(since(env, start)));
}

const SERVE_ONLY = {
  async "giving up goes dormant: same onclose and rejections, later calls reject at once"(env, name) {
    await giveUpAfterOpen(env);
    const afterGiveUp = env.trace.length;
    check(same(result(env, "inflight"), ["reject", "inflight", "NeelDisconnectedError",
      "neel: connection lost (close code 1006)"]), name, "in-flight call rejected as connection lost");
    check(same(result(env, "queued"), ["reject", "queued", "NeelDisconnectedError", GAVE_UP]),
      name, "queued call rejected with the give-up reason");
    check(same(result(env, "after"), ["reject", "after", "NeelDisconnectedError", DORMANT]),
      name, "a call while dormant rejects at once with the dormant reason, got " +
      JSON.stringify(result(env, "after")));
    const closes = entries(env, "onclose");
    check(closes.length === 6 && same(closes[5], ["onclose", 1006, false]) &&
      closes.slice(0, 5).every((c) => same(c, ["onclose", 1006, true])),
      name, "five onclose(1006, true) then one onclose(1006, false), got " + JSON.stringify(closes));
    check(env.sockets.length === 6, name, "1 + 5 sockets before going dormant");
    check(env.neel.connected === false, name, "neel.connected is false while dormant");
    check(env.pendingTimers() === 0, name, "no timer pending while dormant");
    await quiet(env, name, "a minute dormant", () => env.advance(60000));
    await quiet(env, name, "the page going hidden", () => env.setVisibility("hidden"));
    check(env.trace.length === afterGiveUp && entries(env, "reject").length === 3,
      name, "nothing happens while dormant");
  },

  async "a dormant shim wakes once on visible, connects at once, and calls work again"(env, name) {
    await giveUpAfterOpen(env);
    await env.setVisibility("hidden");
    const before = env.sockets.length;
    const start = env.trace.length;
    await env.setVisibility("visible");
    check(env.sockets.length === before + 1, name, "one new socket on visible");
    check(entries({ trace: since(env, start) }, "timer").length === 0, name,
      "the first wake attempt is immediate (no timer)");
    check(env.socket().url === env.sockets[0].url, name, "the wake presents the same URL");
    await env.online();
    await env.setVisibility("visible");
    check(env.sockets.length === before + 1, name, "further wake events during the round start nothing");
    env.call("during", 1, 1);
    await settle();
    check(result(env, "during") === undefined, name, "a call during the wake round is queued, not rejected");
    await env.open();
    check(entries(env, "onreconnect").length === 1, name, "onreconnect fires once on a successful wake");
    check(env.neel.connected === true, name, "neel.connected is true after the wake");
    const sent = entries(env, "sent").map((e) => JSON.parse(e[1]));
    check(same(sent[sent.length - 1], { t: "call", id: 1, name: "add", args: [1, 1] }),
      name, "the queued call is flushed with id 1 on the new socket");
    await env.receive({ t: "ret", id: 1, value: 2 });
    check(same(result(env, "during"), ["resolve", "during", 2]), name, "the queued call resolves");
    await quiet(env, name, "wake events while connected", () => env.wakeEvents());
    // A later drop starts a normal round with fresh attempts.
    await env.drop(1006);
    check(same(env.trace[env.trace.length - 2], ["timer", 250]) &&
      same(env.trace[env.trace.length - 1], ["onclose", 1006, true]),
      name, "a drop after the wake retries after 250 ms with attempts reset");
  },

  async "online wakes a dormant shim too"(env, name) {
    await giveUpAfterOpen(env);
    const before = env.sockets.length;
    await env.online();
    await env.online();
    check(env.sockets.length === before + 1, name, "one new socket for two online events");
    await env.open();
    check(entries(env, "onreconnect").length === 1, name, "onreconnect fires");
  },

  async "a failed wake goes dormant again, with onclose(code, false) again"(env, name) {
    await giveUpAfterOpen(env);
    const start = env.trace.length;
    await env.online();
    env.call("during", 1, 1);
    await settle();
    await env.failRound(true);
    const round = since(env, start);
    check(same(entries({ trace: round }, "timer").map((e) => e[1]), DELAYS), name,
      "the wake round backs off 250/500/1000/2000/4000 ms, got " +
      JSON.stringify(entries({ trace: round }, "timer")));
    check(entries({ trace: round }, "socket").length === 6, name, "1 immediate + 5 retries");
    const closes = entries({ trace: round }, "onclose");
    check(closes.length === 6 && same(closes[5], ["onclose", 1006, false]), name,
      "the round ends with onclose(1006, false), got " + JSON.stringify(closes));
    check(same(result(env, "during"), ["reject", "during", "NeelDisconnectedError", GAVE_UP]),
      name, "a call made during the failed round rejects with the give-up reason");
    env.call("after", 2, 2);
    await settle();
    check(same(result(env, "after"), ["reject", "after", "NeelDisconnectedError", DORMANT]),
      name, "dormant again: calls reject at once");
    await quiet(env, name, "a minute dormant again", () => env.advance(60000));
    const before = env.sockets.length;
    await env.setVisibility("hidden");
    await env.setVisibility("visible");
    check(env.sockets.length === before + 1, name, "the next wake event starts a new round");
  },

  async "a shim that never connected: ready stays rejected, a successful wake fires onreconnect"(env, name) {
    await giveUpBeforeOpen(env);
    check(same(result(env, "ready"), ["reject", "ready", "NeelDisconnectedError", GAVE_UP]),
      name, "ready rejected on giving up");
    check(same(result(env, "queued"), ["reject", "queued", "NeelDisconnectedError", GAVE_UP]),
      name, "the queued call rejected on giving up");
    await env.online();
    await env.open();
    check(entries(env, "onreconnect").length === 1, name, "onreconnect fires on the first successful open");
    let late = "pending";
    env.neel.ready.then(() => { late = "resolved"; }, () => { late = "rejected"; });
    await settle();
    check(late === "rejected", name, "neel.ready stays rejected after the wake");
  },

  async "neel.close() while dormant terminates: onclose(1000, false), wake events do nothing"(env, name) {
    await giveUpAfterOpen(env);
    const start = env.trace.length;
    env.neel.close();
    await settle();
    check(same(since(env, start), [["onclose", 1000, false]]), name,
      "close while dormant fires onclose(1000, false) only, got " + JSON.stringify(since(env, start)));
    env.call("closed", 1, 1);
    await settle();
    check(same(result(env, "closed"), ["reject", "closed", "NeelDisconnectedError", CLOSED]),
      name, "calls reject as closed, not dormant, got " + JSON.stringify(result(env, "closed")));
    await quiet(env, name, "a second neel.close()", async () => { env.neel.close(); await settle(); });
    await quiet(env, name, "wake events after terminating", () => env.wakeEvents());
    await quiet(env, name, "a minute after terminating", () => env.advance(60000));
  },

  async "a final close code during a wake round terminates"(env, name) {
    await giveUpAfterOpen(env);
    await env.online();
    await env.open();
    await env.drop(4000);
    check(same(env.trace[env.trace.length - 1], ["onclose", 4000, false]), name,
      "4000 after a wake is final");
    await quiet(env, name, "wake events after 4000", () => env.wakeEvents());
    await quiet(env, name, "a minute after 4000", () => env.advance(60000));
  },

  async "neel.close() during a wake round terminates"(env, name) {
    await giveUpAfterOpen(env);
    await env.online();
    const start = env.trace.length;
    env.neel.close();
    await settle();
    check(same(since(env, start), [["wsclose", 1000, "neel.close()"], ["onclose", 1000, false]]),
      name, "the wake socket is closed with 1000, got " + JSON.stringify(since(env, start)));
    await quiet(env, name, "wake events after closing", () => env.wakeEvents());
  },
};

// --- run ------------------------------------------------------------------

async function run(flavor, scenario) {
  const env = makeEnv(flavor);
  await settle();
  await scenario(env, flavor + ": " + scenario.name);
  return env;
}

async function main() {
  const keys = {};
  for (const flavor of Object.keys(SOURCES)) keys[flavor] = Object.keys(makeEnv(flavor).neel);
  check(same(keys.serve, keys.reference) && same(keys.local, keys.reference), "Object.keys(neel)",
    "differs: " + JSON.stringify(keys));

  for (const flavor of ["local", "reference"]) {
    const env = makeEnv(flavor);
    check(env.docListeners.length === 0 && env.winListeners.length === 0, flavor,
      "adds no document or window listeners");
  }
  const serveEnv = makeEnv("serve");
  check(same(serveEnv.docListeners.map((l) => l[0]), ["visibilitychange"]) &&
    same(serveEnv.winListeners.map((l) => l[0]), ["online"]), "serve",
    "adds one visibilitychange and one online listener");

  for (const [title, scenario] of Object.entries(COMMON)) {
    const ref = await run("reference", scenario);
    const local = await run("local", scenario);
    const serve = await run("serve", scenario);
    check(same(local.trace, ref.trace), "local vs reference: " + title,
      "trace differs\n  reference: " + JSON.stringify(ref.trace) + "\n  local:     " +
      JSON.stringify(local.trace));
    check(same(serve.trace, ref.trace), "serve vs reference: " + title,
      "trace differs\n  reference: " + JSON.stringify(ref.trace) + "\n  serve:     " +
      JSON.stringify(serve.trace));
    check(ref.trace.length > 0, "reference: " + title, "left an empty trace");
  }

  for (const [title, scenario] of Object.entries(LOCAL_ONLY)) {
    const ref = await run("reference", scenario);
    const local = await run("local", scenario);
    check(same(local.trace, ref.trace), "local vs reference: " + title,
      "trace differs\n  reference: " + JSON.stringify(ref.trace) + "\n  local:     " +
      JSON.stringify(local.trace));
    check(entries(ref, "reject").length > 0, "reference: " + title, "rejected nothing");
  }

  // Serve mode plays the give-up path exactly like local mode up to the
  // point of giving up; only what follows differs.
  for (const prefixOf of [giveUpAfterOpen, giveUpBeforeOpen]) {
    const local = await run("local", prefixOf);
    const serve = await run("serve", prefixOf);
    const cut = (env) => env.trace.slice(0, env.trace.findIndex((e) => same(e, ["mark", "gave up"])));
    check(cut(local).length > 0 && same(cut(serve), cut(local)), "serve vs local: " + prefixOf.name,
      "the trace up to giving up differs");
  }

  for (const [title, scenario] of Object.entries(SERVE_ONLY)) {
    const env = makeEnv("serve");
    await settle();
    await scenario(env, "serve: " + title);
  }
}

main().then(
  () => {
    const report = failures.length === 0
      ? "ok " + checks + " checks\n"
      : failures.length + " of " + checks + " checks failed\n" + failures.join("\n") + "\n";
    fs.writeFileSync(reportPath, report);
    process.exit(failures.length === 0 ? 0 : 1);
  },
  (e) => {
    fs.writeFileSync(reportPath, "harness error: " + (e && e.stack ? e.stack : e) + "\n");
    process.exit(1);
  });
