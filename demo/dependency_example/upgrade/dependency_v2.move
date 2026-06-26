/// V2 of dependency_example, introduced via a package *upgrade*. Adds a
/// trivial module so the upgrade produces a distinct package id (additive
/// changes are upgrade-safe). The demo attests a vulnerability against this
/// *newer* version while `subject_example` still pins v1 — exercising
/// cross-version propagation (a vuln on v2 is an upgrade-risk for a dependent
/// pinned to v1).
///
/// Staged into `sources/` only for the upgrade step by
/// `scripts/test-publish.sh` (mirrors `audit_example/upgrade/audit_v2.move`).
module dependency_example::dependency_v2;

public fun version_v2(): u64 { 2 }
