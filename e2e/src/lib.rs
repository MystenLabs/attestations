//! Snapshot of the attestation state that `e2e/run.sh` leaves on its localnet.
//!
//! [`chain`] reads that state the way a consumer would, and [`snapshot`]
//! renders it as readable text, which `tests/attestation_state.rs` checks with
//! insta.

pub mod chain;
pub mod snapshot;

use std::thread::sleep;
use std::time::{Duration, Instant};

use anyhow::{Result, bail};

/// Call `check` every `interval` until it returns a value, or fail after
/// `timeout` with an error naming `what` was being waited for.
pub(crate) fn wait_for<T>(
    what: &str,
    timeout: Duration,
    interval: Duration,
    mut check: impl FnMut() -> Result<Option<T>>,
) -> Result<T> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(value) = check()? {
            return Ok(value);
        }
        if Instant::now() >= deadline {
            bail!("timed out after {timeout:?} waiting for {what}");
        }
        sleep(interval);
    }
}
