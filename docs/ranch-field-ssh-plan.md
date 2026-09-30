# Ranch Field SSH: feasibility and design

Termius-style SSH terminals inside Ranch Field, from the iPhone to LOJO devices, over the private VPN overlay only. The existing Cameras and GPIO features stay as they are. SSH is added as a second tab.

Status: Stage 1 (this doc) and the Stage 2 MVP are on branch `cursor/ranch-field-ssh-a06d`. Port forwarding and SFTP are design-only (sections 9 and 10).

## 1. Decision summary

| Area | Choice | Why |
|---|---|---|
| SSH protocol | **apple/swift-nio-ssh 0.15.0** (Apple, Apache-2.0), pure Swift | Compiles for arm64 iOS with xtool on Linux (verified). No C and no BoringSSL build. Has a Secure Enclave P-256 initializer. Upstream-maintained. |
| Transport | swift-nio-transport-services (Network.framework) on iOS, NIOPosix on Linux | Network.framework follows VPN routes and path changes on iOS. NIOPosix lets the same SSH core run on santa for smoke tests. |
| Terminal | **SwiftTerm v1.11.2**, pinned by commit, with our own manifest | Mature xterm emulator with iOS `TerminalView`, a built-in key bar (Esc, Ctrl, Tab, arrows, F-keys) and selection with copy/paste. v1.12+ adds a Metal shader, which can't be compiled on Linux. See 2.2. |
| Keys | Secure Enclave P-256 (default), Ed25519 in the Keychain (secondary), password fallback | The Secure Enclave only does P-256. All probed servers accept `ecdsa-sha2-nistp256` user keys. |
| Host keys | Our own known_hosts: confirm on first use, hard stop on change | See section 6. |
| Where the code lives | `RanchField/` in `macdadyj/lojo-private-networks-ios`, branch off `main` | Next to the LOJO Networks app without touching its files. See section 11. |

Rejected options:
- **Citadel 0.12.1.** It compiles with xtool, but it resolves `swift-nio-ssh` to a personal fork (`Wellz26/swift-nio-ssh` 0.3.7), which is a supply-chain risk for an SSH client. It also builds BoringSSL (`_CryptoExtras`) and BigInt, and the build takes 2m44s against 1m12s. It's worth another look for SFTP later if its fork situation changes.
- **libssh2 wrappers** (NMSSH, Shout, etc.). These need libssh2 plus OpenSSL or mbedTLS cross-compiled for arm64 iOS on Linux as SwiftPM C targets or xcframeworks. Xcode-built xcframeworks can't be produced here. There's also no Secure Enclave signing hook without patching libssh2's sign callback. Highest risk.

## 2. Feasibility evidence (santacomputa, 2026-09-30)

Toolchain: Swift 6.3.3, Darwin SDK from Xcode 26.6 (slim), xtool 1.20.1, `xtool dev build`.

### 2.1 Build matrix

| Package set | Result |
|---|---|
| swift-nio-ssh 0.15.0 + swift-nio 2.103 + swift-nio-transport-services 1.28 + swift-crypto 4.5.2 (with `SecureEnclave.P256`, `NIOSSHPrivateKey(secureEnclaveP256Key:)`) | Compiles and links (the probe has no `@main`, so only the final link fails, as expected) |
| SwiftTerm 1.20.0 (upstream manifest) | Fails: `cannot find type 'TerminalView'` |
| SwiftTerm 1.11.2 at commit `b1262db5`, with the manifest replaced by `RanchField/vendor/SwiftTerm.Package.swift` | Compiles, `TerminalView` usable |
| Citadel 0.12.1 | Compiles, 782 compile steps including BoringSSL; depends on a forked swift-nio-ssh |

### 2.2 Why SwiftTerm needs our own manifest

SwiftTerm's `Package.swift` says `#if os(Linux) exclude: ["Apple","Mac","iOS"]`. A manifest is evaluated on the build host, so on santa it drops every iOS source even though the target is the iPhone. From v1.12 it also ships `Shaders.metal`, and Metal can't be compiled on Linux. `RanchField/scripts/sync-app.sh` clones SwiftTerm at the pinned commit into `App/Vendor/SwiftTerm` (gitignored) and swaps in a single-target manifest. No third-party source is committed.

### 2.3 What the overlay servers speak (read-only probe, `nc -z` and `ssh -vv` with `PreferredAuthentications=none`)

Every sshd that answered offers `curve25519-sha256`, `ecdh-sha2-nistp256`, `aes128-gcm@openssh.com` and `aes256-gcm@openssh.com`, plus `ssh-ed25519` and `ecdsa-sha2-nistp256` host keys. That is exactly the set swift-nio-ssh implements. It doesn't do RSA, chacha20-poly1305 or CTR+HMAC, and none of those are needed. AES-GCM isn't affected by the Terrapin prefix-truncation attack.

## 3. Device inventory and what each device would need

The probe was run from santa (overlay address `100.96.1.18`) on 2026-09-30. **No device config was changed.**

| Device (Connexa name) | Overlay path | sshd now | Auth offered | Needs, and all of it waits for Jon's OK |
|---|---|---|---|---|
| **santacomputa** (gateway) | `100.96.1.18` | **None.** `openssh-server` isn't installed. | — | `sudo apt install openssh-server`. A drop-in `/etc/ssh/sshd_config.d/10-lojo.conf` with `ListenAddress 100.96.1.18`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `AllowUsers jon`. On Ubuntu 24.04 sshd is socket-activated, so `ssh.socket` also needs `FreeBind=yes`; otherwise it can't bind the overlay address before `tun0` is up. Then add the phone's public key to `~jon/.ssh/authorized_keys`, and keep port 22 un-forwarded on the home router. |
| **labMachine** | `100.96.1.90` | OpenSSH 9.6p1 | publickey, password | Add the phone key to `jon`'s `~/.ssh/authorized_keys`. Recommended: `PasswordAuthentication no`, and `ListenAddress` on the overlay or a firewall rule if it has a public interface. |
| **visiondeploy** / LabWebcam Pi | `100.96.1.115` (its LAN `192.168.7.124` is filtered from santa) | OpenSSH 7.9p1 (Raspbian 10) | publickey, password, keyboard-interactive | Add the phone key to `pi`'s `~/.ssh/authorized_keys`. Recommended: turn off password and keyboard-interactive. Buster is EOL, but its algorithm set is compatible. |
| Pi at `192.168.7.42` | Through the publican/speakeasy route `192.168.7.0/24` | OpenSSH 7.9p1 | publickey, password | Same as the vision Pi. Name it in the directory once Jon says which node it is. |
| **gcpegress** (GCE) | `10.128.0.3` through the montanoGCPegress route | OpenSSH 8.2p1 | publickey only | The key has to go in through instance or project metadata `ssh-keys` (a GCP change). **Separately: GCP rule `default-allow-ssh` allows tcp:22 from `0.0.0.0/0`, and the VM has an external IP, so its sshd is reachable from the public internet today.** Recommend limiting that rule to `35.235.240.0/20` (IAP) or deleting it. RDP (`default-allow-rdp`, 3389) is open the same way. Not changed. |
| speakeasy connector | `100.96.1.54` | Closed | — | None. It's a connector address, not a host. |
| montanogcpegress connector | `100.96.1.66` | Closed | — | None. Connector address. |
| Offline in Connexa (cactusflats×3, raspberrypi41, ccTestBed, ccredeploy, no8deploy, byzantinemachine, phones and laptops) | — | Unknown | — | Probe again when they are online. |

## 4. Architecture

```
RanchField/App  (xtool app, bundle com.lojo.RanchField)
├── Sources/RanchField      SwiftUI app: Cameras tab (unchanged) + Terminal tab
│     Terminal/*            hosts, groups, sessions, tabs, TerminalView bridge, themes
│     Security/*            KeyStore (Keychain, Secure Enclave), KnownHostsStore, OverlayPolicy
└── Sources/RanchSSH        platform-neutral SSH core (no UIKit, no Keychain)
      SSHConnection         TCP + NIOSSH handshake, auth, keep-alive ping, exec
      ShellChannel          PTY + shell child channel, window-change, exit status
      KnownHosts            OpenSSH known_hosts parse/format, SHA256 fingerprints
      OpenSSHKeyImport      unencrypted openssh-key-v1 Ed25519 / P-256 import

RanchField/Tools/ssh-smoke  Linux CLI that links the same RanchSSH sources and runs
                            against a real sshd on santa (CI-free smoke test)
RanchField/gateway/ranch-ssh-directory
                            santa-side read-only directory: Connexa devices + routes + :22 probe → JSON
```

Data flow for a session:

```
TerminalView (SwiftTerm) ⇄ TerminalSession (@MainActor) ⇄ ShellChannel ⇄ NIOSSHHandler ⇄ NWConnection (utun, overlay)
```

## 5. Features (MVP marked ★)

**Hosts and groups ★.** A saved host is a label, address, port, user, group, key choice and an optional saved password (Keychain). Hosts are stored as JSON in Application Support. That file holds no secrets. The list is grouped by `group` (Gateway, Pis, Lab, Cloud, …) and searchable.

**Device list from the gateway ★.** The "Overlay devices" section is filled by running `~/.local/bin/ranch-ssh-directory --json` on the gateway host **over the already-authenticated SSH connection** (an exec channel). The script is read-only: Connexa `/api/v1/devices` and `/api/v1/networks`, then a 1.5 s parallel TCP probe of port 22. It returns names, overlay addresses, online state and whether SSH is open. The result is cached on the phone. Two reasons it isn't an HTTP route on `ranch-field-api`: (a) the sidecar serves plain HTTP on the LAN, and an unauthenticated overlay address map shouldn't be served there; (b) the sidecar belongs to the LOJO Networks PR. If Jon prefers a `/v1/ssh-targets` route behind the pinned HTTPS pairing, the JSON shape is the same.

**Sessions and tabs ★.** Any number of concurrent sessions, each with its own `TerminalView` that survives tab switches. There's a tab strip, "+" opens the host picker, and closing a tab closes its SSH channel.

**Terminal ★.** SwiftTerm `TerminalView` in xterm-256color with PTY size tracking. The key bar has Esc, Ctrl (sticky), Tab, arrows, `~ | / -`, F1–F10 and a keyboard toggle. Long-press selects; Copy and Paste are in the edit menu and in the session toolbar. Font size runs 9–24 pt (pinch or Settings). Themes: LOJO Dark, Solarized Dark, Solarized Light, Classic Green. OSC 52 clipboard writes from the host need a confirmation.

**Keep-alive and reconnect ★.** TCP keepalive (idle 30 s, interval 10 s, count 3) plus an SSH-level ping every 30 s. The ping is a `cancel-tcpip-forward` global request with want-reply, which OpenSSH must answer. Two missed pings drop the connection. An unexpected drop reconnects automatically (1, 2, 5, 10, 30 s backoff) while the app is active and the VPN is up, and also when the network path or scene phase comes back. A clean shell exit shows "Session ended (exit N)" with a Restart button and no auto-reconnect. A reconnect starts a fresh shell (this isn't mosh); tmux on the host keeps work alive. iOS suspends sockets roughly 30 s after the app is backgrounded, so the app asks for a background task for the grace period and then lets the reconnect logic take over.

## 6. Keys, passwords, known_hosts ★

- **Generate (default):** a `SecureEnclave.P256.Signing.PrivateKey` with access control `.privateKeyUsage`, plus an optional "Require Face ID for each use" (`.userPresence`; this prompts on every reconnect, so it's off by default). Only the SE-wrapped `dataRepresentation` blob is stored, as a Keychain generic password with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. That blob can't be used off this phone's Secure Enclave, and it's excluded from backups.
- **Ed25519 (secondary):** generated with CryptoKit, and the raw key goes into the Keychain with the same accessibility. It's for hosts that refuse ECDSA; none of the probed ones do.
- **Import:** paste an unencrypted OpenSSH `openssh-key-v1` Ed25519 or ECDSA P-256 key, or a PEM or PKCS#8 P-256 key. It goes straight into the Keychain and is never written to a file. Encrypted OpenSSH keys (bcrypt-pbkdf) are a later stage. Generating on the phone is preferred, because an imported key has existed in plaintext somewhere else.
- **Public key out:** shown in the app, shared with the share sheet, and written as `Documents/<label>.pub`. The public key is not secret, and Files and USB can read it.
- **Passwords:** prompted when a server allows password and key auth didn't work. "Save in Keychain" is off by default.
- **Nothing secret in logs:** logs carry only host labels, key labels and fingerprints, never key material or passwords.
- **known_hosts:** stored in OpenSSH format in Application Support, as `[host]:port type base64`. On first connection the app shows the `SHA256:` fingerprint and key type and requires "Trust and connect". If a host key doesn't match, **the connection is refused** and a red screen shows "HOST KEY CHANGED", the old and new fingerprints and "possible man-in-the-middle". The session screen has no "connect anyway". The only way forward is Host → Known host key → "Forget saved key" (which needs a confirmation), then the next connect is treated as first use.

## 7. Overlay-only policy ★

1. **Destination:** an IPv4 literal in `100.64.0.0/10` (Connexa overlay) or in a LOJO-routed subnet (`192.168.7.0/24`, `10.128.0.0/20`, `10.77–10.80.0.0/24`, `10.90.0.0/24`, refreshed from the directory), or a `*.lan` name that resolves into those ranges. Public addresses and public DNS names are refused before any packet is sent. After connecting, the remote address is checked again.
2. **Phone path:** a VPN tunnel interface (`utun*`) with an address in `100.64.0.0/10` must be up. Otherwise the app says "Turn on LOJO VPN (OpenVPN Connect)" and won't connect, even though a `192.168.7.x` host could be reached over home Wi‑Fi.
3. **No listeners** on the phone in the MVP. Later port forwards bind to `127.0.0.1` only.
4. Nothing on any server is exposed by this app. Server-side recommendations are in section 3.

## 8. Test plan

- **santa, same code:** `RanchField/Tools/ssh-smoke` builds the `RanchSSH` sources for Linux and runs PTY/shell, exec, ping, known_hosts first-use and mismatch, and wrong-key rejection against a real OpenSSH server.
- **santa test server:** santa has no system sshd, so `RanchField/scripts/santa-test-sshd.sh` runs a temporary **userland** OpenSSH 9.6 server extracted from the matching Ubuntu package. It uses no sudo and no system config, binds only to `100.96.1.18:2222`, is key-only, allows only `jon`, and keeps its own `authorized_keys` under `~/.cache/ranch-ssh-test/`. It's stopped after testing.
- **Phone:** build and USB-install with `RanchField/scripts/deploy-phone.sh`, then screenshots with `RanchField/scripts/phone-shot.sh`. DEBUG builds read QA launch variables (`RF_TAB`, `RF_SCREEN`, `RF_CONNECT`, `RF_RUN`, `RF_REDACT`, `RF_QA_TRUST_FP`) so screens can be driven over USB. `RF_QA_TRUST_FP` only auto-trusts a host key whose fingerprint equals the one passed in. Release builds ignore all of them.

## 9. Later: port forwarding (design only)

- **Local forward (-L):** `NIOTSListenerBootstrap` on `127.0.0.1:<port>` on the phone. Each accepted socket opens a `directTCPIP` child channel (`SSHChannelType.DirectTCPIP(targetHost:targetPort:originatorAddress:)`), glued with a byte-pump handler pair. Uses: reach a Pi's web UI at `http://127.0.0.1:8080` in Safari while the app is foregrounded. There's a per-host list of saved forwards with an on/off switch, and a toolbar badge while one is active.
- **Constraints:** iOS suspends the listener in the background, so forwards live only while Ranch Field is foregrounded (or in Split View on iPad). The listener is loopback only and never on `0.0.0.0`. Forward targets are limited by the same overlay policy as hosts.
- **Remote forward (-R) and dynamic SOCKS (-D):** not planned. -R exposes a port on the server; SOCKS is a possible later add.
- **Server side:** needs `AllowTcpForwarding local` (OpenSSH default `yes`). santa's test server has it off.

## 10. Later: SFTP browsing (design only)

- A `subsystem sftp` child channel (`SSHChannelRequestEvent.SubsystemRequest`) with an SFTP v3 client in `RanchSSH` (INIT/VERSION, OPENDIR/READDIR, STAT, OPEN/READ/WRITE/CLOSE, REMOVE, RENAME, MKDIR) of roughly 600 lines. Or adopt Citadel's SFTP if it moves back to upstream swift-nio-ssh.
- UI: a directory browser per host that reuses the authenticated connection, Quick Look preview, "Save to Files", upload from the Files picker and Photos, and a transfer queue with progress. Read-only mode is the default, with writes behind a per-host toggle.
- **Server side:** needs `Subsystem sftp` (Debian and Raspbian ship `openssh-sftp-server`). santa's system sshd would need the `openssh-sftp-server` package, which comes with `openssh-server`.

## 11. Repo layout and deploy

```
RanchField/
  App/                      xtool project (Package.swift, xtool.yml, Info.plist, Sources/)
  vendor/SwiftTerm.Package.swift  manifest used for the pinned SwiftTerm checkout
  scripts/sync-app.sh       repo → ~/.local/share/ios-dev/apps/RanchFieldRepo (ext4), fetches pinned SwiftTerm
  scripts/deploy-phone.sh   build, sign (free Apple ID), USB install, launch; --build = compile only
  scripts/phone-shot.sh     launch with QA env and take a screenshot
  scripts/santa-test-sshd.sh start|stop|status   temporary userland test server
  gateway/ranch-ssh-directory                    read-only overlay directory (installed to ~/.local/bin)
  Tools/ssh-smoke/          Linux smoke CLI over the RanchSSH sources
docs/ranch-field-ssh-plan.md
docs/screenshots/ranch-field-*.png
```

The original, untracked build dir `~/.local/share/ios-dev/apps/RanchField` is left untouched as a fallback. The repo builds from its own ext4 mirror, and both use bundle `com.lojo.RanchField`, so installing from either replaces the same app on the phone. The LOJO Networks `scripts/deploy-phone.sh` (PR #1) is unaffected: it lives at the repo root and on a different branch, and this work only adds `RanchField/` and new `docs/` files. Free profile: re-run either deploy script before about 6 Oct 2026.

## 12. Decisions for Jon

1. Install `openssh-server` on santa, bound to the overlay only (section 3)? Until then the MVP test uses the temporary userland server on `100.96.1.18:2222`.
2. Turn on OpenVPN Connect on the phone for the live SSH test. The app won't SSH without the VPN tunnel.
3. Which devices get the phone's public key (labMachine `jon`, vision Pi `pi`, 192.168.7.42 `pi`, gcpegress metadata)?
4. GCP `default-allow-ssh` and `default-allow-rdp` are open to `0.0.0.0/0`. Restrict them?
5. Should Face ID be required for each use of the Secure Enclave key? It's off by default because it would prompt on every auto-reconnect.
6. Should the directory come over SSH exec (current design) or a paired-HTTPS `/v1/ssh-targets` route on the LOJO gateway?
