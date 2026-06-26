# Distribute regent/workloads updates to registered machines via a standalone script

We need to push changes to the `regent` and `workloads` source onto machines
that are already registered with the job server, without re-running the full
`add_machine.sh` provisioning path. A standalone `scripts/distribute_regent.sh`
does this: it reads the machine list from `j machine ls`, then in parallel pulls,
rsyncs, and (for regent) rebuilds on each machine. The following choices are the
non-obvious ones.

## Decisions

- **Pull the top-level repos and update submodules to their pinned commits —
  except `silo`.** `regent` and `workloads` are two separate clones (remotes
  `tiering_solutions.git` and `workloads.git`). After `git pull`, run
  `git -c submodule.silo.update=none submodule update --init --recursive` so
  updated submodules are picked up, while `silo` is left untouched (it carries a
  build-time patch and is built on the machine). `submodule update` refuses to
  clobber a submodule with local edits, so a dirty submodule surfaces as an error
  rather than being silently overwritten — consistent with the abort-on-dirty
  rule below.

- **Abort if a local repo is dirty or can't fast-forward.** The Deploy directory
  is hand-edited (e.g. `setup.sh` lives in `workloads`). Rather than auto-stash,
  rebase, or silently merge, the script refuses to distribute and names the dirty
  repo/files, so an in-progress edit is never discarded or pushed half-finished.
  The operator commits/stashes and re-runs.

- **rsync workloads top-level + all submodules *except* `silo`.** Submodules are
  built on the machine; `silo` additionally carries a build-time patch applied
  from `workloads/patches/`, so overwriting `silo/` would break the built+patched
  state there. Every other submodule (and any newly added one) is copied so its
  source lands on the machine; `--exclude='/silo'` and `--exclude='.git'`, no
  `--delete`. Note: distribute *copies* new submodule source but does not build
  it — a brand-new workload still needs a `setup.sh` run to compile.

- **Sync to both the live (`~/working/`) and staging
  (`/deploy/add_machine/deploy/working/`) copies.** `setup_hemem.sh` runs on the
  machine and rsyncs the staging tree into `$HOME`, then builds — so the live,
  job-running copy is `~/working/{regent,workloads}`, and that is what must be
  updated (and where regent is rebuilt). The staging copy is refreshed too so a
  later re-run of `setup_hemem.sh` (which rsyncs staging→home without `--delete`)
  can't silently revert a distributed update with a stale staging tree.

- **Rebuild regent with `make clean && make`; do not build workloads.** regent is
  compiled, so a source change has no effect until rebuilt; a clean build avoids
  stale-object inconsistency. workloads top-level is interpreted scripts and needs
  no build. `--no-build` skips the regent rebuild for script-only changes.

- **Skip machines currently running a job; `--force` to include.** This is a live
  job server (`j machine ls` shows the running job per machine). rsync + `make
  clean` on a busy machine would corrupt an in-flight experiment, so busy machines
  are skipped and reported by default.

- **Target all registered machines, with optional `--class` / explicit hosts.**
  The common case is "update them all"; filtering is opt-in.

## Consequences

- Distribution is idempotent for unchanged trees (rsync moves only changed files;
  no `--delete`), and safe to re-run after fixing a dirty-tree abort.
- The script depends on `j machine ls` output format and reuses
  `EXPJOBSERVER_SSH_USER` / `EXPJOBSERVER_SSH_OPTIONS`, the `host:port` parsing,
  and the staging path (`/deploy/add_machine/deploy/`) established by
  `add_machine.sh` plus the live `~/working/` location established by
  `setup_hemem.sh`; those are now a shared contract across all three scripts.
