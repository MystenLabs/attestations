/// The package a viewer browses in the demo. Depends on `dependency_example`
/// (a real dependency edge) so the demo can attest about both a package and one
/// of its dependencies.
module subject_example::subject;

use dependency_example::dependency;

/// Returns the dependency's version, exercising the real dependency edge so
/// the dep is not tree-shaken away.
public fun dependency_version(): u64 { dependency::version() }
