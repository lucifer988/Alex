#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/alex-core.sh
source "$ROOT/lib/alex-core.sh"

pass=0
fail=0

test_case() {
    local name=$1
    shift
    if "$@"; then
        printf 'ok - %s\n' "$name"
        pass=$((pass + 1))
    else
        printf 'not ok - %s\n' "$name" >&2
        fail=$((fail + 1))
    fi
}

assert_eq() {
    [[ "$1" == "$2" ]] || {
        printf 'expected <%s>, got <%s>\n' "$2" "$1" >&2
        return 1
    }
}

test_score_caps_download_and_upload() {
    local score
    score=$(alex_score 1100 70 0 0 40 0 1000 60)
    assert_eq "$score" "100000"
}

test_score_rejects_unstable_candidate() {
    local score
    score=$(alex_score 900 55 0 1 40 0 1000 60)
    assert_eq "$score" "-1"
}

test_score_penalizes_retransmits_and_cpu() {
    local clean dirty
    clean=$(alex_score 800 50 0 0 50 0 1000 60)
    dirty=$(alex_score 800 50 20 0 90 0 1000 60)
    (( clean > dirty ))
}

test_apply_candidate_preserves_unknown_and_secrets() {
    local dir input output
    dir=$(mktemp -d)
    trap 'rm -rf "${dir:-}"' RETURN
    input="$dir/input.json"
    output="$dir/output.json"
    cat >"$input" <<'JSON'
{
  "concurrent": 4,
  "key": {"protocol-key": "keep-me", "extra": 7},
  "custom": {"untouched": true},
  "mux": {"mode": "compat", "turbo": false, "tx": {"queue": {"max": 4096, "stall": 8000}}}
}
JSON
    alex_apply_candidate "$input" "$output" 8 flow true 8192 8000 2097152 300
    jq -e '.concurrent == 8 and .mux.mode == "flow" and .mux.turbo == true' "$output" >/dev/null
    jq -e '.mux.tx.queue.max == 8192 and .mux.flow.reorder.bytes == 2097152' "$output" >/dev/null
    jq -e '.key["protocol-key"] == "keep-me" and .key.extra == 7 and .custom.untouched == true' "$output" >/dev/null
}

test_candidate_validation_rejects_unsafe_values() {
    ! alex_validate_candidate 0 flow true 4096 8000 1048576 400 &&
        ! alex_validate_candidate 4 invalid false 4096 8000 1048576 400 &&
        ! alex_validate_candidate 4 flow false 999999 8000 1048576 400
}

test_candidate_validation_accepts_supported_values() {
    alex_validate_candidate 4 flow true 4096 8000 1048576 400
}

test_atomic_install_replaces_target_and_cleans_stage() {
    local dir src target
    dir=$(mktemp -d)
    trap 'rm -rf "${dir:-}"' RETURN
    src="$dir/new"
    target="$dir/config.json"
    printf 'old\n' >"$target"
    printf 'new\n' >"$src"
    alex_atomic_install "$src" "$target" 600
    assert_eq "$(cat "$target")" "new"
    [[ ! -e "$target.alex-new" ]]
}

test_cleanup_removes_only_registered_paths() {
    local dir keep trash
    dir=$(mktemp -d)
    trap 'rm -rf "${dir:-}"' RETURN
    keep="$dir/keep"
    trash="$dir/alex-owned"
    : >"$keep"
    : >"$trash"
    ALEX_CLEANUP_PATHS=()
    alex_register_cleanup "$trash"
    alex_cleanup
    [[ -e "$keep" && ! -e "$trash" ]]
}

test_median_uses_middle_valid_sample() {
    assert_eq "$(alex_median 61 58 60)" "60"
    assert_eq "$(alex_median 900 850 920 880 910)" "900"
}

test_ssh_target_validation_blocks_option_and_shell_injection() {
    alex_validate_ssh_target root 203.0.113.8 22 &&
        ! alex_validate_ssh_target root '-oProxyCommand=bad' 22 &&
        ! alex_validate_ssh_target 'root;id' 203.0.113.8 22 &&
        ! alex_validate_ssh_target root 'host;id' 22 &&
        ! alex_validate_ssh_target root 203.0.113.8 70000
}

test_path_validation_allows_only_absolute_safe_paths() {
    alex_validate_managed_path /opt/openppp2/appsettings.json &&
        alex_validate_managed_path /etc/openppp2/server.json &&
        ! alex_validate_managed_path ../../etc/shadow &&
        ! alex_validate_managed_path '/opt/openppp2/a;id'
}

test_transaction_id_is_safe_and_unique() {
    local first second
    first=$(alex_transaction_id)
    second=$(alex_transaction_id)
    [[ "$first" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}$ ]]
    [[ "$second" =~ ^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}$ ]]
    [[ "$first" != "$second" ]]
}

test_candidate_plan_has_baseline_and_bounded_values() {
    local line count=0
    while IFS= read -r line; do
        read -r concurrent mode turbo queue_max queue_stall reorder_bytes reorder_timeout qlen <<<"$line"
        alex_validate_candidate "$concurrent" "$mode" "$turbo" "$queue_max" \
            "$queue_stall" "$reorder_bytes" "$reorder_timeout"
        [[ "$qlen" =~ ^(1000|5000|10000)$ ]]
        count=$((count + 1))
    done < <(alex_candidate_plan 4 compat false 4096 8000 1048576 400)
    (( count >= 6 && count <= 16 ))
}

test_case 'score caps fixed 1000/60 access limits' test_score_caps_download_and_upload
test_case 'score rejects unstable candidates' test_score_rejects_unstable_candidate
test_case 'score penalizes retransmits and CPU saturation' test_score_penalizes_retransmits_and_cpu
test_case 'candidate edit preserves keys and unknown fields' test_apply_candidate_preserves_unknown_and_secrets
test_case 'candidate validation rejects unsafe values' test_candidate_validation_rejects_unsafe_values
test_case 'candidate validation accepts supported values' test_candidate_validation_accepts_supported_values
test_case 'atomic install replaces target and clears stage' test_atomic_install_replaces_target_and_cleans_stage
test_case 'cleanup removes only registered paths' test_cleanup_removes_only_registered_paths
test_case 'median selects middle valid throughput sample' test_median_uses_middle_valid_sample
test_case 'SSH target validation blocks injection' test_ssh_target_validation_blocks_option_and_shell_injection
test_case 'managed paths are absolute and shell safe' test_path_validation_allows_only_absolute_safe_paths
test_case 'transaction IDs are unique and path safe' test_transaction_id_is_safe_and_unique
test_case 'candidate plan is finite and bounded' test_candidate_plan_has_baseline_and_bounded_values

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
