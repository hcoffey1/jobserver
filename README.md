# `expjobserver`

![Screenshot of `j job ls`](screenshot.png)

This is a job server and client for running many experiments across many test
machines. In some sense, it is like a simple cluster manager.

The high-level idea is that you have a server (the `expjobserver`) that runs on
your machine (some machine that is always on, like a desktop), perhaps in a
screen session or something. You have a bunch of experiments that you want to
run from some driver application or script. You also have a bunch of machines,
possibly of different types, where you want to run jobs. `expjobserver` schedules
those jobs to run on those machines and copies the results back to the host
machine (the one running the server). One interracts with the server using the
stateless CLI client.

Additionally, `expjobserver` supports the following:
- An awesome CLI client, with the ability to generate shell completion scripts.
- Machine classes: similar machines are added to the same class, and jobs are
  scheduled to run on any machine in the class.
- Machine setup: the `expjobserver` can run a sequence of setup machines and
  automatically add machines to its class when finished.
- Job matrices: Run jobs with different combinations of parameters.
- Automatically copies results back to the host, as long as the experiment
  driver outputs a line to `stdout` with format `RESULTS: <OUTPUT FILENAME>`.
- Good server logging.
- Tries to be a bit resilient to failures, crashes, and mismatching
  server/client version by using protobufs to save server history and
  communicate with client"

# Prerequisites

- `rust 1.37+`

# Installing

```sh
cargo install expjobserver
```

This will install both the client (`j`) and server (`expjobserver`).

# Building

These commands both build client and server:

```sh
# Debug
cargo build

# Release
cargo build --release
```

In practice, it doesn't matter, as I've disable optimizations and added
debuginfo for the release build too. The reason is that performance doesn't
matter that much here (and the server isn't performance-optimized anyway),
whereas debuggability is very helpful.

# Usage

## Running the server

```sh
expjobserver \
  /path/to/experiment/driver \
  /path/to/logs/ \
  /path/to/log4rs/config.yaml
```

The first time you run it, you will need to pass the `--allow_snap_fail` flag,
which allows overwriting server history. The default is to fail and exit if
loading history fails. It is intended to give a little bit of safety so that if
you restart in a weird configuration it won't wipe out your server's history,
which can be annoying.

You may want to run the server in a `screen` or `tmux` session. That way, you
can detach and leave it running in the background. You can always check the
logs by either attaching again or looking at `/path/to/logs` from the command,
where the server will dump debug logs.

The server uses the [`log4rs`][l4rs] library for logging. It is highly configurable.
[`example.log.yml`](./example.log.yml) is a reasonable config that I use.
To use it, point the server to it using the second argument in the command.

[l4rs]: https://crates.io/crates/log4rs

## Running the client

```sh
j --help
```

There are a lot of subcommands. They are well-documented by the CLI usage message.

# Examples

This is mostly intended as a quick tour of what you can do (for the client side).
It's not comprehensive. Read the usage message (`--help`) for more info on all
the things you can do. There are a lot of nifty features!

## Adding machines to the pool

First, let's list the machines in the pool.

```console
$ j machine ls


```

Currently, there are none. Let's add some. If we have machine already set up,
we can use `j machine add`, but we can also have a machine run a setup script
and be automatically added to the pool afterwards.

```console
$ j machine setup --class foo -m my.machine.foo.com:22 -- "setup-the-thing {MACHINE} --flag --blah" "another-setup-command"
Server response: Jiresp(
    JobIdResp {
        jid: 0,
    },
)
```

Here `{MACHINE}` is replaced automatically by `my.machine.foo.com:22`. You can
also use other variables (see the `j var` commands). This can help in a few ways:

- `{MACHINE}` allows you to use the same command for multiple machines (you can
  pass `-m` multiple times).
- You can use other variables to minimize the number of secrets that end up in
  your bash history (e.g. if you need a github token or something).

At this point, the machine `my.machine.foo.com:22` will start running the
listed commands in the given order. Assuming that they all succeed, the machine
will be added to the `foo` class in the pool and will be ready to run any jobs
that request a `foo`-class machine.

## Listing and Enqueuing Jobs

The `jid: 0` in the server response above is the job ID of the setup task. We
can see the currently running tasks, including setup tasks.

```console
$ j job ls
 Job   Status  Class  Command                                  Machine                Output
   0  Running  foo    setup-the-thing {MACHINE} --flag --blah  my.machine.foo.com:22
```

Currently, the only thing running so far is the setup task we started above.

We can queue up some other jobs for `foo`-class machines to run on it when ready:

```console
$ j job add foo "bar --the --foo baz" /path/to/results/dir -x 3
Server response: Jiresp(
    JobIdResp {
        jid: 1,
    },
)
Server response: Jiresp(
    JobIdResp {
        jid: 2,
    },
)
Server response: Jiresp(
    JobIdResp {
        jid: 3,
    },
)
```

Here we enqueue 3 identical tasks to run on the first available `foo` machine.
The jobs run in the enqueued order.

```console
$ j job ls
 Job   Status  Class  Command                                  Machine                Output
   0     Done  foo    setup-the-thing {MACHINE} --flag --blah  my.machine.foo.com:22
   1  Running  foo    bar --the --foo baz                      my.machine.foo.com:22
   2  Waiting  foo    bar --the --foo baz
   3  Waiting  foo    bar --the --foo baz
```

We can look at the job's stdout (using `tail`):

```console
j job log -t 1
```

where `1` is the job ID from the table above for the running task. You can also
look at the log of completed tasks or get the path of the log file:

```console
$ j job log -l 0                # look at the log of 0 with `less`
...

$ j job log 0                   # path to the log file
/some/path/0-setup-the-thing_my.machine.foo.com:22_--flag_--blah
```

## Job Matrices

Sometimes you want to run a bunch of similar commands with slight variations
(e.g. to see the effect of varying a parameter).

You can do this with `j job matrix`:

```sh
j job matrix add foo "my-experiment-cmd --param0 {I} --param1 {J} --param2 {K}" \
    /path/to/copy/results/ I=1,2,3,4 J=linear,quadratic,exotic K=banana,rockingchair,airplane
```

This command will enqueue 4x3x3 = 36 jobs, which you can see with `j job ls` or
`j job matrix stat`.

Moreover, you can dump a CSV of the matrix and any results paths using `j job matrix csv`.

## More

Take a look at the `--help` message for the various commands and subcommand to
learn about even more goodies.

---

# Addendum: how *this* fork is actually used (remote SSH wrapper)

The upstream README above describes the generic server. This fork drives it with
a **remote SSH wrapper** so that jobs run on freshly-reserved CloudLab machines.
This section documents the real, day-to-day workflow. For domain vocabulary see
[`CONTEXT.md`](./CONTEXT.md); for an illustrated architecture walkthrough open
[`docs/architecture.html`](./docs/architecture.html) in a browser.

## The mental model

A **job is a single command string** scheduled onto any free machine in a
**class**. You schedule it with:

```sh
j job add <CLASS> "{MACHINE} <command> <args...>" [RESULTS_DIR]
```

What happens to that string:

1. The server substitutes `{VAR}` (server-side variables) and `{MACHINE}` (the
   host it picked) into the command.
2. It runs `RUNNER --print_results_path <command tokens...>`, where `RUNNER` is
   [`expjobserver_remote_wrapper.sh`](./expjobserver_remote_wrapper.sh).
3. The wrapper takes the **first token as the target host** (that is why every
   command begins with `{MACHINE}`), SSHes in, and runs the rest.
4. If the job prints a line `RESULTS: <path>` to stdout, the server rsyncs that
   path back into `RESULTS_DIR`.

So your "bash script + command-line arguments" model is exactly right. Two ways
to supply the script:

- **A script already on the machine** (e.g. `~/workloads/run.sh`) — run directly
  over SSH. This is what `scripts/hemem_baseline.sh` and `scripts/run_pebs.sh`
  do.
- **A local script file** — if the first token after `{MACHINE}` is a path that
  exists *locally*, the wrapper `scp`s it up and runs it with your args.

Real example (from `scripts/hemem_baseline.sh`):

```sh
j job add foo "{MACHINE} ~/workloads/run.sh -b graph500 -w graph500 -o results/baseline -r 3" ./hemem_baseline_bwmon
```

## "Env variables" = template variables, not OS env

The system has no concept of exported shell environment variables for a job.
Its only notion of "variables" is **`{VAR}` template substitution into the
command string**, resolved on the server before SSH:

- `j var set TOKEN abc123` → every `{TOKEN}` in future commands becomes `abc123`
  (handy for keeping secrets out of bash history).
- **Job matrices** sweep the cartesian product of variable lists:

  ```sh
  j job matrix add foo "{MACHINE} ~/workloads/run.sh -b {BENCH} -i {INTERVAL}" \
      ./results BENCH=graph500,flexkvs INTERVAL=1000,2000
  ```

  This enqueues 2×2 = 4 jobs. Inspect with `j job matrix stat <id>` and dump a
  CSV of results paths with `j job matrix csv <id>`.

If you need a *real* environment variable on the remote, bake it into the
command: `"{MACHINE} FOO=bar ~/workloads/run.sh ..."`.

## Important constraint: one command, no shell operators

The server splits the command on whitespace and the wrapper replays the tokens
as `"$@"` on the remote. **Shell operators (`&&`, `||`, `|`, `>`, `;`) do not
work inside a job command** — they are passed as literal arguments. Each job is
a single program invocation. For multi-step logic, put it inside the script you
invoke (`run.sh`) and call that.

## Result collection

A job's results are copied back only if its stdout contains a line:

```
RESULTS: /absolute/or/relative/path/on/remote
```

The wrapper also auto-detects files written into a `results/` subdirectory of
its per-job working dir (`$EXPJOBSERVER_REMOTE_WORKDIR/<job_id>/results`) and
emits the `RESULTS:` line for you. The server then rsyncs that path into the
`RESULTS_DIR` you passed to `j job add`.

## Configuration

The wrapper sources two files (resolved relative to the wrapper, so the server's
working directory doesn't matter):

- [`example_config.sh`](./example_config.sh) — **tracked** defaults. Every value
  uses `${VAR:-default}`, so your shell exports win.
- `config.local.sh` — **gitignored** local overrides (real SSH username/hosts).
  Sourced after the defaults, so it wins. Create your own; an example:

  ```sh
  export EXPJOBSERVER_SSH_USER="hjcoffey"
  ```

Recognised variables: `EXPJOBSERVER_SSH_USER`, `EXPJOBSERVER_SSH_OPTIONS`,
`EXPJOBSERVER_REMOTE_WORKDIR`.

## Adding & provisioning a machine

`scripts/add_machine.sh` provisions a freshly-reserved machine end-to-end:
optionally resize the root partition (reboots and waits for reconnect), rsync a
deploy directory, run a setup script in a remote `tmux` session (survives local
disconnects, logs to `./logs/`), then register it with `j machine add`.

```sh
export EXPJOBSERVER_SSH_USER="hjcoffey"
./scripts/add_machine.sh c220g5-120111.wisc.cloudlab.us foo ./scripts/setup_hemem.sh \
    -d ~/school/grad/research/memregion/deploy -p -v -r
#   <host>                            <class> <setup script>     -p resize  -v keep .git  -r reinstall
```

Note: this script provisions the machine and registers it; it does **not** use
the SSH wrapper (that's only for `j job` execution). The two paths are separate.

## Updating code on registered machines (`distribute_regent.sh`)

Once machines are registered, `scripts/distribute_regent.sh` pushes updated
`regent`/`workloads` source to all of them. From a local deploy directory laid
out as `<deploy>/working/{regent,workloads}`, it:

1. `git pull --ff-only` both repos and updates submodules — **except `silo`**,
   which is patched/built on each machine (a dirty `silo` worktree is fine; any
   other uncommitted change aborts the run so you notice it).
2. rsyncs each repo to the live `~/working` tree on every machine, honoring
   `.gitignore` so only source (not built artifacts) is shipped (see below).
   Pass `--staging` to *also* mirror into the `/deploy/add_machine/deploy`
   staging tree (the re-provisioning source); off by default.
3. rebuilds `regent` on each machine (`make clean && make`), in parallel.

It discovers targets by reading `j machine ls`, and **skips machines currently
running a job** (use `--force` to include them).

**What gets synced.** The rsyncs use `--filter=':- .gitignore'`, so each
directory's `.gitignore` — *including the submodules' own* — is honored. Build
artifacts and generated datasets that the submodules ignore (e.g. `gapbs`'s
~45 GB of compiled binaries plus `benchmark/graphs/`) are **not** shipped; the
machine builds/regenerates them itself, the same reason `silo` is excluded.
There is no `--delete`, so whatever a machine already built stays in place. In
practice this shrinks a full `workloads` sync from ~78 GB to ~1.2 GB.

```sh
# Point --deploy at the dir whose working/{regent,workloads} hold the source.
# EXPJOBSERVER_CLIENT is needed unless `j` is on your PATH (it isn't by default).
EXPJOBSERVER_CLIENT=./target/debug/j \
  ./scripts/distribute_regent.sh -d ~

EXPJOBSERVER_CLIENT=./target/debug/j \
  ./scripts/distribute_regent.sh -d ~ --class regent -j 16   # one class, 16 in parallel

EXPJOBSERVER_CLIENT=./target/debug/j \
  ./scripts/distribute_regent.sh -d ~ --no-build c220g5-111214.wisc.cloudlab.us
```

Key options: `--no-build` (skip the rebuild — right for a script-only change),
`--no-pull` (rsync the working trees as-is, skipping git), `--staging` (also
mirror into the staging tree — needed only to refresh the re-provisioning
source), `--class <name>`, `-j <N>` (parallelism), `--force`, and one or more
`HOST` args to restrict the targets. SSH to the machines must be passwordless (the repo's git remotes also
need to authenticate — switch them to SSH if they're HTTPS without stored creds).
Heads-up: a full `regent` rebuild can run tens of minutes; if your SSH access
relies on a **forwarded** agent, keep the forwarding session alive for the whole
run or the rebuild step will fail with `Permission denied (publickey)`.

### Checking progress

`distribute_regent.sh` is a plain local script, **not** a job — so it does
**not** appear in `j job ls`. As it runs it prints the target list up front and a
timestamped line per host as state changes (`RUN` → `BLD` → `OK`/`FAIL`), then a
per-host summary table at the end. It also writes durable artifacts under
`./logs/distribute-<timestamp>/` (the per-host `.log` files carry the live rsync
transfer progress, since the rsyncs run with `--info=progress2`):

```sh
# Is a run still in progress?
pgrep -af distribute_regent            # prints the process if running; empty when done

ld=$(ls -dt logs/distribute-* | head -1)   # most recent run's log dir
cat "$ld"/*.status                     # per host: "OK<TAB>secs" or "FAILED<TAB>rc<TAB>secs"
                                       #   (a host's .status file appears only when it finishes)
tail -f "$ld"/<host>.log               # live progress for one host (rsync, then rebuild output)
```

A run is done when `pgrep` finds nothing and every targeted host has a `.status`
file; `FAILED` rows point you at that host's `.log` for the cause.

## End-to-end quick start

```sh
# 1. Start the server with the remote wrapper as the RUNNER (first run needs --allow_snap_fail).
expjobserver ./expjobserver_remote_wrapper.sh ./logs/ ./example.log.yml --allow_snap_fail

# 2. Provision + register a machine into class "foo".
./scripts/add_machine.sh <host> foo ./scripts/setup_hemem.sh -d <deploy_dir> -p -v -r

# 3. Schedule jobs onto the class (note the leading {MACHINE}).
bash scripts/hemem_baseline.sh        # a batch of `j job add foo "{MACHINE} ..."` lines

# 4. Watch them.
j job ls
j job log -t <jid>     # tail a running job's stdout
```
