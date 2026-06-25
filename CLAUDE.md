# CLAUDE.md

Context for working in this repo. Domain vocabulary lives in [`CONTEXT.md`](./CONTEXT.md);
an illustrated architecture walkthrough is in [`docs/architecture.html`](./docs/architecture.html).

## What this is

`expjobserver` is a small cluster manager for running experiments across reserved
test machines. Two Rust binaries plus one shell wrapper:

- **`expjobserver`** (`src/bin/server/`) — long-running server. Holds machine
  pool, job queue, and a per-job state machine; runs jobs via a RUNNER; rsyncs
  results back; snapshots state to disk.
- **`j`** (`src/bin/client/`) — stateless CLI client. Talks to the server over
  TCP (`127.0.0.1:3030`) using protobuf messages.
- **`expjobserver_remote_wrapper.sh`** — the RUNNER in this fork. The server
  hands it `--print_results_path <cmd...>`; it treats the first token as the
  target host and SSHes in to run the rest. This is what makes jobs run on
  remote CloudLab machines instead of locally.

How the user actually uses it is documented in the **README addendum**
("how *this* fork is actually used"). Read that before changing job/runner behavior.

## Source map

| Path | Role |
|------|------|
| `src/lib.rs` | Shared helpers: `{VAR}`/`{MACHINE}` substitution, cartesian product, timestamps. |
| `src/protocol.proto` | Client↔server RPC messages (compiled by `build.rs`). |
| `src/bin/server/main.rs` | Server entry; `Server` state, `Task`/`TaskState` definitions, work thread. |
| `src/bin/server/sm.rs` | The job state machine — how each task advances and how the RUNNER is spawned. |
| `src/bin/server/request.rs` | Handlers for each client request. |
| `src/bin/server/copier.rs` | Rsync results back to the destination. |
| `src/bin/server/snapshot.rs` | Serialize/restore server state (`state.proto`). |
| `src/bin/server/notify.rs` | Slack notifications. |
| `src/bin/client/{cli,main,pretty,stat}.rs` | CLI definition, request building, output formatting. |
| `scripts/add_machine.sh` | Provision + register a reserved machine (resize, deploy, tmux setup, `j machine add`). |
| `scripts/{hemem_baseline,run_pebs,...}.sh` | Batches of `j job add` lines — the real experiment workloads. |

## Build & run

```sh
cargo build                 # builds both `j` and `expjobserver`
expjobserver ./expjobserver_remote_wrapper.sh ./logs/ ./example.log.yml --allow_snap_fail
```

`--allow_snap_fail` is required on first run (and any time the on-disk snapshot
should be discarded); otherwise the server refuses to start if it can't load
history — a deliberate guard against wiping job history.

## Conventions & gotchas

- **A job is one command string, no shell operators.** The server splits on
  whitespace and the wrapper replays tokens as `"$@"`, so `&&`, `|`, `>`, `;` are
  passed literally, not interpreted. Multi-step logic goes inside the invoked
  script.
- **Every job command starts with `{MACHINE}`** — the wrapper consumes the first
  token as the SSH host.
- **"Variables" are `{NAME}` template substitutions**, resolved server-side, not
  OS env vars. Set with `j var set`; matrices sweep them.
- **Results copy back only on a `RESULTS: <path>` stdout line** (the wrapper
  emits one automatically for files left in its `results/` subdir).
- **Wrapper config**: `example_config.sh` (tracked, `${VAR:-default}` form) is
  sourced first, then `config.local.sh` (gitignored, real usernames) overrides.
- **Result data dirs** (`old_runs/`, `hemem_arms_bwmon_policies/`) are gitignored
  on purpose — data, not code.
- `add_machine.sh` is a separate provisioning path; it does not go through the
  job server or the SSH wrapper.

## Git

Solo research repo; history is direct-to-`master`. Don't commit result data or
`config.local.sh` (both gitignored).
