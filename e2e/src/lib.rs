//! Snapshot of the attestation state that lives on the localnet once
//! `e2e/run.sh` has run.
//!
//! [`chain`] reads that state through GraphQL, the way a consumer would, and
//! [`snapshot`] renders it as readable text, which `tests/attestation_state.rs`
//! checks with insta.

use std::thread::sleep;
use std::time::Duration;
use std::time::Instant;

use anyhow::Result;
use anyhow::bail;

pub mod chain;
pub mod snapshot;

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
