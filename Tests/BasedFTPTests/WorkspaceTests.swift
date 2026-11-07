import XCTest
@testable import BasedFTP

@MainActor final class WorkspaceTests: XCTestCase {
    func testBookmarkDoubleClickOpensOnlyOnce() {
        var gate = BookmarkActivationGate()
        let first = UUID(), second = UUID()
        XCTAssertTrue(gate.shouldOpen(first, at: 1, doubleClickInterval: 0.5))
        XCTAssertFalse(gate.shouldOpen(first, at: 1.1, doubleClickInterval: 0.5))
        XCTAssertFalse(gate.shouldOpen(first, at: 1.1, doubleClickInterval: 0.5)) // Double-tap gesture callback.
        XCTAssertTrue(gate.shouldOpen(second, at: 1.2, doubleClickInterval: 0.5))
        XCTAssertTrue(gate.shouldOpen(first, at: 1.3, doubleClickInterval: 0.5))
        XCTAssertTrue(gate.shouldOpen(first, at: 2, doubleClickInterval: 0.5))
    }
    func testClosingActiveTabSelectsNeighbourAndKeepsEmptyWorkspace() {
        let workspace = Workspace()
        let first = ConnectionTab(profile: ServerProfile())
        let middle = ConnectionTab(profile: ServerProfile())
        let last = ConnectionTab(profile: ServerProfile())
        workspace.tabs = [first, middle, last]; workspace.selected = middle.id
        workspace.closeSelectedTab()
        XCTAssertEqual(workspace.tabs.map(\.id), [first.id, last.id])
        XCTAssertEqual(workspace.selected, last.id)
        workspace.close(first)
        XCTAssertEqual(workspace.selected, last.id)
        workspace.closeSelectedTab()
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNil(workspace.selected)
        workspace.closeSelectedTab()
        XCTAssertTrue(workspace.tabs.isEmpty)
    }
}
