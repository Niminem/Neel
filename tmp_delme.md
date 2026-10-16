Final pass, macOS (SPEC.md 13.8). Read SPEC.md fully first, especially 13.8 and
section 16 (16.1 has today's Windows findings, 2026-10-16). Walk me through the
13.8 checks for macOS one at a time: give me the exact steps and the expected
result, and wait for my output. Run the parts you can from your own shell
(building, starting examples, the command-line checks, kill -TERM / kill -INT,
the second-signal checks); I'll do the browser and console parts and anything
that needs Ctrl-C in my own terminal. After each check, record pass/fail/n/a in
the 13.8 macOS column.

Things learned on Windows that apply here:
- DevTools "Offline" throttling did not close an open WebSocket in Chrome/Edge.
  For the two dormant rows, use an outage instead: a small Node TCP relay under
  /tmp listening on 127.0.0.1:5360 and forwarding to 127.0.0.1:5359, with the
  server started as `./examples/serve/serve http://127.0.0.1:5360` and the page
  opened at http://127.0.0.1:5360. Stopping the relay is the outage; starting it
  again restores the server with the same token.
- roundtrip: closing window 2 with X during the prompt gives PromptCancelled
  (the browser dismisses the prompt first). Kill window 2's browser process
  instead to get NeelDisconnectedError (the procedure says so now).
- Local Ctrl-C on Windows crashed debug builds inside Nim's own SIGINT handler
  (documented in the guide). Check whether macOS shows the expected message and
  exit status; don't assume either way.
- SSH forward: the Mac can be the server (Remote Login on), with the Windows
  machine as the client.
- For the idle-behind-a-proxy row, use a cloudflared quick tunnel
  (brew install cloudflared) unless I say otherwise.

On a failure: stop, show me the verbatim output, and explain what's going on
before fixing or logging anything; I'll decide what to do. Keep anything ad hoc
out of the repo (/tmp). Don't commit unless I ask.