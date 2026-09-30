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
- Phone screenshots: [`docs/screenshots/`](docs/screenshots/) (index below)
- Draft PR history: refinement passes are separate commits

[xtool]: https://github.com/xtool-org/xtool

## Repo layout

| Path | What |
|---|---|
| `App/` | xtool project. `xtool.yml` (bundle `com.lojo.PrivateNetworks`, on-device `XTL-HG9HAYXW44.com.lojo.PrivateNetworks`), `Info.plist`, `Resources/AppIcon.png`, `Sources/LojoNetworks/` |
| `App/Sources/LojoNetworks/Model` | Codable models for the gateway `v1` API, naming rules, event kinds |
| `App/Sources/LojoNetworks/Services` | `GatewayClient` (HTTP, probes, exact error codes and wording), `GatewayAddress` (normalise/classify addresses), `PathDiagnostics` (DNS/TCP/HTTP per-path report), `PhoneInterfaces` (Wi‑Fi/cellular/VPN detection) |
| `App/Sources/LojoNetworks/Store` | `NetworkStore` (state, LAN→overlay failover, capture/GPIO flows, demo), `LaunchOptions` (QA hooks) |
| `App/Sources/LojoNetworks/Views` | Home, Device detail, Activity, Map, Connection check, Onboarding, Setup, Settings |
| `App/Sources/LojoNetworks/Demo` | Demo network "Juniper Mesa Ranch", procedurally drawn camera stills and site plan |
| `App/Sources/LojoNetworks/Design` | Theme, cards, status dots, buttons, haptics, toasts |
| `sidecar/` | Site gateway `ranch-field-api` (Node 20). Source of truth for `~/.local/share/ranch-field-api/` |
| `scripts/` | `deploy-phone.sh`, `sync-app.sh`, `phone-shot.sh`, `deploy-sidecar.sh`, `make-icon.py` |
| `docs/` | Design doc, screenshots |

## Architecture

```
iPhone app ──HTTP :8801──▶ site gateway (santacomputa, ranch-field-api)
  LAN   http://192.168.7.103:8801          │ Socket.IO
  VPN   http://100.96.1.18:8801            ▼
                                  overlay proxy 100.96.1.18:8788 ──▶ Cloud Run Pub-Node (pub-node-test)
```

The phone only ever talks HTTP to the gateway. GPIO goes out as `controlState` to the **Cloud Run**
Pub-Node. **App Engine Flex production is never used.** The app tries LAN first, then the overlay.

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

`deploy-phone.sh` rsyncs `App/` into the **ext4** build dir `~/.local/share/ios-dev/apps/LojoNetworks`
(it refuses non-ext4). It exports `XTL_TMPDIR=~/.cache/xtool-tmp` through the env file, runs
`xtool dev run --usb --udid <UDID>` (the UDID is read from USB at run time, or from
`LOJO_UDID`, and is never stored in the repo), then launches the app with
`pymobiledevice3 developer core-device launch-application --userspace`. Always edit in the repo;
the build dir is disposable. Signing on NTFS (`LOJODESKDRIVE`) fails with `0xe8008017`.

`ld64.lld: warning: This version of lld does not support linking for platform iOS` is expected.

### First install on a phone (needs a human at the phone)

1. Phone unlocked, on the USB cable, Developer Mode on (`pymobiledevice3 amfi developer-mode-status` → `true`).
2. Developer Disk Image mounted: `pymobiledevice3 mounter auto-mount` (fails while locked).
3. If iOS says the developer isn't trusted: **Settings → General → VPN & Device Management → Apple
   Development: (the signing Apple ID) → Trust**. (Already trusted on Jon's iPhone 11.)
4. The first time the app goes live, iOS asks **“Allow ‘LOJO Networks’ to find devices on local
   networks?” → tap Allow**. Without it the LAN path is blocked, and the Connection check says so.
   You can change it later in Settings → Privacy & Security → Local Network → LOJO Networks.

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
RanchField, LOJO Networks) and 10 new App IDs per week. USB only; no TestFlight or push.

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

## QA guide

Every screen can be reached without touching the phone by using launch environment variables:

```bash
scripts/phone-shot.sh OUT.png [KEY=VALUE ...]    # launches (kills existing) then screenshots
```

| Variable | Values |
|---|---|
| `LOJO_DEMO` | `1` demo network, `0` live gateway (persisted) |
| `LOJO_SCREEN` | `home`, `detail`, `activity`, `map`, `check`, `onboarding`, `setup`, `settings` |
| `LOJO_DEVICE` | key or name for `detail`, e.g. `north-gate`, `SantaWebcam` |
| `LOJO_CONFIRM_GPIO` | pin; opens the GPIO confirmation sheet on `detail` (nothing is sent) |
| `LOJO_SIMULATE_OFFLINE` | `1` routes both paths to unroutable TEST-NET addresses (real failure path) |
| `LOJO_APPEARANCE` | `light` / `dark` / `system` |
| `LOJO_LAN`, `LOJO_OVERLAY` | override the site Wi‑Fi / overlay gateway address for this launch (IP or host name, port defaults to 8801) |
| `LOJO_SCROLL` | `diagnostics` scrolls the Connection check to its diagnostics card when it finishes |
| `LOJO_AUTOTEST` | debug builds only: on `detail`, `capture` or `gpio:<pin>:<0\|1>` runs that action through the same code as the buttons (real hardware!) |

Examples:

```bash
scripts/phone-shot.sh /tmp/home.png   LOJO_DEMO=0 LOJO_SCREEN=home
scripts/phone-shot.sh /tmp/gate.png   LOJO_DEMO=1 LOJO_SCREEN=detail LOJO_DEVICE=north-gate LOJO_CONFIRM_GPIO=11
scripts/phone-shot.sh /tmp/off.png    LOJO_DEMO=0 LOJO_SCREEN=check LOJO_SIMULATE_OFFLINE=1
```

### Connection check and diagnostics

The Connection tab tests both paths at once, each with 5 s step timeouts, and shows a plain
verdict plus a **Diagnostics** card per path: address and type (RFC 1918 LAN, 100.64/10 overlay,
host name, `.local`), DNS (resolved addresses and time, or "not needed" for IPs), a raw TCP connect
(time, interface such as `en0 (Wi‑Fi)` or `utun4 (VPN tunnel)`, local address), the HTTP result
with the exact `NSURLError` name and code plus the POSIX error (e.g. `NSURLErrorCannotConnectToHost
(-1004) · ENETUNREACH (51)`) and what it means, and the gateway's name and how it saw the phone.
**Copy** puts the whole report on the clipboard for support. No passwords, keys or device
identifiers are ever shown. Settings and Setup have a per-address **Test** button that uses the
same probe.

`App/Info.plist` must keep `NSAllowsArbitraryLoads` and must **not** gain `NSAllowsLocalNetworking`:
with that key present iOS ignores arbitrary loads and blocks plain HTTP to the 100.64/10 overlay
(`-1022`). `NSExceptionDomains` can't express IP ranges.

### End-to-end capture and GPIO from the phone

Runs from the phone through the gateway and the Cloud Run hub. GPIO physically switches header
pin 11 (GPIO 17) on the LabWebcam Pi, so only do it when that's safe:

```bash
LOJO_SHOT_WAIT=25 scripts/phone-shot.sh /tmp/cap.png LOJO_DEMO=0 LOJO_SCREEN=detail LOJO_DEVICE=SantaWebcam LOJO_AUTOTEST=capture
LOJO_SHOT_WAIT=12 scripts/phone-shot.sh /tmp/on.png  LOJO_DEMO=0 LOJO_SCREEN=detail LOJO_DEVICE=LabWebcam LOJO_AUTOTEST=gpio:11:1
LOJO_SHOT_WAIT=12 scripts/phone-shot.sh /tmp/off.png LOJO_DEMO=0 LOJO_SCREEN=detail LOJO_DEVICE=LabWebcam LOJO_AUTOTEST=gpio:11:0
curl -s 'http://127.0.0.1:8801/v1/events?limit=4'     # capture.requested/completed, gpio.set with via
ssh -i ~/.ssh/id_ed25519_labpi pi@100.96.1.115 'raspi-gpio get 17'   # level=1 after ON, 0 after OFF
```

Device agents number GPIO by **40-pin header position** (rpi-gpio's default), so the app shows
"Header pin 11 · GPIO 17" and the gateway rejects non-GPIO header positions.

Gateway checks from santa: `curl -s http://192.168.7.103:8801/v1/network` (LAN) and
`curl -s http://100.96.1.18:8801/v1/network` (overlay). Both should say `"hub":{"connected":true`.

What to verify by hand on the phone (the host can't tap):

- Pull to refresh on Network. Tapping a device opens its detail. **Capture now** on a camera
  device shows the progress overlay, then a new still and a success haptic.
- A GPIO **Turn on/off** tap always opens the confirmation sheet first. Cancel sends nothing.
- Turn Wi‑Fi off (with no VPN): within 15 s the health card goes red, the last roster stays
  visible with a "last known state" banner, and actions are disabled with an explanation.
- Settings → Demo network toggles cleanly between demo and live.
- Settings → Connection setup: both paths test automatically; with no VPN connected the overlay
  row is amber ("expected until you connect your LOJO VPN"), not red.

## Screenshots

All taken on the iPhone 11 with `scripts/phone-shot.sh` (demo network uses fictional names and a
drawn site plan; the live map is deliberately not captured because live positions are real places).

| File | Screen |
|---|---|
| `01-onboarding.png` | Welcome, page 1 |
| `02-setup.png` | Connect your network: site Wi‑Fi answering, overlay expected-off without VPN |
| `03-home-live.png` / `04-home-demo.png` / `05-home-demo-light.png` | Network home, live and demo, dark and light |
| `06-detail-demo.png` / `08-detail-live.png` | Device detail (camera still, controls, facts) |
| `07-gpio-confirm.png` | GPIO confirmation sheet |
| `09-activity-live.png` / `10-activity-demo.png` | Activity timeline (live shows the end-to-end capture and GPIO test) |
| `11-map-demo.png` | Map (demo site plan) |
| `12-check-demo.png` | Connection check, away from site on the overlay |
| `13-check-live.png` / `14-check-live-diagnostics.png` | Connection check on site Wi‑Fi, verdict and diagnostics |
| `15-settings.png` | Settings with gateway addresses and Test buttons |
| `16-offline.png` | Not connected: plain reason plus exact per-path codes |

## Hard rules (from `~/CURSOR_ONBOARDING.md`)

No App Engine Flex deploys or changes; GPIO only through Cloud Run Pub-Node; no secrets, Apple
cookies, pairing records or device identifiers (IMEI/serial/ICCID) in commits or logs; no sudo;
free Apple ID only; USB deploy only. In-app wording avoids internal project names, cloud project
ids and supplier names.
