#!/usr/bin/env bash

# Core functions are side-effect free unless their name explicitly says install/cleanup.

ALEX_CLEANUP_PATHS=()

alex_score() {
    local download_mbps=$1 upload_mbps=$2 retransmits=$3 unstable=$4
    local cpu_percent=$5 drops=$6 download_cap=$7 upload_cap=$8

    awk -v d="$download_mbps" -v u="$upload_mbps" -v r="$retransmits" \
        -v unstable="$unstable" -v cpu="$cpu_percent" -v drops="$drops" \
        -v dc="$download_cap" -v uc="$upload_cap" 'BEGIN {
        if (unstable != 0 || drops != 0 || dc <= 0 || uc <= 0) {
            print -1
            exit
        }
        dr = d / dc
        ur = u / uc
        if (dr > 1) dr = 1
        if (ur > 1) ur = 1
        if (dr < 0) dr = 0
        if (ur < 0) ur = 0
        score = (dr * 70000) + (ur * 30000)
        score -= r * 20
        if (cpu > 85) score -= (cpu - 85) * 100
        if (score < 0) score = 0
        printf "%.0f\n", score
    }'
}

alex_validate_candidate() {
    local concurrent=$1 mode=$2 turbo=$3 queue_max=$4 queue_stall=$5
    local reorder_bytes=$6 reorder_timeout=$7

    [[ "$concurrent" =~ ^[0-9]+$ ]] && (( concurrent >= 1 && concurrent <= 32 )) || return 1
    [[ "$mode" =~ ^(compat|flow|balance)$ ]] || return 1
    [[ "$turbo" == "true" || "$turbo" == "false" ]] || return 1
    [[ "$queue_max" =~ ^[0-9]+$ ]] && (( queue_max >= 512 && queue_max <= 32768 )) || return 1
    [[ "$queue_stall" =~ ^[0-9]+$ ]] && (( queue_stall >= 1000 && queue_stall <= 30000 )) || return 1
    [[ "$reorder_bytes" =~ ^[0-9]+$ ]] && (( reorder_bytes >= 262144 && reorder_bytes <= 16777216 )) || return 1
    [[ "$reorder_timeout" =~ ^[0-9]+$ ]] && (( reorder_timeout >= 50 && reorder_timeout <= 5000 )) || return 1
}

alex_apply_candidate() {
    local input=$1 output=$2 concurrent=$3 mode=$4 turbo=$5 queue_max=$6
    local queue_stall=$7 reorder_bytes=$8 reorder_timeout=$9

    alex_validate_candidate "$concurrent" "$mode" "$turbo" "$queue_max" \
        "$queue_stall" "$reorder_bytes" "$reorder_timeout" || return 1

    jq --argjson concurrent "$concurrent" \
        --arg mode "$mode" \
        --argjson turbo "$turbo" \
        --argjson queue_max "$queue_max" \
        --argjson queue_stall "$queue_stall" \
        --argjson reorder_bytes "$reorder_bytes" \
        --argjson reorder_timeout "$reorder_timeout" '
        .concurrent = $concurrent |
        .mux = (.mux // {}) |
        .mux.mode = $mode |
        .mux.turbo = $turbo |
        .mux.tx = (.mux.tx // {}) |
        .mux.tx.queue = (.mux.tx.queue // {}) |
        .mux.tx.queue.max = $queue_max |
        .mux.tx.queue.stall = $queue_stall |
        .mux.flow = (.mux.flow // {}) |
        .mux.flow.reorder = (.mux.flow.reorder // {}) |
        .mux.flow.reorder.bytes = $reorder_bytes |
        .mux.flow.reorder.timeout = $reorder_timeout
    ' "$input" >"$output"
}

alex_atomic_install() {
    local source=$1 target=$2 mode=${3:-600}
    local stage="${target}.alex-new"

    install -m "$mode" "$source" "$stage"
    mv -f "$stage" "$target"
}

alex_register_cleanup() {
    ALEX_CLEANUP_PATHS+=("$1")
}

alex_cleanup() {
    local path
    for path in "${ALEX_CLEANUP_PATHS[@]:-}"; do
        [[ -n "$path" ]] && rm -rf -- "$path"
    done
    ALEX_CLEANUP_PATHS=()
}

alex_median() {
    (($# > 0)) || return 1
    printf '%s\n' "$@" | LC_ALL=C sort -n | awk '{v[NR]=$1} END {
        if (NR % 2) print v[(NR + 1) / 2]
        else printf "%.3f\n", (v[NR / 2] + v[(NR / 2) + 1]) / 2
    }'
}

alex_validate_ssh_target() {
    local user=$1 host=$2 port=$3
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
    [[ "$host" =~ ^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9._:-]*[A-Za-z0-9])$ ]] || return 1
    [[ "$host" != -* && "$host" != *'..'* ]] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
}

alex_validate_managed_path() {
    local path=$1
    [[ "$path" =~ ^/(opt|etc|usr/local/etc)/[A-Za-z0-9._/+:-]+$ ]] || return 1
    [[ "$path" != *'/../'* && "$path" != *'/./'* && "$path" != */.. && "$path" != */. ]]
}

alex_validate_interface() {
    [[ "$1" =~ ^[A-Za-z0-9_.:-]+$ ]]
}

alex_validate_tunnel_address() {
    [[ "$1" =~ ^[0-9a-fA-F:.]+$ ]]
}

alex_b64_word() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

alex_parse_iperf_json() {
    local input=$1
    jq -er '
        (.end.sum_received.bits_per_second // error("missing received throughput")) as $bps |
        (.end.sum_sent.retransmits // 0) as $retrans |
        if (($bps | type) != "number") or $bps <= 0 or (($retrans | type) != "number") or $retrans < 0
        then error("invalid iperf3 metrics")
        else [($bps / 1000000), $retrans] | @tsv
        end
    ' "$input"
}

alex_counter_delta() {
    local before=$1 after=$2
    if (( after >= before )); then
        printf '%d\n' "$((after - before))"
    else
        printf '0\n'
    fi
}

alex_transaction_id() {
    local random
    random=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$random"
}

alex_candidate_plan() {
    local base_concurrent=$1 base_mode=$2 base_turbo=$3 base_queue_max=$4
    local base_queue_stall=$5 base_reorder_bytes=$6 base_reorder_timeout=$7
    local concurrent

    # Baseline first, then one-dimensional probes, then two conservative combined candidates.
    printf '%s %s %s %s %s %s %s 1000\n' "$base_concurrent" "$base_mode" \
        "$base_turbo" "$base_queue_max" "$base_queue_stall" "$base_reorder_bytes" "$base_reorder_timeout"
    for concurrent in 2 4 6 8; do
        [[ "$concurrent" == "$base_concurrent" ]] && continue
        printf '%s %s %s %s %s %s %s 5000\n' "$concurrent" "$base_mode" \
            "$base_turbo" "$base_queue_max" "$base_queue_stall" "$base_reorder_bytes" "$base_reorder_timeout"
    done
    printf '%s flow false 4096 8000 1048576 400 5000\n' "$base_concurrent"
    printf '%s flow true 4096 8000 2097152 400 5000\n' "$base_concurrent"
    printf '6 flow true 8192 8000 2097152 400 10000\n'
    printf '8 balance false 8192 8000 2097152 400 10000\n'
}