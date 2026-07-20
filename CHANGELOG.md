# Changelog

## 1.1.0 - 2026-07-20

### Reliability

- Detect service PID changes, automatic restart deltas, and counter resets during each benchmark.
- Re-check the 2% minimum improvement threshold before commit and after the persistent restart.
- Guarantee a non-zero exit path on INT, TERM, and HUP so unfinished transactions enter rollback.
- Refuse duplicate transaction preparation that could overwrite the original recovery material.
- Refuse cleanup of committed transactions until they are finalized or restored.
- Preserve the content, owner, group, and mode of an existing systemd queue drop-in on rollback.
- Install new systemd drop-ins with deterministic `0644` permissions.

### Security and operations

- Require non-interactive remote sudo and disable SSH password and keyboard-interactive authentication.
- Restrict host verification to the dedicated known_hosts file and disable global known_hosts fallback.
- Make remote package installation opt-in through `--install-remote-deps`.
- Reject systemd unit names beginning with `-` to prevent option injection.
- Track the iperf3 process start time as well as its PID before terminating a benchmark server.
- Return the baseline, acceptance threshold, selected non-secret tuning fields, and final verification metrics as JSON.

### Quality

- Add clear validation for missing option values and incompatible JSON object shapes.
- De-duplicate identical candidate plans to avoid unnecessary service restarts.
- Expand unit and transaction tests for the new safety invariants.
- Add CI concurrency cancellation, a job timeout, version verification, and an explicit iperf3 dependency.
