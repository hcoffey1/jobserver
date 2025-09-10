//! A thread that copies results back to the host machine and notifies the server of completion.

use log::{debug, error, info, warn};

use std::collections::{HashMap, LinkedList};
use std::process::{Child, Command, Output, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Timeout on the copy task in minutes.
const RSYNC_TIMEOUT: u64 = 60;
/// Passed to rsync's --timeout option.
const RSYNC_IO_TIMEOUT: u64 = 60; // seconds
/// The number of times to retry before giving up.
const RETRIES: usize = 3;
/// The max number of concurrent copy jobs.
const MAX_CONCURRENCY: usize = 2;

/// (jid, machine, from_path, to_path, attempt)
pub type CopierThreadQueue = LinkedList<CopyJobInfo>;

#[derive(Clone, Debug)]
pub struct CopyJobInfo {
    pub jid: u64,
    pub machine: String,
    pub from: String,
    pub to: String,
    pub attempt: usize,
}

/// Internal state of the copier thread. This basically just keeps track of in-flight copies.
#[derive(Debug)]
struct CopierThreadState {
    /// Copy tasks that have not been started yet.
    incoming: Arc<Mutex<CopierThreadQueue>>,
    /// Copy tasks that are currently running.
    ongoing: HashMap<u64, ResultsInfo>,
    /// Used to notify the worker thread of completion.
    copying_flags: Arc<Mutex<HashMap<u64, CopierThreadResult>>>,
}

/// Possible outcomes for copying of results.
#[derive(Debug)]
pub enum CopierThreadResult {
    Success,
    SshUnknownHostKey,
    OtherFailure,
}

/// Info about a single copy job.
#[derive(Debug)]
struct ResultsInfo {
    /// The job we are copying results for.
    jid: u64,
    /// The machine to copy results from.
    machine: String,
    /// The path on `machine` to copy from.
    from: String,
    /// The path on the host to copy to.
    to: String,
    /// The process currently doing the copy.
    process: Child,
    /// The time when the process was started.
    start_time: Instant,
    /// The current attempt number.
    attempt: usize,
}

impl std::hash::Hash for ResultsInfo {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.jid.hash(state)
    }
}

impl std::cmp::PartialEq for ResultsInfo {
    fn eq(&self, other: &Self) -> bool {
        self.jid == other.jid
    }
}
impl std::cmp::Eq for ResultsInfo {}

/// Start the copier thread and return a handle.
pub fn init(
    copying_flags: Arc<Mutex<HashMap<u64, CopierThreadResult>>>,
) -> (std::thread::JoinHandle<()>, Arc<Mutex<CopierThreadQueue>>) {
    let incoming = Arc::new(Mutex::new(LinkedList::new()));
    let state = CopierThreadState {
        incoming: incoming.clone(),
        ongoing: HashMap::default(),
        copying_flags,
    };

    (std::thread::spawn(|| copier_thread(state)), incoming)
}

/// Inform the copier thread to copy the given results from the given machine to the given
/// location. This will kill any pre-existing copy task for the same jid.
pub fn copy(queue: Arc<Mutex<CopierThreadQueue>>, task: CopyJobInfo) {
    queue.lock().unwrap().push_back(task);
}

/// The main routine of the copier thread.
fn copier_thread(mut state: CopierThreadState) {
    // We loop around checking on various tasks.
    loop {
        // Sleep a bit. This prevents wasted CPU and hogging locks.
        std::thread::sleep(Duration::from_secs(1));

        // Check for new tasks to start if we have capacity.
        if state.ongoing.len() < MAX_CONCURRENCY {
            while let Some(new) = state.incoming.lock().unwrap().pop_front() {
                let jid = new.jid;

                // If there is an existing task, kill it.
                if let Some(mut old) = state.ongoing.remove(&jid) {
                    let _ = old.process.kill();
                }

                match start_copy(new.clone()) {
                    // If success, good.
                    Ok(results_info) => {
                        state.ongoing.insert(jid, results_info);
                    }

                    // Otherwise, re-enqueue and try again later.
                    Err(err) => {
                        error!(
                            "Unable to start copying process for job {}. Re-enqueuing. {}",
                            jid, err,
                        );
                        state.incoming.lock().unwrap().push_back(new);
                    }
                }
            }
        }

        if !state.ongoing.is_empty() {
            debug!("Ongoing copy jobs: {:?}", state.ongoing);
        }

        // Check on ongoing copies. If they are taking too long, restart them. If they are
        // complete, notify the worker thread.
        let mut to_remove = vec![];
        for (jid, results_info) in state.ongoing.iter_mut() {
            match results_info.process.try_wait() {
                Ok(Some(exit)) if exit.success() => {
                    info!("Finished copying results for job {}.", jid,);
                    state
                        .copying_flags
                        .lock()
                        .unwrap()
                        .insert(*jid, CopierThreadResult::Success);
                    to_remove.push(*jid);
                }
                Ok(Some(exit)) => {
                    warn!(
                        "Copying results for job {} failed with exit code {} (attempt {}).",
                        jid, exit, results_info.attempt
                    );

                    // Check for unknown host key SSH error and report a special error for that.
                    // First, we can do a quick check: if SSH experienced an error, we will get
                    // exit code 255. If that is the error code, we can use ssh-keygen to check if
                    // there is a known fingerprint.
                    if let Some(255) = exit.code() {
                        let fingerprint_found = Command::new("ssh-keygen")
                            .arg("-F")
                            .arg(&results_info.machine)
                            .stdout(Stdio::piped())
                            .stderr(Stdio::piped())
                            .output();

                        // If there is a failure here, we will just move on and let the normal
                        // retry mechanism handle it.
                        if let Ok(Output { status, .. }) = fingerprint_found {
                            if let Some(1) = status.code() {
                                // Unknown host error. Report the error and move on. Retrying is
                                // not useful.
                                error!(
                                    "Error copy results for job {}: SSH host key verification \
                                     failed. Add the host to known_hosts.",
                                    jid
                                );

                                state
                                    .copying_flags
                                    .lock()
                                    .unwrap()
                                    .insert(*jid, CopierThreadResult::SshUnknownHostKey);
                                to_remove.push(*jid);
                                continue;
                            }
                        }
                    }

                    // Maybe retry.
                    if results_info.attempt < RETRIES {
                        state.incoming.lock().unwrap().push_back(CopyJobInfo {
                            jid: results_info.jid,
                            machine: results_info.machine.clone(),
                            from: results_info.from.clone(),
                            to: results_info.to.clone(),
                            attempt: results_info.attempt + 1,
                        });
                    } else {
                        error!(
                            "Copying results for job {} failed after {} attempts.",
                            jid, RETRIES
                        );
                        state
                            .copying_flags
                            .lock()
                            .unwrap()
                            .insert(*jid, CopierThreadResult::OtherFailure);
                    }
                    to_remove.push(*jid);
                }
                Err(err) => {
                    error!("Error copy results for job {}: {}", jid, err);

                    // Maybe retry.
                    if results_info.attempt < RETRIES {
                        state.incoming.lock().unwrap().push_back(CopyJobInfo {
                            jid: results_info.jid,
                            machine: results_info.machine.clone(),
                            from: results_info.from.clone(),
                            to: results_info.to.clone(),
                            attempt: results_info.attempt + 1,
                        });
                    } else {
                        error!(
                            "Copying results for job {} failed after {} attempts.",
                            jid, RETRIES
                        );
                        state
                            .copying_flags
                            .lock()
                            .unwrap()
                            .insert(*jid, CopierThreadResult::OtherFailure);
                    }
                    to_remove.push(*jid);
                }
                Ok(None) => {
                    let timed_out = (Instant::now() - results_info.start_time)
                        >= Duration::from_secs(RSYNC_TIMEOUT * 60);

                    // If timed out maybe retry
                    if timed_out {
                        warn!("Copying results for job {} timed out.", jid);
                        if results_info.attempt < RETRIES {
                            state.incoming.lock().unwrap().push_back(CopyJobInfo {
                                jid: results_info.jid,
                                machine: results_info.machine.clone(),
                                from: results_info.from.clone(),
                                to: results_info.to.clone(),
                                attempt: results_info.attempt + 1,
                            });
                        } else {
                            error!(
                                "Copying results for job {} failed after {} attempts.",
                                jid, RETRIES
                            );
                            state
                                .copying_flags
                                .lock()
                                .unwrap()
                                .insert(*jid, CopierThreadResult::OtherFailure);
                            to_remove.push(*jid);
                        }
                    } else {
                        info!(
                            "Still copying results for job {}, attempt {}.",
                            jid, results_info.attempt
                        );
                    }
                }
            }
        }

        for jid in to_remove.drain(..) {
            state.ongoing.remove(&jid);
        }
    }
}

/// Start copying some results.
fn start_copy(
    CopyJobInfo {
        jid,
        machine,
        from,
        to,
        attempt,
    }: CopyJobInfo,
) -> Result<ResultsInfo, std::io::Error> {
    // Copy via rsync
    info!(
        "Copying results (job {}; attempt {}) to {}",
        jid, attempt, to
    );

    // HACK: assume all machine names are in the form HOSTNAME:PORT.
    let machine_ip = machine.split(":").next().unwrap();

    // Get SSH user from environment variable, default to current user
    let ssh_user = std::env::var("EXPJOBSERVER_SSH_USER")
        .unwrap_or_else(|_| {
            std::env::var("USER")
                .or_else(|_| std::env::var("USERNAME"))
                .unwrap_or_else(|_| "root".to_string())
        });

    // Get SSH options from environment variable, with sensible defaults
    // let ssh_options = std::env::var("EXPJOBSERVER_SSH_OPTIONS")
    //     .unwrap_or_else(|_| "-o StrictHostKeyChecking=yes".to_string());

    let log = std::fs::OpenOptions::new()
        .truncate(false)
        .create(true)
        .write(true)
        .open(copier_log_fname(jid))
        .expect("Unable to open rsync log file.");
    let log_err = log.try_clone().expect("Unable to open rsync log err file.");

    // SSH will hang waiting for StrictHostKeyChecking to get user input confirming the key
    // fingerprint. Instead, we tell SSH to just fail fast. We can then check for the error and
    // report it properly to the user.
    let mut cmd = Command::new("rsync");
    let cmd = cmd
        .arg("-avvzP")
        .args(&["-e", "ssh -o StrictHostKeyChecking=yes"])
        .arg(&format!("--timeout={}", RSYNC_IO_TIMEOUT))
        .arg(&format!("{}@{}:{}*", ssh_user, machine_ip, from))
        .arg(&to)
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));

    debug!("{:?}", cmd);

    let process = cmd.spawn()?;

    Ok(ResultsInfo {
        jid,
        machine,
        from,
        to,
        process,
        start_time: std::time::Instant::now(),
        attempt,
    })
}

fn copier_log_fname(jid: u64) -> String {
    const RSYNC_LOG_PATH: &str = "/tmp/jobserver-rsync";
    format!("{}-{}.log", RSYNC_LOG_PATH, jid)
}
