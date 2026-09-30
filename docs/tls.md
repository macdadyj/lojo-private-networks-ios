# HTTPS for the site gateway

Goal: traffic between the app and the site gateway is encrypted on site Wi‑Fi, not just over
the VPN, without breaking the existing HTTP clients (the old Ranch Field app, device tooling).

## Approach: per-site private CA, pinned by the phone

- **The gateway serves HTTPS on :8443** next to the unchanged HTTP listener on :8801. Both run
  the same Express app, so every route (legacy `/health`, `/devices…`, `/v1/*`) exists on both.
  `/v1/network` reports `scheme`, `tls {caSha256, leafSha256, leafNotAfter}` and
  `site {name}` (1.4.1+, see "Site name" below). Events record
  the scheme a capture or GPIO request arrived on. GPIO still goes only to Cloud Run Pub-Node.
- **Each site has its own CA** (P-256, 10 years) that signs a short-lived server certificate
  (P-256, 397 days, `serverAuth`, SANs for every LAN/overlay address and name). The CA key never
  leaves `~/.config/lojo-gateway-tls/` (0600, directory 0700). The server key lives in
  `~/.local/state/ranch-field-api/tls/` (0600, directory 0700). Nothing secret is in the repo or
  printed.
- **The phone pins the CA, not the leaf.** The app evaluates the server chain with
  `SecTrustSetAnchorCertificates([siteCA])` + `AnchorCertificatesOnly` and the SSL policy for
  the host it dialled. The system trust store is never consulted, so a public or rogue CA can't
  stand in, and a leaf rotation needs nothing on the phone. The CA certificate (public) is stored
  as a Keychain item, `AfterFirstUnlockThisDeviceOnly`.
- **Pairing is a QR code.** `scripts/gateway-tls.sh pair` shows
  `lojo://pair?v=1&n=<site>&lan=https://…:8443&ov=https://…:8443&ca=<SHA-256 of the CA>`.
  The owner scans it with the iPhone **Camera** app ("Open in LOJO Networks"), or pastes it in
  Settings › Security. The app then connects to those addresses. It saves the CA only if the
  gateway's chain contains a certificate with exactly that SHA-256 and the chain verifies
  against it. The code carries no secret; it's a fingerprint, so photographing it is harmless.

### Why not "the VPN is enough" (overlay only)?

The overlay already encrypts off-site traffic, but on site the phone talks to the gateway
directly over Wi‑Fi (often shared with staff or guests), and requiring the VPN on site would
make the app depend on a VPN profile even at the barn. TLS on the gateway covers both paths with
one mechanism. Inside the VPN it's simply a second layer. A public CA isn't possible for private
IPs, and a self-signed leaf pin would force re-pairing on every rotation; a per-site CA avoids
both.

## Legacy fallback (labelled)

| State | Site Wi‑Fi | Overlay | UI label |
|---|---|---|---|
| Not paired | HTTP :8801 | HTTP :8801 | **Unencrypted (legacy HTTP)** (amber) |
| Paired | HTTPS :8443 only | HTTPS :8443, then HTTP :8801 if the build offers "Legacy HTTP over VPN" and it's on | **Encrypted · pinned** (green) / **Legacy HTTP over VPN** (amber) |

- **The overlay fallback is a build setting**, the `LOJOLegacyHTTPOverVPN` Info.plist key:

  | Build | Command | Key | Settings › Security |
  |---|---|---|---|
  | Dev (debug) | `scripts/deploy-phone.sh` | `true` | "Legacy HTTP over VPN" toggle, default on |
  | Release / sold | `scripts/deploy-phone.sh --release` | `false` | No toggle; paired phones never use HTTP |

  `App/Info.plist` holds the dev value. `deploy-phone.sh` writes the key into the build copy
  only, so the repo never changes between flavours; `LOJO_LEGACY_HTTP_OVER_VPN=on|off` overrides
  it for either one. Without the key, a debug build offers the fallback and a release build
  doesn't. Unpaired phones use HTTP in both flavours (the label says so) until they're paired.
  For now Jon's phone stays on the dev build with the fallback on; switch to `--release` when
  every gateway runs 1.4+.
- Once paired, the app **never uses plain HTTP on site Wi‑Fi**, so blocking :8443 on the LAN
  can't downgrade it. The overlay fallback exists for gateways still on the pre-1.4 service; it
  is encrypted by the VPN but the gateway's identity isn't checked, and a legacy connection is
  never "sticky": every refresh tries HTTPS first.
- **ATS**: `Info.plist` has no `NSAppTransportSecurity` exceptions at all. URLSession only
  speaks HTTPS. The labelled HTTP fallback runs on Network.framework (`PlainHTTP.swift`), which
  ATS doesn't govern. This also removes the old `NSAllowsArbitraryLoads` exception.
- If the Keychain item is missing (e.g. restored onto a new phone) while the addresses are
  https, the app says "not paired" with the exact reason; it doesn't silently fall back.

## Exact failures

The pinning delegate records why it refused a certificate. Errors, the Home card and the
Connection check show that reason plus a stable code:

| Code shown | Meaning |
|---|---|
| `TLS pin mismatch` | Chain doesn't contain the pinned site CA (shows the presented root's fingerprint) |
| `TLS pairing fingerprint mismatch` | While pairing, the gateway's CA isn't the one in the code |
| `TLS errSecHostNameMismatch (-67602)` | The certificate doesn't list the address dialled: add it to `SANS` and rotate |
| `TLS errSecCertificateExpired (-67818)` | Leaf expired or not yet valid (check the phone's date): rotate |
| `TLS errSSLPeerProtocolVersion (-9836)` | The port doesn't speak TLS (usually https pointed at :8801) |
| `TLS: no pinned site CA` | https address but the phone isn't paired |

Diagnostics show, per endpoint: **Scheme** (HTTPS pinned / HTTP legacy, VPN-only or
unencrypted), **Pin** (Keychain fingerprint or "not paired"), and **TLS**: the negotiated
version, "chain verified to site CA", the leaf fingerprint the phone saw and its expiry, or the
exact failure.

## Rotation

| Command | Effect on phones |
|---|---|
| `scripts/gateway-tls.sh rotate` | New server key and certificate from the same CA, hot-reloaded (SIGHUP, no restart). None: phones pin the CA |
| `scripts/gateway-tls.sh rotate-ca` | New CA (after a CA key compromise or at CA expiry). Every phone must scan the new pairing code; until then they show `TLS pin mismatch` |
| `scripts/gateway-tls.sh status` | Fingerprints, expiry, SANs, key permissions; warns under 30 days |

Rotate the server certificate yearly (it's valid 397 days; `status` warns at 30 days left).
Adding an address or name means editing `SANS` in `~/.config/lojo-gateway-tls/site.env` and
running `rotate`.

## Site name

The name on the phone (Home title, Settings, Setup, diagnostics) comes from the gateway, not the
certificates:

1. `SITE_NAME` in `~/.config/lojo-gateway-tls/site.env` is the source.
2. `gateway-tls.sh init|rotate` writes it to `~/.local/state/ranch-field-api/tls/site.json`
   (public, 0600); the gateway loads it at start and on SIGHUP and serves it as `site.name`.
3. The pairing code carries it as `n=`.
4. The app adopts `site.name` only from a **pinned HTTPS** answer, and only while the phone's
   name is still the generic default or the name it last adopted. A name the user typed in
   Settings is kept.

To rename a site: edit `SITE_NAME`, then `rotate` (new leaf and `site.json`, same CA, phones keep
working) and `pair` (new QR). Paired phones pick up the new name on their next refresh; nobody
re-pairs. The CA subject keeps the name the CA was created with (santa's is
`CN=My Private Network site CA`). That's harmless: phones pin the CA by fingerprint and never
show its subject, and replacing the CA would force every phone to re-pair.

**What's per-site and what's generic.** `scripts/gateway-tls.sh`'s `site.env` template carries
santa's values (`SITE_NAME="LOJO VPN"`, its IPs), because it already hard-codes santa's
addresses and every new site must edit all of it before `init` anyway. The app's built-in
default name stays the generic "My Private Network": the app is sold to other customers, and a
fresh install shows that only until it's paired and adopts the site's name.
