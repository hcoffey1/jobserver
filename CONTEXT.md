# expjobserver

A job server that schedules experiment commands onto a pool of remote test
machines over SSH and copies their results back. This glossary fixes the
vocabulary used across the server, client, and wrapper.

## Language

**Job**:
A single experiment command scheduled to run on one machine of a given class.
Has its own id (`jid`), captured variables, optional results destination, and a
lifecycle state machine.
_Avoid_: process, run, experiment (when you mean the unit of scheduling).

**Setup Task**:
A job-like task that runs setup commands against a *specific* named machine and,
on success, adds that machine to a class. Shares the state machine with Jobs but
is not scheduled by class.
_Avoid_: provisioning job, init job.

**Class**:
A label grouping interchangeable machines. A Job names a class; the server runs
it on any free machine in that class.
_Avoid_: pool, group, queue, tag.

**Machine**:
A remote host (`hostname:port`) that can run jobs. Belongs to exactly one class;
is either free or running one job.
_Avoid_: node, worker, server (which means the scheduler itself).

**Runner**:
The executable the server invokes to actually run a job's command
(`RUNNER --print_results_path <cmd...>`). In this fork it is
`expjobserver_remote_wrapper.sh`, which SSHes to the target machine.
_Avoid_: executor, driver, agent.

**Variable**:
A `{NAME}` placeholder substituted into a command string before it runs.
Server-wide variables are set with `j var set`; matrix variables come from a
Matrix; `{MACHINE}` is the special variable for the chosen host. Resolved on the
server — *not* an OS environment variable on the remote.
_Avoid_: env var, parameter, macro.

**Matrix**:
A set of jobs generated from the cartesian product of one or more Variables over
lists of values, sharing one command template.
_Avoid_: sweep, grid, batch.

**Tag**:
An organisational label grouping arbitrary jobs together for bulk status. Purely
for the operator; does not affect scheduling.
_Avoid_: label, group (which means Class).

**Results destination** (`cp_results`):
The local directory a Job's results are rsynced into after it finishes.
_Avoid_: output dir, sink.

**RESULTS line**:
The convention `RESULTS: <path>` printed to a job's stdout that tells the server
which remote path to copy back.
_Avoid_: output marker.

**Hold**:
A state in which a waiting Job is prevented from being scheduled until released
(unheld).
_Avoid_: pause, suspend.

**Snapshot**:
The server's full state serialized to disk (protobuf) so it survives restarts.
_Avoid_: dump, backup, checkpoint.

**Campaign**:
A named set of Jobs answering one experimental question, identified by its
`RUN_TAG` — which fixes both the per-workload `MASTER_DIR` root on the workers
(`~/working/sweep_runs_<tag>/`) and the Results destination here
(`./sweep_results_<tag>/`). A fresh tag means every cell starts from scratch
wherever the scheduler places it; re-dispatching an existing tag resumes,
skipping completed cells.
_Avoid_: run, batch, study, experiment.

**Arm**:
One configuration under comparison within a Campaign — a *(source tree, runtime
knobs)* pair. Two Arms differing only in knobs share a built `.so`; two Arms
differing in source tree must not, because the cached lib is named
`libarms_kernel_<MODE_TAG>.so` where `MODE_TAG` encodes clustering mode and
bucket boundary but **not** the source branch. Pointing two source-tree Arms at
one `LIB_CACHE_DIR` silently measures the first Arm twice.
_Avoid_: variant, condition, policy (which names a runtime knob value, one
possible axis of an Arm), version.

**Cell**:
One *(Arm, ratio, iteration)* triple — a single workload execution. A Campaign's
size is `workloads × arms × ratios × iters` Cells.
_Avoid_: run, point, trial.

**Baseline tree**:
The second regent checkout on a worker (`~/working/regent_base`), holding the
Arm being compared *against*, distinct from the primary Deploy directory tree at
`~/working/regent`. Selected per Cell via `ARMS_DIR`, with its own
`LIB_CACHE_DIR`. Exists so every Arm of a workload runs on one Machine inside
one Job, removing Machine identity and campaign-time drift as confounds.
_Avoid_: fork, copy, mirror.

**Deploy directory**:
The local source tree (e.g. `.../deploy/working/`) holding the `regent` and
`workloads` repos that `add_machine.sh` rsyncs onto a Machine during setup. The
authoritative copy of experiment code that lives off the server. Maps to
`~/working/{regent,workloads}` on each Machine. **One deploy tree per repo is
the norm, but not a guarantee**: a multi-Arm Campaign also places a Baseline
tree alongside it (see Arm).
_Avoid_: workspace, repo root.

**Distribute**:
Propagating updated `regent`/`workloads` source from the Deploy directory to
already-registered Machines, out-of-band of the Job pipeline — distinct from
Setup, which provisions a *new* Machine. Pulls the top-level repos, rsyncs to
each Machine in parallel, and rebuilds where needed.
_Avoid_: deploy, sync, push (as a bare verb), redeploy.

## Relationships

- A **Campaign** is a set of **Jobs**, one per workload, sharing a `RUN_TAG`
- A **Job** runs every **Cell** for its workload on exactly one **Machine**
- A **Cell** is one *(Arm, ratio, iteration)* triple
- An **Arm** names a source tree (Deploy directory or **Baseline tree**) plus its
  runtime knobs; each source tree needs its own `LIB_CACHE_DIR`
- **Distribute** delivers the Deploy directory; a multi-Arm Campaign additionally
  delivers a **Baseline tree**

## Flagged ambiguities

- "wave" was used in `add_sweep_jobs_fallback.sh` to mean *a sequential
  re-dispatch that appends a new Arm into an existing tree*. It is now also
  reachable as *a scheduling batch forced by having fewer Machines than
  workloads*. Resolved: **wave** means only the latter (a scheduling
  consequence, invisible to the results); adding an Arm to an existing Campaign
  is a **re-dispatch**, and Arms that must be compared against each other belong
  in the same **Job**, not in successive re-dispatches.
- "policy" was doing double duty for a runtime knob value
  (`cluster_dram_sens_bucket`) and for a thing being A/B'd. Resolved: the unit of
  comparison is an **Arm**; a policy is one axis an Arm may vary, alongside the
  source tree.
