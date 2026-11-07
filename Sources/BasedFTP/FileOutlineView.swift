import SwiftUI
import AppKit

/// AppKit owns row selection, disclosure, keyboard navigation and drag hit testing.
struct FileOutlineView: NSViewRepresentable {
    @ObservedObject var pane: PaneModel
    let workspace: Workspace
    let tabID: UUID
    let open: (FileEntry) -> Void
    let openWith: (FileEntry, URL?) -> Void
    let action: (FilePane.FileAction) -> Void
    let delete: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let outline = BrowserOutline()
        outline.delegate = context.coordinator; outline.dataSource = context.coordinator
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = true
        outline.rowHeight = 26
        outline.intercellSpacing = NSSize(width: 4, height: 0)
        outline.indentationPerLevel = 16
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (key, title, width) in [("name", "Name", 200.0), ("size", "Size", 72.0), ("kind", "Kind", 56.0), ("modified", "Modified", 140.0), ("mode", "Mode", 54.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title; column.width = width
            column.minWidth = key == "name" ? 120 : 44
            if key != "mode" { column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true) }
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.target = context.coordinator; outline.doubleAction = #selector(Coordinator.doubleClick(_:))
        outline.registerForDraggedTypes([.string, .fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.menuBuilder = { [weak coordinator = context.coordinator] in coordinator?.menu() }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = outline
        context.coordinator.outline = outline
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.parent = self
        coordinator.reload()
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: FileOutlineView
        weak var outline: BrowserOutline?
        var nodes: [String: Node] = [:]
        var roots: [Node] = []
        var children: [String: [Node]] = [:]
        var syncing = false
        var lastVisible: [FileEntry]?
        var lastExpanded: Set<String> = []
        var lastLoading: Set<String> = []
        var lastErrors: [String: String] = [:]
        init(_ parent: FileOutlineView) { self.parent = parent }
        func reload() {
            guard let outline else { return }
            syncing = true; defer { syncing = false }
            let pane = parent.pane
            let visible = pane.visible
            let key = pane.sort == .size ? "size" : pane.sort == .kind ? "kind" : pane.sort == .modified ? "modified" : "name"
            if outline.sortDescriptors.first?.key != key || outline.sortDescriptors.first?.ascending != pane.ascending {
                outline.sortDescriptors = [NSSortDescriptor(key: key, ascending: pane.ascending)]
            }
            if lastVisible == visible, lastExpanded == pane.expanded, lastLoading == pane.loadingChildren, lastErrors == pane.treeErrors {
                syncSelection(outline); return
            }
            lastVisible = visible; lastExpanded = pane.expanded; lastLoading = pane.loadingChildren; lastErrors = pane.treeErrors
            for entry in pane.allEntries {
                if let node = nodes[entry.path] { node.entry = entry } else { nodes[entry.path] = Node(entry) }
            }
            let rootIDs = Set(pane.entries.map(\.path))
            roots = visible.filter { rootIDs.contains($0.path) }.compactMap { nodes[$0.path] }
            let ranks = Dictionary(visible.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { _, new in new })
            children = pane.children.mapValues { values in
                values.filter { ranks[$0.path] != nil }.sorted { ranks[$0.path]! < ranks[$1.path]! }.compactMap { nodes[$0.path] }
            }
            let live = Set(pane.allEntries.map(\.path)); nodes = nodes.filter { live.contains($0.key) }
            let origin = (outline.enclosingScrollView?.contentView.bounds.origin) ?? .zero
            outline.reloadData()
            for path in pane.expanded.sorted(by: { (nodes[$0].map { pane.depth(of: $0.entry) } ?? 0) < (nodes[$1].map { pane.depth(of: $0.entry) } ?? 0) }) {
                if let node = nodes[path] { outline.expandItem(node) }
            }
            for row in (0..<outline.numberOfRows).reversed() {
                if let node = outline.item(atRow: row) as? Node, !pane.expanded.contains(node.entry.path), outline.isItemExpanded(node) { outline.collapseItem(node) }
            }
            syncSelection(outline)
            outline.enclosingScrollView?.contentView.scroll(to: origin)
        }
        private func syncSelection(_ outline: NSOutlineView) {
            let selected = IndexSet((0..<outline.numberOfRows).filter { row in
                (outline.item(atRow: row) as? Node).map { parent.pane.selection.contains($0.entry.path) } ?? false
            })
            if outline.selectedRowIndexes != selected { outline.selectRowIndexes(selected, byExtendingSelection: false) }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if let node = item as? Node { return children[node.entry.path]?.count ?? 0 }; return roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let node = item as? Node { return children[node.entry.path]![index] }; return roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Node)?.entry.isDirectory ?? false }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let column = tableColumn else { return nil }
            let entry = node.entry
            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle; text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(text); cell.textField = text
            var inset: CGFloat = 4
            switch column.identifier.rawValue {
            case "name":
                text.stringValue = entry.name + (parent.pane.loadingChildren.contains(entry.path) ? " …" : "")
                let symbol = entry.isDirectory ? "folder.fill" : entry.isSymlink ? "link" : "doc"
                let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
                image.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
                image.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(image); cell.imageView = image
                NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16)])
                inset = 25
                cell.toolTip = parent.pane.treeErrors[entry.path] ?? entry.path
                if parent.pane.treeErrors[entry.path] != nil { image.contentTintColor = .systemOrange }
                if parent.pane.loadingChildren.contains(entry.path) { text.textColor = .secondaryLabelColor }
            case "size": text.stringValue = entry.sizeText; text.alignment = .right
            case "kind": text.stringValue = entry.kind
            case "modified": text.stringValue = entry.modified == .distantPast ? "—" : entry.modified.formatted(date: .abbreviated, time: .shortened)
            default: text.stringValue = entry.modeText; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            }
            if column.identifier.rawValue != "name" { text.textColor = .secondaryLabelColor }
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: inset), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? Node, !parent.pane.expanded.contains(node.entry.path) else { return }
            parent.pane.toggleExpanded(node.entry)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !syncing, let node = notification.userInfo?["NSObject"] as? Node, parent.pane.expanded.contains(node.entry.path) else { return }
            parent.pane.toggleExpanded(node.entry)
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            parent.workspace.activeRemote = parent.pane.remote
            parent.pane.selection = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Node)?.entry.path })
        }
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !syncing, let sort = outlineView.sortDescriptors.first else { return }
            parent.pane.sort = sort.key == "size" ? .size : sort.key == "kind" ? .kind : sort.key == "modified" ? .modified : .name
            parent.pane.ascending = sort.ascending
        }
        @objc func doubleClick(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? Node else { return }
            parent.open(node.entry)
        }
        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node else { return nil }
            let entries = parent.pane.selection.contains(node.entry.path) ? parent.pane.selected : [node.entry]
            let payload = DragPayload(tab: parent.tabID, remote: parent.pane.remote, entries: entries.map { .init(path: $0.path) })
            let item = NSPasteboardItem(); item.setString(payload.text, forType: .string); return item
        }
        private func droppedStrings(_ info: NSDraggingInfo) -> [String] {
            let pasteboard = info.draggingPasteboard
            let internalItems = pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) }.filter { DragPayload.parse($0) != nil } ?? []
            if !internalItems.isEmpty { return internalItems }
            guard parent.pane.remote else { return [] }
            return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.map(\.absoluteString) ?? []
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard !parent.pane.busy else { return [] }
            let strings = droppedStrings(info); guard !strings.isEmpty else { return [] }
            if let node = item as? Node {
                guard node.entry.isDirectory else { return [] }
                outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            if let payload = strings.first.flatMap(DragPayload.parse) {
                guard payload.tab == parent.tabID else { return [] }
                if payload.remote == parent.pane.remote {
                    let paths = Set(payload.entries.map(\.path))
                    let entries = PaneModel.topLevelSelection(parent.pane.allEntries.filter { paths.contains($0.path) })
                    let destination = (item as? Node)?.entry.path ?? parent.pane.path
                    guard !entries.isEmpty, (try? PaneModel.validateMove(entries, to: destination)) != nil else { return [] }
                    return .move
                }
            }
            return .copy
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            parent.workspace.drop(droppedStrings(info), to: parent.pane, directory: (item as? Node)?.entry.path ?? parent.pane.path)
        }
        func menu() -> NSMenu {
            let menu = NSMenu()
            let entries = parent.pane.selected
            func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
                let handler = MenuHandler(action)
                let item = NSMenuItem(title: title, action: #selector(MenuHandler.invokeMenuAction), keyEquivalent: "")
                item.target = handler; item.representedObject = handler; item.isEnabled = enabled; menu.addItem(item)
            }
            menu.autoenablesItems = false
            add(parent.pane.remote ? "Download" : "Upload", enabled: !entries.isEmpty) { self.parent.workspace.transfer(from: self.parent.pane) }
            if entries.count == 1, let entry = entries.first {
                add(entry.isDirectory ? "Open" : self.parent.pane.remote ? "Edit Remote File" : "Open") { self.parent.open(entry) }
                if entry.isRegular {
                    let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                    item.submenu = EditorApplications.menu(for: entry) { app in self.parent.openWith(entry, app) }
                    menu.addItem(item)
                }
                add("Rename…") { self.parent.action(.rename) }
            }
            add("Move To…", enabled: !entries.isEmpty) { self.parent.action(.move) }
            add("Permissions…", enabled: !entries.isEmpty) { self.parent.action(.chmod) }
            menu.addItem(.separator())
            add("New Folder…") { self.parent.action(.folder) }; add("New File…") { self.parent.action(.file) }
            menu.addItem(.separator())
            add(parent.pane.remote ? "Delete Permanently…" : "Move to Trash…", enabled: !entries.isEmpty) { self.parent.delete() }
            return menu
        }
    }
}

final class Node: NSObject {
    var entry: FileEntry
    init(_ entry: FileEntry) { self.entry = entry }
}
private final class MenuHandler: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invokeMenuAction() { action() }
}
final class BrowserOutline: NSOutlineView {
    var menuBuilder: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !isRowSelected(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if row < 0 { deselectAll(nil) }
        return menuBuilder?()
    }
}
