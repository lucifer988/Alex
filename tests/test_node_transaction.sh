#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'if [[ "${ALEX_TEST_KEEP:-0}" == 1 ]]; then echo "kept: $TMP" >&2; else rm -rf "$TMP"; fi' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/etc/openppp2" "$TMP/state" "$TMP/run" "$TMP/lock" "$TMP/net/ppp0/statistics"
mkdir -p "$TMP/net/eth0/statistics"
printf '0\n' >"$TMP/net/ppp0/statistics/tx_dropped"
printf '0\n' >"$TMP/net/ppp0/statistics/rx_dropped"
printf '1000\n' >"$TMP/net/ppp0/tx_queue_len"
printf '0\n' >"$TMP/net/eth0/statistics/tx_dropped"
printf '0\n' >"$TMP/net/eth0/statistics/rx_dropped"
cat >"$TMP/etc/openppp2/appsettings.json" <<'JSON'
{"concurrent":4,"key":{"protocol-key":"secret"},"mux":{"mode":"compat"}}
JSON
cp "$TMP/etc/openppp2/appsettings.json" "$TMP/original.json"

cat >"$BIN/systemctl" <<'SH'
#!/usr/bin/env bash
case "$1" in
  cat) echo '[Service]'; echo 'ExecStart=/bin/true' ;;
  is-active) [[ "${2:-}" == --quiet ]] || echo active ;;
  is-enabled) echo enabled ;;
  show)
    case "$4" in
      MainPID) echo "$ALEX_TEST_MAIN_PID" ;;
      NRestarts) echo 0 ;;
    esac ;;
  restart|daemon-reload|stop|reset-failed) exit 0 ;;
  *) exit 0 ;;
esac
SH
cat >"$BIN/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ALEX_TEST_SYSTEMD_RUN_LOG"
SH
cat >"$BIN/ip" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2 $3 $4" == 'link set dev ppp0' && "$5" == txqueuelen ]]; then
  printf '%s\n' "$6" >"$ALEX_TEST_NET/ppp0/tx_queue_len"
fi
SH
cat >"$BIN/ps" <<'SH'
#!/usr/bin/env bash
printf '12.5\n'
SH
chmod +x "$BIN/systemctl" "$BIN/systemd-run" "$BIN/ip" "$BIN/ps"

# Rewrite fixed kernel/systemd paths only in an isolated copy of the helper.
HELPER="$TMP/alex-node"
sed \
  -e "s|/sys/class/net|$TMP/net|g" \
  -e "s|/etc/systemd/system|$TMP/etc/systemd/system|g" \
  -e "s#\^/(opt|etc|usr/local/etc)/#^$TMP/etc/#g" \
  "$ROOT/alex-node" >"$HELPER"
chmod +x "$HELPER"

export PATH="$BIN:$PATH"
export ALEX_TEST_SYSTEMD_RUN_LOG="$TMP/systemd-run.log"
export ALEX_TEST_NET="$TMP/net"
export ALEX_TEST_MAIN_PID=$$
export ALEX_STATE_ROOT="$TMP/state"
export ALEX_RUN_ROOT="$TMP/run"
export ALEX_LOCK_FILE="$TMP/lock/alex.lock"
TXID=20260720T120000Z-0123456789abcdef
CONFIG="$TMP/etc/openppp2/appsettings.json"

"$HELPER" prepare "$TXID" "$CONFIG" test.service ppp0 >/dev/null
[[ "$(stat -c '%a' "$TMP/state/transactions/$TXID/original.json")" == 600 ]]
[[ "$(stat -c '%a' "$TMP/state/transactions/$TXID")" == 700 ]]
[[ -f "$TMP/state/active-transaction" ]]
grep -q auto-rollback "$TMP/systemd-run.log"
backup_sha=$(sha256sum "$TMP/state/transactions/$TXID/original.json" | awk '{print $1}')
if "$HELPER" prepare "$TXID" "$CONFIG" test.service ppp0 >/dev/null 2>&1; then
    echo 'duplicate prepare unexpectedly overwrote transaction state' >&2
    exit 1
fi
[[ "$(sha256sum "$TMP/state/transactions/$TXID/original.json" | awk '{print $1}')" == "$backup_sha" ]]
printf '%s\n' '{"concurrent":8,"key":{"protocol-key":"secret"},"mux":{"mode":"flow"}}' |
  "$HELPER" apply "$TXID" 5000 >/dev/null
jq -e '.concurrent == 8 and .key["protocol-key"] == "secret"' "$CONFIG" >/dev/null
[[ "$(cat "$TMP/net/ppp0/tx_queue_len")" == 5000 ]]
"$HELPER" restore "$TXID" >/dev/null
cmp -s "$CONFIG" "$TMP/original.json"
[[ "$(cat "$TMP/net/ppp0/tx_queue_len")" == 1000 ]]
"$HELPER" cleanup "$TXID" >/dev/null
[[ ! -e "$TMP/state/transactions/$TXID" ]]
[[ ! -e "$TMP/state/active-transaction" ]]

TXID=20260720T120001Z-fedcba9876543210
"$HELPER" prepare "$TXID" "$CONFIG" test.service ppp0 >/dev/null
"$HELPER" discard "$TXID" >/dev/null
"$HELPER" cleanup "$TXID" >/dev/null
cmp -s "$CONFIG" "$TMP/original.json"
[[ ! -e "$TMP/state/transactions/$TXID" ]]
[[ ! -e "$TMP/state/active-transaction" ]]

TXID=20260720T120002Z-0011223344556677
"$HELPER" prepare "$TXID" "$CONFIG" test.service ppp0 >/dev/null
printf '%s\n' '{"concurrent":6,"key":{"protocol-key":"secret"},"mux":{"mode":"flow"}}' |
  "$HELPER" apply "$TXID" 10000 >/dev/null
"$HELPER" commit "$TXID" >/dev/null
[[ -f "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf" ]]
[[ "$(stat -c '%a' "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf")" == 644 ]]
grep -q 'txqueuelen 10000' "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf"
if "$HELPER" cleanup "$TXID" >/dev/null 2>&1; then
    echo 'cleanup unexpectedly removed an unfinalized committed transaction' >&2
    exit 1
fi
[[ -d "$TMP/state/transactions/$TXID" ]]
"$HELPER" auto-rollback "$TXID" >/dev/null
cmp -s "$CONFIG" "$TMP/original.json"
[[ ! -e "$TMP/state/transactions/$TXID" ]]

TXID=20260720T120003Z-8899aabbccddeeff
"$HELPER" prepare "$TXID" "$CONFIG" test.service ppp0 >/dev/null
printf '%s\n' '{"concurrent":8,"key":{"protocol-key":"secret"},"mux":{"mode":"balance"}}' |
  "$HELPER" apply "$TXID" 5000 >/dev/null
"$HELPER" commit "$TXID" >/dev/null
"$HELPER" finalize "$TXID" >/dev/null
[[ "$(cat "$TMP/state/transactions/$TXID/stage")" == FINALIZED ]]
"$HELPER" auto-rollback "$TXID" >/dev/null
jq -e '.concurrent == 8 and .mux.mode == "balance"' "$CONFIG" >/dev/null
[[ ! -e "$TMP/state/transactions/$TXID" ]]
cp "$TMP/original.json" "$CONFIG"
rm -f "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf"

TXID=20260720T120004Z-7766554433221100
mkdir -p "$TMP/etc/systemd/system/test.service.d"
printf '%s\n' '[Service]' 'Environment=KEEP=1' >"$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf"
chmod 0640 "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf"
cp "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf" "$TMP/original.dropin"
"$HELPER" prepare "$TXID" "$CONFIG" test.service ppp0 >/dev/null
printf '%s\n' '{"concurrent":6,"key":{"protocol-key":"secret"},"mux":{"mode":"flow"}}' |
  "$HELPER" apply "$TXID" 5000 >/dev/null
"$HELPER" restore "$TXID" >/dev/null
cmp -s "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf" "$TMP/original.dropin"
[[ "$(stat -c '%a' "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf")" == 640 ]]
"$HELPER" cleanup "$TXID" >/dev/null
rm -f "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf"

TXID=20260720T120004Z-aabbccddeeff0011
mkdir -p "$TMP/etc/systemd/system/test.service.d"
ln -s /dev/null "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf"
if "$HELPER" prepare "$TXID" "$CONFIG" test.service ppp0 >/dev/null 2>&1; then
    echo 'prepare unexpectedly accepted a symlink drop-in' >&2
    exit 1
fi
[[ -L "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf" ]]
rm -rf "$TMP/state/transactions/$TXID" "$TMP/run/$TXID"
rm -f "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf"

TXID=20260720T120004Z-abcdef0123456789
"$HELPER" prepare "$TXID" "$CONFIG" test.service ppp0 >/dev/null
encoded_command=$(printf '%s' health | base64 | tr -d '\n')
encoded_txid=$(printf '%s' "$TXID" | base64 | tr -d '\n')
"$HELPER" --b64 "$encoded_command" "$encoded_txid" | jq -e '.ok' >/dev/null
"$HELPER" discard "$TXID" >/dev/null
"$HELPER" cleanup "$TXID" >/dev/null

TXID=20260720T120005Z-1234567890abcdef
"$HELPER" prepare "$TXID" "$CONFIG" test.service eth0 server >/dev/null
[[ "$(cat "$TMP/state/transactions/$TXID/mode")" == server ]]
printf '%s\n' '{"concurrent":7,"key":{"protocol-key":"secret"},"mux":{"mode":"flow"}}' |
  "$HELPER" apply "$TXID" 5000 >/dev/null
"$HELPER" health "$TXID" | jq -e '.ok and .tun_drops == 0' >/dev/null
"$HELPER" commit "$TXID" >/dev/null
[[ ! -e "$TMP/etc/systemd/system/test.service.d/90-alex-tun-queue.conf" ]]
"$HELPER" finalize "$TXID" >/dev/null
"$HELPER" auto-rollback "$TXID" >/dev/null
[[ ! -e "$TMP/state/transactions/$TXID" ]]
printf 'node transaction integration: ok\n'
