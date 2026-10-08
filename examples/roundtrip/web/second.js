// second.js - window 2 of the round-trip example: a Nim -> JS target that
// returns a value.

"use strict";

const log = document.getElementById("log");
document.getElementById("window-id").textContent = String(neel.windowId);

function note(text) {
  const li = document.createElement("li");
  li.textContent = text;
  log.appendChild(li);
}

neel.expose({
  ask(question) {
    note("asked: " + question);
    const answer = prompt(question);
    if (answer === null) {
      const e = new Error("the prompt was cancelled in window " + neel.windowId);
      e.name = "PromptCancelled"; // becomes NeelRemoteError.kind on the Nim side
      note("cancelled");
      throw e;
    }
    note("answered: " + answer);
    return answer;
  },
});
