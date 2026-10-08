// neel.js - browser-side shim for Neel 2.0.
//
// Plain ES2020, no build step, no dependencies. Served at /neel.js after
// frontend.nim substitutes the placeholders __NEEL_TOKEN__, __NEEL_WINDOW_ID__,
// and __NEEL_EXPOSED__ at compile time.
//
// Responsibilities (Task 10):
// - Connect to /ws with the launch token and window id; reconnect on refresh
//   and queue calls made before the socket is open.
// - Promise map keyed by id: `ret` resolves, `err` rejects with an Error whose
//   name is the Nim exception kind and message is the Nim message.
// - Generate `neel.<name>(...)` (Promise) and `neel.<name>.send(...)`
//   (fire-and-forget) for every exposed Nim proc.
// - `neel.expose(fn)` / `neel.expose({name: fn})` registry for Nim -> JS
//   targets, falling back to `window[name]`.
// - Handle incoming `call` from Nim: invoke, await promises, reply `ret`/`err`
//   when an id is present.
//
// Wire format: PLAN.md "Protocol reference".
