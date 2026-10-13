// main.js - window 1 of the round-trip example.

"use strict";

const byId = (id) => document.getElementById(id);
const error = byId("error");
let secondId = 0; // id returned by neel.openSecond()

byId("window-id").textContent = String(neel.windowId);

// Nim -> JS target: `askPage` in Nim does `js.wait.answer(question)`. The
// function is async on purpose: the shim awaits the returned promise and
// replies with the resolved value.
neel.expose({
  async answer(question) {
    await new Promise((resolve) => setTimeout(resolve, 300));
    return question + " -> " + byId("answer-text").value;
  },
});

// Runs `fn`, writes its result into `out`, and shows a rejection as
// "<name>: <message>" (the Nim exception kind and message).
async function run(button, out, fn) {
  button.disabled = true;
  out.textContent = "...";
  error.textContent = "";
  try {
    out.textContent = String(await fn());
  } catch (e) {
    out.textContent = "";
    error.textContent = e.name + ": " + e.message;
  } finally {
    button.disabled = false;
  }
}

byId("sum").addEventListener("click", (ev) =>
  run(ev.target, byId("sum-result"), () => neel.sum([1, 2, 3, 4, 5])));

byId("ask-page").addEventListener("click", (ev) =>
  run(ev.target, byId("ask-page-result"), () => neel.askPage("what now?")));

byId("open-second").addEventListener("click", (ev) =>
  run(ev.target, byId("open-second-result"), async () => {
    secondId = await neel.openSecond();
    return "opened window " + secondId;
  }));

byId("ask-second").addEventListener("click", (ev) =>
  run(ev.target, byId("ask-second-result"), () => neel.askSecond(secondId)));

byId("close-second").addEventListener("click", (ev) =>
  run(ev.target, byId("ask-second-result"), async () => {
    await neel.closeSecond(secondId);
    return "closed window " + secondId;
  }));

byId("list-windows").addEventListener("click", async (ev) => {
  const list = byId("window-list");
  list.replaceChildren();
  await run(ev.target, document.createElement("output"), async () => {
    for (const w of await neel.listWindows()) {
      const li = document.createElement("li");
      li.textContent = "window " + w.id + (w.connected ? " (connected)" : " (not connected)");
      list.appendChild(li);
    }
    return "";
  });
});
