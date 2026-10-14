import XCTest
import SwiftUI
@testable import ProjeHealthMonitor

final class PopoverListTests: XCTestCase {
    func testHeightIsFullUntilContentIsMeasured() {
        XCTAssertEqual(PopoverList<EmptyView>.height(forContent: nil), PopoverList<EmptyView>.maxHeight)
        XCTAssertEqual(PopoverList<EmptyView>.height(forContent: 0), PopoverList<EmptyView>.maxHeight)
    }

    func testHeightFollowsShortContent() {
        XCTAssertEqual(PopoverList<EmptyView>.height(forContent: 56), 56)
    }

    func testHeightIsCappedForTallContent() {
        XCTAssertEqual(PopoverList<EmptyView>.height(forContent: 900), PopoverList<EmptyView>.maxHeight)
    }
}
