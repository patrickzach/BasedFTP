import XCTest
@testable import BasedFTP

@MainActor final class TreeTests: XCTestCase {
    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Asynchrone Dateioperation wurde nicht abgeschlossen")
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BasedFTP-tree-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A/nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        try Data("content".utf8).write(to: root.appendingPathComponent("A/nested/file.txt"))
        return root
    }
    func testLazyTreeExpansionFilteringRefreshAndNestedRename() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let pane = PaneModel(); pane.navigate(root.path)
        try await waitFor { !pane.busy }
        XCTAssertNil(pane.error)
        let folder = try XCTUnwrap(pane.entries.first { $0.name == "A" })
        XCTAssertNil(pane.children[folder.path])
        pane.toggleExpanded(folder)
        try await waitFor { pane.children[folder.path] != nil }
        let nested = try XCTUnwrap(pane.children[folder.path]?.first)
        pane.toggleExpanded(nested)
        try await waitFor { pane.children[nested.path] != nil }
        let file = try XCTUnwrap(pane.visible.first { $0.name == "file.txt" })
        XCTAssertEqual(pane.depth(of: file), 2, "root=\(pane.path) entry=\(file.path)")
        pane.filter = "file.txt"
        XCTAssertEqual(pane.visible.map(\.name), ["A", "nested", "file.txt"])
        pane.filter = ""
        pane.refresh()
        try await waitFor { !pane.busy && pane.children[nested.path] != nil }
        XCTAssertTrue(pane.expanded.contains(folder.path))
        pane.rename(file, name: "renamed.txt")
        try await waitFor { !pane.busy && pane.children[nested.path] != nil }
        XCTAssertNil(pane.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("A/nested/renamed.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed.txt").path))
        pane.toggleExpanded(folder)
        XCTAssertFalse(pane.visible.contains { $0.name == "renamed.txt" })
    }
    func testDropMovesTreeSelectionAndRejectsSelfAndConflicts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(); let tab = ConnectionTab(profile: ServerProfile())
        workspace.tabs = [tab]; workspace.selected = tab.id
        let pane = tab.local; pane.navigate(root.path)
        try await waitFor { !pane.busy }
        let folder = try XCTUnwrap(pane.entries.first { $0.name == "A" })
        pane.toggleExpanded(folder)
        try await waitFor { pane.children[folder.path] != nil }
        let nested = try XCTUnwrap(pane.children[folder.path]?.first)
        let payload = DragPayload(tab: tab.id, remote: false, entries: [.init(path: folder.path), .init(path: nested.path)])
        XCTAssertTrue(workspace.drop([payload.text], to: pane, directory: nested.path))
        XCTAssertNotNil(pane.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("A/nested"))
        pane.move([folder], to: alias.path)
        try await waitFor { !pane.busy }
        XCTAssertNotNil(pane.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(workspace.drop([payload.text, payload.text], to: pane, directory: root.appendingPathComponent("B").path))
        try await waitFor { !pane.busy }
        XCTAssertNil(pane.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/A/nested/file.txt").path))
        // Existing targets must not be overwritten by a move/drop.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: false)
        pane.refresh(); try await waitFor { !pane.busy }
        let newFolder = try XCTUnwrap(pane.entries.first { $0.name == "A" })
        pane.move([newFolder], to: root.appendingPathComponent("B").path)
        try await waitFor { !pane.busy }
        XCTAssertNotNil(pane.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFolder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/A/nested/file.txt").path))
        XCTAssertFalse(workspace.drop(["unrelated text"], to: pane))
    }
}
