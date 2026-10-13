// main.js - the page side of the file picker example.
//
// `neel.filePicker` exists because the Nim proc is marked {.expose.}; it
// returns a Promise that resolves with the proc's return value or rejects
// with an Error whose `name` is the Nim exception type and whose `message`
// is the Nim message.

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
