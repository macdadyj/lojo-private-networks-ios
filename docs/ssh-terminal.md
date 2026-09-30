# LOJO Networks SSH terminal: feasibility and design

Termius-style SSH terminals inside the LOJO Networks app, from the iPhone to the owner's LOJO devices, over the private VPN overlay only. SSH is a new **Terminal** tab. The Network, Activity, Map and Connection tabs are unchanged.

Stages: (1) this doc; (2) MVP, a key-based shell on the iPhone 11; (3) saved hosts from the gateway device list, Keychain and Secure Enclave keys, host-key checks, tabs, key toolbar, reconnect. Port forwarding and SFTP are design-only (sections 9 and 10).

## 1. Decision summary

| Area | Choice | Why |
|---|---|---|
| SSH protocol | **apple/swift-nio-ssh 0.15.0** (Apple, Apache-2.0), pure Swift | Compiles for arm64 iOS with xtool on Linux (verified). No C and no BoringSSL build. Has a Secure Enclave P-256 initializer. Upstream-maintained. |
| Transport | swift-nio-transport-services (Network.framework) on iOS, NIOPosix on Linux | Network.framework follows VPN routes and path changes on iOS. NIOPosix lets the same SSH core run on santa for smoke tests. |
| Terminal | **SwiftTerm v1.11.2**, pinned by commit, with our own manifest | Mature xterm emulator with iOS `TerminalView`, a built-in key bar (Esc, Ctrl, Tab, arrows, F-keys) and selection with copy/paste. v1.12+ adds a Metal shader, which can't be compiled on Linux. See 2.2. |
| Keys | Secure Enclave P-256 (default), Ed25519 in the Keychain (secondary), password fallback | The Secure Enclave only does P-256. All probed servers accept `ecdsa-sha2-nistp256` user keys. |
| Host keys | Our own known_hosts: confirm on first use, hard stop on change | See section 6. |
| Where the code lives | `App/Sources/LojoSSH` (SSH core target) and `App/Sources/LojoNetworks/Terminal` (UI) | It's the same xtool app and bundle (`com.lojo.PrivateNetworks`), so `scripts/deploy-phone.sh` is unchanged. |

Rejected options:
- **Citadel 0.12.1.** It compiles with xtool, but it resolves `swift-nio-ssh` to a personal fork (`Wellz26/swift-nio-ssh` 0.3.7), which is a supply-chain risk for an SSH client. It also builds BoringSSL (`_CryptoExtras`) and BigInt, and the build takes 2m44s against 1m12s. It's worth another look for SFTP later if its fork situation changes.
- **libssh2 wrappers** (NMSSH, Shout, etc.). These need libssh2 plus OpenSSL or mbedTLS cross-compiled for arm64 iOS on Linux as SwiftPM C targets or xcframeworks. Xcode-built xcframeworks can't be produced here. There's also no Secure Enclave signing hook without patching libssh2's sign callback. Highest risk.

## 2. Feasibility evidence (santacomputa, 2026-09-30)

Toolchain: Swift 6.3.3, Darwin SDK from Xcode 26.6 (slim), xtool 1.20.1, `xtool dev build`.

### 2.1 Build matrix

| Package set | Result |
|---|---|
| swift-nio-ssh 0.15.0 + swift-nio 2.103 + swift-nio-transport-services 1.28 + swift-crypto 4.5.2 (with `SecureEnclave.P256`, `NIOSSHPrivateKey(secureEnclaveP256Key:)`) | Compiles for arm64-apple-ios |
| SwiftTerm 1.20.0 (upstream manifest) | Fails: `cannot find type 'TerminalView'` |
| SwiftTerm 1.11.2 at commit `b1262db5`, with the manifest replaced by `vendor/SwiftTerm.Package.swift` | Compiles, `TerminalView` usable |
| Citadel 0.12.1 | Compiles, 782 compile steps including BoringSSL; depends on a forked swift-nio-ssh |
| The same `LojoSSH` sources for x86_64 Linux (`tools/ssh-smoke`) | Compiles and passes the smoke checks against OpenSSH 9.6 (section 8) |

### 2.2 Why SwiftTerm needs our own manifest

SwiftTerm's `Package.swift` says `#if os(Linux) exclude: ["Apple","Mac","iOS"]`. A manifest is evaluated on the build host, so on santa it drops every iOS source even though the target is the iPhone. From v1.12 it also ships `Shaders.metal`, and Metal can't be compiled on Linux. `scripts/sync-app.sh` clones SwiftTerm at the pinned commit into the build copy's `Vendor/SwiftTerm` (gitignored) and swaps in `vendor/SwiftTerm.Package.swift`, a single-target manifest. No third-party source is committed.

### 2.3 What the overlay servers speak (read-only probe, `nc -z` and `ssh -vv` with `PreferredAuthentications=none`)

Every sshd that answered offers `curve25519-sha256`, `ecdh-sha2-nistp256`, `aes128-gcm@openssh.com` and `aes256-gcm@openssh.com`, plus `ssh-ed25519` and `ecdsa-sha2-nistp256` host keys. That is exactly the set swift-nio-ssh implements. It doesn't do RSA, chacha20-poly1305 or CTR+HMAC, and none of those are needed. AES-GCM isn't affected by the Terrapin prefix-truncation attack.

## 3. Device inventory and what each device would need

The probe was run from santa (overlay address `100.96.1.18`) on the morning of 2026-09-30. **No device config was changed.** By about 10:00 the vision Pi was OFFLINE in Connexa and neither it nor the `192.168.7.42` Pi answered on port 22 from santa. The directory reports that live, so they show as offline or "no SSH" until they're back.

| Device (Connexa name) | Overlay path | sshd now | Auth offered | Needs, and all of it waits for Jon's OK |
|---|---|---|---|---|
| **santacomputa** (gateway) | `100.96.1.18` | **None.** `openssh-server` isn't installed. | — | `sudo apt install openssh-server`. A drop-in `/etc/ssh/sshd_config.d/10-lojo.conf` with `ListenAddress 100.96.1.18`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `AllowUsers jon`. On Ubuntu 24.04 sshd is socket-activated, so `ssh.socket` also needs `FreeBind=yes`; otherwise it can't bind the overlay address before `tun0` is up. Then add the phone's public key to `~jon/.ssh/authorized_keys`, and keep port 22 un-forwarded on the home router. |
| **labMachine** | `100.96.1.90` | OpenSSH 9.6p1 | publickey, password | Add the phone key to `jon`'s `~/.ssh/authorized_keys`. Recommended: `PasswordAuthentication no`, and `ListenAddress` on the overlay or a firewall rule if it has a public interface. |
| **visiondeploy** / LabWebcam Pi | `100.96.1.115` (its LAN `192.168.7.124` is filtered from santa) | OpenSSH 7.9p1 (Raspbian 10) | publickey, password, keyboard-interactive | Add the phone key to `pi`'s `~/.ssh/authorized_keys`. Recommended: turn off password and keyboard-interactive. Buster is EOL, but its algorithm set is compatible. |
| Pi at `192.168.7.42` | Through the publican/speakeasy route `192.168.7.0/24` | OpenSSH 7.9p1 | publickey, password | Same as the vision Pi. Listed in the gateway directory as "Routed Pi (shop LAN)" until Jon says which node it is. |
| **gcpegress** (GCE) | `10.128.0.3` through the montanoGCPegress route | OpenSSH 8.2p1 | publickey only | The key has to go in through instance or project metadata `ssh-keys` (a GCP change). **Separately: GCP rule `default-allow-ssh` allows tcp:22 from `0.0.0.0/0`, and the VM has an external IP, so its sshd is reachable from the public internet today.** Recommend limiting that rule to `35.235.240.0/20` (IAP) or deleting it. RDP (`default-allow-rdp`, 3389) is open the same way. Not changed. |
| speakeasy connector | `100.96.1.54` | Closed | — | None. It's a connector address, not a host. |
| montanogcpegress connector | `100.96.1.66` | Closed | — | None. Connector address. |
| Offline in Connexa (cactusflats×3, raspberrypi41, ccTestBed, ccredeploy, no8deploy, byzantinemachine, phones and laptops) | — | Unknown | — | Probe again when they are online. |

## 4. Architecture

```
App/  (xtool app, bundle com.lojo.PrivateNetworks)
├── Sources/LojoSSH                 platform-neutral SSH core (no UIKit, no Keychain)
│     SSHConnection.swift           TCP + NIOSSH handshake, auth, keep-alive ping, exec, shell channel
│     KnownHosts.swift              OpenSSH known_hosts parse/format, SHA256 fingerprints, verdicts
│     OverlayPolicy.swift           allowed destination ranges, *.lan resolution
│     KeyImport.swift               unencrypted openssh-key-v1 Ed25519 / P-256 and PEM P-256 import
└── Sources/LojoNetworks/Terminal   Terminal tab
      TerminalModels / HostStore    saved hosts and groups, gateway directory cache, known_hosts file
      SSHKeyStore                   Keychain + Secure Enclave keys, saved passwords
      TerminalSession               one SSH session per tab: SwiftTerm view, keep-alive, reconnect, prompts
      TerminalCenter                open sessions, credentials, directory refresh, QA launch hooks
      TerminalHomeView              hosts list, sessions, gateway devices, VPN gate
      SessionScreen                 tab strip, session bar, host-key/password/changed-key screens, SwiftTerm bridge
      KeysView / HostEditorView     keys (generate, import, share), host editor, terminal settings
tools/ssh-smoke                     Linux CLI linking the same LojoSSH sources (symlink) for smoke tests
gateway/lojo-ssh-directory          santa-side read-only directory: Connexa devices + routes + :22 probe → JSON
scripts/test-sshd.sh                start|stop|status for the temporary userland test sshd on santa
```

Data flow for a session:

```
SwiftTerm TerminalView ⇄ TerminalSession (@MainActor) ⇄ ShellChannel ⇄ NIOSSHHandler ⇄ NWConnection (utun, overlay)
```

## 5. Features (MVP marked ★)

**Hosts and groups.** A saved host is a label, address, port, user, group, key choice and an optional saved password (Keychain). Hosts are stored as JSON in Application Support. That file holds no secrets. The list is grouped by `group` (Gateway, Pis, Lab, Cloud, …). The gateway host is seeded from the app's configured overlay gateway (`100.96.1.18`, user `jon`).

**Device list from the gateway.** "Gateway devices" is filled by running `~/.local/bin/lojo-ssh-directory --json` on the gateway **over the authenticated SSH connection** (an exec channel). The script is read-only: Connexa `/api/v1/devices` and `/api/v1/networks`, an optional local `~/.config/lojo-ssh-directory/extra.json` for routed hosts (Pis on `192.168.7.x`, GCE), then a 1.5 s parallel TCP probe of port 22. It returns names, overlay addresses, online state and whether SSH is open. The phone caches the result, and one tap saves an entry as a host. Two reasons it isn't a `/v1` route on the sidecar: (a) the sidecar also answers on LAN HTTP :8801 without client auth, and an overlay address map shouldn't be handed to anyone on the Wi‑Fi; (b) there's no sidecar redeploy while other work uses it. If Jon prefers `/v1/ssh-targets` behind the pinned HTTPS pairing, the JSON shape is ready for it.

**Sessions and tabs ★.** Any number of concurrent sessions, each with its own `TerminalView` that survives tab switches. There's a tab strip, "+" opens the host picker, and closing a tab closes its SSH channel.

**Terminal ★.** SwiftTerm `TerminalView` in xterm-256color with PTY size tracking. The key bar has Esc, Ctrl (sticky), Tab, arrows, `~ | / -`, F1–F10 and a keyboard toggle. Long-press selects; Copy and Paste are in the edit menu and in the session toolbar. Font size runs 9–24 pt. Themes: LOJO Dark, Solarized Dark, Solarized Light, Classic Green.

**Keep-alive and reconnect.** TCP keepalive (idle 30 s, interval 10 s, count 3) plus an SSH-level ping every 30 s. The ping is a `cancel-tcpip-forward` global request with want-reply, which OpenSSH must answer. Two missed pings drop the connection. An unexpected drop reconnects automatically (1, 2, 5, 10, 30 s backoff) while the app is active and the VPN is up, and also when the scene becomes active again. A clean shell exit shows "Session ended (exit N)" with a Reconnect button and no auto-reconnect. A reconnect starts a fresh shell (this isn't mosh); tmux on the host keeps work alive. iOS suspends sockets roughly 30 s after the app is backgrounded.

## 6. Keys, passwords, known_hosts

- **Generate (default) ★:** a `SecureEnclave.P256.Signing.PrivateKey` with access control `.privateKeyUsage`. Only the SE-wrapped `dataRepresentation` blob is stored, as a Keychain generic password with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. That blob can't be used off this phone's Secure Enclave, and it's excluded from backups. "Require Face ID for each use" (`.userPresence`) is a later option: it would prompt on every reconnect.
- **Ed25519 (secondary):** generated with CryptoKit, and the raw key goes into the Keychain with the same accessibility. It's for hosts that refuse ECDSA; none of the probed ones do.
- **Import:** paste an unencrypted OpenSSH `openssh-key-v1` Ed25519 or ECDSA P-256 key, or a PEM or PKCS#8 P-256 key. It goes straight into the Keychain and is never written to a file. Encrypted OpenSSH keys (bcrypt-pbkdf) are a later stage. Generating on the phone is preferred, because an imported key has existed in plaintext somewhere else.
- **Public key out:** shown in the app, copied or shared with the share sheet. The public key is not secret.
- **Passwords:** prompted when a server allows password and key auth didn't work. "Save in Keychain" is off by default.
- **Nothing secret in logs:** logs carry only host labels, key labels and fingerprints, never key material or passwords.
- **known_hosts ★:** stored in OpenSSH format in Application Support, as `[host]:port type base64`. On first connection the app shows the `SHA256:` fingerprint and key type and requires "Trust and connect". If a host key doesn't match, **the connection is refused** and a red screen shows "HOST KEY CHANGED", the old and new fingerprints and "possible man-in-the-middle". The session screen has no "connect anyway". The only way forward is the host's editor → "Forget saved host key" (which needs a confirmation), then the next connect is treated as first use.

## 7. Overlay-only policy ★

1. **Destination:** an IPv4 literal in `100.64.0.0/10` (Connexa overlay) or in a LOJO-routed subnet (`192.168.7.0/24`, `10.128.0.0/20`, `10.77–10.80.0.0/24`, `10.90.0.0/24`), or a `*.lan` name that resolves into those ranges. Public addresses and public DNS names are refused before any packet is sent.
2. **Phone path:** a VPN tunnel interface (`utun*`) with an address in `100.64.0.0/10` must be up (it reuses `PhoneInterfaces`). Otherwise the app says "Turn on LOJO VPN (OpenVPN Connect)" and won't connect, even though a `192.168.7.x` host could be reached over home Wi‑Fi.
3. **No listeners** on the phone. Later port forwards bind to `127.0.0.1` only.
4. Nothing on any server is exposed by this app. Server-side recommendations are in section 3.

## 8. Test plan

- **santa, same code:** `tools/ssh-smoke` builds the `LojoSSH` sources for Linux and checks overlay policy, key import (Ed25519 and P-256), first-use trust, exec, pings, PTY shell with window-change and exit status, reconnect from known_hosts, P-256 user auth, refusal of a changed host key, rejection of an unknown user key, and a closed port. Run it with `scripts/test-sshd.sh smoke`.
- **santa test server:** santa has no system sshd, so `scripts/test-sshd.sh start` runs a temporary **userland** OpenSSH 9.6 server extracted from the matching Ubuntu package. It uses no sudo and no system config, binds only to `100.96.1.18:2222`, is key-only, allows only `jon`, and keeps its own `authorized_keys` under `~/.cache/lojo-ssh-test/`. Stop it with `scripts/test-sshd.sh stop`.
- **Phone:** `LOJO_BUILD_DIR=~/.local/share/ios-dev/apps/LojoNetworksSSH scripts/deploy-phone.sh` (a separate ext4 build dir, so other work in the default build dir is left alone), then `scripts/phone-shot.sh`. QA launch variables: `LOJO_SCREEN=terminal`, `LOJO_SSH_SCREEN=hosts|keys|settings|edit` (edit opens the gateway host), `LOJO_SSH_CONNECT=<host label>`, `LOJO_SSH_REDACT=1` (mask addresses in screenshots), `LOJO_SSH_REFRESH=1` (pull the device list at launch). DEBUG builds only: `LOJO_SSH_RUN=<command>` types a command once the shell is up; `LOJO_SSH_TRUST_FP=SHA256:…` auto-trusts a first-use host key **only if** its fingerprint equals the one given; `LOJO_SSH_GATEWAY_PORT` points the seeded gateway host at the test server; `LOJO_SSH_ENSURE_KEY=1` creates a Secure Enclave key if none exists. DEBUG builds also write the public keys (only) to `Documents/lojo-ssh-public-keys.txt`, so the USB-attached Mac or Linux box can pull them with `pymobiledevice3 apps pull` and add them to a test `authorized_keys`.

### 8.1 Verified on the iPhone 11 (2026-09-30)

Debug build installed with `deploy-phone.sh`, driven with the QA variables above; screenshots are in `docs/screenshots/ssh-*.png` (index in the README).

- **MVP:** a live shell from the phone to the santa test server (`100.96.1.18:2222`) over the LOJO overlay (phone tunnel `utun`, overlay address), authenticated with a **Secure Enclave P-256 key generated on the phone**. The server log shows `Accepted publickey for jon … ECDSA SHA256:Qb+F7…` (the phone's key). PTY size tracks the view (51×26 with the keyboard up), `TERM=xterm-256color`, ANSI colours render, and the Esc/Ctrl/Tab/arrow key bar works.
- **First-use host key:** the prompt shows type and full fingerprint, matching `scripts/test-sshd.sh fingerprint`.
- **Changed host key:** with a different key planted in the phone's `known_hosts` (pushed over USB, then restored), the phone refuses and shows the red screen; the server log shows `Connection closed … [preauth]`, so no login happened.
- **Gateway devices:** pulled over SSH exec of `lojo-ssh-directory` once the gateway key was trusted, SSH-open devices first, the phone's own profile marked "This iPhone".
- **Tabs and reconnect:** two concurrent sessions; killing their server-side processes shows "connection lost", then both reconnect about a second later with a "reconnected" banner.
- **Clean exit:** `exit 0` ends the session with "Session ended (exit 0)" and no reconnect.
- **VPN gate:** with the tunnel down, hosts are disabled and a forced connect is refused before any packet with "Turn on LOJO VPN".
- **Not verified on the phone:** password auth (the test server is key-only, so the password prompt path is untested), OSC 52 clipboard prompt, a two-missed-ping drop (needs a network black hole rather than a clean close), iOS background/foreground resume, and import of a pasted private key (covered by the Linux smoke test's parser checks).

## 9. Later: port forwarding (design only)

- **Local forward (-L):** `NIOTSListenerBootstrap` on `127.0.0.1:<port>` on the phone. Each accepted socket opens a `directTCPIP` child channel (`SSHChannelType.DirectTCPIP(targetHost:targetPort:originatorAddress:)`), glued with a byte-pump handler pair. Uses: reach a Pi's web UI at `http://127.0.0.1:8080` in Safari while the app is foregrounded. There's a per-host list of saved forwards with an on/off switch, and a toolbar badge while one is active.
- **Constraints:** iOS suspends the listener in the background, so forwards live only while LOJO Networks is foregrounded. The listener is loopback only and never on `0.0.0.0`. Forward targets are limited by the same overlay policy as hosts.
- **Remote forward (-R) and dynamic SOCKS (-D):** not planned. -R exposes a port on the server; SOCKS is a possible later add.
- **Server side:** needs `AllowTcpForwarding local` (OpenSSH default `yes`). santa's test server has it off.

## 10. Later: SFTP browsing (design only)

- A `subsystem sftp` child channel (`SSHChannelRequestEvent.SubsystemRequest`) with an SFTP v3 client in `LojoSSH` (INIT/VERSION, OPENDIR/READDIR, STAT, OPEN/READ/WRITE/CLOSE, REMOVE, RENAME, MKDIR) of roughly 600 lines. Or adopt Citadel's SFTP if it moves back to upstream swift-nio-ssh.
- UI: a directory browser per host that reuses the authenticated connection, Quick Look preview, "Save to Files", upload from the Files picker and Photos, and a transfer queue with progress. Read-only mode is the default, with writes behind a per-host toggle.
- **Server side:** needs `Subsystem sftp` (Debian and Raspbian ship `openssh-sftp-server`, which comes with `openssh-server`).

## 11. Deploy notes

- The bundle is the same (`XTL-HG9HAYXW44.com.lojo.PrivateNetworks`), so `scripts/deploy-phone.sh` works as before. `scripts/sync-app.sh` now also fetches the pinned SwiftTerm into the build copy.
- The free provisioning profile expires around 6 Oct 2026. Re-run `scripts/deploy-phone.sh` to re-sign.
- Twice on 2026-09-30, `xtool dev run` stalled after "Installing 100%" while the app was open on the phone, which left it half-installed (launch fails with CoreDevice error 10002). Running `deploy-phone.sh` again installed it normally in about 20 s. Wrap unattended deploys in `timeout 420`.
- Check `pgrep -af xtool` before any USB deploy. The script also refuses to install while another `xtool dev run` is active (compile-only `--build` still runs).

## 12. Decisions for Jon

1. Install `openssh-server` on santa, bound to the overlay only (section 3)? Until then the MVP test uses the temporary userland server on `100.96.1.18:2222`.
2. The phone's VPN profile is the Connexa device named `device_1790719767795`. Rename it (e.g. "Jon's iPhone") so the directory and the Network tab read better?
3. Which devices get the phone's public key (labMachine `jon`, vision Pi `pi`, 192.168.7.42 `pi`, gcpegress metadata)?
4. GCP `default-allow-ssh` and `default-allow-rdp` are open to `0.0.0.0/0`. Restrict them?
5. Should Face ID be required for each use of the Secure Enclave key? It would prompt on every auto-reconnect.
6. Should the directory come over SSH exec (current design) or a paired-HTTPS `/v1/ssh-targets` route on the gateway?
