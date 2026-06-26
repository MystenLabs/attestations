/// The package a user browses in the demo. It depends on
/// `dependency_example` so the dependency relationship is real — it shows up
/// in MVR's Dependencies tab, and lets an `Audit` on this package `require`
/// an `Audit` on its dependency (the conditional-trust scenario).
module subject_example::subject;

use dependency_example::dependency;

/// Returns the dependency's version, exercising the real dependency edge so
/// the dep is not tree-shaken away.
public fun dependency_version(): u64 { dependency::version() }
