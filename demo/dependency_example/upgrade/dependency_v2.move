/// Added in the v2 upgrade of dependency_example so the package has two
/// published versions; the mvr demo's version selector switches between them.
/// Like audit_v2, this lives outside sources/ and is copied in only for the
/// upgrade step (see demo/scripts/test-publish.sh).
module dependency_example::dependency_v2;
public fun version(): u64 { 2 }
