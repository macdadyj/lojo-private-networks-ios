# LOJO Private Networks — field app plan & design

Status: v1, built on Linux with xtool, USB-installed on the iPhone 11 (see `README.md`).

## Product frame

Customers connect **their own** devices (ranch Pis, webcams, GPIO relays, lab machines) to a
LOJO private network and reach them from anywhere over a private overlay. Nothing is exposed to
the public internet. The phone app is the owner's field remote: *see what's online, look through
the cameras, flip the relays, know whether you can reach your network right now and why.*

Pitch in one line: **your devices, your network, your control.**

In-app wording rules: no internal project/company code names, no cloud project ids, no names of
overlay/cloud suppliers. Vocabulary used in the UI:

| UI term | Meaning (internal) |
|---|---|
| Private network | The customer's overlay + sites |
| Site gateway | santacomputa sidecar (`ranch-field-api`, HTTPS :8443 pinned to a per-site CA, legacy HTTP :8801; see [`tls.md`](tls.md)) |
| Cloud hub | Cloud Run Pub-Node (`pub-node-test`) reached by the gateway over the overlay |
| Site Wi‑Fi (LAN) | Phone reaches the gateway at `192.168.7.103:8801` |
| Private overlay (VPN) | Phone reaches the gateway at `100.96.1.18:8801` via its VPN profile |
| Device | A device-node on the hub (camera, GPIO relay, or both) |

## Architecture

```
iPhone app ──HTTP──▶ site gateway :8801 ──Socket.IO──▶ overlay proxy :8788 ──▶ cloud hub (Cloud Run)
   (LAN first, then overlay)          (santacomputa)                             ▲
                                                                     device-nodes (Pis, webcams)
```

- The phone never speaks Socket.IO and never talks to the hub directly.
- GPIO goes only through the gateway's `controlState` emit to the **Cloud Run** hub. App Engine
  Flex is never used.
- The app tries the LAN endpoint first, then the overlay endpoint; both are probed independently
  on the Connection Check screen.

### Gateway (sidecar) routes

Existing routes (kept byte-compatible for the older Ranch Field app):
`GET /health`, `GET /devices`, `GET /devices/:id`, `GET /devices/:id/still`,
`POST /devices/:id/capture`, `POST /devices/:id/gpio`.

Additive, read-only `v1` routes used by this app:

| Route | Purpose |
|---|---|
| `GET /v1/network` | Gateway + hub health, device counts, **which interface the request arrived on** (`lan` / `overlay` / `local`), server time |
| `GET /v1/devices` | Roster including devices that went **offline** (kept by stable name), capabilities, GPIO pins, location (lat/lon) when reported |
| `GET /v1/events?limit=&device=` | Activity timeline: device online/offline, capture requested/completed/failed, GPIO set, hub connected/disconnected. In-memory ring (300) persisted to `~/.local/state/ranch-field-api/` |

Capture and GPIO writes also append events. GPIO validates 40-pin header GPIO positions and value 0/1, and now
refuses (409) when the device is offline.

## Screens

1. **Network (home)** — network name, connection health card (path, latency, hub status), counts,
   device roster with live online/offline dots, capability chips, last-seen relative time.
   Pull to refresh; auto-refresh every 15 s while foregrounded.
2. **Device detail** — latest camera still (tap to full screen), *Capture now* with progress and
   timeout, GPIO rows with state; every GPIO change goes through a confirmation sheet naming the
   device, pin and action, with a warning that it moves real hardware. Device facts + recent events.
3. **Activity** — grouped-by-day timeline with icons per event type and filters
   (All / Devices / Cameras / Controls).
4. **Map** — MapKit pins for devices that report coordinates, colored by status; list of
   devices without a location; empty state when nothing reports.
5. **Connection check** — runs probes (Wi‑Fi/VPN interface detection on the phone, LAN endpoint,
   overlay endpoint, cloud hub) and explains the verdict in plain language with next steps:
   *On site Wi‑Fi*, *Through the private overlay*, *Gateway reachable but hub down*, or
   *Can't reach your network* (with what to try).
6. **Onboarding / empty / demo** — 3-page first-run intro ending with *Connect my network* or
   *Explore the demo*; empty states for no devices / no events / no locations / offline; a demo
   network (**Juniper Mesa Ranch**) with realistic devices, events, locations, procedurally drawn
   camera stills, simulated capture latency and GPIO round-trips. Demo is clearly badged.
7. **iPhone Remote Controller** — a mode of this app. Both phones use the site gateway they already
   paired (LAN, then the private overlay, pinned site CA). The network code is that CA fingerprint.
   The gateway serves the phone routes (`relay/rooms.js`, mounted by `sidecar/server.js` on :8443).
   The spare iPhone registers, reports online/offline and battery, and plays bundled
   sounds or an Apple Music playlist in the background. Bedtime white noise starts at 8:00 PM and
   morning off stops it at 6:00 AM, on the spare phone. Shortcuts and Siri can play a sound, stop,
   set volume, play a Music playlist, start a sleep timer, and report status. The controller runs
   a listed Shortcut by name. Samples run in the app. A Shortcut made in the Shortcuts app opens
   only while that phone is in the foreground or already playing audio. The help screen says the app cannot
   read iMessages, move Home Screen icons, or inject taps. A view-only live screen is not in this build.

## Design system

- Brand: deep teal-to-indigo accent (`LojoTheme.accent`), status colors green/amber/red/gray
  with **shape + text** backups (never color alone).
- Cards: rounded 16 pt, material backgrounds, adapts to **dark and light** (follows system; an
  override lives in Settings).
- Type: SF system styles only → Dynamic Type works; monospaced digits for times/pins.
- Accessibility: every control and status dot has an `accessibilityLabel`; device rows combine into
  one element with a spoken summary; GPIO confirmation is VoiceOver-reachable.
- Haptics: light impact on refresh completion, success/warning notifications on capture/GPIO
  results, rigid impact on GPIO confirm. No haptics on passive auto-refresh.

## Network failure behavior

- Short request timeouts (probe 3 s, data 8 s, capture 20 s poll window).
- The last good roster stays on screen, marked **stale** with its age, rather than blanking.
- Offline banner explains *why* (no path vs. hub down vs. device offline) and links to the
  Connection Check.
- Actions (capture/GPIO) are disabled with an explanation when the path or the device is down.
- `LOJO_SIMULATE_OFFLINE=1` swaps endpoints to unroutable TEST-NET addresses to exercise the real
  failure path on the phone.

## QA hooks (launch environment)

Used by `scripts/phone-shot.sh` so a QA agent can reach every screen without touching the phone:

| Env var | Effect |
|---|---|
| `LOJO_DEMO=1` / `0` | Force demo mode on/off |
| `LOJO_SCREEN=home\|detail\|activity\|map\|check\|onboarding\|settings` | Open that screen |
| `LOJO_DEVICE=<name>` | Device for `detail` (default: first with a camera) |
| `LOJO_SIMULATE_OFFLINE=1` | Unreachable endpoints |
| `LOJO_CONFIRM_GPIO=<pin>` | Open the GPIO confirmation sheet on the detail screen (does not send) |

## Out of scope / constraints

Free Apple ID (7-day profile, USB only, no push/TestFlight), no Simulator on Linux, no Flex, no
direct hub access from the phone, no secrets in the repo.
