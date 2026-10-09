/// A trivial package used in the demo as the subject of a dependency-level
/// attestation, and as a real dependency of `subject_example`. Its only
/// purpose is to be a published package with a stable id to attest about.
module dependency_example::dependency;

/// Returns the package's notional version. Exists only so the module has
/// some content; the demo only uses the package id.
public fun version(): u64 { 1 }
