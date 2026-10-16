# Serve mode behind Cloudflare Tunnel with Access

This walkthrough puts a serve-mode app on a fixed public hostname
(`https://notes.example.com`) with a login in front of it. A named
Cloudflare Tunnel carries the traffic from Cloudflare to `127.0.0.1` on your
machine, so no port is opened, and Cloudflare Access asks for a login before
any request reaches Neel. It was verified with `examples/serve` on Windows 11,
cloudflared 2026.10.1, and Chrome; the commands are the same on macOS and
Linux. Dashboard labels change from time to time; the ones below are from
October 2026.

For the short version and how this setup compares to the others, see
[Setups](GUIDE.md#setups) in the guide.

## What you need

- A domain whose DNS Cloudflare runs. On the Free plan that means the whole
  domain: you point its nameservers at Cloudflare. A domain you use for
  nothing else is the simplest.
- A Cloudflare account and Zero Trust, both on their Free plans. Zero Trust
  asks for a payment method even on the Free plan (see [Costs](#costs)).
- `cloudflared` on the machine that runs the app: `winget install --id
  Cloudflare.cloudflared` on Windows (open a new terminal afterwards so it is
  on `PATH`), Homebrew or Cloudflare's release binaries on macOS, Cloudflare's
  packages or release binaries on Linux.
- The app, started with `serve = true`, a fixed `port`, and the hostname in
  `allowedOrigins`. The examples below use `examples/serve` on port 8080.

## 1. Move the domain's DNS to Cloudflare

1. Sign up at <https://dash.cloudflare.com/sign-up> and verify your e-mail.
2. **Add a domain**, enter the bare domain (`example.com`), keep **Quick
   scan for DNS records**, and choose the **Free** plan.
3. Delete the records the scan found that you do not need (a new domain
   usually has only the registrar's parking records). An empty list is fine:
   the tunnel creates its own record later. If Cloudflare warns that it
   cannot activate the site without records, choose **Add records later**.
4. Cloudflare shows two nameservers (`<name>.ns.cloudflare.com`). At your
   registrar, replace the domain's nameservers with these two. At Namecheap:
   **Domain List**, **Manage**, **Nameservers**, **Custom DNS**, then the
   green checkmark. Make sure DNSSEC is off at the registrar.
5. Back in Cloudflare, **Check nameservers now**. The domain becomes
   **Active** within minutes to hours, and Cloudflare e-mails you. To check
   from a terminal: `nslookup -type=NS example.com 1.1.1.1` lists the two
   Cloudflare nameservers once the switch is visible.

## 2. Enable Zero Trust

1. In the dashboard, open **Zero Trust** and click **Get started**.
2. Pick a team name. It becomes your login page,
   `<team>.cloudflareaccess.com`, and can be changed later under
   **Settings**.
3. Choose the **Free** plan and add the payment method.
4. Login methods are under **Integrations**, **Identity providers**.
   **One-time PIN** (a code sent to the e-mail address) works without any
   setup; you can add others, such as Google.

## 3. Create the Access application

Create it before the tunnel, so the hostname is never reachable without a
login.

1. **Zero Trust**, **Access controls**, **Applications**, **Create new
   application**, **Self-hosted**.
2. Name it, and add a public hostname: subdomain `notes`, your domain, path
   empty.
3. Leave **Allow access through browser-based RDP, SSH, or VNC sessions**
   off; this app is an ordinary website.
4. Under **Access policies**, **Create new policy**: action **Allow**,
   **Include**, selector **Emails**, your address. Attach it to the
   application.
5. Leave the remaining settings at their defaults and save.

Without a login, `curl -I https://notes.example.com` now answers `302` with a
`location` on `<team>.cloudflareaccess.com` (once the tunnel exists; before
that the name does not resolve).

## 4. Create the tunnel

```
cloudflared tunnel login
cloudflared tunnel create myapp
cloudflared tunnel route dns myapp notes.example.com
```

`tunnel login` opens the browser: pick the domain and **Authorize**; it saves
`cert.pem` in `~/.cloudflared` (`%USERPROFILE%\.cloudflared` on Windows).
`tunnel create` prints the path of the tunnel's credentials file; keep that
file private. `route dns` adds a `CNAME` for `notes.example.com` that points
at the tunnel.

Write `~/.cloudflared/config.yml` (on Windows
`%USERPROFILE%\.cloudflared\config.yml`, with
`credentials-file: C:\Users\<user>\.cloudflared\<tunnel-id>.json`):

```yaml
tunnel: myapp
credentials-file: /home/<user>/.cloudflared/<tunnel-id>.json
ingress:
  - hostname: notes.example.com
    service: http://127.0.0.1:8080
  - service: http_status:404
```

`cloudflared tunnel ingress validate` checks it. On Windows, cloudflared may
not find the file by itself; pass it before `tunnel`, here and in the next
step: `cloudflared --config $env:USERPROFILE\.cloudflared\config.yml tunnel
ingress validate`.

## 5. Run it

```
cloudflared tunnel run myapp
./examples/serve/serve --port=8080 https://notes.example.com
```

Open `https://notes.example.com`, log in on the Access page, and the app
loads. Until the app is up, the tunnel answers 502.

## How it behaves

- **The login redirect.** Access sends you back to the app from
  `<team>.cloudflareaccess.com`, so the browser marks that first page load
  as cross-site. Serve mode accepts cross-site top-level navigations for
  this reason; frames, scripts, and fetches from other sites are still
  refused (see [Security in serve mode](GUIDE.md#security-in-serve-mode)).
- **Idle connections.** Cloudflare closes a WebSocket after about 100
  seconds of silence; serve mode's pings every 30 seconds keep it open.
- **Restarts.** The hostname is fixed, so the app restarts with the same
  origin. A page that uses the
  [reload recipe](GUIDE.md#reloading-after-a-server-restart) reloads once
  the app answers again. If the Access login has expired by then, the reload
  goes to the login page instead of waiting. If the login is still valid at
  Cloudflare or at your identity provider, the reload signs you back in
  without asking, and if the app is still down at that moment you land on
  Cloudflare's 502 page, which does not reload by itself: reload it by hand
  once the app is up.
- **Ending a login.** **Team & Resources**, **Users**, the user, **Revoke
  session** ends it. The application's **Revoke existing tokens** alone does
  not: the login on `<team>.cloudflareaccess.com` signs the next request
  back in.

## Costs

The domain's Free plan, Zero Trust Free (up to 50 users), and Cloudflare
Tunnel cost nothing, and nothing in this setup is billed by usage. Charges
come only from things you turn on: a plan upgrade or trial, or add-ons such
as Argo Smart Routing (billed per GB). **Manage account**, **Billing**,
**Subscriptions** lists what you have.

## Removing it

1. Stop the app, and stop `cloudflared tunnel run` with Ctrl-C, which
   tells Cloudflare its connections are closing.
2. `cloudflared tunnel delete myapp` deletes the tunnel and its credentials
   file. If `cloudflared` was killed instead, Cloudflare still lists its
   connections for a few minutes and the delete fails with "This tunnel has
   active connections"; `cloudflared tunnel cleanup myapp` drops them, and
   the delete then works.
3. The DNS record stays: dashboard, the domain, **DNS**, **Records**, then
   **Edit** and **Delete** on the `CNAME` for `notes`.
4. **Zero Trust**, **Access controls**: delete the application under
   **Applications** first, then its policy under **Policies**.
5. Optionally delete `cert.pem` and `config.yml` in `~/.cloudflared`
   (`%USERPROFILE%\.cloudflared` on Windows), cancel the Zero Trust
   subscription under **Billing**, **Subscriptions**, and remove the domain
   from Cloudflare.
