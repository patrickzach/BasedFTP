import AppKit
import UniformTypeIdentifiers

@MainActor final class EditorPreferences {
    static let shared = EditorPreferences()
    private let defaults: UserDefaults
    private let key = "editorApplicationsByExtension"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func fileType(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }
    func application(for name: String) -> URL? {
        guard let path = defaults.dictionary(forKey: key)?[Self.fileType(name)] as? String else { return nil }
        return URL(fileURLWithPath: path)
    }
    func set(_ application: URL?, for name: String) {
        var values = defaults.dictionary(forKey: key) ?? [:]
        values[Self.fileType(name)] = application?.path
        defaults.set(values, forKey: key)
    }
}

@MainActor enum EditorApplications {
    static func applications(for name: String) -> [URL] {
        let type = UTType(filenameExtension: EditorPreferences.fileType(name)) ?? .data
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: type)
        let preferred = EditorPreferences.shared.application(for: name)
        var seen: Set<String> = []
        return ([preferred].compactMap { $0 } + apps).filter { app in
            let identity = Bundle(url: app)?.bundleIdentifier ?? app.standardizedFileURL.path
            return seen.insert(identity).inserted
        }
    }
    static func open(_ file: URL, application: URL?) async throws {
        let app = application ?? EditorPreferences.shared.application(for: file.lastPathComponent) ?? NSWorkspace.shared.urlForApplication(toOpen: file)
        guard let app else { throw FTPError.message("No application is assigned. Choose an application using Open With.") }
        _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    static func menu(for entry: FileEntry, open: @escaping (URL?) -> Void) -> NSMenu {
        let menu = NSMenu(title: "Open With"); menu.autoenablesItems = false
        func add(_ title: String, to menu: NSMenu, app: URL? = nil, action: @escaping () -> Void) {
            let handler = EditorMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(EditorMenuAction.invoke), keyEquivalent: "")
            item.target = handler; item.representedObject = handler
            if let app { item.image = NSWorkspace.shared.icon(forFile: app.path); item.image?.size = NSSize(width: 16, height: 16) }
            menu.addItem(item)
        }
        let apps = applications(for: entry.name)
        let preferred = EditorPreferences.shared.application(for: entry.name)
        for app in apps {
            let title = FileManager.default.displayName(atPath: app.path)
            add(title + (app == preferred ? " (BasedFTP Default)" : ""), to: menu, app: app) { open(app) }
        }
        menu.addItem(.separator())
        add("Other Application…", to: menu) {
            let panel = NSOpenPanel(); panel.title = "Choose an application for \(entry.name)"
            panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            let remember = NSButton(checkboxWithTitle: "Always use this application for this file type in BasedFTP", target: nil, action: nil)
            panel.accessoryView = remember
            if panel.runModal() == .OK, let app = panel.url {
                if remember.state == .on { EditorPreferences.shared.set(app, for: entry.name) }
                open(app)
            }
        }
        let defaults = NSMenu(title: "Always Open With"); defaults.autoenablesItems = false
        add("Use macOS Default", to: defaults) { EditorPreferences.shared.set(nil, for: entry.name) }
        for app in apps {
            add(FileManager.default.displayName(atPath: app.path), to: defaults, app: app) {
                EditorPreferences.shared.set(app, for: entry.name); open(app)
            }
        }
        let item = NSMenuItem(title: "Always Open With", action: nil, keyEquivalent: ""); item.submenu = defaults; menu.addItem(item)
        return menu
    }
}

private final class EditorMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
