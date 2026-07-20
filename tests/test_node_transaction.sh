#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'if [[ "${ALEX_TEST_KEEP:-0}" == 1 ]]; then echo "kept: $TMP" >&2; else rm -rf "$TMP"; fi' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/etc/openppp2" "$TMP/state" "$TMP/run" "$TMP/lock" "$TMP/net/ppp0/statistics"
printf '0\n' >"$TMP/net/ppp0/statistics/tx_dropped"
printf '0\n' >"$TMP/net/ppp0/statistics/rx_dropped"
printf '1000\n' >"$TMP/net/ppp0/tx_queue_len"
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
    case "$3" in
      MainPID) echo $$ ;;
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
chmod +x "$BIN/systemctl" "$BIN/systemd-run" "$BIN/ip"

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
export ALEX_STATE_ROOT="$TMP/state"
export ALEX_RUN_ROOT="$TMP/run"
export ALEX_LOCK_FILE="$TMP/lock/alex.lock"
TXID=20260720T120000Z-0123456789abcdef
CONFIG="$TMP/etc/openppp2/appsettings.json"

"$HELPER" prepare "$TXID" "$CONFIG" test.service ppp0 >/dev/null
[[ -f "$TMP/state/active-transaction" ]]
grep -q auto-rollback "$TMP/systemd-run.log"
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
printf 'node transaction integration: ok\n'
