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

test_minimum_improvement_is_at_least_two_percent() {
    assert_eq "$(alex_minimum_improved_score 50000)" 51000
    assert_eq "$(alex_minimum_improved_score 1)" 2
    assert_eq "$(alex_minimum_improved_score 0)" 1
    ! alex_minimum_improved_score invalid >/dev/null
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

test_apply_candidate_rejects_incompatible_object_shapes() {
    local dir input output
    dir=$(mktemp -d)
    trap 'rm -rf "${dir:-}"' RETURN
    input="$dir/input.json"
    output="$dir/output.json"
    printf '%s\n' '{"concurrent":4,"mux":"legacy-scalar"}' >"$input"
    ! alex_apply_candidate "$input" "$output" 8 flow true 8192 8000 2097152 300 >/dev/null 2>&1
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

test_service_validation_blocks_systemctl_option_injection() {
    alex_validate_service openppp2-client.service &&
        alex_validate_service 'openppp2@edge.service' &&
        ! alex_validate_service '--no-pager.service' &&
        ! alex_validate_service 'bad;id.service'
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

test_network_identifiers_reject_shell_metacharacters() {
    # shellcheck disable=SC2016 # These are literal attack payloads.
    alex_validate_interface ppp0 &&
        alex_validate_tunnel_address 10.0.0.1 &&
        alex_validate_tunnel_address fd00::1 &&
        ! alex_validate_interface 'ppp0;id' &&
        ! alex_validate_interface 'ppp0$(id)' &&
        ! alex_validate_interface $'ppp0\nkey' &&
        ! alex_validate_tunnel_address '10.0.0.1`id`' &&
        ! alex_validate_tunnel_address '10.0.0.1>file'
}

test_base64_control_words_round_trip_without_shell_tokens() {
    local value encoded decoded
    # shellcheck disable=SC2016 # These are literal attack payloads.
    for value in 'ppp0;id' '$(id)' $'line\nfeed' '`id`' '>file' 'plain value'; do
        encoded=$(alex_b64_word "$value")
        [[ "$encoded" =~ ^[A-Za-z0-9+/]*={0,2}$ ]]
        decoded=$(printf '%s' "$encoded" | base64 -d)
        assert_eq "$decoded" "$value"
    done
}

test_iperf_parser_handles_forward_and_reverse_json() {
    local forward reverse
    forward=$(alex_parse_iperf_json "$ROOT/tests/fixtures/iperf-forward.json")
    reverse=$(alex_parse_iperf_json "$ROOT/tests/fixtures/iperf-reverse.json")
    [[ "$forward" == $'88260.39415272544\t0' ]]
    [[ "$reverse" == $'101442.86086417078\t0' ]]
}

test_iperf_parser_rejects_missing_or_zero_throughput() {
    local dir
    dir=$(mktemp -d)
    trap 'rm -rf "${dir:-}"' RETURN
    printf '%s\n' '{"end":{"sum_received":{"bits_per_second":0},"sum_sent":{"retransmits":0}}}' >"$dir/zero.json"
    printf '%s\n' '{"end":{"sum_sent":{"retransmits":0}}}' >"$dir/missing.json"
    printf '%s\n' '{"end":{"sum_received":{"bits_per_second":1000},"sum_sent":{"retransmits":0.5}}}' >"$dir/fractional.json"
    ! alex_parse_iperf_json "$dir/zero.json" >/dev/null 2>&1 &&
        ! alex_parse_iperf_json "$dir/missing.json" >/dev/null 2>&1 &&
        ! alex_parse_iperf_json "$dir/fractional.json" >/dev/null 2>&1
}

test_counter_delta_does_not_mask_other_endpoint_drops() {
    local local_delta remote_delta
    local_delta=$(alex_counter_delta 100 0)
    remote_delta=$(alex_counter_delta 0 10)
    assert_eq "$local_delta" 0
    assert_eq "$remote_delta" 10
    assert_eq "$((local_delta + remote_delta))" 10
}

test_counter_reset_is_reported_as_instability() {
    alex_counter_reset 100 0 &&
        ! alex_counter_reset 10 10 &&
        ! alex_counter_reset 10 11
}

test_benchmark_rejects_pid_change_during_sampling() (
    export ALEX_LIB="$ROOT/lib/alex-core.sh"
    export ALEX_NODE_HELPER=/bin/true
    # shellcheck source=../alex
    source "$ROOT/alex"
    local dir health_calls result
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    printf '0\n' >"$dir/health-calls"
    REPEATS=3
    DOWNLOAD_CAP=1000
    UPLOAD_CAP=60
    # shellcheck disable=SC2317,SC2329 # benchmark invokes this test double dynamically.
    health_pair() {
        health_calls=$(cat "$dir/health-calls")
        health_calls=$((health_calls + 1))
        printf '%s\n' "$health_calls" >"$dir/health-calls"
        if (( health_calls == 1 )); then
            jq -n '{cpu_percent:20,local_drops:0,remote_drops:0,local_restarts:0,remote_restarts:0,local_pid:100,remote_pid:200}'
        else
            jq -n '{cpu_percent:20,local_drops:0,remote_drops:0,local_restarts:0,remote_restarts:0,local_pid:101,remote_pid:200}'
        fi
    }
    # shellcheck disable=SC2317,SC2329 # benchmark invokes this test double dynamically.
    iperf_sample() { printf '900 0\n'; }
    result=$(benchmark)
    jq -e '.unstable == true and .score == -1' <<<"$result" >/dev/null
)

test_missing_option_value_has_clear_failure() {
    local output next_option
    if output=$("$ROOT/alex" optimize --ssh-host 2>&1); then
        return 1
    fi
    if next_option=$("$ROOT/alex" optimize --ssh-host --yes 2>&1); then
        return 1
    fi
    [[ "$output" == *'参数 --ssh-host 缺少值'* && "$next_option" == *'参数 --ssh-host 缺少值'* ]]
}

test_case 'score caps fixed 1000/60 access limits' test_score_caps_download_and_upload
test_case 'score rejects unstable candidates' test_score_rejects_unstable_candidate
test_case 'score penalizes retransmits and CPU saturation' test_score_penalizes_retransmits_and_cpu
test_case 'minimum persisted improvement is at least two percent' test_minimum_improvement_is_at_least_two_percent
test_case 'candidate edit preserves keys and unknown fields' test_apply_candidate_preserves_unknown_and_secrets
test_case 'candidate edit rejects incompatible object shapes' test_apply_candidate_rejects_incompatible_object_shapes
test_case 'candidate validation rejects unsafe values' test_candidate_validation_rejects_unsafe_values
test_case 'candidate validation accepts supported values' test_candidate_validation_accepts_supported_values
test_case 'atomic install replaces target and clears stage' test_atomic_install_replaces_target_and_cleans_stage
test_case 'cleanup removes only registered paths' test_cleanup_removes_only_registered_paths
test_case 'median selects middle valid throughput sample' test_median_uses_middle_valid_sample
test_case 'SSH target validation blocks injection' test_ssh_target_validation_blocks_option_and_shell_injection
test_case 'systemd service validation blocks option injection' test_service_validation_blocks_systemctl_option_injection
test_case 'managed paths are absolute and shell safe' test_path_validation_allows_only_absolute_safe_paths
test_case 'transaction IDs are unique and path safe' test_transaction_id_is_safe_and_unique
test_case 'candidate plan is finite and bounded' test_candidate_plan_has_baseline_and_bounded_values
test_case 'network identifiers reject shell metacharacters' test_network_identifiers_reject_shell_metacharacters
test_case 'Base64 control words round trip safely' test_base64_control_words_round_trip_without_shell_tokens
test_case 'iperf parser handles forward and reverse JSON' test_iperf_parser_handles_forward_and_reverse_json
test_case 'iperf parser rejects missing or zero throughput' test_iperf_parser_rejects_missing_or_zero_throughput
test_case 'counter reset does not mask other endpoint drops' test_counter_delta_does_not_mask_other_endpoint_drops
test_case 'counter reset is marked unstable' test_counter_reset_is_reported_as_instability
test_case 'benchmark rejects service PID changes' test_benchmark_rejects_pid_change_during_sampling
test_case 'missing option values fail clearly' test_missing_option_value_has_clear_failure

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
