import XCTest
@testable import ProjeHealthMonitor

final class BuildInfoTests: XCTestCase {
    func testAcceptsShortAndFullHashes() {
        XCTAssertEqual(BuildInfo.normalizedCommit("8f3c2a1"), "8f3c2a1")
        XCTAssertEqual(BuildInfo.normalizedCommit(" 8F3C2A1\n"), "8f3c2a1")
        XCTAssertNotNil(BuildInfo.normalizedCommit(String(repeating: "a", count: 40)))
    }

    func testRejectsMissingEmptyAndGarbage() {
        XCTAssertNil(BuildInfo.normalizedCommit(nil))
        XCTAssertNil(BuildInfo.normalizedCommit(""))
        XCTAssertNil(BuildInfo.normalizedCommit("unknown"))
        XCTAssertNil(BuildInfo.normalizedCommit("8f3c2"))
        XCTAssertNil(BuildInfo.normalizedCommit("8f3c2a1; rm -rf"))
    }

    func testVersionLineIncludesCommitOnlyWhenKnown() {
        XCTAssertEqual(BuildInfo.versionLine(shortVersion: "0.2.0", build: "30", commit: "8f3c2a1"),
                       "Version 0.2.0 (30) · 8f3c2a1")
        XCTAssertEqual(BuildInfo.versionLine(shortVersion: "0.2.0", build: "30", commit: nil),
                       "Version 0.2.0 (30)")
    }
}
