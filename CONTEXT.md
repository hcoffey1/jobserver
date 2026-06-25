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
