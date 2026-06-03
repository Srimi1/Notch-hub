import Foundation
import Testing
@testable import NotchHub

// Uses swift-testing (`import Testing`). Exercises the pure, security-sensitive
// logic behind the RAM cleaner's passwordless "Always Allow" feature: the
// sudoers-line generator and its username safety gate. These are the pieces that,
// if wrong, could inject into `/etc/sudoers.d/notchhub` — so they're locked down
// here. The live `visudo -cf` validation in PurgePrivilege.enableAlwaysAllow is
// the runtime backstop and isn't reproduced in this (process-free) unit test.
@Suite("PurgePrivilege")
struct PurgePrivilegeTests {

    /// A normal account name yields exactly the expected NOPASSWD rule, scoped to
    /// `/usr/sbin/purge` and nothing else, with the trailing newline visudo wants.
    @Test
    func sudoersLineForNormalUserIsExact() {
        let line = PurgePrivilege.sudoersLine(for: "srimi")
        #expect(line == "srimi ALL=(root) NOPASSWD: /usr/sbin/purge\n")
    }

    /// The rule must grant exactly one command — never a wildcard or extra path.
    @Test
    func sudoersLineGrantsOnlyPurge() {
        let line = PurgePrivilege.sudoersLine(for: "alice")
        #expect(line?.contains("NOPASSWD: /usr/sbin/purge") == true)
        #expect(line?.contains("ALL : ALL") == false)
        #expect(line?.contains("*") == false)
    }

    /// Plausible real usernames (dots, underscores, hyphens, digits, mixed case)
    /// are accepted.
    @Test(arguments: ["srimi", "john.doe", "user_1", "a-b", "User123", "_svc"])
    func acceptsValidUsernames(_ name: String) {
        #expect(PurgePrivilege.isSafeUsername(name))
        #expect(PurgePrivilege.sudoersLine(for: name) != nil)
    }

    /// Anything carrying whitespace, shell metacharacters, quotes, newlines, or
    /// path separators is rejected — and the generator returns nil rather than
    /// emitting a poisoned line.
    @Test(arguments: [
        "", // empty
        "a b", // space
        "a\tb", // tab
        "root\nevil ALL=(ALL) NOPASSWD: ALL", // newline injection
        "a;rm -rf /", // command separator
        "a$(whoami)", // command substitution
        "a`id`", // backtick substitution
        "a'b", // single quote
        "a\"b", // double quote
        "a,b", // sudoers list separator
        "../etc/passwd", // path traversal / slash
        "a|b", // pipe
    ])
    func rejectsUnsafeUsernames(_ name: String) {
        #expect(!PurgePrivilege.isSafeUsername(name))
        #expect(PurgePrivilege.sudoersLine(for: name) == nil)
    }

    /// The well-known install location is the single file the feature manages, so
    /// enable/revoke and any external cleanup target the same path.
    @Test
    func sudoersPathIsTheManagedFile() {
        #expect(PurgePrivilege.sudoersPath == "/etc/sudoers.d/notchhub")
    }
}
