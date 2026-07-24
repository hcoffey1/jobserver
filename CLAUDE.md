# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
| `scripts/{setup,add}_all_machines.sh` | Batch drivers: provision a fleet from a machine list / register an already-provisioned fleet. |
| `scripts/gen_machine_list.sh` | Regenerate `machine_list.txt` from `/etc/hosts`; excludes the control node. |
| `scripts/setup_hemem.sh` | The per-worker setup script: scratch disk, packages, unpack deploy, build workloads. |
| `scripts/setup_worker_key.sh` | Give the head node its own local key to the workers (unattended runs). |
| `scripts/patches/apply_zshrc_ssh_agent.sh` | Pin the forwarded ssh-agent socket so detached tmux sessions survive reconnects. |
| `scripts/{hemem_baseline,run_pebs,...}.sh` | Batches of `j job add` lines — the real experiment workloads. |

## Build & run

```sh
cargo build                 # builds both `j` and `expjobserver`
expjobserver ./expjobserver_remote_wrapper.sh ./logs/ ./example.log.yml --allow_snap_fail
```

`--allow_snap_fail` is required on first run (and any time the on-disk snapshot
should be discarded); otherwise the server refuses to start if it can't load
history — a deliberate guard against wiping job history.

Neither binary is on `PATH` by default. `cargo build` leaves them at
`./target/debug/{expjobserver,j}`; either `cargo install --path .` or call them
by path. **Scripts that shell out to the client need `EXPJOBSERVER_CLIENT=./target/debug/j`**
(they default to that path, but any invocation from elsewhere must set it).

## First-time setup on a new machine

Bootstrapping the **head/control node** (the machine that runs the long-lived
server in tmux and drives the CloudLab workers) from a *bare* node. Do these in
order; the README addendum has the full rationale for each.

> **What survives losing the node.** On this cluster `/users` is **`/dev/sda3`,
> the node's local disk — NOT NFS**. Home dies with the experiment: this
> checkout, `~/working` (~100 G), `~/.ssh/id_jobserver`, and `config.local.sh`
> all go. Only **`/proj/instrument-PG0`** (NFS, 100 G) persists. So: keep all
> three repos pushed to GitHub (`jobserver`, `workloads`,
> `tiering_solutions`→`regent`), and treat everything below as reproducible from
> git + `/proj`. Nothing else is backed up.

0. **Bootstrap the node.** `bash /proj/instrument-PG0/setup.sh` — packages,
   `cargo` (Ubuntu `cargo-1.91`, symlinked to `/usr/bin/cargo`), conda, zsh/tmux
   dotfiles. It lives on `/proj`, so it survives. Nothing below works without it;
   in particular step 1's `cargo build` has no compiler until this runs.
   (`rustc` is intentionally not on `PATH` — cargo resolves its own toolchain at
   `/usr/lib/rust-1.91/bin/rustc`. `protoc` is not needed: `prost-build` 0.10
   vendors its own.)
1. **Clone the repos into the layout the scripts assume.** The deploy root is
   `~/working`, and it **must** contain `regent/` and `workloads/` — every job
   path, `distribute_regent.sh`, and `setup_hemem.sh` depend on it:
   ```sh
   git clone git@github.com:hcoffey1/jobserver.git ~/jobserver
   mkdir -p ~/working
   git clone git@github.com:hcoffey1/workloads.git          ~/working/workloads
   git clone git@github.com:hcoffey1/tiering_solutions.git  ~/working/regent
   ```
   Optional but recommended: restore the cached raw datasets from `/proj` (see
   "Provisioning a fleet" below) so the workers skip two large external
   downloads.
2. **Build.** `cargo build` (see Build & run). Create `config.local.sh` with
   `export EXPJOBSERVER_SSH_USER="<cloudlab-user>"` — without it the wrapper
   uses the placeholder user and *every* job fails with exit 255 (`publickey`).
   `config.local.sh` is gitignored, so it never exists on a fresh checkout.
3. **Worker SSH access.** The server, wrapper, and results copier all reach
   workers over SSH via whatever the ssh-agent offers.
   - For interactive/short work with a **forwarded** agent, pin the socket so a
     detached tmux server keeps auth across reconnects:
     `scripts/patches/apply_zshrc_ssh_agent.sh` (idempotent; installs the managed
     block in `~/.zshrc`). New shell or `source ~/.zshrc` to activate.
   - **Before any unattended/overnight run**, run `scripts/setup_worker_key.sh`
     *while your current SSH to the workers still works*. It mints a local
     `~/.ssh/id_jobserver` key, `ssh-copy-id`s it to each worker, and writes an
     `~/.ssh/config` block so the head node no longer depends on your forwarded
     agent. The copier ignores `EXPJOBSERVER_SSH_OPTIONS`, so `~/.ssh/config` is
     the only knob that fixes its SSH too.
     **Its `Host` glob defaults to `*.cloudlab.us`, which does NOT match bare
     `/etc/hosts` names** — on a LAN-addressed fleet pass
     `EXPJOBSERVER_HOST_PATTERN='node*'` and list the hosts explicitly (with no
     server running yet it cannot discover them from `j machine ls`).
     Verify with `env -u SSH_AUTH_SOCK ssh node1 true` — that, not a plain `ssh`,
     is the real overnight condition.
4. **Start the server** in tmux (survives disconnects):
   `expjobserver ./expjobserver_remote_wrapper.sh ./logs/ ./example.log.yml --allow_snap_fail`
   (the flag is required on this very first run; **drop it on every restart
   after**, or you discard accumulated job history).
5. **Provision + register workers.** One host: `scripts/add_machine.sh <host> <class> <setup.sh> -d <deploy> -p -v -r`.
   A fleet — see "Provisioning a fleet" below for why each env var is needed:
   ```sh
   DEPLOY_DIR=$HOME/working \
   EXPJOBSERVER_RSYNC_EXCLUDES='/workloads/liblinear-2.47/kdd12' \
     ./scripts/setup_all_machines.sh
   ```
   First generate `machine_list.txt` with `scripts/gen_machine_list.sh` (reads
   `/etc/hosts`, drops the control node — otherwise the server schedules jobs
   onto itself), then `scripts/setup_all_machines.sh` to provision and
   `scripts/add_all_machines.sh` to register them with the running server.
   **The list parser only accepts fields containing `@` or `.`** — a bare `node1`
   is *silently dropped*, so entries must be `user@host` (a pasted
   `ssh user@host` line also works). An empty list aborts, but a partial one does
   not: always check the host count the script echoes.
   `setup_all_machines.sh`'s final `j machine add` step fails when no server is
   up yet — it reports that as `SETUP_OK_NO_JOBSERVER`, not a failure. Starting
   the server *before* provisioning avoids this entirely; hosts auto-register.
6. **Verify before enqueuing** — a host marked `OK` only means the driver exited,
   not that the workloads built. See "Provisioning a fleet" below.
7. **Enqueue jobs** with the workload batch scripts (`bash scripts/hemem_baseline.sh`, etc.).

`setup_worker_key.sh`, `apply_zshrc_ssh_agent.sh`, and `restart_all_machines.sh`
are all idempotent — safe to re-run.

## Provisioning a fleet: deploy layout, excludes, verification

Rules for `setup_all_machines.sh` / `setup_hemem.sh`. Getting these wrong fails
*silently* — the driver still reports `OK` and the breakage only surfaces hours
later when jobs start running.

- **`DEPLOY_DIR` must be passed explicitly.** Its built-in default points at a
  path that does not exist on a fresh head node, and the sanity check aborts.
  Here it is `$HOME/working`.
- **Cache the raw datasets on `/proj` before you lose a node.** ~96 G of
  `~/working` is regenerable data (75 G gapbs graphs + 21 G kdd12) that dies with
  the local disk. Re-deriving it means two large external downloads (a GitHub
  release for the twitter traces, a university web server for kdd12) plus a slow
  conversion. Stashing just the *raw inputs* — the twitter `.gz` files (6.1 G)
  and `kdd12` (21 G), 27 G total — fits `/proj`'s free space and skips both
  downloads; conversion still runs. The 44.5 G of derived graphs is not worth
  caching: with `raw/` absent, `make` re-downloads anyway.
- **The deploy root IS `~/working`.** `setup_hemem.sh` unpacks it into
  `$HOME/working/` on the worker, keeping the remote layout at
  `$HOME/working/{regent,workloads}` — what every job command and
  `distribute_regent.sh` assume. Unpacking into `$HOME` instead flattens
  `regent/`+`workloads/` into the home dir and breaks all of them.
- **`mount_scratch.sh` runs first** and makes `~/working` a symlink onto the 1 TB
  `/dev/sdb`, so the deploy lands on scratch rather than the ~440 G root. The
  mount point is **`/mydata`**.
- **Never exclude a directory you have not run `git ls-files` on.**
  `EXPJOBSERVER_RSYNC_EXCLUDES` (space-separated, anchor with a leading `/`)
  skips bulk data the worker can regenerate. The trap is directories that mix
  generated data with *tracked build files*: `gapbs/benchmark` is 75 G of graphs
  **plus `bench.mk`**, an 8 K Makefile fragment that `gapbs/Makefile` includes
  unconditionally. Excluding the parent removed it and every `make` in gapbs died
  with `No rule to make target 'benchmark/bench.mk'` across the whole fleet.
  Also confirm the data really is cheap to regenerate — `make bench-graphs` does
  not synthesize graphs, it `wget`s ~6.3 G of traces and converts them.
  Known-good exclude set is **kdd12 only** (it re-downloads cleanly in ~17 min):
  `EXPJOBSERVER_RSYNC_EXCLUDES='/workloads/liblinear-2.47/kdd12'`
- **Submodules**: `workloads/setup.sh` `prereqs()` runs
  `git submodule update --init --recursive --force`. Both flags earn their keep —
  `--recursive` because builds `cd` into nested content (`build_npb` needs
  `NPB-CPP/libs/tbb-2020.1`), and `--force` because a plain update is a **no-op
  when the recorded SHA already matches even if the worktree has been emptied**.
  That is how an empty NPB-CPP shipped to a whole fleet while `git submodule
  status` reported it clean.
- **Verify; do not trust the summary.** A host is marked `OK` when the *driver*
  exits cleanly, not when the workloads actually build. Check per-workload exit
  codes, where `rc != 0` is a real failure:
  ```sh
  ssh node1 'cat ~/working/workloads/setup_logs/*.status'   # name|rc|seconds
  ```
  Sanity-check the physical evidence too: a fleet finishing suspiciously fast
  (~28 min) or having written only ~27 G to `/mydata` means big builds were
  skipped, not that everything went well.
- **`setup_hemem.sh` hard-aborts a host when `msr-tools` is missing** — by
  design. Without `wrmsr` the bandwidth emulation silently no-ops and every
  result from that node is invalid. A `FAILED` host is more often this guard
  firing than a broken machine, so read the log before re-running.

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
