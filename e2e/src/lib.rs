//! Snapshot of the attestation state that lives on the localnet once
//! `e2e/run.sh` has run.
//!
//! [`chain`] reads that state through GraphQL, the way a consumer would, and
//! [`snapshot`] renders it as readable text, which `tests/attestation_state.rs`
//! checks with insta.

use std::future::Future;
use std::time::Duration;
use std::time::Instant;

use anyhow::Result;
use anyhow::ensure;
use tokio::time::sleep;

pub mod chain;
pub mod snapshot;

/// Call `check` every `interval` until it returns a value, or fail after
/// `timeout` with an error naming `what` was being waited for.
pub(crate) async fn wait_for<T, F, Fut>(
    what: &str,
    timeout: Duration,
    interval: Duration,
    mut check: F,
) -> Result<T>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<Option<T>>>,
{
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(value) = check().await? {
            return Ok(value);
        }
        ensure!(
            Instant::now() < deadline,
            "timed out after {timeout:?} waiting for {what}"
        );
        sleep(interval).await;
    }
}
