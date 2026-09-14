import AppKit
import CryptoKit
import ServiceManagement

func savedRefreshInterval(_ value: Double?) -> TimeInterval {
    let choices: Set<Double> = [900, 1800, 3600, 10800, 21600, 43200, 86400]
    return value.flatMap { choices.contains($0) ? $0 : nil } ?? 3600
}

func statusItemIcon() -> NSImage {
    if let icon = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Wapacal") {
        icon.isTemplate = true
        return icon
    }
    let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setStroke()
        NSColor.black.setFill()
        let outline = NSBezierPath(
            roundedRect: NSRect(x: 2.5, y: 2.5, width: 13, height: 12), xRadius: 2, yRadius: 2)
        outline.lineWidth = 1.5
        outline.stroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 3, y: 10.5))
        divider.line(to: NSPoint(x: 15, y: 10.5))
        divider.lineWidth = 1.5
        divider.stroke()
        for x in [6.0, 9.0, 12.0] {
            NSBezierPath(ovalIn: NSRect(x: x - 0.75, y: 5.25, width: 1.5, height: 1.5)).fill()
        }
        return true
    }
    icon.isTemplate = true
    return icon
}

// Both windows report the same operation result, including refresh failures.
final class StatusLabel: NSTextField {
    weak var mirror: NSTextField?
    override var stringValue: String { didSet { mirror?.stringValue = stringValue } }
}

@MainActor final class EditorApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate
{
    var window: NSWindow!
    var settingsWindow: NSWindow!
    var aboutWindow: NSWindow?
    let settingsTabs = NSTabView()
    let settingsStatus = NSTextField(wrappingLabelWithString: "")
    let wallpaperSharingWarning = NSStackView()
    var wallpaperWarningHeight: NSLayoutConstraint?
    let wallpaperSharingMessage = NSTextField(
        wrappingLabelWithString:
            "Wallpaper Apply is blocked. Turn off “Show on all Spaces” in macOS Wallpaper settings so Wapacal can update displays separately."
    )
    lazy var wallpaperSettingsButton = NSButton(
        title: "Open Wallpaper Settings…", target: self,
        action: #selector(openWallpaperSettings))
    var localCalendars: LocalCalendarProviding = EventKitCalendarProvider()
    var localCalendarObserver: NSObjectProtocol?
    var localCalendarTimer: Timer?
    var localRefreshPending = false
    var localApplyPending = false
    var waitingForCalendarAccess = false
    let engine = CalendarEngine()
    let editorView = EditorViewController()
    var appearanceObservation: NSKeyValueObservation?
    var previewRevision = -1
    var exporting = false
    var lastEditorError: String?
    var pendingEdits = 0
    var terminating = false
    var stateReadable = true
    var stateLoadError: String?
    var workerStarted = false
    var item: NSStatusItem!
    let status = StatusLabel(wrappingLabelWithString: "Loading your calendar…")
    let urlField = NSTextField()
    let sourcePicker = NSPopUpButton()
    var lastSelectedSourceID: String?
    let sourceName = NSTextField()
    let sourceColor = NSPopUpButton()
    var customSourceColor = NSColor.systemBlue
    let sourceColorNames = [
        "Default", "Green", "Blue", "Purple", "Pink", "Orange", "Red", "Custom",
    ]
    let sourceEnabled = NSButton(checkboxWithTitle: "Enable calendar", target: nil, action: nil)
    let saveSourceButton = NSButton(title: "Save & refresh", target: nil, action: nil)
    let refreshPicker = NSPopUpButton()
    let screenPicker = NSPopUpButton()
    let automatic = NSButton(
        checkboxWithTitle: "Update automatically while running", target: nil, action: nil)
    let login = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    var saved: [String: Any] = [:]
    var companion: WallpaperApp?
    var pendingFiles: [String] = []
    var ready = false
    var fetching = false
    var refreshFailure: String?
    var rendering = false
    var rerender = false
    var displaySelectionGeneration = 0
    var dataGeneration = 0
    var timer: Timer?
    var saveTimer: Timer?
    var escapeMonitor: Any?
    var statusMenu: NSMenu?
    var statusMenuClosedAt: TimeInterval = -.infinity
    var statusMenuOpen = false
    var session = URLSession(configuration: .ephemeral)
    var stateURL: URL { stateDirectory().appendingPathComponent("app-state.json") }
    var nextCheck: Date { Date(timeIntervalSince1970: saved["nextCheck"] as? Double ?? 0) }
    var refreshInterval: TimeInterval { savedRefreshInterval(saved["refreshInterval"] as? Double) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try migrateLegacyWorkspace() } catch {
            status.stringValue =
                "Could not migrate older app data. The original files were kept. \(error.localizedDescription)"
        }
        do {
            let seed = Bundle.main.url(forResource: "seed", withExtension: "json")!
            guard
                let stored = try JSONSerialization.jsonObject(
                    with: Data(
                        contentsOf: FileManager.default.fileExists(atPath: stateURL.path)
                            ? stateURL : seed)) as? [String: Any]
            else { throw WallpaperError.invalid("Expected a settings object.") }
            saved = stored
        } catch {
            stateReadable = false
            stateLoadError =
                "Could not load saved settings. The original file was kept. \(error.localizedDescription)"
            status.stringValue = stateLoadError!
        }
        if saved["subscriptions"] == nil {
            if let url = saved["subscriptionUrl"] as? String, !url.isEmpty {
                var source: [String: Any] = [
                    "id": "legacy", "name": "TimeEdit", "url": url, "kind": "auto",
                    "legacyIds": true,
                ]
                for key in ["ics", "fetchedAt", "etag", "modified"] { source[key] = saved[key] }
                saved["subscriptions"] = [source]
            } else {
                saved["subscriptions"] = [] as [[String: Any]]
            }
            for key in ["subscriptionUrl", "ics", "etag", "modified"] {
                saved.removeValue(forKey: key)
            }
        }
        clearInaccessibleLocalSnapshots()
        observeLocalCalendars()
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.ready,
                    self.editorView.editor["theme"] as? String == "system"
                else { return }
                do { _ = try await self.js("return true;") } catch { self.reportEditorError(error) }
            }
        }
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu(title: "Wapacal")
        let about = NSMenuItem(
            title: "About Wapacal", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Wapacal", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.target = NSApp
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(quit)
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        fileItem.title = "File"
        let fileMenu = NSMenu(title: "File")
        let open = NSMenuItem(
            title: "Open wallpaper…", action: #selector(openExport), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        fileMenu.addItem(.separator())
        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exports = NSMenu(title: "Export")
        _ = editorView.view
        for item in editorView.exportMenu.menu!.items.dropFirst() {
            exports.addItem(item.copy() as! NSMenuItem)
        }
        exportItem.submenu = exports
        fileMenu.addItem(exportItem)
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        let editItem = NSMenuItem()
        editItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
        ] {
            let entry = NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key)
            if title == "Redo" { entry.keyEquivalentModifierMask = [.command, .shift] }
            editMenu.addItem(entry)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let calendarItem = NSMenuItem()
        calendarItem.title = "Calendar"
        let calendarMenu = NSMenu(title: "Calendar")
        let refresh = NSMenuItem(
            title: "Refresh & Apply", action: #selector(refreshAndApplyNow), keyEquivalent: "r")
        refresh.target = self
        calendarMenu.addItem(refresh)
        calendarItem.submenu = calendarMenu
        menu.addItem(calendarItem)

        let windowItem = NSMenuItem()
        windowItem.title = "Window"
        let windowMenu = NSMenu(title: "Window")
        let close = NSMenuItem(
            title: "Close Window", action: #selector(closeWindow), keyEquivalent: "w")
        close.target = self
        windowMenu.addItem(close)
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        item = NSStatusBar.system.statusItem(withLength: 20)
        if let button = item.button {
            button.image = statusItemIcon()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Wapacal"
            button.setAccessibilityLabel("Wapacal")
        }
        let tray = NSMenu()
        for (title, action) in [
            ("Open Wapacal", #selector(show)), ("Settings…", #selector(showSettings)),
            ("Refresh & Apply", #selector(refreshAndApplyNow)),
            ("Quit", #selector(NSApplication.terminate(_:))),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = title == "Quit" ? NSApp : self
            tray.addItem(entry)
        }
        tray.delegate = self
        statusMenu = tray
        item.button?.target = self
        item.button?.action = #selector(toggleStatusMenu)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 850),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = "Wapacal"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1060, height: 720)
        window.delegate = self
        buildSettingsWindow()
        let root = NSView()
        let displayLabel = NSTextField(labelWithString: "Display")
        displayLabel.textColor = .secondaryLabelColor
        screenPicker.setAccessibilityLabel("Wallpaper display")
        screenPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let apply = NSButton(title: "Apply wallpaper", target: self, action: #selector(applyNow))
        apply.bezelStyle = .rounded
        apply.bezelColor = .controlAccentColor
        let calendars = NSButton(
            title: "Calendars…", target: self, action: #selector(showCalendars))
        calendars.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
        calendars.imagePosition = .imageLeading
        calendars.toolTip = "Add and manage your calendars."
        let header = EditorViewController.stack(
            [
                displayLabel, screenPicker, spacer,
                NSButton(title: "Refresh", target: self, action: #selector(refreshNow)),
                calendars,
                editorView.exportMenu, apply,
            ], vertical: false, spacing: 10)
        header.distribution = .fill
        wallpaperSharingMessage.font = .systemFont(ofSize: 12)
        wallpaperSharingMessage.textColor = .labelColor
        wallpaperSharingMessage.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
        let warningIcon = NSImageView(
            image: NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Wallpaper setting needs attention")!)
        warningIcon.contentTintColor = .systemOrange
        wallpaperSharingWarning.orientation = .horizontal
        wallpaperSharingWarning.alignment = .centerY
        wallpaperSharingWarning.spacing = 10
        for child in [warningIcon, wallpaperSharingMessage, wallpaperSettingsButton] {
            wallpaperSharingWarning.addArrangedSubview(child)
        }
        wallpaperWarningHeight = wallpaperSharingWarning.heightAnchor.constraint(equalToConstant: 0)
        wallpaperWarningHeight?.isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        for child in [header, wallpaperSharingWarning, editorView.view, status] {
            root.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        window.contentView = root
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: 32),
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            wallpaperSharingWarning.topAnchor.constraint(equalTo: header.bottomAnchor),
            wallpaperSharingWarning.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            wallpaperSharingWarning.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            editorView.view.topAnchor.constraint(
                equalTo: wallpaperSharingWarning.bottomAnchor, constant: 14),
            editorView.view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            editorView.view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            editorView.view.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -10),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            status.heightAnchor.constraint(equalToConstant: 30),
        ])
        refreshWallpaperSharingWarning()
        editorView.onChange = { [weak self] patch in self?.queueEditorPatch(patch) }
        editorView.onInclude = { [weak self] uid, included in
            guard let self, ready else { return }
            pendingEdits += 1
            let generation = dataGeneration
            Task { @MainActor in
                defer { self.pendingEdits -= 1 }
                guard generation == self.dataGeneration else { return }
                do {
                    _ = try await self.js(
                        "return window.nativeInclude(uid,included)",
                        ["uid": uid, "included": included])
                    self.scheduleEditorSave()
                } catch { self.reportEditorError(error) }
            }
        }
        editorView.canExport = { [weak self] in self?.ready == true && self?.exporting == false }
        editorView.onExport = { [weak self] heic, theme in
            self?.exportImage(heic: heic, theme: theme)
        }
        engine.onFailure = { [weak self] error in
            self?.ready = false
            self?.workerStarted = false
            self?.editorView.setReady(false)
            self?.reportEditorError(error)
        }
        screenPicker.target = self
        screenPicker.action = #selector(changeScreen)
        editorView.displayResolution.target = self
        editorView.displayResolution.action = #selector(useDisplayResolution)
        updateScreens()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let window = self?.window, NSApp.keyWindow === window else {
                return event
            }
            if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
                window.makeFirstResponder(nil)
            } else {
                self?.editorView.closeDetails()
            }
            return nil
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateScreens),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(tick), name: NSWorkspace.didWakeNotification, object: nil)
        Task { @MainActor in
            do {
                try await engine.start()
                workerStarted = true
                if let stateLoadError { throw WallpaperError.invalid(stateLoadError) }
                // The editor includes all calendar events; clear the retired course filter.
                var editor = saved["editor"] as? [String: Any] ?? [:]
                editor["course"] = ""
                saved["editor"] = editor
                _ = try await js("return window.nativeLoad(payload)", ["payload": saved])
                ready = true
                editorView.setReady(true)
                updateDisplayResolution()
                persist()
                status.stringValue = "Saved calendar loaded. Your edits are saved automatically."
                tick()
                localCalendarsChanged()
            } catch { reportEditorError(error) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        show()
        for file in pendingFiles { openExportFile(file) }
        pendingFiles.removeAll()
    }
    func queueEditorPatch(_ patch: [String: Any], automaticApply: Bool = true) {
        guard ready else { return }
        let selectionGeneration = displaySelectionGeneration
        if let width = patch["width"] as? Int, let height = patch["height"] as? Int,
            (1280...7680).contains(width), (720...4320).contains(height),
            let selection = saved["screen"] as? String
        {
            var sizes = saved["displaySizes"] as? [String: [String: Int]] ?? [:]
            sizes[selection] = ["width": width, "height": height]
            saved["displaySizes"] = sizes
        }
        pendingEdits += 1
        let generation = dataGeneration
        Task { @MainActor in
            defer { self.pendingEdits -= 1 }
            guard generation == self.dataGeneration else { return }
            do {
                _ = try await self.js("return window.nativeUpdate(patch)", ["patch": patch])
                if patch["mode"] as? String == "module", patch["proposed"] as? Bool == false {
                    self.editorView.closeDetails()
                }
                let localRangeChanged =
                    ["mode", "month", "start", "end"].contains { patch[$0] != nil }
                    && self.subscriptions.contains { $0["provider"] as? String == "eventkit" }
                if localRangeChanged { self.beginRefresh(force: true, localOnly: true) }
                self.scheduleEditorSave(
                    automaticApply: automaticApply && !localRangeChanged
                        && selectionGeneration == self.displaySelectionGeneration)
            } catch { self.reportEditorError(error) }
        }
    }
    func showWallpaperSharingWarning(_ shared: Bool) {
        wallpaperSharingWarning.isHidden = !shared
        wallpaperWarningHeight?.constant = shared ? 56 : 0
    }
    func refreshWallpaperSharingWarning() {
        showWallpaperSharingWarning(wallpaperSharesAllSpacesAndDisplays())
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshWallpaperSharingWarning()
        if ready {
            updateDisplayResolution()
            if resumeLocalCalendarAccessIfNeeded() { return }
            localCalendarsChanged()
        }
    }
    @objc func openWallpaperSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }
    func menuWillOpen(_ menu: NSMenu) { statusMenuOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        statusMenuOpen = false
        statusMenuClosedAt = ProcessInfo.processInfo.systemUptime
        item.menu = nil
    }
    @objc func toggleStatusMenu() {
        guard let menu = statusMenu, let button = item.button else { return }
        if statusMenuOpen {
            menu.cancelTracking()
            return
        }
        // Menu tracking may deliver the closing click back to the status button.
        // Reject that click, including a queued event, before attaching the menu again.
        if let event = NSApp.currentEvent,
            event.type == .leftMouseUp || event.type == .rightMouseUp,
            event.timestamp <= statusMenuClosedAt + 0.3
        {
            return
        }
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }
    func getCompanion() -> WallpaperApp {
        if let companion { return companion }
        let controller = WallpaperApp()
        controller.onError = { [weak self] error in
            self?.show()
            self?.reportEditorError(error)
        }
        companion = controller
        return controller
    }
    @objc func openExport() {
        let controller = getCompanion()
        controller.openFile()
        controller.window?.delegate = self
    }
    func openExportFile(_ path: String) {
        let controller = getCompanion()
        controller.openURL(URL(fileURLWithPath: path))
        controller.window?.delegate = self
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if window == nil {
            pendingFiles.append(contentsOf: filenames)
        } else {
            for file in filenames { openExportFile(file) }
        }
        sender.reply(toOpenOrPrint: .success)
    }
    @objc func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func closeWindow() { NSApp.keyWindow?.performClose(nil) }
    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if ![window, settingsWindow, aboutWindow, companion?.window].compactMap({ $0 }).contains(
            where: {
                $0 !== closing && $0.isVisible
            })
        {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    @objc func showCalendars() {
        settingsTabs.selectTabViewItem(withIdentifier: "calendars")
        showSettings()
    }
    @objc func showAbout() {
        if aboutWindow == nil {
            let panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 480),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "About Wapacal"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            let content = panel.contentView!
            func label(_ text: String, size: CGFloat, secondary: Bool = false) -> NSTextField {
                let field = NSTextField(wrappingLabelWithString: text)
                field.alignment = .center
                field.font = .systemFont(ofSize: size)
                field.textColor = secondary ? .secondaryLabelColor : .labelColor
                return field
            }
            let icon = NSImageView(image: NSApp.applicationIconImage)
            icon.imageScaling = .scaleProportionallyUpOrDown
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 88),
                icon.heightAnchor.constraint(equalToConstant: 88),
            ])
            let name = label("Wapacal", size: 26)
            name.font = .systemFont(ofSize: 26, weight: .bold)
            let version =
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            let versionText =
                version.map { "Version \($0)" + (build.map { " (\($0))" } ?? "") }
                ?? "Development build"
            let heading = EditorViewController.stack(
                [
                    name, label(versionText, size: 12, secondary: true),
                ], spacing: 5)
            heading.alignment = .centerX
            let description = label("Turn your calendar into a\nMac desktop wallpaper.", size: 15)
            let author = label("Created by Samuel Kremer", size: 12, secondary: true)
            let license = label(
                "Free software under GNU GPL version 3.\nYou may redistribute and modify it under this license.\nThis software comes without any warranty.",
                size: 11, secondary: true)
            let links = EditorViewController.stack([], vertical: false, spacing: 20)
            for (title, url) in [
                ("GitHub", URL(string: "https://github.com/31samu/Wapacal")),
                ("License", Bundle.main.url(forResource: "LICENSE", withExtension: nil)),
                (
                    "Third-party notices",
                    Bundle.main.url(forResource: "THIRD-PARTY-NOTICES.txt", withExtension: nil)
                ),
            ] {
                guard let url else { continue }
                let button = NSButton(
                    title: title, target: self, action: #selector(openAboutLink(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
                button.bezelStyle = .inline
                button.isBordered = false
                button.contentTintColor = .linkColor
                links.addArrangedSubview(button)
            }
            let copyright = label(
                Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
                    ?? "Copyright © 2026 Samuel Kremer",
                size: 11, secondary: true)
            let stack = EditorViewController.stack(
                [
                    icon, heading, description, author, license, links, copyright,
                ], spacing: 20)
            stack.alignment = .centerX
            stack.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
                stack.bottomAnchor.constraint(
                    lessThanOrEqualTo: content.bottomAnchor, constant: -28),
                license.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            panel.center()
            aboutWindow = panel
        }
        NSApp.setActivationPolicy(.regular)
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func openAboutLink(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc func showSettings() {
        window.makeFirstResponder(nil)
        NSApp.setActivationPolicy(.regular)
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func buildSettingsWindow() {
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settingsWindow.title = "Wapacal Settings"
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        func note(_ text: String) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            return label
        }
        func field(_ title: String, _ control: NSView) -> NSStackView {
            control.setAccessibilityLabel(title)
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            let row = EditorViewController.stack([label, control], spacing: 6)
            control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            return row
        }
        func tab(_ id: String, _ title: String, _ children: [NSView]) {
            let content = NSView()
            let stack = EditorViewController.stack(children, spacing: 18)
            content.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                stack.bottomAnchor.constraint(
                    lessThanOrEqualTo: content.bottomAnchor, constant: -22),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            ])
            for child in children {
                child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            let item = NSTabViewItem(identifier: id)
            item.label = title
            item.view = content
            settingsTabs.addTabViewItem(item)
        }
        sourcePicker.target = self
        sourcePicker.action = #selector(selectSource)
        sourceEnabled.target = self
        sourceEnabled.action = #selector(toggleSourceEnabled)
        sourceEnabled.toolTip = "Show this calendar’s events and check for updates."
        sourceColor.addItems(withTitles: sourceColorNames)
        updateSourceColorSwatches()
        sourceColor.target = self
        sourceColor.action = #selector(selectSourceColor)
        sourceColor.setAccessibilityLabel("Event color")
        sourceColor.toolTip =
            "Color for this calendar’s events. Presets adapt to appearance. Choose Custom to open the color picker."
        sourceName.placeholderString = "e.g. University"
        urlField.placeholderString = "https://…"
        sourceName.setAccessibilityLabel("Calendar name")
        urlField.setAccessibilityLabel("Subscription URL")
        let sourceRow = EditorViewController.stack(
            [
                sourcePicker,
                NSButton(title: "New subscription", target: self, action: #selector(addSource)),
                NSButton(title: "Remove", target: self, action: #selector(removeSource)),
            ], vertical: false)
        sourcePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sourcePicker.setAccessibilityLabel("Saved calendars")
        saveSourceButton.target = self
        saveSourceButton.action = #selector(saveSource)
        let saveRow = EditorViewController.stack([saveSourceButton, NSView()], vertical: false)
        tab(
            "calendars", "Calendars",
            [
                note(
                    "Choose calendars, then use the event checklist in the editor to choose what appears on your wallpaper."
                ),
                NSButton(
                    title: "Calendars on this Mac…", target: self,
                    action: #selector(chooseLocalCalendars)),
                sourceRow, field("Calendar name", sourceName), field("Subscription URL", urlField),
                field("Event color", sourceColor),
                sourceEnabled, saveRow,
            ])
        for (title, seconds) in [
            ("15 minutes", 900.0), ("30 minutes", 1800.0), ("1 hour", 3600.0), ("3 hours", 10800.0),
            ("6 hours", 21600.0), ("12 hours", 43200.0), ("24 hours", 86400.0),
        ] {
            refreshPicker.addItem(withTitle: title)
            refreshPicker.lastItem?.representedObject = seconds
        }
        refreshPicker.selectItem(
            at: refreshPicker.itemArray.firstIndex(where: {
                ($0.representedObject as? Double) == refreshInterval
            }) ?? 2)
        refreshPicker.target = self
        refreshPicker.action = #selector(changeRefreshInterval)
        automatic.title = "Automatically apply wallpaper changes"
        automatic.target = self
        automatic.action = #selector(toggleUpdates)
        automatic.state = saved["autoApply"] as? Bool == true ? .on : .off
        login.target = self
        login.action = #selector(toggleLogin)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let separator = NSBox()
        separator.boxType = .separator
        tab(
            "general", "General",
            [
                field("Check calendars every", refreshPicker),
                EditorViewController.stack(
                    [
                        automatic,
                        note(
                            "Updates the selected display, or all connected displays, when calendars or your edits change. Wapacal must be running."
                        ), login,
                    ], spacing: 10),
                separator,
                EditorViewController.stack(
                    [
                        NSButton(
                            title: "Restore previous wallpaper", target: self,
                            action: #selector(restore)),
                        note(
                            "Restores the selected display, or all connected displays, and pauses automatic updates."
                        ),
                        NSButton(
                            title: "Reset application data…", target: self,
                            action: #selector(resetData)),
                    ], spacing: 12),
            ])
        let root = NSView()
        settingsWindow.contentView = root
        settingsStatus.font = .systemFont(ofSize: 12)
        settingsStatus.textColor = .secondaryLabelColor
        settingsStatus.maximumNumberOfLines = 4
        status.mirror = settingsStatus
        settingsStatus.stringValue = status.stringValue
        for child in [settingsTabs, settingsStatus] {
            root.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            settingsTabs.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            settingsTabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            settingsTabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            settingsTabs.bottomAnchor.constraint(equalTo: settingsStatus.topAnchor, constant: -16),
            settingsStatus.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            settingsStatus.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            settingsStatus.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            settingsStatus.heightAnchor.constraint(equalToConstant: 64),
        ])
        reloadSources()
    }
    func persist() {
        guard stateReadable else { return }
        do {
            try ensureWorkspaceDirectories()
            try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys]).write(
                to: stateURL, options: .atomic)
        } catch {
            status.stringValue = "Settings could not be saved. \(error.localizedDescription)"
        }
    }
    @objc func updateScreens() {
        let previous = saved["screen"] as? String
        let wasConnected = screenPicker.itemArray.contains {
            ($0.representedObject as? String) == previous
        }
        screenPicker.removeAllItems()
        for screen in NSScreen.screens {
            screenPicker.addItem(withTitle: screen.localizedName)
            screenPicker.lastItem?.representedObject = screenID(screen)
        }
        screenPicker.addItem(withTitle: "All connected displays")
        screenPicker.lastItem?.representedObject = "all"
        if previous == "all" {
            screenPicker.selectItem(at: screenPicker.numberOfItems - 1)
        } else if let index = NSScreen.screens.firstIndex(where: { screenID($0) == previous }) {
            screenPicker.selectItem(at: index)
        } else if previous != nil {
            screenPicker.select(nil)
        }
        updateDisplayResolution()
        if ready, previous != nil, (!wasConnected || previous == "all"),
            screenPicker.selectedItem != nil
        {
            saved.removeValue(forKey: "lastHash")
            saved.removeValue(forKey: "displayHashes")
            persist()
            if automatic.state == .on { applyNow() }
        }
    }
    @objc func changeScreen() {
        var sizes = saved["displaySizes"] as? [String: [String: Int]] ?? [:]
        if let previous = saved["screen"] as? String, sizes[previous] == nil,
            let width = editorView.editor["width"] as? Int,
            let height = editorView.editor["height"] as? Int
        {
            sizes[previous] = ["width": width, "height": height]
            saved["displaySizes"] = sizes
        }
        displaySelectionGeneration &+= 1
        saved["screen"] = screenPicker.selectedItem?.representedObject as? String
        saved.removeValue(forKey: "lastHash")
        saved.removeValue(forKey: "displayHashes")
        persist()
        updateDisplayResolution()
        guard ready, let selection = saved["screen"] as? String else { return }
        var dimensions = sizes[selection]
        if dimensions == nil, let screen = try? targetScreen() {
            let size = wallpaperPixelSize(screen)
            dimensions = ["width": Int(size.width), "height": Int(size.height)]
        }
        if let dimensions, let width = dimensions["width"], let height = dimensions["height"],
            (1280...7680).contains(width), (720...4320).contains(height)
        {
            queueEditorPatch(["width": width, "height": height], automaticApply: false)
        }
    }
    var allDisplays: Bool { saved["screen"] as? String == "all" }
    func updateDisplayResolution() {
        let button = editorView.displayResolution
        let resolution = editorView.resolution
        button.isHidden = allDisplays
        editorView.displaySizes.isHidden = !allDisplays
        if allDisplays {
            resolution.removeAllItems()
            resolution.addItem(withTitle: "Use screen sizes")
            resolution.selectItem(at: 0)
            resolution.isEnabled = false
            let sizes = NSScreen.screens.map { screen in
                let size = wallpaperPixelSize(screen)
                return "\(screen.localizedName): \(Int(size.width)) × \(Int(size.height))"
            }
            let editor = editorView.editor
            var notes =
                sizes + [
                    "Apply uses each screen's size. Preview and exports use \(editor["width"] as? Int ?? 3024) × \(editor["height"] as? Int ?? 1964)."
                ]
            if wallpaperSharesAllSpacesAndDisplays() {
                notes.append(
                    "Turn off macOS's “Show on all Spaces” setting to use separate display sizes.")
            }
            editorView.displaySizes.stringValue = notes.joined(separator: "\n\n")
            button.isEnabled = false
            return
        }
        if resolution.item(withTitle: "Use screen sizes") != nil {
            editorView.updateResolutionMenu()
        }
        resolution.isEnabled = ready
        guard let screen = try? targetScreen() else {
            button.title = "Choose a connected display"
            button.isEnabled = false
            return
        }
        let size = wallpaperPixelSize(screen)
        button.title = "Use \(Int(size.width)) × \(Int(size.height))"
        button.toolTip = "Match \(screen.localizedName)'s current resolution in pixels."
        button.isEnabled =
            ready && size.width >= 1280 && size.height >= 720
            && size.width <= 7680 && size.height <= 4320
        if size.width < 1280 || size.height < 720 || size.width > 7680 || size.height > 4320 {
            button.toolTip = "Supported image sizes range from 1280 × 720 to 7680 × 4320."
        }
    }
    @objc func useDisplayResolution() {
        guard ready, let screen = try? targetScreen() else { return }
        let size = wallpaperPixelSize(screen)
        guard size.width >= 1280, size.height >= 720, size.width <= 7680, size.height <= 4320 else {
            return
        }
        window?.makeFirstResponder(nil)
        editorView.onChange?(["width": Int(size.width), "height": Int(size.height)])
    }
    @objc func changeRefreshInterval() {
        saved["refreshInterval"] = refreshPicker.selectedItem?.representedObject as? Double ?? 3600
        saved["nextCheck"] = Date().addingTimeInterval(refreshInterval).timeIntervalSince1970
        persist()
        status.stringValue =
            "Refresh frequency saved. Next check \(nextCheck.formatted(date:.omitted,time:.shortened))."
    }
    func targetScreen() throws -> NSScreen {
        guard let id = screenPicker.selectedItem?.representedObject as? String,
            let screen = NSScreen.screens.first(where: { screenID($0) == id })
        else { throw WallpaperError.invalid("Choose a connected display.") }
        return screen
    }
    func targetScreens() throws -> [NSScreen] {
        if allDisplays {
            guard !NSScreen.screens.isEmpty else {
                throw WallpaperError.invalid("Choose a connected display.")
            }
            return NSScreen.screens
        }
        return [try targetScreen()]
    }
    func js(_ body: String, _ arguments: [String: Any] = [:], updates: Bool = true) async throws
        -> Any
    {
        let generation = dataGeneration
        let script =
            updates
            ? """
            const value = await (async () => { \(body) })();
            if (value === false) return {value};
            const snapshot = window.nativeSnapshot();
            delete snapshot.svg;
            // Preview failures never discard a successfully parsed feed or saved edits.
            try { snapshot.image = (await window.nativePNG()).png; }
            catch (error) { snapshot.imageError = error.message; }
            return {value, snapshot};
            """ : body
        let response = try await engine.call(script, arguments)
        guard generation == dataGeneration else {
            throw WallpaperError.invalid("Application data changed during the operation.")
        }
        guard updates, let envelope = response as? [String: Any] else { return response }
        if let snapshot = envelope["snapshot"] as? [String: Any],
            let editor = snapshot["editor"] as? [String: Any],
            let revision = snapshot["revision"] as? Int, revision >= previewRevision
        {
            previewRevision = revision
            saved["editor"] = editor
            editorView.display(snapshot)
            updateDisplayResolution()
            if let encoded = snapshot["image"] as? String, let bytes = Data(base64Encoded: encoded),
                let image = NSImage(data: bytes)
            {
                editorView.preview.image = image
                lastEditorError = nil
                editorView.showError("")
            } else {
                reportEditorError(
                    WallpaperError.invalid(
                        snapshot["imageError"] as? String
                            ?? "Could not display the wallpaper preview."))
            }
        }
        return envelope["value"] ?? NSNull()
    }
    func reportEditorError(_ error: Error) {
        let detail =
            (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            ?? error.localizedDescription
        lastEditorError = detail
        editorView.showError(detail)
        status.stringValue = detail
    }
    func scheduleEditorSave(automaticApply: Bool = true) {
        let selectionGeneration = displaySelectionGeneration
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persist()
                if automaticApply && self?.ready == true && self?.automatic.state == .on
                    && self?.displaySelectionGeneration == selectionGeneration
                {
                    Task { @MainActor in await self?.makeAndApply(force: false) }
                }
            }
        }
    }
    func exportImage(heic: Bool, theme: String? = nil) {
        guard ready, !exporting else { return }
        exporting = true
        editorView.exportMenu.isEnabled = false
        Task { @MainActor in
            defer {
                exporting = false
                editorView.exportMenu.isEnabled = ready
            }
            do {
                while pendingEdits > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
                guard lastEditorError == nil else { return }
                let rendered =
                    try await js(
                        heic
                            ? "return await window.nativePair()"
                            : "return await window.nativePNG(\(theme == "light" ? "'light'" : theme == "dark" ? "'dark'" : "null"))",
                        updates: false) as? [String: Any]
                    ?? [:]
                let panel = NSSavePanel()
                panel.allowedContentTypes = heic ? [.heic] : [.png]
                panel.nameFieldStringValue =
                    heic ? "wapacal.heic" : theme.map { "wapacal-\($0).png" } ?? "wapacal.png"
                guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else {
                    return
                }
                if heic {
                    let parsed = try JSONDecoder().decode(
                        PairExport.self, from: JSONSerialization.data(withJSONObject: rendered))
                    guard let light = Data(base64Encoded: parsed.light),
                        let dark = Data(base64Encoded: parsed.dark)
                    else { throw WallpaperError.invalid("Could not render both appearances.") }
                    try encodePair(light: loadImage(light), dark: loadImage(dark), to: url)
                } else {
                    guard let png = rendered["png"] as? String, let bytes = Data(base64Encoded: png)
                    else { throw WallpaperError.invalid("Could not render the PNG.") }
                    try bytes.write(to: url, options: .atomic)
                }
                status.stringValue =
                    heic ? "HEIC saved with light and dark appearances." : "PNG saved."
            } catch { reportEditorError(error) }
        }
    }
    var subscriptions: [[String: Any]] { saved["subscriptions"] as? [[String: Any]] ?? [] }
    var selectedSourceIndex: Int? {
        guard let id = sourcePicker.selectedItem?.representedObject as? String else { return nil }
        return subscriptions.firstIndex { $0["id"] as? String == id }
    }
    private func sourceMenuIcon(local: Bool) -> NSImage? {
        let description = local ? "Calendar on this Mac" : "Calendar subscription"
        let image = NSImage(
            systemSymbolName: local ? "calendar" : "link", accessibilityDescription: description
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }
    func reloadSources(selected: String? = nil) {
        let currentID = sourcePicker.selectedItem?.representedObject as? String
        sourcePicker.removeAllItems()
        let groups = [
            ("CALENDARS ON THIS MAC", true),
            ("SUBSCRIPTIONS", false),
        ]
        for (title, local) in groups {
            let sources = subscriptions.filter {
                ($0["provider"] as? String == "eventkit") == local
            }
            guard !sources.isEmpty else { continue }
            if !(sourcePicker.menu?.items.isEmpty ?? true) {
                sourcePicker.menu?.addItem(.separator())
            }
            let header: NSMenuItem
            if #available(macOS 14.0, *) {
                header = .sectionHeader(title: title)
            } else {
                header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                header.attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ])
            }
            sourcePicker.menu?.addItem(header)
            for source in sources {
                let name = source["name"] as? String ?? "Calendar"
                let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
                item.representedObject = source["id"]
                item.image = sourceMenuIcon(local: local)
                item.setAccessibilityLabel(
                    "\(name), \(local ? "calendar on this Mac" : "subscription")")
                sourcePicker.menu?.addItem(item)
            }
        }
        let availableIDs = Set(subscriptions.compactMap { $0["id"] as? String })
        let preferredID =
            [selected, currentID, lastSelectedSourceID].compactMap { $0 }.first {
                availableIDs.contains($0)
            } ?? subscriptions.first?["id"] as? String
        if let item = sourcePicker.itemArray.first(where: {
            $0.representedObject as? String == preferredID
        }) {
            sourcePicker.select(item)
        } else {
            sourcePicker.select(nil)
        }
        selectSource()
    }
    @objc func selectSource() {
        NSColorPanel.shared.orderOut(nil)
        if selectedSourceIndex == nil {
            let availableIDs = Set(subscriptions.compactMap { $0["id"] as? String })
            let fallbackID =
                lastSelectedSourceID.flatMap {
                    availableIDs.contains($0) ? $0 : nil
                } ?? subscriptions.first?["id"] as? String
            if let item = sourcePicker.itemArray.first(where: {
                $0.representedObject as? String == fallbackID
            }) {
                sourcePicker.select(item)
            }
        }
        guard let index = selectedSourceIndex else {
            lastSelectedSourceID = nil
            configureSourceFields([:])
            return
        }
        let source = subscriptions[index]
        lastSelectedSourceID = source["id"] as? String
        configureSourceFields(source)
    }
    private func configureSourceFields(_ source: [String: Any]) {
        let local = source["provider"] as? String == "eventkit"
        urlField.isEnabled = !local
        urlField.stringValue = local ? "Managed by macOS Calendar" : source["url"] as? String ?? ""
        sourceName.stringValue = source["name"] as? String ?? ""
        let color = source["color"] as? String ?? "default"
        if color.hasPrefix("#"), color.count == 7, let rgb = UInt32(color.dropFirst(), radix: 16) {
            sourceColor.selectItem(withTitle: "Custom")
            customSourceColor = NSColor(
                srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
        } else {
            sourceColor.selectItem(
                at: sourceColorNames.firstIndex { $0.lowercased() == color } ?? 0)
        }
        updateSourceColorSwatches()
        sourceEnabled.state = source["enabled"] as? Bool == false ? .off : .on
        sourceEnabled.isEnabled = !source.isEmpty
        saveSourceButton.title = source.isEmpty ? "Add & refresh" : "Save & refresh"
        if ready && !fetching {
            status.stringValue =
                refreshFailure
                ?? (source.isEmpty
                    ? "Enter a name and subscription URL, then choose Add & refresh."
                    : "Editing \(sourceName.stringValue). Choose Save & refresh to save changes.")
        }
    }
    @objc func addSource() {
        NSColorPanel.shared.orderOut(nil)
        if let index = selectedSourceIndex {
            let source = subscriptions[index]
            // Keep a new URL typed before starting the new-calendar entry.
            if urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == source["url"]
                as? String
            {
                urlField.stringValue = ""
            }
            if sourceName.stringValue == source["name"] as? String { sourceName.stringValue = "" }
            sourcePicker.select(nil)
        }
        urlField.isEnabled = true
        if urlField.stringValue == "Managed by macOS Calendar" { urlField.stringValue = "" }
        sourceColor.selectItem(at: 0)
        sourceEnabled.state = .on
        sourceEnabled.isEnabled = false
        saveSourceButton.title = "Add & refresh"
        settingsWindow.makeFirstResponder(urlField)
        status.stringValue = "Enter a name and subscription URL, then choose Add & refresh."
    }
    private func updateSourceColorSwatches() {
        // Representative light-appearance colors from src/layout.mjs.
        let presets: [String: UInt32] = [
            "Green": 0x356e50, "Blue": 0x285e9b, "Purple": 0x754398,
            "Pink": 0x9b3e70, "Orange": 0x91501f, "Red": 0xa13c38,
        ]
        for item in sourceColor.itemArray {
            if item.title == "Custom" {
                item.image = colorMenuDot(hex: nil)
                continue
            }
            let color: NSColor
            if let rgb = presets[item.title] {
                color = NSColor(
                    srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                    green: CGFloat((rgb >> 8) & 255) / 255,
                    blue: CGFloat(rgb & 255) / 255, alpha: 1)
            } else {
                color = .secondaryLabelColor
            }
            item.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
                let dot = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 10, height: 10))
                color.setFill()
                dot.fill()
                NSColor.labelColor.withAlphaComponent(0.25).setStroke()
                dot.lineWidth = 0.5
                dot.stroke()
                return true
            }
        }
    }

    var selectedSourceColor: String {
        guard sourceColor.titleOfSelectedItem == "Custom" else {
            return (sourceColor.titleOfSelectedItem ?? "Default").lowercased()
        }
        let color = customSourceColor.usingColorSpace(.sRGB) ?? .systemBlue
        return String(
            format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }
    @objc func selectSourceColor() {
        if sourceColor.titleOfSelectedItem == "Custom" {
            let panel = NSColorPanel.shared
            panel.setTarget(self)
            panel.setAction(#selector(customColorChanged))
            panel.showsAlpha = false
            panel.isContinuous = false
            panel.color = customSourceColor
            panel.makeKeyAndOrderFront(nil)
        } else {
            NSColorPanel.shared.orderOut(nil)
            changeSourceColor()
        }
    }
    @objc func customColorChanged(_ panel: NSColorPanel) {
        guard sourceColor.titleOfSelectedItem == "Custom" else { return }
        customSourceColor = panel.color
        updateSourceColorSwatches()
        changeSourceColor()
    }
    @objc func changeSourceColor() {
        guard let index = selectedSourceIndex else { return }
        guard ready, !fetching else {
            selectSource()
            status.stringValue = "Wait for the current refresh to finish."
            return
        }
        var sources = subscriptions
        sources[index]["color"] = selectedSourceColor
        fetching = true
        pendingEdits += 1
        Task { @MainActor in
            do {
                _ = try await js(
                    "return window.nativeSources(subscriptions,clearCourse)",
                    ["subscriptions": sources, "clearCourse": false])
                saved["subscriptions"] = sources
                persist()
                status.stringValue =
                    "Calendar color saved. Choose Apply wallpaper to update your desktop."
            } catch {
                selectSource()
                status.stringValue =
                    "Could not change calendar color. \(error.localizedDescription)"
            }
            fetching = false
            finishLocalRefresh()
            pendingEdits -= 1
            if automatic.state == .on { await makeAndApply(force: false) }
        }
    }
    @objc func toggleSourceEnabled() {
        guard let index = selectedSourceIndex else { return }
        guard ready, !fetching else {
            sourceEnabled.state = subscriptions[index]["enabled"] as? Bool == false ? .off : .on
            status.stringValue = "Wait for the current refresh to finish."
            return
        }
        let enabled = sourceEnabled.state == .on
        var sources = subscriptions
        sources[index]["enabled"] = enabled
        fetching = true
        sourceEnabled.isEnabled = false
        Task { @MainActor in
            defer {
                fetching = false
                if enabled { localRefreshPending = true }
                finishLocalRefresh()
                sourceEnabled.isEnabled = selectedSourceIndex != nil
            }
            do {
                _ = try await js(
                    "return window.nativeSources(subscriptions,clearCourse)",
                    ["subscriptions": sources, "clearCourse": false])
                saved["subscriptions"] = sources
                if enabled { saved["nextCheck"] = 0.0 }
                persist()
                status.stringValue = enabled ? "Calendar enabled." : "Calendar disabled."
                if automatic.state == .on { await makeAndApply(force: false) }
            } catch {
                sourceEnabled.state = subscriptions[index]["enabled"] as? Bool == false ? .off : .on
                status.stringValue = "Could not update calendar. \(error.localizedDescription)"
            }
        }
    }
    @objc func removeSource() {
        guard ready, !fetching else {
            status.stringValue = "Wait for the current refresh to finish."
            return
        }
        guard let index = selectedSourceIndex else { return }
        var sources = subscriptions
        sources.remove(at: index)
        fetching = true
        Task { @MainActor in
            defer {
                fetching = false
                finishLocalRefresh()
            }
            do {
                guard
                    let reconciled = try await js(
                        "return window.nativeCalendars(subscriptions,fetchedAt)",
                        [
                            "subscriptions": sources,
                            "fetchedAt": ISO8601DateFormatter().string(from: Date()),
                        ]) as? [[String: Any]]
                else {
                    throw WallpaperError.invalid("Could not save calendar history.")
                }
                saved["subscriptions"] = reconciled
                persist()
                reloadSources()
                status.stringValue = "Calendar removed."
                if automatic.state == .on { await makeAndApply(force: false) }
            } catch {
                status.stringValue = "Could not remove calendar. \(error.localizedDescription)"
            }
        }
    }
    @objc func saveSource() {
        if let selected = selectedSourceIndex,
            subscriptions[selected]["provider"] as? String == "eventkit"
        {
            saveLocalSource(at: selected)
            return
        }
        let value = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme == "https", let host = url.host else {
            status.stringValue = "Enter an HTTPS calendar subscription URL."
            return
        }
        guard ready, !fetching else {
            status.stringValue =
                "Wait for the current refresh to finish before changing subscriptions."
            return
        }
        let index = selectedSourceIndex
        var sources = subscriptions
        guard
            !sources.enumerated().contains(where: {
                $0.offset != index && $0.element["url"] as? String == value
            })
        else {
            status.stringValue = "That calendar is already subscribed."
            return
        }
        let adding = index == nil
        var source: [String: Any] = adding ? ["id": UUID().uuidString] : sources[index!]
        if source["url"] as? String != value {
            for key in ["ics", "fetchedAt", "checkedAt", "etag", "modified", "history"] {
                source.removeValue(forKey: key)
            }
        }
        let name = sourceName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        source["url"] = value
        source["name"] = name.isEmpty ? host : name
        source["color"] = selectedSourceColor
        source["kind"] =
            host == "timeedit.net" || host.hasSuffix(".timeedit.net") ? "timeedit" : "generic"
        if adding { sources.append(source) } else { sources[index!] = source }
        saved["subscriptions"] = sources
        saved["nextCheck"] = 0.0
        if adding {
            var editor = saved["editor"] as? [String: Any] ?? [:]
            editor["course"] = ""
            saved["editor"] = editor
        }
        persist()
        reloadSources(selected: source["id"] as? String)
        Task { @MainActor in
            do {
                _ = try await js(
                    "return window.nativeSources(subscriptions,clearCourse)",
                    ["subscriptions": sources, "clearCourse": adding])
                persist()
                refreshNow()
            } catch {
                status.stringValue = "Could not load subscriptions. \(error.localizedDescription)"
            }
        }
    }
    @objc func toggleUpdates() {
        saved["autoApply"] = automatic.state == .on
        persist()
        if automatic.state == .on { applyNow() }
    }
    @objc func toggleLogin() {
        do {
            if login.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            status.stringValue =
                SMAppService.mainApp.status == .requiresApproval
                ? "Allow Wapacal under System Settings → Login Items." : "Login preference saved."
        } catch {
            status.stringValue = "Could not update login preference. \(error.localizedDescription)"
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
    @objc func tick() {
        refreshWallpaperSharingWarning()
        guard ready else { return }
        Task { @MainActor in
            do {
                let changed = try await js("return window.nativeDay()")
                if changed as? Bool == true {
                    persist()
                    if automatic.state == .on { applyNow() }
                }
            } catch { status.stringValue = error.localizedDescription }
        }
        if nextCheck <= Date() { beginRefresh(force: false) }
    }
    @objc func refreshNow() { beginRefresh(force: true) }
    @objc func refreshAndApplyNow() { beginRefresh(force: true, applyAfterRefresh: true) }
    func beginRefresh(force: Bool, applyAfterRefresh: Bool = false, localOnly: Bool = false) {
        guard ready else { return }
        if fetching {
            if localOnly { localRefreshPending = true }
            if applyAfterRefresh
                && subscriptions.contains(where: { $0["provider"] as? String == "eventkit" })
            {
                localRefreshPending = true
                localApplyPending = true
            }
            return
        }
        if localOnly && !subscriptions.contains(where: { $0["provider"] as? String == "eventkit" })
        {
            return
        }
        guard force || nextCheck <= Date() else { return }
        guard !subscriptions.isEmpty else {
            status.stringValue = "Add a calendar subscription to refresh."
            return
        }
        fetching = true
        refreshFailure = nil
        status.stringValue = "Checking calendars…"
        let generation = dataGeneration
        Task { @MainActor in
            defer {
                if generation == dataGeneration {
                    fetching = false
                    finishLocalRefresh()
                }
            }
            clearInaccessibleLocalSnapshots()
            var sources = subscriptions
            var failures: [String] = []
            let range: [String: String]
            do {
                guard
                    let result = try await js("return window.nativeCalendarWindow()")
                        as? [String: String]
                else {
                    throw WallpaperError.invalid("Could not determine the calendar date range.")
                }
                range = result
                if sources.contains(where: { $0["provider"] as? String == "eventkit" })
                    && !localCalendars.hasAccess
                {
                    _ = try await js(
                        "return window.nativeSources(subscriptions,clearCourse)",
                        ["subscriptions": sources, "clearCourse": false])
                    persist()
                }
            } catch {
                status.stringValue = error.localizedDescription
                return
            }
            for index in sources.indices {
                guard generation == dataGeneration else { return }
                let source = sources[index]
                let isLocal = source["provider"] as? String == "eventkit"
                if localOnly && !isLocal { continue }
                if isLocal {
                    do {
                        // Revocation also clears disabled calendars' cached private events.
                        if !localCalendars.hasAccess { throw LocalCalendarError.accessUnavailable }
                        if source["enabled"] as? Bool == false { continue }
                        guard let identifier = source["calendarIdentifier"] as? String,
                            let from = range["from"], let to = range["to"]
                        else {
                            throw WallpaperError.invalid("Invalid saved local calendar.")
                        }
                        let snapshot = try await localCalendars.snapshot(
                            identifier: identifier, from: from, to: to)
                        guard generation == dataGeneration else { return }
                        sources[index]["snapshot"] = snapshot
                        sources[index]["fetchedAt"] = ISO8601DateFormatter().string(from: Date())
                        sources[index].removeValue(forKey: "error")
                    } catch {
                        guard generation == dataGeneration else { return }
                        if error is LocalCalendarError {
                            sources[index].removeValue(forKey: "snapshot")
                        }
                        sources[index]["error"] = error.localizedDescription
                        failures.append(
                            "\(source["name"] as? String ?? "Calendar"): \(error.localizedDescription)"
                        )
                    }
                    do {
                        _ = try await js(
                            "return window.nativeSources(subscriptions,clearCourse)",
                            ["subscriptions": sources, "clearCourse": false])
                    } catch {
                        sources[index] = source
                        failures.append(error.localizedDescription)
                    }
                    guard generation == dataGeneration else { return }
                    continue
                }
                if source["enabled"] as? Bool == false { continue }
                do {
                    guard let value = source["url"] as? String, let url = URL(string: value),
                        url.scheme == "https", url.host != nil
                    else { throw WallpaperError.invalid("Invalid subscription URL.") }
                    var request = URLRequest(
                        url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                    if source["ics"] != nil {
                        request.setValue(
                            source["etag"] as? String, forHTTPHeaderField: "If-None-Match")
                        request.setValue(
                            source["modified"] as? String, forHTTPHeaderField: "If-Modified-Since")
                    }
                    let (bytes, response) = try await session.bytes(for: request)
                    guard generation == dataGeneration else { return }
                    guard let http = response as? HTTPURLResponse else {
                        throw WallpaperError.invalid("Invalid response.")
                    }
                    let now = ISO8601DateFormatter().string(from: Date())
                    if http.statusCode == 200 {
                        guard http.expectedContentLength <= 10_000_000 else {
                            throw WallpaperError.invalid("Calendar exceeds 10 MB.")
                        }
                        var data = Data()
                        if http.expectedContentLength > 0 {
                            data.reserveCapacity(Int(http.expectedContentLength))
                        }
                        for try await byte in bytes {
                            guard data.count < 10_000_000 else {
                                throw WallpaperError.invalid("Calendar exceeds 10 MB.")
                            }
                            data.append(byte)
                        }
                        guard let ics = String(data: data, encoding: .utf8)
                        else {
                            throw WallpaperError.invalid("Calendar is not valid UTF-8.")
                        }
                        var candidate = source
                        candidate["ics"] = ics
                        candidate["fetchedAt"] = now
                        candidate["etag"] = http.value(forHTTPHeaderField: "ETag")
                        candidate["modified"] = http.value(forHTTPHeaderField: "Last-Modified")
                        var next = sources
                        next[index] = candidate
                        guard
                            let reconciled = try await js(
                                "return window.nativeCalendars(subscriptions,fetchedAt)",
                                ["subscriptions": next, "fetchedAt": now]) as? [[String: Any]]
                        else {
                            throw WallpaperError.invalid("Could not save calendar history.")
                        }
                        guard generation == dataGeneration else { return }
                        sources = reconciled
                    } else if http.statusCode != 304 || source["ics"] == nil {
                        throw WallpaperError.invalid("HTTP \(http.statusCode).")
                    }
                    sources[index]["checkedAt"] = now
                    sources[index].removeValue(forKey: "error")
                } catch {
                    guard generation == dataGeneration else { return }
                    let detail =
                        (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                        ?? error.localizedDescription
                    sources[index]["error"] = detail
                    failures.append("\(source["name"] as? String ?? "Calendar"): \(detail)")
                }
            }
            guard generation == dataGeneration else { return }
            saved["subscriptions"] = sources
            if !localOnly {
                saved["nextCheck"] =
                    Date().addingTimeInterval(failures.isEmpty ? refreshInterval : 300)
                    .timeIntervalSince1970
            }
            persist()
            let sourceFailures = sources.compactMap { source -> String? in
                guard let error = source["error"] as? String else { return nil }
                return "\(source["name"] as? String ?? "Calendar"): \(error)"
            }
            failures = Array(Set(failures + sourceFailures)).sorted()
            refreshFailure =
                failures.isEmpty
                ? nil
                : "Refresh failed. \(failures.joined(separator:" ")) Unavailable calendars may be empty or show saved events. Check calendar access and try Refresh again."
            status.stringValue =
                refreshFailure
                ?? "Calendars checked at \(Date().formatted(date:.omitted,time:.shortened))."
            localApplyPending = localApplyPending || applyAfterRefresh
            if !localRefreshPending && (localApplyPending || automatic.state == .on) {
                let forceApply = localApplyPending
                localApplyPending = false
                await makeAndApply(force: forceApply)
            }
        }
    }
    @objc func applyNow() {
        window?.makeFirstResponder(nil)
        Task { @MainActor in await makeAndApply(force: true) }
    }
    func makeAndApply(force: Bool) async {
        refreshWallpaperSharingWarning()
        while pendingEdits > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard ready, lastEditorError == nil else { return }
        if rendering {
            rerender = true
            return
        }
        rendering = true
        defer {
            rendering = false
            if rerender {
                rerender = false
                Task { @MainActor in await makeAndApply(force: false) }
            }
        }
        do {
            let operationGeneration = displaySelectionGeneration
            let selection = saved["screen"] as? String
            let screens = try targetScreens()
            if wallpaperSharesAllSpacesAndDisplays() {
                throw WallpaperError.invalid(
                    "macOS is set to show one wallpaper on all Spaces and displays. Turn off “Show on all Spaces” in System Settings → Wallpaper before applying separate display wallpapers."
                )
            }
            let previousWallpapers = Dictionary(
                uniqueKeysWithValues: NSScreen.screens.map {
                    (screenID($0), NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL)
                })
            var failures: [String] = []
            for screen in screens {
                do {
                    let size = wallpaperPixelSize(screen)
                    if allDisplays && (size.width > 7680 || size.height > 4320) {
                        throw WallpaperError.invalid("Resolution exceeds 7680 × 4320.")
                    }
                    let dimensions: [String: Any] =
                        allDisplays
                        ? ["width": Int(size.width), "height": Int(size.height)] : [:]
                    guard
                        let pair = try await js(
                            "return await window.nativePair(size)", ["size": dimensions],
                            updates: false
                        ) as? [String: Any]
                    else {
                        throw WallpaperError.invalid("Could not render the wallpaper.")
                    }
                    guard saved["screen"] as? String == selection else {
                        rerender = true
                        return
                    }
                    guard displaySelectionGeneration == operationGeneration else {
                        rerender = true
                        return
                    }
                    guard NSScreen.screens.contains(where: { screenID($0) == screenID(screen) })
                    else {
                        throw WallpaperError.invalid("Display disconnected.")
                    }
                    try install(pair, screen: screen, force: force)
                } catch {
                    failures.append("\(screen.localizedName): \(error.localizedDescription)")
                }
            }
            if !allDisplays, failures.isEmpty {
                let targetIDs = Set(screens.map(screenID))
                let changedOther = NSScreen.screens.first { other in
                    guard !targetIDs.contains(screenID(other)) else { return false }
                    return NSWorkspace.shared.desktopImageURL(for: other)?.standardizedFileURL
                        != previousWallpapers[screenID(other)]
                }
                if let changedOther {
                    throw WallpaperError.invalid(
                        "macOS changed the wallpaper on \(changedOther.localizedName) too. Turn off “Show on all Spaces” in System Settings → Wallpaper before applying to one display."
                    )
                }
            }
            if !failures.isEmpty {
                status.stringValue = failures.joined(separator: " ")
            } else if allDisplays && refreshFailure == nil {
                status.stringValue =
                    "Wallpaper applied to \(screens.count) displays at their own resolutions."
            }
        } catch { status.stringValue = "Wallpaper kept. \(error.localizedDescription)" }
    }
    func install(_ pair: [String: Any], screen: NSScreen, force: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: pair, options: [.sortedKeys])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var hashes = saved["displayHashes"] as? [String: String] ?? [:]
        if !force && hashes[screenID(screen)] == digest {
            return
        }
        let parsed = try JSONDecoder().decode(PairExport.self, from: data)
        guard let light = Data(base64Encoded: parsed.light),
            let dark = Data(base64Encoded: parsed.dark)
        else { throw WallpaperError.invalid("Could not render both appearances.") }
        let file = wallpapersDirectory().appendingPathComponent("editor-wallpaper.heic")
        try encodePair(light: loadImage(light), dark: loadImage(dark), to: file)
        let restorable = try applyWallpaper(file, screen: screen)
        hashes[screenID(screen)] = digest
        saved["displayHashes"] = hashes
        if !allDisplays { saved["screen"] = screenID(screen) }
        persist()
        status.stringValue =
            refreshFailure
            ?? (restorable
                ? "Wallpaper applied. macOS switches between light and dark."
                : "Wallpaper applied. The previous wallpaper file is unavailable for restoration.")
    }
    @objc func restore() {
        guard !rendering else {
            status.stringValue = "Wait for the current wallpaper operation to finish."
            return
        }
        do {
            automatic.state = .off
            saved["autoApply"] = false
            saved.removeValue(forKey: "lastHash")
            saved.removeValue(forKey: "displayHashes")
            persist()
            var failures: [String] = []
            for screen in try targetScreens() {
                do { try restoreWallpaper(screen: screen) } catch {
                    failures.append("\(screen.localizedName): \(error.localizedDescription)")
                }
            }
            guard failures.isEmpty else {
                throw WallpaperError.invalid(failures.joined(separator: " "))
            }
            status.stringValue = "Previous wallpaper restored. Automatic updates paused."
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc func resetData() {
        let alert = NSAlert()
        alert.messageText = "Reset Wapacal data?"
        alert.informativeText =
            "This removes the saved subscriptions, cached calendars, editor settings, and inactive generated wallpapers. Active wallpaper files and recovery records are kept so your desktop can still be restored."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset data")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            saveTimer?.invalidate()
            dataGeneration += 1
            localCalendarTimer?.invalidate()
            localRefreshPending = false
            localApplyPending = false
            waitingForCalendarAccess = false
            fetching = false
            refreshFailure = nil
            session.invalidateAndCancel()
            session = URLSession(configuration: .ephemeral)
            try? SMAppService.mainApp.unregister()
            automatic.state = .off
            login.state = .off
            try resetInactiveRuntimeData()
            stateReadable = true
            stateLoadError = nil
            saved = [
                "subscriptions": [] as [[String: Any]], "courseCode": "", "refreshInterval": 3600.0,
                "nextCheck": 0.0,
            ]
            reloadSources()
            refreshPicker.selectItem(at: 2)
            persist()
            if workerStarted {
                Task { @MainActor in
                    do {
                        _ = try await js("return window.nativeReset()")
                        ready = true
                        editorView.setReady(true)
                        persist()
                        status.stringValue =
                            "Application data reset. Active wallpaper recovery was kept."
                    } catch {
                        status.stringValue =
                            "Data reset, but the editor could not refresh. Reopen the app. \(error.localizedDescription)"
                    }
                }
            } else {
                status.stringValue =
                    "Application data reset. Active wallpaper recovery was kept. Reopen Wapacal to start the editor."
            }
        } catch {
            status.stringValue =
                "Application data could not be reset. \(error.localizedDescription)"
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        show()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        window?.makeFirstResponder(nil)
        guard pendingEdits > 0 else {
            persist()
            return .terminateNow
        }
        if !terminating {
            terminating = true
            Task { @MainActor in
                while pendingEdits > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
                persist()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { persist() }
}
