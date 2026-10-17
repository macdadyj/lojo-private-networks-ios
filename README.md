# LOJO Private Networks — iOS field app

SwiftUI iPhone app for LOJO Private Networks customers: see which of **your own devices**
(ranch Pis, webcams, GPIO relays, lab machines) are online, pull camera stills, switch relays
with a confirmation step, read the activity log, see devices on a map, and find out in plain
language whether the phone can reach the private network right now (site Wi‑Fi, private
overlay, or not at all). Nothing is exposed to the public internet.

Built **on Linux** (santacomputa) with Swift 6.3.3 + the Xcode 26.6 iOS SDK + [xtool], signed
with a **free Apple ID**, and installed over **USB** on Jon's iPhone 11. There's no Xcode.app
and no Simulator; "run" means the physical phone.

- Design and plan: [`docs/design.md`](docs/design.md)
- HTTPS design (per-site CA, pinning, QR pairing, legacy fallback): [`docs/tls.md`](docs/tls.md)
- SSH terminal (Terminal tab) feasibility, design and device inventory: [`docs/ssh-terminal.md`](docs/ssh-terminal.md)
- Phone screenshots: [`docs/screenshots/`](docs/screenshots/) (index below)
- Draft PR history: refinement passes are separate commits

[xtool]: https://github.com/xtool-org/xtool

## Repo layout

| Path | What |
|---|---|
| `App/` | xtool project. `xtool.yml` (bundle `com.lojo.PrivateNetworks`, on-device `XTL-HG9HAYXW44.com.lojo.PrivateNetworks`), `Info.plist`, `Resources/AppIcon.png`, `Sources/LojoNetworks/` |
| `App/Sources/LojoNetworks/Model` | Codable models for the gateway `v1` API, naming rules, event kinds |
| `App/Sources/LojoNetworks/Services` | `GatewayClient` (pinned HTTPS via URLSession, legacy HTTP via `PlainHTTP`, probes, pairing, exact error codes and wording), `SiteTrust` (site CA in the Keychain, pairing code parser, pinning delegate, TLS failure reasons), `PlainHTTP` (HTTP/1.1 on Network.framework for the labelled fallback), `GatewayAddress` (normalise/classify addresses), `PathDiagnostics` (DNS/TCP/TLS/HTTP per-path report), `PhoneInterfaces` (Wi‑Fi/cellular/VPN detection) |
| `App/Sources/LojoNetworks/Store` | `NetworkStore` (state, LAN→overlay failover, capture/GPIO flows, demo), `LaunchOptions` (QA hooks) |
| `App/Sources/LojoNetworks/Views` | Home, Device detail, Activity, Map, Connection check, Onboarding, Setup, Settings, pairing sheet and Security section (`SecurityViews`) |
| `App/Sources/LojoNetworks/Demo` | Demo network "Juniper Mesa Ranch", procedurally drawn camera stills and site plan |
| `App/Sources/LojoNetworks/Design` | Theme, cards, status dots, buttons, haptics, toasts |
| `App/Sources/LojoSSH` | SSH core on apple/swift-nio-ssh: connection, auth, PTY shell, exec, keep-alive ping, known_hosts, overlay-only policy, key import. No UIKit, so `tools/ssh-smoke` builds it on Linux too |
| `App/Sources/LojoNetworks/Terminal` | Terminal tab: saved hosts, gateway device list, Secure Enclave / Keychain keys, host-key checks, session tabs on SwiftTerm (pinned v1.11.2, fetched by `sync-app.sh`). Each tab attaches a named tmux session so the shell survives a dropped SSH connection. Scrollback is 10,240 lines with pin-to-bottom and a Jump to latest chip |
| `App/Sources/LojoTerminalScroll` | Foundation-only scrollback policy (buffer size, pin/unpin, TUI wheel translation). Linux-tested from `tools/terminal-scrollback` |
| `App/Sources/LojoRemote` | iPhone Remote Controller protocol: sounds, schedules, Shortcuts names, relay client. Linux-tested from `tools/remote-controller` |
| `relay/` | Relay the spare iPhone and the controller share. `node relay/server.js` on the site gateway (loopback unless `BIND` is set). No secrets |
| `.github/workflows/ios.yml` | macOS unit tests, phone UI tests (every tap + flood scroll), TestFlight upload on `main` |
| `gateway/lojo-ssh-directory` | Read-only gateway script the Terminal tab runs over SSH to list LOJO devices and whether SSH is open |
| `tools/ssh-smoke` | Linux smoke test for `LojoSSH` against a real OpenSSH (`scripts/test-sshd.sh smoke`) |
| `tools/terminal-persist` | Unit tests for the reconnect state machine and tmux command strings (`swift test`). GitHub Actions runs them on Linux and macOS |
| `tools/terminal-scrollback` | Linux unit tests for the 10k-line scrollback policy |
| `sidecar/` | Site gateway `ranch-field-api` (Node 20). Source of truth for `~/.local/share/ranch-field-api/` |
| `scripts/` | `deploy-phone.sh`, `sync-app.sh`, `phone-shot.sh`, `deploy-sidecar.sh`, `gateway-tls.sh` (site CA, server cert, rotation, pairing QR), `make-icon.py`, `archive-upload.sh`, `ios-unit-test.sh`, `phone-ui-test.sh` |
| `docs/` | Design doc, HTTPS design, screenshots |

## Architecture

```
iPhone app ──HTTPS :8443 (pinned site CA)──▶ site gateway (santacomputa, ranch-field-api 1.4)
  LAN   https://192.168.7.103:8443                 │ Socket.IO
  VPN   https://100.96.1.18:8443                   ▼
  legacy HTTP :8801 (unpaired phones,      overlay proxy 100.96.1.18:8788 ──▶ Cloud Run Pub-Node (pub-node-test)
    old Ranch Field app, VPN fallback)
```

Paired phones talk HTTPS to the gateway on both paths; see [`docs/tls.md`](docs/tls.md). The HTTP
listener on :8801 and every legacy route are unchanged. GPIO goes out as `controlState` to the
**Cloud Run** Pub-Node. **App Engine Flex production is never used.** The app tries LAN first,
then the overlay.

## Rebuild and redeploy (santacomputa)

Prereqs are already installed on santa (see `~/CURSOR_IOS_BRIEF.md`): `~/.config/ios-dev/env`,
xtool 1.20.1 (`~/.local/bin/xtool`), Swift 6.3.3, Darwin SDK (slim, Xcode 26.6),
pymobiledevice3 11.x. Don't upgrade to Xcode 27 or Swift 6.4.

```bash
cd ~/lojo-private-networks-ios
source ~/.config/ios-dev/env
xtool auth status && xtool sdk status && xtool devices   # Logged in / installed / Jon's iPhone [usb]

scripts/deploy-phone.sh --build   # unsigned compile check
scripts/deploy-phone.sh           # compile + provision + sign + USB install + launch
```

### Dev and release builds

| Flavour | Command | Configuration | "Legacy HTTP over VPN" |
|---|---|---|---|
| Dev (what Jon's phone runs now) | `scripts/deploy-phone.sh` | debug (QA hooks such as `LOJO_PAIR_CONFIRM`, `LOJO_AUTOTEST`) | Offered, toggle in Settings › Security, default on |
| Release / sold | `scripts/deploy-phone.sh --release` | release (optimised, no DEBUG hooks) | Not offered: a paired phone never uses plain HTTP |

Add `--build` to either for a compile check only (`--release --build`). The switch is the
`LOJOLegacyHTTPOverVPN` Info.plist key. `App/Info.plist` has the dev value (`true`), and
`deploy-phone.sh` writes the flavour's value into the build-dir copy only. To override it, set
`LOJO_LEGACY_HTTP_OVER_VPN=on|off`, e.g. a release build that still has the fallback:
`LOJO_LEGACY_HTTP_OVER_VPN=on scripts/deploy-phone.sh --release`. The script prints the
configuration and fallback state before building. The fallback stays **on** for now, until the
project is closer to market. See [`docs/tls.md`](docs/tls.md#legacy-fallback-labelled).

`deploy-phone.sh` rsyncs `App/` into the **ext4** build dir `~/.local/share/ios-dev/apps/LojoNetworks`
(it refuses non-ext4). It exports `XTL_TMPDIR=~/.cache/xtool-tmp` through the env file, runs
`xtool dev run -c debug|release --usb --udid <UDID>`, then launches the app with
`pymobiledevice3 developer core-device launch-application --userspace`. The UDID comes from
`scripts/phone-udid.sh`, which reads USB at run time and accepts only the **iPhone 11** (ProductType
`iPhone12,1`; `LOJO_PHONE_MODEL` overrides). It refuses if none or several match, and `LOJO_UDID` must
also be that model, so another phone on the hub is never installed to. The UDID is never printed or
stored in the repo. Always edit in the repo;
the build dir is disposable. Signing on NTFS (`LOJODESKDRIVE`) fails with `0xe8008017`.

`ld64.lld: warning: This version of lld does not support linking for platform iOS` is expected.

## TestFlight

The **iOS** workflow matches [lojo-watch-remote](https://github.com/macdadyj/lojo-watch-remote) `.github/workflows/ios.yml`: `macos-26`, Xcode 26, tests gate the upload, build number is the GitHub run number (a re-run appends `.attempt`), and a push to `main` archives and uploads to App Store Connect. Pull requests never sign or upload.

The on-device xtool bundle `XTL-N9H4648NB9.com.lojo.*` (or `XTL-HG9HAYXW44.com.lojo.PrivateNetworks` on santa) is a development prefix. App Store Connect cannot use that prefix. TestFlight uses **`com.lojo.PrivateNetworks`**.

### GitHub secrets (same names as Watch Remote)

This agent cannot read or write repository secrets. If any of these are missing on `macdadyj/lojo-private-networks-ios`, paste the Watch Remote values:

```bash
gh secret set ASC_KEY_ID -R macdadyj/lojo-private-networks-ios
gh secret set ASC_ISSUER_ID -R macdadyj/lojo-private-networks-ios
base64 < AuthKey_XXXXXXXXXX.p8 | gh secret set ASC_KEY_P8 -R macdadyj/lojo-private-networks-ios
gh secret set DEVELOPMENT_TEAM -R macdadyj/lojo-private-networks-ios
```

`ASC_KEY_P8` may be the `.p8` as base64 or the PEM text. `DEVELOPMENT_TEAM` is the paid Apple team id (not committed). The workflow mints a one-run iOS Distribution certificate and an App Store profile, then deletes the profile and revokes only that certificate.

### App Store Connect clicks (once)

1. [developer.apple.com/account](https://developer.apple.com/account) → **Certificates, Identifiers & Profiles** → **Identifiers** → **+** → **App IDs** → **Continue**.
2. Type **App**, Continue. Description `LOJO Networks`. Bundle ID **Explicit** `com.lojo.PrivateNetworks`. Continue → Register. No extra capabilities.
3. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Apps** → **+** → **New App**.
4. Platform **iOS**. Name `LOJO Networks`. Primary Language **English (U.S.)**. Bundle ID `com.lojo.PrivateNetworks`. SKU `lojo-private-networks`. User Access **Full Access** → Create.

The build number is shown in the app under **Settings → Build**. After the first green `main` run, install from TestFlight (Developer Mode is not required).

### First install on a phone (needs a human at the phone)

1. Phone unlocked, on the USB cable, Developer Mode on (`pymobiledevice3 amfi developer-mode-status` → `true`).
2. Developer Disk Image mounted: `pymobiledevice3 mounter auto-mount` (fails while locked).
3. If iOS says the developer isn't trusted: **Settings → General → VPN & Device Management → Apple
   Development: (the signing Apple ID) → Trust**. (Already trusted on Jon's iPhone 11.)
4. The first time the app goes live, iOS asks **“Allow ‘LOJO Networks’ to find devices on local
   networks?” → tap Allow**. Without it the LAN path is blocked, and the Connection check says so.
   You can change it later in Settings → Privacy & Security → Local Network → LOJO Networks.
5. **Pair the phone with the gateway (turns on HTTPS).** On santa run
   `scripts/gateway-tls.sh pair`. It prints a QR code in the terminal and writes
   `~/.local/state/ranch-field-api/tls/pairing-qr.png`. On the phone (on site Wi‑Fi or the VPN),
   open the **Camera** app, point it at the QR code, tap the **“Open in LOJO Networks”** banner,
   check the fingerprint matches the one the command printed, and tap **Pair**. Home should then
   show **Encrypted · pinned**. Without a camera handy: copy the `lojo://pair?…` line to the
   phone and use Settings → Security → **Paste pairing code**.

**Install stall while that prompt is on screen.** If the app is in the foreground showing the
Local Network prompt (or any system alert) when you reinstall, `xtool dev run` can hang at
`[Installing] 100%` indefinitely. Stop it (Ctrl‑C), bring another app to the front, then rerun:

```bash
pymobiledevice3 developer core-device launch-application --userspace XTL-HG9HAYXW44.com.lojo.HelloLab ''
scripts/deploy-phone.sh
```

The prompt's answer survives reinstalls, so this only bites before someone taps Allow or Don't Allow.

### 7-day free-profile re-sign

A free Apple ID gives a ~1-year development certificate but a **~7-day provisioning profile**.
**The current profile expires around 6 Oct 2026.** After that the app won't launch
("no longer available" / "unable to verify"). To renew, plug in the phone and re-run
`scripts/deploy-phone.sh`. xtool re-provisions and re-signs, and app data is kept. If
`xtool auth status` isn't "Logged in", run `xtool-auth-login` in a real terminal (password + 2FA,
never pasted into chat). Free-account limits: about 3 sideloaded apps (currently HelloLab,
RanchField, LOJO Networks) and 10 new App IDs per week. USB only for that free-profile install. TestFlight builds come from the **iOS** GitHub Action on `main` (paid team, bundle `com.lojo.PrivateNetworks`, no `XTL-` prefix).

## Site gateway (sidecar)

`sidecar/server.js` is the source of truth for `~/.local/share/ranch-field-api/server.js`
(user unit `ranch-field-api.service`, copy in `sidecar/ranch-field-api.service`).

```bash
scripts/deploy-sidecar.sh   # syntax check, back up live server.js, copy, restart, curl /health + /v1/network
```

The gateway re-lists the hub roster every 60 s and 6 s after any device leaves, because the hub
doesn't re-announce a device that drops and rejoins within a second or two.

| Method | Path | Notes |
|---|---|---|
| GET | `/health`, `/devices`, `/devices/:id`, `/devices/:id/still` | Legacy, unchanged (old Ranch Field app) |
| POST | `/devices/:id/capture` | Webcam still request; now 503 when the hub is disconnected (it used to be silently queued) |
| POST | `/devices/:id/gpio` | `{pin:"11", value:0\|1}` → Cloud Run `controlState`; pin = 40-pin header position (11 = GPIO 17); 503 when hub down |
| GET | `/v1/network` | Gateway/hub health, counts, `arrivedVia` = `lan` / `overlay` / `local`, `seenFrom` (the caller's address as the gateway sees it) |
| GET | `/v1/devices` | Roster incl. offline devices (keyed by stable name), camera, GPIO, `location {lat,lon,source}` |
| GET | `/v1/events?limit=&device=` | Activity log (ring of 300, persisted in `~/.local/state/ranch-field-api/state.json`) |

All routes are served on both HTTP :8801 and HTTPS :8443. `/v1/network` adds `scheme`,
`tls {enabled, port, caSha256, leafSha256, leafNotAfter}` and `site {name}` (the site's display
name, which paired phones adopt). `capture.requested` and `gpio.set`
events record the `scheme` they arrived on.

### Gateway HTTPS: setup and rotation

Design and failure codes: [`docs/tls.md`](docs/tls.md). One script does everything; it never
prints or commits a private key.

```bash
scripts/gateway-tls.sh init        # once per site: site CA + first server cert, reloads the gateway
scripts/gateway-tls.sh status      # CA/server fingerprints, expiry, SANs, key permissions (warns < 30 days)
scripts/gateway-tls.sh pair        # pairing QR (terminal + PNG) and the lojo://pair code
scripts/gateway-tls.sh rotate      # yearly: new server key + cert, same CA; hot reload; phones keep working
scripts/gateway-tls.sh rotate-ca   # only on CA compromise/expiry: every phone must re-pair
```

| File | Mode | What |
|---|---|---|
| `~/.config/lojo-gateway-tls/ca.key` | 0600 | Site CA private key (never leaves santa; back it up offline) |
| `~/.config/lojo-gateway-tls/ca.crt`, `site.env` | 0600 | CA certificate; site name, SANs, pairing URLs (public, editable) |
| `~/.local/state/ranch-field-api/tls/server.key` | 0600 | Gateway TLS key |
| `~/.local/state/ranch-field-api/tls/fullchain.crt`, `server.crt`, `ca.crt`, `pairing-qr.png` | 0600 | Served chain (leaf + CA), leaf, CA copy, QR |
| `~/.local/state/ranch-field-api/tls/site.json` | 0600 | `{"name": …}` from `SITE_NAME`, served as `site.name` (public) |

Directories are 0700. To add an address or host name the phones use, edit `SANS` (and
`LAN_URL`/`OVERLAY_URL` for the QR) in `site.env`, then run `rotate` and, if the URLs changed,
`pair` again.

**Renaming the site** (santa's is **LOJO VPN**): edit `SITE_NAME` in `site.env`, run `rotate`
(new leaf and `site.json`, same CA) and `pair` (new QR). Paired phones show the new name after
their next refresh, with no re-pairing. The CA's subject keeps its original name
(`My Private Network site CA` on santa) on purpose, because replacing the CA would force every
phone to re-pair. The phones never display it. The `site.env` template in `gateway-tls.sh` has
santa's values; the app's own default name stays the generic "My Private Network" for other
customers' fresh installs. Details: [`docs/tls.md`](docs/tls.md#site-name). `.gitignore` blocks `*.key`, `*.p12`, `*.pfx` and `pairing-qr.png`.

Checks from santa (the CA certificate is public):

```bash
CA=~/.local/state/ranch-field-api/tls/ca.crt
curl -s --cacert $CA https://192.168.7.103:8443/v1/network   # "scheme":"https","arrivedVia":"lan"
curl -s --cacert $CA https://100.96.1.18:8443/v1/network     # overlay address
curl -s https://192.168.7.103:8443/health                    # must FAIL: not publicly trusted
curl -s http://192.168.7.103:8801/health                     # legacy HTTP still 200
```

## QA guide

Every screen can be reached without touching the phone by using launch environment variables:

```bash
scripts/phone-shot.sh OUT.png [KEY=VALUE ...]    # launches (kills existing) then screenshots
```

| Variable | Values |
|---|---|
| `LOJO_DEMO` | `1` demo network, `0` live gateway (persisted) |
| `LOJO_SCREEN` | `home`, `detail`, `activity`, `map`, `check`, `onboarding`, `setup`, `settings`, `terminal` |
| `LOJO_SSH_SCREEN` | with `terminal`: `hosts`, `keys`, `key` (the Secure Enclave key with Copy authorize command), `settings`, `edit` (host editor, including Keep sessions alive), `diag` (diagnostics), `sessions`, `reconnecting`, `scrollback` (debug flood), `alternate` (debug TUI) |
| `LOJO_SSH_FLOOD` | debug builds only; line count for `scrollback` / `alternate` (default 2500) |
| `LOJO_SSH_HOST` | host label for `edit` and `diag` (default `gateway`) |
| `LOJO_SSH_CONNECT` | with `terminal`: host label to open a session to (`gateway` = the seeded site gateway) |
| `LOJO_SSH_REDACT` | `1` masks IP addresses in the Terminal tab (use for every screenshot) |
| `LOJO_SSH_REFRESH` | `1` pulls the gateway device list at launch even if the cached one is fresh |
| `LOJO_SSH_RUN`, `LOJO_SSH_TRUST_FP`, `LOJO_SSH_GATEWAY_PORT`, `LOJO_SSH_ENSURE_KEY`, `LOJO_SSH_PREVIEW` | debug builds only; `LOJO_SSH_PREVIEW=1` fills the reconnecting indicator and the session list with sample data (no dial). See [`docs/ssh-terminal.md`](docs/ssh-terminal.md) §8 |
| `LOJO_DEVICE` | key or name for `detail`, e.g. `north-gate`, `SantaWebcam` |
| `LOJO_CONFIRM_GPIO` | pin; opens the GPIO confirmation sheet on `detail` (nothing is sent) |
| `LOJO_SIMULATE_OFFLINE` | `1` routes both paths to unroutable TEST-NET addresses (real failure path) |
| `LOJO_APPEARANCE` | `light` / `dark` / `system` |
| `LOJO_LAN`, `LOJO_OVERLAY` | override the site Wi‑Fi / overlay gateway address for this launch (`https://` defaults to port 8443, plain addresses to 8801) |
| `LOJO_PAIR` | a `lojo://pair?…` code: opens the pairing sheet as if scanned with the Camera app |
| `LOJO_PAIR_CONFIRM` | debug builds only: `1` taps Pair automatically (with `LOJO_PAIR`) |
| `LOJO_UNPAIR` | `1` removes the pinned CA at launch and reverts to legacy HTTP addresses |
| `LOJO_SCROLL` | `diagnostics` scrolls the Connection check to its diagnostics card when it finishes |
| `LOJO_AUTOTEST` | debug builds only: on `detail`, `capture` or `gpio:<pin>:<0\|1>` runs that action through the same code as the buttons (real hardware!) |

Examples:

```bash
scripts/phone-shot.sh /tmp/home.png   LOJO_DEMO=0 LOJO_SCREEN=home
scripts/phone-shot.sh /tmp/gate.png   LOJO_DEMO=1 LOJO_SCREEN=detail LOJO_DEVICE=north-gate LOJO_CONFIRM_GPIO=11
scripts/phone-shot.sh /tmp/off.png    LOJO_DEMO=0 LOJO_SCREEN=check LOJO_SIMULATE_OFFLINE=1
LOJO_SHOT_WAIT=12 scripts/phone-shot.sh /tmp/pair.png LOJO_DEMO=0 \
  "LOJO_PAIR=$(scripts/gateway-tls.sh pair | grep -o 'lojo://pair?[^ ]*')" LOJO_PAIR_CONFIRM=1
```

### Connection check and diagnostics

The Connection tab tests both paths at once, each with 5 s step timeouts, and shows a plain
verdict plus a **Diagnostics** card per path: address and type (RFC 1918 LAN, 100.64/10 overlay,
host name, `.local`), **Scheme** (HTTPS pinned, or HTTP legacy and whether only the VPN encrypts
it), **Pin** (the site CA fingerprint from the Keychain, or "not paired"), DNS (resolved addresses
and time, or "not needed" for IPs), a raw TCP connect (time, interface such as `en0 (Wi‑Fi)` or
`utun4 (VPN tunnel)`, local address), **TLS** (version, "chain verified to site CA", the leaf
fingerprint the phone saw and its expiry, or the exact failure such as `TLS pin mismatch` or
`TLS errSecHostNameMismatch (-67602)`), the HTTP(S) result
with the exact `NSURLError` name and code plus the POSIX error (e.g. `NSURLErrorCannotConnectToHost
(-1004) · ENETUNREACH (51)`) and what it means, the gateway's name, the site name it serves, and how it saw the phone.
**Copy** puts the whole report on the clipboard for support. No passwords, keys or device
identifiers are ever shown. Settings and Setup have a per-address **Test** button that uses the
same probe.

A separate **Encryption** step says whether the path in use is pinned HTTPS, legacy HTTP over
the VPN, or unencrypted, and a refused certificate gets its own "Secure connection refused"
verdict with the reason and what to do.

`App/Info.plist` has **no ATS exceptions**. URLSession is HTTPS-only. Legacy HTTP goes through
`PlainHTTP` (Network.framework, not governed by ATS). Don't re-add `NSAllowsArbitraryLoads` or
`NSAllowsLocalNetworking` (the latter blocked the 100.64/10 overlay with `-1022`).

### End-to-end capture and GPIO from the phone

Runs from the phone through the gateway and the Cloud Run hub. GPIO physically switches header
pin 11 (GPIO 17) on the LabWebcam Pi, so only do it when that's safe:

```bash
LOJO_SHOT_WAIT=25 scripts/phone-shot.sh /tmp/cap.png LOJO_DEMO=0 LOJO_SCREEN=detail LOJO_DEVICE=SantaWebcam LOJO_AUTOTEST=capture
LOJO_SHOT_WAIT=12 scripts/phone-shot.sh /tmp/on.png  LOJO_DEMO=0 LOJO_SCREEN=detail LOJO_DEVICE=LabWebcam LOJO_AUTOTEST=gpio:11:1
LOJO_SHOT_WAIT=12 scripts/phone-shot.sh /tmp/off.png LOJO_DEMO=0 LOJO_SCREEN=detail LOJO_DEVICE=LabWebcam LOJO_AUTOTEST=gpio:11:0
curl -s --cacert ~/.local/state/ranch-field-api/tls/ca.crt 'https://127.0.0.1:8443/v1/events?limit=4'
#   capture.requested / gpio.set show "via":"lan","scheme":"https" from a paired phone
ssh -i ~/.ssh/id_ed25519_labpi pi@100.96.1.115 'raspi-gpio get 17'   # level=1 after ON, 0 after OFF
```

The overlay path over HTTPS can be exercised from any overlay peer, e.g. the vision Pi, by
sending it the public CA certificate on stdin:

```bash
ssh -i ~/.ssh/id_ed25519_labpi pi@100.96.1.115 'cat > /tmp/ca.crt; curl -s --cacert /tmp/ca.crt https://100.96.1.18:8443/v1/network; rm /tmp/ca.crt' \
  < ~/.local/state/ranch-field-api/tls/ca.crt      # "arrivedVia":"overlay","scheme":"https"
```

Device agents number GPIO by **40-pin header position** (rpi-gpio's default), so the app shows
"Header pin 11 · GPIO 17" and the gateway rejects non-GPIO header positions.

Gateway checks from santa: see "Gateway HTTPS" above; every `/v1/network` should say
`"hub":{"connected":true`.

What to verify by hand on the phone (the host can't tap):

- Pull to refresh on Network. Tapping a device opens its detail. **Capture now** on a camera
  device shows the progress overlay, then a new still and a success haptic.
- A GPIO **Turn on/off** tap always opens the confirmation sheet first. Cancel sends nothing.
- Turn Wi‑Fi off (with no VPN): within 15 s the health card goes red, the last roster stays
  visible with a "last known state" banner, and actions are disabled with an explanation.
- Settings → Demo network toggles cleanly between demo and live.
- Settings → Connection setup: both paths test automatically; with no VPN connected the overlay
  row is amber ("expected until you connect your LOJO VPN"), not red.
- **HTTPS over the VPN:** turn Wi‑Fi off, connect the LOJO VPN profile, open the app. Home should
  say **Connected · Private overlay** with **Encrypted · pinned**. Connection tab → Diagnostics →
  "Private overlay (VPN) · HTTPS" shows `TLS 1.3 · chain verified to site CA`. Then do one Capture
  and one GPIO on/off. The gateway events show `"via":"overlay","scheme":"https"`. If it shows
  amber **Legacy HTTP over VPN** instead, HTTPS :8443 isn't reachable through the tunnel (the
  Encryption step and diagnostics give the exact code).
- **Pairing from the Camera app:** Settings → Security → Forget pairing, then scan the QR code
  from `scripts/gateway-tls.sh pair` with the Camera app, tap the banner, tap Pair.

## Screenshots

All taken on the iPhone 11 with `scripts/phone-shot.sh` (demo network uses fictional names and a
drawn site plan; the live map is deliberately not captured because live positions are real places).

| File | Screen |
|---|---|
| `01-onboarding.png` | Welcome, page 1 |
| `02-setup.png` | Connect your network: paired, site Wi‑Fi answering over HTTPS, overlay expected-off without VPN |
| `03-home-live.png` / `04-home-demo.png` / `05-home-demo-light.png` | Network home with the **Encrypted · pinned** label, live and demo, dark and light |
| `06-detail-demo.png` / `08-detail-live.png` | Device detail (camera still, controls, facts incl. Encryption) |
| `07-gpio-confirm.png` | GPIO confirmation sheet |
| `09-activity-live.png` / `10-activity-demo.png` | Activity timeline (live shows the end-to-end capture and GPIO test) |
| `11-map-demo.png` | Map (demo site plan) |
| `12-check-demo.png` | Connection check, away from site on the overlay (HTTPS, pinned) |
| `13-check-live.png` / `14-check-live-diagnostics.png` | Connection check on site Wi‑Fi: verdict, Encryption step, diagnostics with Scheme / Pin / TLS |
| `15-settings.png` | Settings › Security: pinned, site name from the gateway, CA fingerprint, legacy-over-VPN toggle (dev build), forget |
| `16-offline.png` | Not connected: plain reason plus exact per-endpoint codes |
| `17-pairing.png` | Pairing sheet after scanning the QR code (addresses, CA fingerprint, Pair) |
| `18-tls-refused.png` / `19-tls-refused-diagnostics.png` | A different CA answering: "Secure connection refused", `TLS pin mismatch` with the presented root |
| `20-home-unpaired.png` | Not paired: **Unencrypted (legacy HTTP)** label |

Terminal tab (all with `LOJO_SSH_REDACT=1`; 01–12 live shells are against the temporary test server on santa, 13–18 against the real devices before the phone's key was authorized, see [`docs/ssh-terminal.md`](docs/ssh-terminal.md) §8):

| File | Screen |
|---|---|
| `ssh-01-first-run.png` | First run with the VPN off: VPN gate, key setup prompt, seeded gateway (disabled) |
| `ssh-02-keys.png` | SSH keys: a Secure Enclave P-256 key made on the phone |
| `ssh-03-session-vpn-off.png` | Session opened with the VPN off: refused before any packet, with the key bar |
| `ssh-04-settings.png` | Font size, themes, address masking |
| `ssh-05-host-editor.png` | Host editor (address masked, key choice, host key section) |
| `ssh-06-host-key-prompt.png` | First connection: host key type and full SHA256 fingerprint, Trust and connect |
| `ssh-07-shell.png` | Live shell over the overlay with the Secure Enclave key: PTY size, xterm-256color, ANSI colours |
| `ssh-08-gateway-devices.png` | Gateway devices pulled over SSH (`lojo-ssh-directory`), SSH-open first, "This iPhone" marked |
| `ssh-09-tabs.png` | Two sessions in the tab strip |
| `ssh-10-reconnected.png` | Server dropped the connection; automatic reconnect with a banner |
| `ssh-11-exit.png` | Clean `exit`: "Session ended (exit 0)", no auto-reconnect |
| `ssh-12-host-key-changed.png` | Changed host key: connection refused, saved and offered fingerprints |
| `ssh-13-hosts-seeded.png` | Known devices seeded with their user and port: santacomputa `jon`:2222, labMachine, Vision Pi `pi`, BlueBox |
| `ssh-14-diag-host-key.png` | Diagnostics on santa's real sshd: VPN, route, TCP time, banner, first-use host key with Trust |
| `ssh-15-diag-login-denied.png` | Diagnostics after trusting: login denied with the exact reason (phone key not in `authorized_keys`) |
| `ssh-16-diag-connector-route.png` | BlueBox on `192.168.7.0/24`, reached through the overlay connector |
| `ssh-17-key-authorize.png` | Key detail: Copy authorize command, Copy and Share public key |
| `ssh-18-session-login-denied.png` | Session to santa denied: exact reason, Copy authorize command, Diagnose |

## Hard rules (from `~/CURSOR_ONBOARDING.md`)

No App Engine Flex deploys or changes; GPIO only through Cloud Run Pub-Node; no secrets, Apple
cookies, pairing records or device identifiers (IMEI/serial/ICCID) in commits or logs; no sudo;
free Apple ID only; USB deploy only. In-app wording avoids internal project names, cloud project
ids and supplier names.
