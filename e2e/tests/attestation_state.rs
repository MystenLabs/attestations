//! Checks the attestation state that `e2e/run.sh` leaves on its localnet
//! against the insta snapshot in `snapshots/`.
//!
//! It reads a live localnet, so run it through `bash e2e/run.sh`, which starts
//! one, runs the demo and the template walkthrough on it, and then runs this
//! test with the `E2E_*` variables set. When the run leaves a changed snapshot,
//! review it with `cargo insta review --manifest-path e2e/Cargo.toml`.

use std::path::Path;

use attestations_e2e::chain::Chain;
use attestations_e2e::snapshot::{Names, render};
use sui_sdk_types::Address;

/// The snapshot's header, for whoever reads it.
const DESCRIPTION: &str = "\
The attestation state e2e/run.sh leaves on its localnet. For each subject: the \
attestations at its active box and at its revoked address, both derived \
off-chain from the registry and subject ids, with their data and rendered \
Display; then every registry event, in order. Ids are replaced with names: a \
package's directory name, `name@vN` for version N of an upgraded package, or a \
label from the test. A line starting with `!!` marks an inconsistency.";

#[test]
fn attestation_state() {
    let state = read_state().unwrap_or_else(|e| panic!("{e:?}"));
    insta::with_settings!({
        description => DESCRIPTION,
        omit_expression => true,
        prepend_module_to_snapshot => false,
    }, {
        insta::assert_snapshot!(state);
    });
}

fn read_state() -> anyhow::Result<String> {
    let chain = Chain::new(env("E2E_GRAPHQL_URL"), env("E2E_RPC_URL"));
    chain.wait_for_indexer(&env("E2E_SENDER"))?;

    let mut names = Names::new();
    let registry_pkg = names.add_packages(Path::new(&env("E2E_PUBFILE")))?;
    let registry: Address = env("E2E_REGISTRY_ID").parse()?;
    names.add(registry, "registry");
    names.add(
        env("E2E_WALKTHROUGH_SUBJECT").parse()?,
        "walkthrough_subject",
    );

    // dependency_example@v2 is in the demo precisely to stay unaudited, so no
    // event names it; list it to check it stays empty.
    let extra_subjects = [names.address_of("dependency_example@v2")?];
    render(&chain, &mut names, registry, registry_pkg, &extra_subjects)
}

fn env(name: &str) -> String {
    std::env::var(name)
        .unwrap_or_else(|_| panic!("{name} is not set; run this test through `bash e2e/run.sh`"))
}
