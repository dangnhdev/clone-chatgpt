import AppKit

private final class CloneWindowController: NSWindowController {
    private let sourceField = NSTextField()
    private let targetField = NSTextField()
    private let bundleIDField = NSTextField()
    private let iconField = NSTextField()
    private let codexHomeField = NSTextField()
    private let userDataField = NSTextField()
    private let statusField = NSTextField(wrappingLabelWithString: "Choose the app, icon, and profile locations, then create the clone.")
    private let cloneButton = NSButton(title: "Create Chat.app", target: nil, action: nil)
    private let openButton = NSButton(title: "Open Chat.app", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var lastResult: CloneResult?
    private var browseButtons: [NSButton] = []
    private(set) var isBusy = false

    init(configuration: CloneConfiguration) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clone ChatGPT"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface(configuration: configuration)
    }

    required init?(coder: NSCoder) { nil }

    private func buildInterface(configuration: CloneConfiguration) {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        sourceField.stringValue = configuration.sourceApp
        targetField.stringValue = configuration.targetApp
        bundleIDField.stringValue = configuration.bundleIdentifier
        iconField.stringValue = configuration.iconPath
        codexHomeField.stringValue = configuration.codexHome
        userDataField.stringValue = configuration.userDataPath
        for field in [sourceField, targetField, bundleIDField, iconField, codexHomeField, userDataField] {
            field.placeholderString = "Enter a path"
            field.lineBreakMode = .byTruncatingMiddle
        }
        bundleIDField.placeholderString = "com.example.app"

        let heading = NSTextField(labelWithString: "Create an isolated ChatGPT app")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Copy ChatGPT.app, apply a custom icon and bundle ID, set separate Codex and desktop data folders, and sign the finished copy when needed. App data is not copied; existing selected profile folders are reused.")
        intro.textColor = .secondaryLabelColor

        let form = NSGridView()
        form.columnSpacing = 12
        form.rowSpacing = 14
        addRow(to: form, title: "Source app", field: sourceField, buttonTitle: "Choose…", action: #selector(chooseSource))
        addRow(to: form, title: "Destination app", field: targetField, buttonTitle: "Choose…", action: #selector(chooseDestination))
        let bundleLabel = NSTextField(labelWithString: "Bundle ID")
        bundleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        form.addRow(with: [bundleLabel, bundleIDField, NSView()])
        addRow(to: form, title: "App icon", field: iconField, buttonTitle: "Choose…", action: #selector(chooseIcon))
        addRow(to: form, title: "CODEX_HOME", field: codexHomeField, buttonTitle: "Choose…", action: #selector(chooseCodexHome))
        addRow(to: form, title: "Desktop data folder", field: userDataField, buttonTitle: "Choose…", action: #selector(chooseUserData))
        for index in 0..<form.numberOfRows {
            form.row(at: index).height = 32
        }
        form.column(at: 0).width = 145
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).xPlacement = .fill
        form.column(at: 2).width = 90
        form.column(at: 2).xPlacement = .center

        let warning = NSTextField(wrappingLabelWithString: "If Chat.app already exists, it will be moved to the Trash before the new copy is installed.")
        warning.font = .systemFont(ofSize: 12, weight: .medium)
        warning.textColor = .systemOrange

        statusField.font = .systemFont(ofSize: 12)
        statusField.textColor = .secondaryLabelColor
        statusField.maximumNumberOfLines = 3
        statusField.cell?.wraps = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        cloneButton.bezelStyle = .rounded
        cloneButton.keyEquivalent = "\r"
        cloneButton.target = self
        cloneButton.action = #selector(createClone)
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openCreatedApp)
        openButton.isEnabled = false

        let actionRow = NSStackView(views: [spinner, statusField, openButton, cloneButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.distribution = .fill
        actionRow.spacing = 12
        actionRow.setHuggingPriority(.defaultHigh, for: .horizontal)
        statusField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let layout = NSStackView(views: [heading, intro, form, warning, actionRow])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.distribution = .fill
        layout.spacing = 16
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            form.widthAnchor.constraint(equalTo: layout.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: layout.widthAnchor),
            intro.widthAnchor.constraint(equalTo: layout.widthAnchor),
            warning.widthAnchor.constraint(equalTo: layout.widthAnchor),
            sourceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            targetField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            iconField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            codexHomeField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            userDataField.widthAnchor.constraint(greaterThanOrEqualToConstant: 400)
        ])
    }

    private func addRow(to grid: NSGridView, title: String, field: NSTextField, buttonTitle: String, action: Selector) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        browseButtons.append(button)
        grid.addRow(with: [label, field, button])
    }

    private var configuration: CloneConfiguration {
        CloneConfiguration(
            sourceApp: sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            targetApp: targetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            iconPath: iconField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            codexHome: codexHomeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            userDataPath: userDataField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleIdentifier: bundleIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @objc private func chooseSource() {
        chooseApplication(title: "Choose the original ChatGPT app") { self.sourceField.stringValue = $0 }
    }

    @objc private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "Choose where to create Chat.app"
        panel.nameFieldStringValue = (targetField.stringValue as NSString).lastPathComponent.isEmpty ? "Chat.app" : (targetField.stringValue as NSString).lastPathComponent
        panel.allowedContentTypes = [.application]
        panel.canCreateDirectories = true
        panel.begin { response in
            if response == .OK, let url = panel.url { self.targetField.stringValue = url.path }
        }
    }

    @objc private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app icon"
        panel.allowedContentTypes = [.icns, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let url = panel.url { self.iconField.stringValue = url.path }
        }
    }

    @objc private func chooseCodexHome() {
        chooseFolder(title: "Choose CODEX_HOME folder", currentPath: codexHomeField.stringValue) { self.codexHomeField.stringValue = $0 }
    }

    @objc private func chooseUserData() {
        chooseFolder(title: "Choose desktop data folder", currentPath: userDataField.stringValue) { self.userDataField.stringValue = $0 }
    }

    private func chooseApplication(title: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        // macOS application bundles are packages presented as files to the panel.
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url { completion(url.path) }
        }
    }

    private func chooseFolder(title: String, currentPath: String, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.directoryURL = URL(fileURLWithPath: currentPath).deletingLastPathComponent()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { completion(url.path) }
        }
    }

    @objc private func createClone() {
        let config = configuration
        setBusy(true, message: "Checking paths and preparing the app…")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CloneEngine.validate(config)
                let result = try CloneEngine.clone(config) { message in
                    DispatchQueue.main.async { self.setStatus(message) }
                }
                DispatchQueue.main.async {
                    self.lastResult = result
                    self.openButton.isEnabled = true
                    var summary = "Created \((result.targetApp as NSString).lastPathComponent)"
                    if let trashPath = result.trashPath {
                        summary += " · Previous app moved to Trash: \((trashPath as NSString).lastPathComponent)"
                        self.statusField.toolTip = "Previous app moved to Trash: \(trashPath)"
                    }
                    if !result.notes.isEmpty {
                        let notes = result.notes.joined(separator: "\n")
                        self.statusField.toolTip = [self.statusField.toolTip, notes].compactMap { $0 }.joined(separator: "\n\n")
                    }
                    self.setBusy(false, message: summary)
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusField.toolTip = error.localizedDescription
                    self.setBusy(false, message: "Could not create the app: \(error.localizedDescription)")
                    NSSound.beep()
                }
            }
        }
    }

    @objc private func openCreatedApp() {
        guard let result = lastResult else { return }
        let appURL = URL(fileURLWithPath: result.targetApp)
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self.statusField.toolTip = error.localizedDescription
                self.setStatus("Could not open \((result.targetApp as NSString).lastPathComponent): \(error.localizedDescription)")
                NSSound.beep()
            }
        }
    }

    private func setBusy(_ busy: Bool, message: String) {
        isBusy = busy
        cloneButton.isEnabled = !busy
        openButton.isEnabled = !busy && lastResult != nil
        for control in [sourceField, targetField, bundleIDField, iconField, codexHomeField, userDataField] { control.isEnabled = !busy }
        for button in browseButtons { button.isEnabled = !busy }
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        setStatus(message)
    }

    private func setStatus(_ message: String) {
        statusField.stringValue = message
        statusField.textColor = .secondaryLabelColor
    }
}

extension CloneWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isBusy else { return true }
        NSSound.beep()
        return false
    }
}

private final class CloneApplicationDelegate: NSObject, NSApplicationDelegate {
    private var controller: CloneWindowController?

    init(configuration: CloneConfiguration) {
        super.init()
        controller = CloneWindowController(configuration: configuration)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller?.isBusy == true else { return .terminateNow }
        NSSound.beep()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func runGUI(initial configuration: CloneConfiguration) {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    installMenus(on: application)
    let delegate = CloneApplicationDelegate(configuration: configuration)
    application.delegate = delegate
    // Retain the delegate for the entire event loop.
    withExtendedLifetime(delegate) { application.run() }
}

private func installMenus(on application: NSApplication) {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Clone ChatGPT", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "Edit")
    let editActions: [(String, String, String)] = [
        ("Undo", "undo:", "z"),
        ("Redo", "redo:", "Z"),
        ("Cut", "cut:", "x"),
        ("Copy", "copy:", "c"),
        ("Paste", "paste:", "v"),
        ("Select All", "selectAll:", "a")
    ]
    for (title, action, key) in editActions {
        editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
    }
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)
    application.mainMenu = mainMenu
}
