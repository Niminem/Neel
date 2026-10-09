// neel.js - browser-side shim for Neel 2.0.
//
// Plain ES2020, no build step, no dependencies. This file is a template:
// before serving it at /neel.js, frontend.nim replaces the three placeholders
// below (launch token, window id, exposed proc names) with JS literals, so
// the unrendered file is not valid JS on its own.
//
// Loading: include it as a classic script element, `<script src="/neel.js">`,
// placed before the app's own script. It installs one global, `neel`
// (globalThis.neel). One file cannot be both a classic script and an ES
// module, so module code cannot `import` this file; it reads `window.neel`,
// which exists once the classic script has run.
//
// Surface:
//   neel.<name>(...args)       -> Promise, one per exposed Nim proc
//   neel.<name>.send(...args)  -> undefined; fire-and-forget, never answered
//   neel.call(name, ...args)   -> Promise, for names not in the exposed list
//   neel.send(name, ...args)   -> undefined
//   neel.expose(fn) | neel.expose(name, fn) | neel.expose({name: fn, ...})
//   neel.ready                 -> Promise resolved on the first open
//   neel.windowId              -> number
//   neel.close()               -> deliberate close, no reconnect
//   neel.connected             -> boolean, true while the socket is open
//   neel.onclose(fn)           -> fn(code, reconnecting) after every close
//   neel.onreconnect(fn)       -> fn() after every successful open but the first
//
// Connection state for a page that wants to show it: `neel.ready` covers the
// first open; `neel.onclose` fires once per lost or closed connection with the
// WebSocket close code (1006 for a lost connection, 1000/1001 for a deliberate
// close, null when the shim gave up without a socket event) and whether a
// reconnect attempt follows; `neel.onreconnect` fires when such an attempt
// succeeds. A listener that throws is reported with console.warn and ignored.
//
// Errors: a rejected call carries an Error whose `name` (and `kind`) is the
// Nim exception type ("ValueError", "NeelArgumentError", ...) and whose
// `message` is the Nim message, so `catch (e) { e.name === "ValueError" }`
// works. "NeelDisconnectedError" means the connection was lost before the
// reply arrived, is closed, or could not be re-established. In the other
// direction, a Nim call to a JS name that is neither exposed nor a global
// function is answered with kind "NeelUnknownFunctionError".
//
// Connection: ws(s)://<location.host>/ws?token=<token>&window=<id>. Ids are
// positive integers starting at 1 per connection and are allocated when the
// frame goes on the wire. Calls made before the socket is open (or while it
// reconnects) are queued and flushed on open. On an abnormal close (anything
// but 1000/1001 or neel.close()) in-flight promises are rejected with
// NeelDisconnectedError and the shim reconnects up to MAX_RECONNECT_ATTEMPTS
// times with exponential backoff (250, 500, 1000, 2000, 4000 ms), presenting
// the same window id again. A close with 1000 or 1001 (server shutdown or
// closeWindow) is final: no reconnect, and every later call rejects at once.
//
// Wire format: PLAN.md "Protocol reference".

(function () {
  "use strict";

  if (globalThis.neel !== undefined && globalThis.neel.windowId !== undefined) {
    console.warn("neel: neel.js was loaded twice; the second copy is ignored");
    return;
  }

  const TOKEN = __NEEL_TOKEN__;
  const WINDOW_ID = __NEEL_WINDOW_ID__;
  const EXPOSED = __NEEL_EXPOSED__;

  const MAX_RECONNECT_ATTEMPTS = 5;
  const RECONNECT_BASE_MS = 250;
  const DISCONNECTED = "NeelDisconnectedError";
  const UNKNOWN_FUNCTION = "NeelUnknownFunctionError";
  const RESERVED = new Set(["call", "send", "expose", "ready", "windowId", "close",
                            "connected", "onclose", "onreconnect"]);

  const registry = new Map(); // name -> function, from neel.expose
  const pending = new Map();  // id -> {resolve, reject}, in flight on `socket`
  const queue = [];           // {name, args, settle} waiting for an open socket
  const closeListeners = [];      // from neel.onclose
  const reconnectListeners = [];  // from neel.onreconnect
  let socket = null;          // the current WebSocket, null while disconnected
  let nextId = 1;             // reset for every connection
  let attempts = 0;           // reconnects since the last successful open
  let everOpened = false;     // distinguishes the first open from a reconnect
  let timer = null;           // pending reconnect timer
  let terminated = false;     // closed deliberately, by the server, or gave up

  let resolveReady;
  let rejectReady;
  const ready = new Promise((resolve, reject) => {
    resolveReady = resolve;
    rejectReady = reject;
  });
  ready.catch(() => {}); // no "unhandled rejection" when nobody awaits it

  // --- errors -------------------------------------------------------------

  function neelError(kind, message) {
    const e = new Error(message);
    e.name = kind;
    e.kind = kind;
    return e;
  }

  function errorInfo(e) {
    // Shape of `err.error` for a JS exception; both fields must be strings.
    const kind = e?.name;
    return {
      kind: typeof kind === "string" && kind !== "" ? kind : "Error",
      msg: String(e?.message ?? e),
    };
  }

  // --- outgoing calls -----------------------------------------------------

  function isOpen() {
    return socket !== null && socket.readyState === WebSocket.OPEN;
  }

  function transmit(name, args, settle) {
    // Allocates the id (if any) and writes one `call` frame; requires isOpen().
    const msg = { t: "call" };
    if (settle !== null) {
      msg.id = nextId++;
      pending.set(msg.id, settle);
    }
    msg.name = name;
    msg.args = args;
    socket.send(JSON.stringify(msg));
  }

  function enqueue(name, args, settle) {
    if (terminated) {
      if (settle !== null) settle.reject(neelError(DISCONNECTED, "neel: connection is closed"));
      return;
    }
    if (isOpen()) transmit(name, args, settle);
    else queue.push({ name, args, settle });
  }

  function flushQueue() {
    while (queue.length > 0 && isOpen()) {
      const { name, args, settle } = queue.shift();
      transmit(name, args, settle);
    }
  }

  function failPending(reason) {
    for (const settle of pending.values()) settle.reject(neelError(DISCONNECTED, reason));
    pending.clear();
  }

  function failQueue(reason) {
    while (queue.length > 0) {
      const { settle } = queue.shift();
      if (settle !== null) settle.reject(neelError(DISCONNECTED, reason));
    }
  }

  function notify(listeners, ...args) {
    for (const fn of listeners) {
      try {
        fn(...args);
      } catch (e) {
        console.warn("neel: connection listener threw", e);
      }
    }
  }

  function terminate(reason, code) {
    terminated = true;
    if (timer !== null) {
      clearTimeout(timer);
      timer = null;
    }
    failPending(reason);
    failQueue(reason);
    rejectReady(neelError(DISCONNECTED, reason)); // no-op once resolved
    notify(closeListeners, code === undefined ? null : code, false);
  }

  function call(name, ...args) {
    if (typeof name !== "string") {
      return Promise.reject(new TypeError("neel.call: name must be a string"));
    }
    return new Promise((resolve, reject) => enqueue(name, args, { resolve, reject }));
  }

  function send(name, ...args) {
    if (typeof name !== "string") throw new TypeError("neel.send: name must be a string");
    enqueue(name, args, null);
  }

  // --- incoming messages --------------------------------------------------

  function parse(text) {
    // The three wire shapes, validated like protocol.decode; null if malformed.
    let msg;
    try {
      msg = JSON.parse(text);
    } catch (e) {
      return null;
    }
    if (msg === null || typeof msg !== "object" || Array.isArray(msg)) return null;
    if (msg.id !== undefined && !(Number.isInteger(msg.id) && msg.id > 0)) return null;
    switch (msg.t) {
      case "call":
        return typeof msg.name === "string" && Array.isArray(msg.args) ? msg : null;
      case "ret":
        return msg.id !== undefined && Object.prototype.hasOwnProperty.call(msg, "value") ? msg : null;
      case "err":
        return msg.id !== undefined &&
          msg.error !== null && typeof msg.error === "object" &&
          typeof msg.error.kind === "string" && typeof msg.error.msg === "string"
          ? msg : null;
      default:
        return null;
    }
  }

  function reply(ws, msg) {
    // Replies go only to the socket the call arrived on; never queued.
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
  }

  function lookup(name) {
    const fn = registry.get(name);
    if (typeof fn === "function") return fn;
    const g = globalThis[name];
    return typeof g === "function" ? g : null;
  }

  async function handleCall(ws, msg) {
    const hasId = msg.id !== undefined;
    const fn = lookup(msg.name);
    if (fn === null) {
      const text = "no exposed JS function named '" + msg.name + "'";
      if (hasId) reply(ws, { t: "err", id: msg.id, error: { kind: UNKNOWN_FUNCTION, msg: text } });
      else console.warn("neel: " + text);
      return;
    }
    let result;
    try {
      result = await fn(...msg.args); // await also unwraps thenables
    } catch (e) {
      if (hasId) reply(ws, { t: "err", id: msg.id, error: errorInfo(e) });
      else console.warn("neel: fire-and-forget call '" + msg.name + "' threw", e);
      return;
    }
    if (hasId) reply(ws, { t: "ret", id: msg.id, value: result === undefined ? null : result });
  }

  function handleReply(msg) {
    const settle = pending.get(msg.id);
    if (settle === undefined) {
      console.warn("neel: dropping reply for unknown id " + msg.id);
      return;
    }
    pending.delete(msg.id);
    if (msg.t === "ret") settle.resolve(msg.value);
    else settle.reject(neelError(msg.error.kind, msg.error.msg));
  }

  // --- connection ---------------------------------------------------------

  function wsUrl() {
    const scheme = location.protocol === "https:" ? "wss:" : "ws:";
    return scheme + "//" + location.host +
      "/ws?token=" + encodeURIComponent(TOKEN) + "&window=" + WINDOW_ID;
  }

  function scheduleReconnect(code) {
    if (terminated) return;
    if (attempts >= MAX_RECONNECT_ATTEMPTS) {
      terminate("neel: gave up reconnecting after " + MAX_RECONNECT_ATTEMPTS + " attempts", code);
      return;
    }
    attempts += 1;
    timer = setTimeout(connect, RECONNECT_BASE_MS * 2 ** (attempts - 1));
    notify(closeListeners, code, true);
  }

  function connect() {
    timer = null;
    const ws = new WebSocket(wsUrl());
    socket = ws;
    nextId = 1;

    ws.onopen = () => {
      if (ws !== socket) return;
      attempts = 0;
      const reconnected = everOpened;
      everOpened = true;
      resolveReady();
      flushQueue();
      if (reconnected) notify(reconnectListeners);
    };

    ws.onmessage = (event) => {
      if (ws !== socket) return;
      if (typeof event.data !== "string") {
        console.warn("neel: dropping non-text frame");
        return;
      }
      const msg = parse(event.data);
      if (msg === null) {
        console.warn("neel: dropping malformed message", event.data);
        return;
      }
      if (msg.t === "call") handleCall(ws, msg);
      else handleReply(msg);
    };

    ws.onclose = (event) => {
      if (ws !== socket) return;
      socket = null;
      failPending("neel: connection lost (close code " + event.code + ")");
      if (terminated) return;
      if (event.code === 1000 || event.code === 1001) {
        terminate("neel: server closed the connection (close code " + event.code + ")", event.code);
        return;
      }
      scheduleReconnect(event.code);
    };
    // onerror carries no information the following onclose does not; ignored.
  }

  // --- public surface -----------------------------------------------------

  function expose(nameOrFn, maybeFn) {
    if (typeof nameOrFn === "string") {
      if (typeof maybeFn !== "function") {
        throw new TypeError("neel.expose(name, fn): fn must be a function");
      }
      registry.set(nameOrFn, maybeFn);
    } else if (typeof nameOrFn === "function") {
      if (!nameOrFn.name) {
        throw new TypeError("neel.expose(fn): anonymous function; use neel.expose(name, fn)");
      }
      registry.set(nameOrFn.name, nameOrFn);
    } else if (nameOrFn !== null && typeof nameOrFn === "object") {
      for (const [name, fn] of Object.entries(nameOrFn)) {
        if (typeof fn !== "function") {
          throw new TypeError("neel.expose({...}): '" + name + "' is not a function");
        }
        registry.set(name, fn);
      }
    } else {
      throw new TypeError("neel.expose: expected a function, a name and a function, or an object");
    }
  }

  function close() {
    if (terminated) return;
    if (socket !== null) {
      const ws = socket;
      socket = null;
      ws.close(1000, "neel.close()");
    }
    terminate("neel: closed by neel.close()", 1000);
  }

  function addListener(listeners, label, fn) {
    if (typeof fn !== "function") throw new TypeError("neel." + label + "(fn): fn must be a function");
    listeners.push(fn);
  }

  const neel = {};
  Object.defineProperties(neel, {
    call: { value: call, enumerable: true },
    send: { value: send, enumerable: true },
    expose: { value: expose, enumerable: true },
    close: { value: close, enumerable: true },
    ready: { value: ready, enumerable: true },
    windowId: { value: WINDOW_ID, enumerable: true },
    connected: { get: isOpen, enumerable: true },
    onclose: { value: (fn) => addListener(closeListeners, "onclose", fn), enumerable: true },
    onreconnect: { value: (fn) => addListener(reconnectListeners, "onreconnect", fn), enumerable: true },
  });

  for (const name of EXPOSED) {
    if (typeof name !== "string" || name === "") continue;
    if (RESERVED.has(name)) {
      console.warn("neel: exposed proc '" + name + "' collides with the neel API; " +
                   "reach it with neel.call(" + JSON.stringify(name) + ", ...)");
      continue;
    }
    const fn = (...args) => call(name, ...args);
    fn.send = (...args) => send(name, ...args);
    Object.defineProperty(fn, "name", { value: name });
    Object.defineProperty(neel, name, { value: fn, enumerable: true });
  }

  globalThis.neel = neel;
  connect();
})();
