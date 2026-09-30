#!/usr/bin/env bash
# Temporary userland OpenSSH server on santa for testing the SSH terminal (no sudo, no system config).
# It binds the overlay address only, is key-only, allows only the current user, and keeps its own
# host keys and authorized_keys under ~/.cache/lojo-ssh-test.
#   scripts/test-sshd.sh start|stop|status
#   scripts/test-sshd.sh authorize 'ecdsa-sha2-nistp256 AAAA… comment'   add a public key (test server only)
#   scripts/test-sshd.sh fingerprint                                     ed25519 host key fingerprint
#   scripts/test-sshd.sh smoke                                           build + run tools/ssh-smoke against it
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$HOME/.cache/lojo-ssh-test"
LISTEN="${LOJO_TEST_SSHD_LISTEN:-100.96.1.18:2222}"
SSHD="$DIR/root/usr/sbin/sshd"

setup() {
  mkdir -p "$DIR/deb" "$DIR/hostkeys"
  chmod 700 "$DIR" "$DIR/hostkeys"
  if [[ ! -x "$SSHD" ]]; then
    local ver
    ver="$(dpkg-query -W -f='${Version}' openssh-client)"
    (cd "$DIR/deb" && apt-get download "openssh-server=$ver" >/dev/null)
    dpkg-deb -x "$DIR"/deb/openssh-server_*.deb "$DIR/root"
  fi
  for t in ed25519 ecdsa; do
    [[ -f "$DIR/hostkeys/ssh_host_${t}_key" ]] || ssh-keygen -q -t "$t" -N '' -C lojo-test-host -f "$DIR/hostkeys/ssh_host_${t}_key"
  done
  touch "$DIR/authorized_keys"
  chmod 600 "$DIR/authorized_keys"
  cat > "$DIR/sshd_config" <<EOF
ListenAddress $LISTEN
HostKey $DIR/hostkeys/ssh_host_ed25519_key
HostKey $DIR/hostkeys/ssh_host_ecdsa_key
PidFile $DIR/sshd.pid
AuthorizedKeysFile $DIR/authorized_keys
AllowUsers $USER
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM no
AllowTcpForwarding no
X11Forwarding no
PermitTunnel no
ClientAliveInterval 30
LogLevel INFO
EOF
  "$SSHD" -t -f "$DIR/sshd_config"
}

running() { [[ -f "$DIR/sshd.pid" ]] && kill -0 "$(cat "$DIR/sshd.pid")" 2>/dev/null; }

case "${1:-status}" in
  start)
    setup
    if running; then echo "already running on $LISTEN"; exit 0; fi
    "$SSHD" -f "$DIR/sshd_config" -E "$DIR/sshd.log"
    sleep 0.5
    running && echo "test sshd listening on $LISTEN (key-only, user $USER)"
    ;;
  stop)
    if running; then kill "$(cat "$DIR/sshd.pid")"; echo stopped; else echo "not running"; fi
    ;;
  status)
    if running; then echo "running on $LISTEN"; else echo "not running"; fi
    ;;
  authorize)
    [[ -n "${2:-}" ]] || { echo "usage: $0 authorize 'type base64 [comment]'" >&2; exit 2; }
    setup
    grep -qxF "$2" "$DIR/authorized_keys" || echo "$2" >> "$DIR/authorized_keys"
    echo "authorized on the test server only ($DIR/authorized_keys)"
    ;;
  fingerprint)
    ssh-keygen -l -E sha256 -f "$DIR/hostkeys/ssh_host_ed25519_key.pub" | awk '{print $2}'
    ;;
  smoke)
    running || "$0" start
    for t in ed25519 ecdsa; do
      if [[ ! -f "$DIR/smoke_$t" ]]; then
        ssh-keygen -q -t "$t" -N '' -C "lojo-smoke-$t" -f "$DIR/smoke_$t"
        cat "$DIR/smoke_$t.pub" >> "$DIR/authorized_keys"
      fi
    done
    # shellcheck disable=SC1091
    source "$HOME/.config/ios-dev/env"
    export PATH="$SWIFT_ROOT/usr/bin:$HOME/.local/bin:$PATH"
    (cd "$REPO/tools/ssh-smoke" && swift build -q --scratch-path "$HOME/.cache/lojo-ssh-smoke-build")
    rm -f "$DIR/known_hosts_smoke"
    "$HOME/.cache/lojo-ssh-smoke-build/debug/ssh-smoke" \
      --host "${LISTEN%:*}" --port "${LISTEN##*:}" --user "$USER" \
      --ed25519 "$DIR/smoke_ed25519" --ecdsa "$DIR/smoke_ecdsa" \
      --fingerprint "$("$0" fingerprint)" --known "$DIR/known_hosts_smoke"
    ;;
  *) echo "usage: $0 start|stop|status|authorize KEY|fingerprint|smoke" >&2; exit 2 ;;
esac
