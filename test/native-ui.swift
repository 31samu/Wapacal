import AppKit
import WebKit

// Compiled into a temporary fixture-only app by native-ui.mjs.
// Wallpaper apply/restore checks require explicit WAPACAL_TEST_WALLPAPER=1.
// Never changes login items or the user's Application Support directory.
func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw WallpaperError.invalid("Native UI test failed: " + message) }
}
func supportsImageSize(_ size: NSSize) -> Bool {
    (1280...7680).contains(Int(size.width)) && (720...4320).contains(Int(size.height))
}
@MainActor
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

// No EventKit requests or personal calendar access in this fixture app.
final class FixtureLocalCalendars: LocalCalendarProviding {
    var hasAccess = true
    var removed = false
    var missing = false
    var temporaryFailure = false
    var requests: [(String, String)] = []
    func requestAccess() async throws -> Bool { hasAccess }
    func calendars() async throws -> [LocalCalendarInfo] {
        (0..<24).map { index in
            LocalCalendarInfo(
                identifier: "fixture-\(index)", title: "Local Calendar \(index)",
                account: "Fixture Account", color: "#336699")
        }
    }
    func snapshot(identifier: String, from: String, to: String) async throws -> [String: Any] {
        requests.append((from, to))
        if missing { throw LocalCalendarError.calendarMissing }
        if temporaryFailure { throw WallpaperError.invalid("Temporary fixture failure") }
        return [
            "version": 1, "coverageStart": from, "coverageEnd": to,
            "events": removed
                ? []
                : [
                    [
                        "uid": "fixture-event", "start": "2026-09-08T08:00:00Z",
                        "end": "2026-09-08T09:00:00Z",
                        "allDay": false, "title": "Local fixture event",
                        "summary": "Local fixture event",
                        "description": "Fixture details", "location": "Fixture room",
                    ]
                ],
        ]
    }
}

let application = NSApplication.shared
let editorApp = MainActor.assumeIsolated { EditorApp() }
application.delegate = editorApp
@MainActor
func hideTestApplication() {
    // Reopen checks request activation just before shutdown. Withdraw the fixture
    // from the Dock explicitly before exiting, including when an assertion fails.
    application.hide(nil)
    application.setActivationPolicy(.prohibited)
}
Task { @MainActor in
    do {
        let deadline = Date().addingTimeInterval(40)
        while !editorApp.ready && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(editorApp.ready, "startup: \(editorApp.status.stringValue)")
        editorApp.timer?.invalidate()
        for (shared, expected) in [("$null" as Any, false), (["Desktop": [:]] as Any, true)] {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["AllSpacesAndDisplays": shared], format: .binary, options: 0)
            try require(
                wallpaperSharesAllSpacesAndDisplays(in: data) == expected,
                "shared wallpaper detection distinguishes the disabled sentinel from a configuration"
            )
        }
        let ui = editorApp.editorView
        editorApp.showWallpaperSharingWarning(true)
        editorApp.window.contentView!.layoutSubtreeIfNeeded()
        try require(
            !editorApp.wallpaperSharingWarning.isHidden
                && editorApp.wallpaperSharingWarning.frame.height > 0,
            "shared-wallpaper warning is visible above the editor")
        try require(
            editorApp.wallpaperSharingMessage.stringValue.contains("Show on all Spaces")
                && editorApp.wallpaperSettingsButton.action == #selector(
                    editorApp.openWallpaperSettings),
            "warning explains the setting and offers a settings shortcut")
        let warningFrame = editorApp.wallpaperSharingWarning.convert(
            editorApp.wallpaperSharingWarning.bounds, to: editorApp.window.contentView)
        try require(
            editorApp.window.contentView!.bounds.contains(warningFrame),
            "warning fits in the window")
        editorApp.showWallpaperSharingWarning(false)
        try require(
            editorApp.wallpaperSharingWarning.isHidden, "warning disappears when sharing is off")
        editorApp.refreshWallpaperSharingWarning()
        try require(
            !descendants(editorApp.window.contentView!).contains { $0 is WKWebView },
            "web view in window hierarchy")
        try require(ui.preview.image != nil, "native image preview")
        try require(ui.table.numberOfRows > 0, "event rows")
        try require(ui.name.stringValue == "Prototype module", "saved module name")
        try require(ui.resolution.titleOfSelectedItem == "2880 × 1800", "custom saved image size")
        let initialScreen = editorApp.saved["screen"]
        for screen in NSScreen.screens {
            editorApp.screenPicker.selectItem(
                at: editorApp.screenPicker.itemArray.firstIndex {
                    $0.representedObject as? String == screenID(screen)
                }!)
            let previousSize = ui.resolution.titleOfSelectedItem
            let size = wallpaperPixelSize(screen)
            let screenSize = "\(Int(size.width)) × \(Int(size.height))"
            let expectedSize = supportsImageSize(size) ? screenSize : previousSize
            editorApp.changeScreen()
            while editorApp.pendingEdits > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
            try require(
                ui.resolution.titleOfSelectedItem == expectedSize,
                "display \(screen.localizedName) at \(screenSize): expected \(expectedSize ?? "nil"), got \(ui.resolution.titleOfSelectedItem ?? "nil")"
            )
            try require(
                ui.displayResolution.isEnabled == supportsImageSize(size),
                "display resolution button availability for \(screenSize)")
            try require(
                ui.displayResolution.title == "Use \(Int(size.width)) × \(Int(size.height))",
                "display pixel suggestion")
            print(
                "Display: \(screen.localizedName), \(Int(size.width)) × \(Int(size.height)) pixels")
        }
        let selectedSize = wallpaperPixelSize(try editorApp.targetScreen())
        let previousWidth = ui.editor["width"] as? Int
        let previousHeight = ui.editor["height"] as? Int
        if supportsImageSize(selectedSize) {
            ui.displayResolution.performClick(nil)
        } else {
            // A direct invocation must also reject sizes unavailable through the button.
            editorApp.useDisplayResolution()
        }
        while editorApp.pendingEdits > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        let expectedWidth =
            supportsImageSize(selectedSize) ? Int(selectedSize.width) : previousWidth
        let expectedHeight =
            supportsImageSize(selectedSize) ? Int(selectedSize.height) : previousHeight
        try require(
            ui.editor["width"] as? Int == expectedWidth
                && ui.editor["height"] as? Int == expectedHeight,
            "use display resolution: expected \(String(describing: expectedWidth)) × \(String(describing: expectedHeight)), got \(String(describing: ui.editor["width"])) × \(String(describing: ui.editor["height"]))"
        )
        for (index, screen) in NSScreen.screens.enumerated() {
            editorApp.screenPicker.selectItem(at: index)
            editorApp.changeScreen()
            while editorApp.pendingEdits > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
            editorApp.queueEditorPatch(
                ["width": 2560 + index * 128, "height": 1440], automaticApply: false)
            while editorApp.pendingEdits > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
            try require(
                (editorApp.saved["displaySizes"] as? [String: [String: Int]])?[screenID(screen)]?[
                    "width"] == 2560 + index * 128,
                "custom dimensions are saved under the display identity")
        }
        for index in NSScreen.screens.indices.reversed() {
            editorApp.screenPicker.selectItem(at: index)
            editorApp.changeScreen()
            while editorApp.pendingEdits > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
            try require(
                ui.editor["width"] as? Int == 2560 + index * 128,
                "switching back restores that display's custom resolution")
            try require(
                ui.preview.image?.representations.first?.pixelsWide == 2560 + index * 128
                    && ui.preview.image?.representations.first?.pixelsHigh == 1440,
                "switching back rerenders the preview at that display's saved size")
            ui.displayResolution.performClick(nil)
            while editorApp.pendingEdits > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        _ = try await editorApp.js(
            "return window.nativeUpdate(patch)", ["patch": ["width": 2880, "height": 1800]])
        editorApp.screenPicker.selectItem(withTitle: "All connected displays")
        editorApp.changeScreen()
        let targets = try editorApp.targetScreens()
        try require(targets.count == NSScreen.screens.count, "all displays selected")
        try require(!ui.displayResolution.isEnabled, "all displays use their own size")
        try require(
            ui.resolution.titleOfSelectedItem == "Use screen sizes" && !ui.resolution.isEnabled,
            "all displays show screen sizing instead of one numeric resolution")
        try require(
            ui.displayResolution.isHidden && !ui.displaySizes.isHidden,
            "all displays show the per-screen size explanation")
        for screen in try editorApp.targetScreens() {
            let size = wallpaperPixelSize(screen)
            try require(
                ui.displaySizes.stringValue.contains(
                    "\(screen.localizedName): \(Int(size.width)) × \(Int(size.height))"),
                "each screen's size is visible")
            if !supportsImageSize(size) {
                let error =
                    try await editorApp.js(
                        "try { await window.nativePair(size); return ''; } catch (error) { return error.message; }",
                        ["size": ["width": Int(size.width), "height": Int(size.height)]],
                        updates: false
                    ) as? String
                try require(
                    error?.contains("Use an image between 1280 × 720 and 7680 × 4320 pixels.")
                        == true,
                    "unsupported display render must report the image size limits, got \(error ?? "nil")"
                )
                continue
            }
            let pair =
                try await editorApp.js(
                    "return await window.nativePair(size)",
                    ["size": ["width": Int(size.width), "height": Int(size.height)]], updates: false
                ) as! [String: Any]
            for theme in ["light", "dark"] {
                let image = try loadImage(Data(base64Encoded: pair[theme] as! String)!)
                try require(
                    image.width == Int(size.width) && image.height == Int(size.height),
                    "per-display \(theme) render dimensions")
            }
        }
        try require(
            ui.editor["width"] as? Int == 2880 && ui.editor["height"] as? Int == 1800,
            "per-display render preserves editor size")
        for (index, screen) in NSScreen.screens.enumerated() {
            editorApp.screenPicker.selectItem(
                at: editorApp.screenPicker.itemArray.firstIndex {
                    $0.representedObject as? String == screenID(screen)
                }!)
            editorApp.changeScreen()
            try require(
                editorApp.pendingEdits > 0, "leaving all displays queues sizing before Apply")
            while editorApp.pendingEdits > 0 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let size = wallpaperPixelSize(screen)
            let width = supportsImageSize(size) ? Int(size.width) : 2560 + index * 128
            let height = supportsImageSize(size) ? Int(size.height) : 1440
            try require(
                ui.editor["width"] as? Int == width && ui.editor["height"] as? Int == height,
                "leaving all displays restores saved size: expected \(width) × \(height), got \(String(describing: ui.editor["width"])) × \(String(describing: ui.editor["height"]))"
            )
            try require(
                ui.resolution.titleOfSelectedItem == "\(width) × \(height)",
                "selected screen size is reflected in the size menu")
            editorApp.screenPicker.selectItem(withTitle: "All connected displays")
            editorApp.changeScreen()
        }
        _ = try await editorApp.js(
            "return window.nativeUpdate(patch)", ["patch": ["width": 2880, "height": 1800]])
        if ProcessInfo.processInfo.environment["WAPACAL_TEST_WALLPAPER"] == "1" {
            let screens = NSScreen.screens
            let originals = screens.map { WallpaperBackup(screen: $0) }
            try require(
                originals.allSatisfy { $0.canRestore },
                "all original wallpapers must be restorable before live testing")
            defer {
                for (screen, original) in zip(screens, originals) {
                    try? NSWorkspace.shared.setDesktopImageURL(
                        original.url!, for: screen, options: original.options)
                }
            }
            await editorApp.makeAndApply(force: true)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            for screen in screens {
                let url = NSWorkspace.shared.desktopImageURL(for: screen)!
                try require(
                    url.path.hasPrefix(appliedDirectory().path),
                    "live wallpaper applied to \(screen.localizedName): \(editorApp.status.stringValue)"
                )
                let info = try inspectData(readBounded(url))
                let size = wallpaperPixelSize(screen)
                try require(
                    info.width == Int(size.width) && info.height == Int(size.height),
                    "live wallpaper dimensions for \(screen.localizedName)")
                let originalData = try readBounded(url)
                let source = CGImageSourceCreateWithData(originalData as CFData, nil)!
                let changed = wallpapersDirectory().appendingPathComponent("refresh-test.heic")
                // Swap appearances to ensure subsequent updates contain changed content.
                try encodePair(
                    light: CGImageSourceCreateImageAtIndex(source, 1, nil)!,
                    dark: CGImageSourceCreateImageAtIndex(source, 0, nil)!, to: changed)
                let changedData = try readBounded(changed)
                try require(changedData != originalData, "refresh fixture has different content")
                try encodePair(
                    light: CGImageSourceCreateImageAtIndex(source, 0, nil)!,
                    dark: CGImageSourceCreateImageAtIndex(source, 0, nil)!, to: changed)
                let thirdData = try readBounded(changed)
                let backupData = try Data(contentsOf: backupURL(screen))
                var imagesByURL: [URL: Data] = [url.standardizedFileURL: originalData]
                for expectedData in [changedData, thirdData, originalData, originalData] {
                    try expectedData.write(to: changed, options: .atomic)
                    _ = try applyWallpaper(changed, screen: screen)
                    let updatedURL = NSWorkspace.shared.desktopImageURL(for: screen)!
                        .standardizedFileURL
                    if let existing = imagesByURL[updatedURL] {
                        try require(existing == expectedData, "a reused URL has identical content")
                    }
                    imagesByURL[updatedURL] = expectedData
                    for (oldURL, oldData) in imagesByURL {
                        let retainedData = try readBounded(oldURL)
                        try require(
                            retainedData == oldData, "earlier wallpaper images stay unchanged")
                    }
                    let appliedData = try readBounded(updatedURL)
                    try require(appliedData == expectedData, "repeated update writes the new image")
                    _ = try inspectData(appliedData)
                    let savedBackup = try Data(contentsOf: backupURL(screen))
                    try require(savedBackup == backupData, "refresh preserves the original backup")
                }
                try require(imagesByURL.count == 3, "three images have three stable URLs")
            }
            let appliedFiles = try FileManager.default.contentsOfDirectory(
                at: appliedDirectory(), includingPropertiesForKeys: nil)
            try require(
                appliedFiles.filter { $0.pathExtension == "heic" }.count <= screens.count * 3,
                "identical images do not create duplicate files")
            editorApp.restore()
            for (screen, original) in zip(screens, originals) {
                try require(
                    NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL
                        == original.url?.standardizedFileURL, "live wallpaper restoration")
            }
            for index in Array(screens.indices) + Array(screens.indices.reversed()) {
                let screen = screens[index]
                editorApp.automatic.state = .on
                editorApp.screenPicker.selectItem(at: index)
                editorApp.changeScreen()
                try await Task.sleep(nanoseconds: 800_000_000)
                try require(
                    screens.allSatisfy {
                        NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL
                            == originals[screens.firstIndex(of: $0)!].url?.standardizedFileURL
                    },
                    "changing the target display does not apply a wallpaper automatically")
                editorApp.useDisplayResolution()
                let applyDeadline = Date().addingTimeInterval(15)
                var didApply = false
                while Date() < applyDeadline {
                    if let url = NSWorkspace.shared.desktopImageURL(for: screen),
                        url.path.hasPrefix(appliedDirectory().path)
                    {
                        let info = try inspectData(readBounded(url))
                        let size = wallpaperPixelSize(screen)
                        try require(
                            info.width == Int(size.width) && info.height == Int(size.height),
                            "automatic size edit uses the selected display's resolution"
                        )
                        if !editorApp.rendering && editorApp.pendingEdits == 0 {
                            didApply = true
                            break
                        }
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try require(
                    didApply, "size edit automatically applies to the selected screen")
                try require(
                    NSWorkspace.shared.desktopImageURL(for: screen)!.path.hasPrefix(
                        appliedDirectory().path), "single-display apply")
                for (other, original) in zip(screens, originals)
                where screenID(other) != screenID(screen) {
                    try require(
                        NSWorkspace.shared.desktopImageURL(for: other)?.standardizedFileURL
                            == original.url?.standardizedFileURL,
                        "single-display apply leaves other displays unchanged")
                }
                editorApp.restore()
                try require(
                    NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL
                        == originals[index].url?.standardizedFileURL, "single-display restore")
            }
            print("Live wallpaper apply and restore passed on \(screens.count) displays")
        }
        _ = try await editorApp.js(
            "return window.nativeUpdate(patch)", ["patch": ["width": 2880, "height": 1800]])
        editorApp.saved["screen"] = "disconnected-fixture-display"
        editorApp.updateScreens()
        try require(
            editorApp.screenPicker.selectedItem == nil,
            "disconnected selection does not fall back to another display")
        try require(!ui.displayResolution.isEnabled, "disconnected resolution button disabled")
        editorApp.saved["screen"] = "all"
        editorApp.updateScreens()
        try require(
            editorApp.screenPicker.titleOfSelectedItem == "All connected displays",
            "all displays selection survives display refresh")
        editorApp.saved["screen"] = initialScreen
        editorApp.updateScreens()
        try require(
            ui.resolution.titleOfSelectedItem == "2880 × 1800" && ui.resolution.isEnabled,
            "returning to one display restores the custom size control")
        try require(ui.resolution.item(withTitle: "Custom…") != nil, "custom size menu option")
        editorApp.saved["screen"] = screenID(NSScreen.screens[0])
        editorApp.updateScreens()
        for accept in [false, true] {
            ui.resolution.selectItem(withTitle: "Custom…")
            ui.changeControl(ui.resolution)
            guard let sheet = editorApp.window.attachedSheet else {
                throw WallpaperError.invalid("Custom image size sheet did not open")
            }
            let fields = descendants(sheet.contentView!).compactMap { $0 as? NSTextField }
                .filter { $0.isEditable }
            try require(fields.count == 2, "custom size has width and height fields")
            try require(
                fields[0].stringValue == "2880" && fields[1].stringValue == "1800",
                "custom size starts with current dimensions")
            let useSize = descendants(sheet.contentView!).compactMap { $0 as? NSButton }
                .first { $0.title == "Use size" }!
            for invalid in ["", "abc", "1280.5", "1279", "7681"] {
                fields[0].stringValue = invalid
                ui.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
                try require(!useSize.isEnabled, "invalid custom width is rejected: \(invalid)")
            }
            fields[0].stringValue = "3200"
            fields[1].stringValue = "4321"
            ui.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            try require(!useSize.isEnabled, "invalid custom height is rejected")
            fields[1].stringValue = "2000"
            ui.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            try require(useSize.isEnabled, "valid custom size is accepted")
            editorApp.window.endSheet(
                sheet, returnCode: accept ? .alertFirstButtonReturn : .alertSecondButtonReturn)
            try await Task.sleep(nanoseconds: 300_000_000)
            while editorApp.pendingEdits > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
            try require(
                ui.resolution.titleOfSelectedItem == (accept ? "3200 × 2000" : "2880 × 1800"),
                "custom size applies only when confirmed")
        }
        try require(
            (editorApp.saved["displaySizes"] as? [String: [String: Int]])?[
                screenID(NSScreen.screens[0])] == ["width": 3200, "height": 2000],
            "custom menu size is remembered for the selected display")
        editorApp.queueEditorPatch(["width": 2880, "height": 1800], automaticApply: false)
        while editorApp.pendingEdits > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        try require(ui.showTitle.state == .off, "legacy title default")
        try require(ui.includeWeekends.state == .off, "weekends default off")
        ui.includeWeekends.performClick(nil)
        let weekendDeadline = Date().addingTimeInterval(15)
        while ui.editor["includeWeekends"] as? Bool != true && Date() < weekendDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(
            ui.editor["includeWeekends"] as? Bool == true,
            "weekend inclusion action persists")
        try require(
            (editorApp.saved["editor"] as? [String: Any])?["futureSetting"] as? String == "kept",
            "unknown saved setting")
        try require(editorApp.refreshInterval == 1800, "saved refresh interval")

        if ProcessInfo.processInfo.environment["WAPACAL_UI_HOLD"] == "1" {
            print("Fixture UI ready")
            return
        }

        let mainMenu = NSApp.mainMenu!
        let appMenu = mainMenu.items[0].submenu!
        try require(
            appMenu.items.first?.title == "About Wapacal"
                && appMenu.items.first?.action == #selector(editorApp.showAbout),
            "About is the first application menu item")
        appMenu.performActionForItem(at: 0)
        let aboutWindow = editorApp.aboutWindow
        try require(aboutWindow?.isVisible == true, "About menu opens a window")
        let aboutContent = aboutWindow!.contentView!
        try require(
            !descendants(aboutContent).contains { $0 is NSScrollView },
            "About fits without scrolling")
        aboutContent.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let aboutImage = aboutContent.bitmapImageRepForCachingDisplay(in: aboutContent.bounds)!
        aboutContent.cacheDisplay(in: aboutContent.bounds, to: aboutImage)
        try aboutImage.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAPACAL_UI_OUTPUT"]!)
                .appendingPathComponent("native-about.png"))
        editorApp.showAbout()
        try require(editorApp.aboutWindow === aboutWindow, "About reuses its window")
        editorApp.window.performClose(nil)
        try require(NSApp.activationPolicy() == .regular, "About keeps the application active")
        aboutWindow?.performClose(nil)
        try require(NSApp.activationPolicy() == .accessory, "closing About returns to menu bar")
        editorApp.show()
        try require(
            editorApp.statusMenu!.items.map { $0.title } == [
                "Open Wapacal", "Settings…", "Refresh & Apply", "Quit",
            ]
                && editorApp.statusMenu!.items[2].action
                    == #selector(editorApp.refreshAndApplyNow),
            "compact menu bar refresh-and-apply action")
        let calendarMenu = mainMenu.items.first { $0.title == "Calendar" }!.submenu!
        try require(
            calendarMenu.items.first?.title == "Refresh & Apply"
                && calendarMenu.items.first?.action == #selector(editorApp.refreshAndApplyNow),
            "Calendar menu refresh-and-apply action")
        let fileMenu = mainMenu.items.first { $0.title == "File" }!.submenu!
        try require(
            fileMenu.items.first?.title == "Open wallpaper…"
                && fileMenu.items.first?.keyEquivalent == "o", "File menu import shortcut")
        let importer = editorApp.getCompanion()
        try require(
            importer.window == nil && NSApp.mainMenu === mainMenu,
            "creating importer opens no empty window or replacement menu")
        let missing = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["WAPACAL_UI_OUTPUT"]!
        ).appendingPathComponent("missing.heic")
        editorApp.openExportFile(missing.path)
        try require(
            importer.window == nil && editorApp.lastEditorError != nil,
            "invalid import reports error without empty preview")
        ui.showError("")

        let originalAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        _ = try await editorApp.js("return window.nativeUpdate({theme: 'system'});")
        let systemLight = ui.preview.image!.tiffRepresentation!
        let explicitLight =
            try await editorApp.engine.call(
                "window.nativeUpdate({theme: 'light'}); return window.nativeSnapshot().svg;")
            as! String
        let systemSVG =
            try await editorApp.engine.call(
                "window.nativeUpdate({theme: 'system'}); return window.nativeSnapshot().svg;")
            as! String
        try require(systemSVG == explicitLight, "system uses AppKit light appearance")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let appearanceDeadline = Date().addingTimeInterval(15)
        while ui.preview.image!.tiffRepresentation! == systemLight && Date() < appearanceDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(
            ui.preview.image!.tiffRepresentation! != systemLight,
            "system preview refreshes when AppKit appearance changes")
        let systemDark =
            try await editorApp.engine.call(
                "return window.nativeSnapshot().svg;") as! String
        let explicitDark =
            try await editorApp.engine.call(
                "window.nativeUpdate({theme: 'dark'}); return window.nativeSnapshot().svg;")
            as! String
        try require(systemDark == explicitDark, "system uses AppKit dark appearance")
        _ = try await editorApp.js("return true;")
        NSApp.appearance = originalAppearance
        _ = try await editorApp.js("return window.nativeUpdate({theme: 'light'});")
        print("System appearance checks passed")

        // Settings reuse the original controls and state in a separate native window.
        try require(
            editorApp.urlField.window === editorApp.settingsWindow,
            "subscription field belongs to Settings")
        try require(!editorApp.settingsWindow.isVisible, "Settings stays closed at startup")
        let settingsItem = NSApp.mainMenu!.items[0].submenu!.items.first { $0.title == "Settings…" }
        try require(settingsItem?.keyEquivalent == ",", "standard Settings shortcut")
        editorApp.showSettings()
        editorApp.settingsWindow.contentView?.layoutSubtreeIfNeeded()
        try require(editorApp.settingsWindow.isVisible, "open Settings")
        try require(
            !descendants(editorApp.settingsWindow.contentView!).contains { $0 is WKWebView },
            "native Settings")
        try require(editorApp.urlField.frame.width > 450, "readable subscription URL field")
        let settingsRoot = editorApp.settingsWindow.contentView!
        let saveBounds = editorApp.saveSourceButton.convert(
            editorApp.saveSourceButton.bounds, to: settingsRoot)
        let statusBounds = editorApp.settingsStatus.convert(
            editorApp.settingsStatus.bounds, to: settingsRoot)
        try require(settingsRoot.bounds.contains(saveBounds), "save button inside Settings")
        try require(!saveBounds.intersects(statusBounds), "save button does not overlap status")
        try require(
            !descendants(settingsRoot).contains { $0 is NSColorWell }, "custom color uses the menu")
        let subscriptionMenuItems = editorApp.sourcePicker.itemArray
        try require(
            subscriptionMenuItems.map(\.title) == ["SUBSCRIPTIONS", "Fixture calendar"],
            "subscription calendars have a labeled menu section")
        if #available(macOS 14.0, *) {
            try require(
                subscriptionMenuItems[0].isSectionHeader,
                "calendar menu uses a native section heading")
        } else {
            try require(
                !subscriptionMenuItems[0].isEnabled,
                "calendar menu heading is disabled on macOS 13")
        }
        try require(subscriptionMenuItems[1].image != nil, "subscription calendar has an icon")
        try require(
            editorApp.selectedSourceIndex == 0, "menu headings do not change source indexing")
        editorApp.sourcePicker.selectItem(at: 0)
        editorApp.selectSource()
        try require(
            editorApp.sourcePicker.titleOfSelectedItem == "Fixture calendar",
            "selecting a section heading restores the calendar")
        let fixtureSubscription = editorApp.subscriptions[0]
        editorApp.saved["subscriptions"] =
            [
                fixtureSubscription,
                [
                    "id": "menu-local", "provider": "eventkit",
                    "calendarIdentifier": "menu-local", "name": "Local fixture",
                ],
            ] as [[String: Any]]
        editorApp.reloadSources(selected: "legacy")
        guard
            let separatorIndex = editorApp.sourcePicker.itemArray.firstIndex(where: {
                $0.isSeparatorItem
            })
        else { throw WallpaperError.invalid("Calendar menu separator is missing") }
        editorApp.sourcePicker.selectItem(at: separatorIndex)
        editorApp.selectSource()
        try require(
            editorApp.sourcePicker.titleOfSelectedItem == "Fixture calendar",
            "selecting a separator restores the calendar")
        editorApp.saved["subscriptions"] = [fixtureSubscription]
        editorApp.reloadSources(selected: "legacy")
        let settingsImage = settingsRoot.bitmapImageRepForCachingDisplay(in: settingsRoot.bounds)!
        settingsRoot.cacheDisplay(in: settingsRoot.bounds, to: settingsImage)
        try settingsImage.representation(using: .png, properties: [:])!.write(
            to:
                URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAPACAL_UI_OUTPUT"]!)
                .appendingPathComponent("native-settings.png"))
        editorApp.addSource()
        try require(
            editorApp.settingsWindow.firstResponder is NSTextView,
            "new calendar focuses Settings URL field")
        editorApp.sourcePicker.select(
            editorApp.sourcePicker.itemArray.first { $0.representedObject as? String == "legacy" })
        // Restore the fixture selection without changing saved subscriptions.
        editorApp.selectSource()
        try require(editorApp.sourceEnabled.state == .on, "existing calendars default to enabled")
        for choice in ["Blue", "Custom", "Default"] {
            editorApp.sourceColor.selectItem(withTitle: choice)
            editorApp.customSourceColor = NSColor(
                srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
            editorApp.changeSourceColor()
            let deadline = Date().addingTimeInterval(10)
            while editorApp.fetching && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try require(!editorApp.fetching, "calendar color change completed")
            let expected = choice == "Custom" ? "#336699" : choice.lowercased()
            try require(
                editorApp.subscriptions[0]["color"] as? String == expected, "calendar color saved")
            let snapshot =
                try await editorApp.js("return window.nativeSnapshot()", updates: false)
                as! [String: Any]
            let svg = snapshot["svg"] as! String
            if choice != "Default" {
                try require(
                    svg.contains(choice == "Blue" ? "#285e9b" : "#336699"),
                    "selected color reaches wallpaper SVG")
            }
            editorApp.selectSource()
            try require(
                editorApp.sourceColor.titleOfSelectedItem == choice, "calendar color restored")
        }
        let originalCheck = editorApp.saved["nextCheck"]
        for enabled in [false, true] {
            editorApp.sourceEnabled.state = enabled ? .on : .off
            editorApp.toggleSourceEnabled()
            let deadline = Date().addingTimeInterval(10)
            while editorApp.fetching && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try require(!editorApp.fetching, "calendar toggle completed")
            try require(
                editorApp.subscriptions[0]["enabled"] as? Bool == enabled,
                "calendar enabled preference saved")
            try require(
                editorApp.editorView.events.isEmpty == !enabled,
                "calendar toggle updates visible events")
        }
        editorApp.saved["nextCheck"] = originalCheck
        editorApp.status.stringValue = "Settings status check"
        try require(
            editorApp.settingsStatus.stringValue == "Settings status check",
            "operation feedback in both windows")
        editorApp.settingsTabs.selectTabViewItem(withIdentifier: "general")
        try require(
            editorApp.automatic.window === editorApp.settingsWindow,
            "automatic updates belong to Settings")
        editorApp.refreshPicker.selectItem(at: 0)
        editorApp.changeRefreshInterval()
        try require(editorApp.refreshInterval == 900, "refresh frequency in Settings persists")
        editorApp.refreshPicker.selectItem(at: 1)
        editorApp.changeRefreshInterval()
        editorApp.window.performClose(nil)
        try require(
            editorApp.settingsWindow.isVisible && NSApp.activationPolicy() == .regular,
            "Settings remains usable after editor closes")
        editorApp.show()
        editorApp.showSettings()
        let focusDeadline = Date().addingTimeInterval(5)
        while NSApp.keyWindow !== editorApp.settingsWindow && Date() < focusDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(
            NSApp.keyWindow === editorApp.settingsWindow, "Settings receives keyboard focus")
        editorApp.closeWindow()
        try require(
            !editorApp.settingsWindow.isVisible && editorApp.window.isVisible,
            "Close Window targets Settings")
        try require(NSApp.activationPolicy() == .regular, "closing Settings keeps editor active")
        editorApp.showSettings()
        try require(
            editorApp.refreshPicker.indexOfSelectedItem == 1,
            "Settings reopens with retained values")
        editorApp.settingsWindow.performClose(nil)
        try require(ui.appearanceFields.isHidden, "appearance starts collapsed")
        ui.appearanceToggle.performClick(nil)
        try require(!ui.appearanceFields.isHidden, "appearance disclosure opens")
        try require(
            (0..<ui.theme.segmentCount).map { ui.theme.label(forSegment: $0) } == [
                "System", "Light", "Dark",
            ], "appearance choices")
        try require(
            ui.exportMenu.menu!.items.count == 5, "all export appearances remain accessible")

        try require(
            ui.colorTheme.itemTitles == [
                "Forest", "Neutral", "Ocean", "Plum", "Rose", "Sand", "Custom",
            ], "color theme choices")
        ui.colorTheme.selectItem(withTitle: "Custom")
        ui.changeControl(ui.colorTheme)
        let colorDeadline = Date().addingTimeInterval(15)
        while ui.editor["colorTheme"] as? String != "custom" && Date() < colorDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(ui.editor["colorTheme"] as? String == "custom", "custom theme action")
        let well = ui.colorWells["light.bg"]!
        well.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        _ = well.sendAction(well.action!, to: well.target)
        let wellDeadline = Date().addingTimeInterval(15)
        while (ui.editor["customColors"] as? [String: [String: String]])?["light"]?["bg"]
            != "#ff0000" && Date() < wellDeadline
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(
            (ui.editor["customColors"] as? [String: [String: String]])?["light"]?["bg"]
                == "#ff0000", "native color picker action")
        ui.colorTheme.selectItem(withTitle: "Forest")
        ui.changeControl(ui.colorTheme)

        // Drive target/action through real native controls.
        try require(
            (0..<ui.eventStyle.segmentCount).map { ui.eventStyle.label(forSegment: $0) } == [
                "Text", "Boxes",
            ],
            "event style choices")
        for (segment, style) in [(1, "boxes"), (0, "text")] {
            ui.eventStyle.selectedSegment = segment
            _ = ui.eventStyle.sendAction(ui.eventStyle.action!, to: ui.eventStyle.target)
            let styleDeadline = Date().addingTimeInterval(15)
            while ui.editor["eventStyle"] as? String != style && Date() < styleDeadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try require(ui.editor["eventStyle"] as? String == style, "event style segment action")
        }
        ui.theme.selectedSegment = 2
        ui.changeControl(ui.theme)
        let darkDeadline = Date().addingTimeInterval(15)
        while ui.editor["theme"] as? String != "dark" && Date() < darkDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(ui.editor["theme"] as? String == "dark", "appearance action")
        ui.tabs.selectTabViewItem(withIdentifier: "events")
        let originalContentSize = editorApp.window.contentView!.frame.size
        // Check the actual layout at both the current size and a compact CI-sized window.
        for size in [originalContentSize, NSSize(width: 1060, height: 588), originalContentSize] {
            editorApp.window.setContentSize(size)
            editorApp.window.contentView?.layoutSubtreeIfNeeded()
            guard let tableScroll = ui.table.enclosingScrollView,
                let split = tableScroll.superview as? NSSplitView,
                let content = ui.tabs.selectedTabViewItem?.view
            else {
                throw WallpaperError.invalid("Native UI test failed: event split hierarchy missing")
            }
            let diagnostic =
                "window=\(editorApp.window.contentView!.frame), split=\(split.frame), content=\(content.bounds)"
            try require(
                abs(split.frame.minX - content.bounds.minX) <= 1
                    && abs(split.frame.width - content.bounds.width) <= 1
                    && abs(tableScroll.frame.width - split.bounds.width) <= 1,
                "event table and split fill the available width: \(diagnostic)")
            try require(
                abs(split.frame.minY - content.bounds.minY) <= 1
                    && abs(split.frame.maxY - content.bounds.maxY) <= 1,
                "event split fills the available height: \(diagnostic)")
            try require(
                split.arrangedSubviews.count == 2,
                "event split contains the table and details: \(diagnostic)")
            try require(
                tableScroll.frame.height >= 110
                    && split.arrangedSubviews[1].frame.height >= 100,
                "event table and details retain their minimum heights: \(diagnostic)")
        }
        ui.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try require(!ui.details.string.isEmpty, "native details")
        let eventID = ui.events[0]["uid"] as! String
        let checkboxCell =
            ui.tableView(ui.table, viewFor: ui.table.tableColumns[0], row: 0) as! NSTableCellView
        let checkbox = checkboxCell.subviews.compactMap { $0 as? NSButton }.first!
        checkbox.state = .off
        ui.includeEvent(checkbox)
        let exclusionDeadline = Date().addingTimeInterval(15)
        while !(ui.editor["excludedEventIds"] as? [String] ?? []).contains(eventID)
            && Date() < exclusionDeadline
        { try await Task.sleep(nanoseconds: 50_000_000) }
        try require(
            (ui.editor["excludedEventIds"] as? [String] ?? []).contains(eventID),
            "native event exclusion")

        let isolated = try await editorApp.engine.call(
            "return document.querySelector('input,button,a,iframe,svg,canvas') === null && !window.webkit?.messageHandlers?.wapacal"
        )
        try require(isolated as? Bool == true, "worker contains no interface or message bridge")
        let blocked = try await editorApp.engine.call(
            "try { await fetch('https://example.invalid/'); return false; } catch { return true; }")
        try require(blocked as? Bool == true, "worker network denied")
        let before = ui.editor
        var rejected = false
        do {
            _ = try await editorApp.js(
                "return window.nativeUpdate(patch)",
                ["patch": ["start": "2026-11-20", "end": "2026-09-01"]])
        } catch { rejected = true }
        try require(
            rejected && ui.editor["start"] as? String == before["start"] as? String,
            "invalid range retention")
        rejected = false
        do {
            _ = try await editorApp.js(
                "return window.nativeFeed(ics,date)",
                ["ics": "invalid ICS", "date": "2026-09-08T12:00:00Z"])
        } catch { rejected = true }
        try require(rejected && ui.events.count > 0, "invalid feed retention")

        let pair = try await editorApp.js("return await window.nativePair()") as! [String: Any]
        let light = Data(base64Encoded: pair["light"] as! String)!
        let dark = Data(base64Encoded: pair["dark"] as! String)!
        try require(light != dark, "different appearance pixels")
        let lightImage = try loadImage(light), darkImage = try loadImage(dark)
        try require(lightImage.width == 2880 && lightImage.height == 1800, "PNG dimensions")
        let output = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["WAPACAL_UI_OUTPUT"]!,
            isDirectory: true)
        try light.write(to: output.appendingPathComponent("worker-light.png"))
        try dark.write(to: output.appendingPathComponent("worker-dark.png"))
        try encodePair(
            light: lightImage, dark: darkImage, to: output.appendingPathComponent("worker.heic"))
        let info = try inspectData(Data(contentsOf: output.appendingPathComponent("worker.heic")))
        try require(
            info.frameCount == 2 && info.width == 2880 && info.darkIndex == 1, "HEIC export")

        editorApp.openExportFile(output.appendingPathComponent("worker.heic").path)
        try require(
            importer.window?.isVisible == true && importer.lightView.image != nil
                && importer.darkView.image != nil, "valid import opens populated preview")
        try require(NSApp.mainMenu === mainMenu, "import retains application menus")
        editorApp.window.performClose(nil)
        try require(
            NSApp.activationPolicy() == .regular && importer.window.isVisible,
            "import preview remains active after editor closes")
        importer.window.performClose(nil)
        try require(
            NSApp.activationPolicy() == .accessory, "closing final preview leaves menu bar app")
        editorApp.openExportFile(output.appendingPathComponent("worker.heic").path)
        try require(
            importer.window.isVisible && NSApp.mainMenu === mainMenu,
            "reopen existing import preview")
        editorApp.show()
        importer.window.performClose(nil)

        for (tab, file) in [
            ("preview", "native-preview"), ("events", "native-events"),
            ("suggestions", "native-suggestions"),
        ] {
            ui.tabs.selectTabViewItem(withIdentifier: tab)
            editorApp.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
            let root = editorApp.window.contentView!
            let image = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(
                to: output.appendingPathComponent(file + ".png"))
            try require(!descendants(root).contains { $0 is WKWebView }, "web content in \(tab)")
        }
        // Minimum-size layout keeps controls accessible and the content area usable.
        editorApp.window.setContentSize(NSSize(width: 1060, height: 698))
        editorApp.window.contentView?.layoutSubtreeIfNeeded()
        try require(ui.tabs.frame.width > 700, "minimum-width tabs")
        try require(ui.preview.frame.width > 650, "minimum-width preview")
        // Suggestions remain editable and require a native button action.
        let buttons = descendants(ui.tabs.selectedTabViewItem!.view!).compactMap { $0 as? NSButton }
        try require(buttons.contains { $0.title == "Use module" }, "native suggestion button")
        buttons.first { $0.title == "Use module" }!.performClick(nil)
        let suggestionDeadline = Date().addingTimeInterval(15)
        while ui.editor["name"] as? String == "Prototype module" && Date() < suggestionDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(ui.editor["name"] as? String != "Prototype module", "accept suggestion")
        try require(
            (ui.editor["excludedEventIds"] as? [String] ?? []).contains(eventID),
            "suggestion preserves exclusions")
        editorApp.persist()
        let persisted =
            try JSONSerialization.jsonObject(with: Data(contentsOf: editorApp.stateURL))
            as! [String: Any]
        try require(
            (persisted["editor"] as? [String: Any])?["futureSetting"] as? String == "kept",
            "unknown field persists")
        _ = try await editorApp.js("return window.nativeLoad(payload)", ["payload": persisted])
        try require(
            (ui.editor["excludedEventIds"] as? [String] ?? []).contains(eventID), "reopen state")
        _ = try await editorApp.js("return window.nativeReset()")
        try require(
            ui.table.numberOfRows == 0 && ui.name.stringValue == "New module", "native reset")
        editorApp.window.performClose(nil)
        try require(!editorApp.window.isVisible, "close window")
        editorApp.show()
        try require(editorApp.window.isVisible, "menu bar reopen")
        let fake = FixtureLocalCalendars()
        editorApp.localCalendars = fake
        editorApp.saved["subscriptions"] = [] as [[String: Any]]
        editorApp.automatic.state = .off
        editorApp.saveTimer?.invalidate()
        editorApp.showSettings()
        editorApp.settingsTabs.selectTabViewItem(withIdentifier: "calendars")
        _ = try await editorApp.js(
            "return window.nativeUpdate(patch)",
            ["patch": ["mode": "month", "month": "2026-09", "course": ""]])
        fake.hasAccess = false
        editorApp.chooseLocalCalendars()
        let recoveryDeadline = Date().addingTimeInterval(10)
        while editorApp.settingsWindow.attachedSheet == nil && Date() < recoveryDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let recovery = editorApp.settingsWindow.attachedSheet,
            let recoveryRoot = recovery.contentView
        else {
            throw WallpaperError.invalid("Calendar access recovery did not open")
        }
        let recoveryButtons = descendants(recoveryRoot).compactMap { $0 as? NSButton }
        try require(
            recoveryButtons.contains { $0.title == "Open Calendar Settings" },
            "denied calendar access offers a settings shortcut")
        recoveryButtons.first { $0.title == "Cancel" }!.performClick(nil)
        let recoveryCloseDeadline = Date().addingTimeInterval(10)
        while (editorApp.settingsWindow.attachedSheet != nil || editorApp.fetching)
            && Date() < recoveryCloseDeadline
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try require(
            editorApp.status.stringValue.contains("Calendar access is off"),
            "denied access explains how to recover")
        fake.hasAccess = true
        editorApp.waitingForCalendarAccess = true
        editorApp.applicationDidBecomeActive(
            Notification(name: NSApplication.didBecomeActiveNotification))
        let sheetDeadline = Date().addingTimeInterval(10)
        while editorApp.settingsWindow.attachedSheet == nil && Date() < sheetDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let sheet = editorApp.settingsWindow.attachedSheet, let sheetRoot = sheet.contentView
        else {
            throw WallpaperError.invalid("Local calendar picker did not open")
        }
        sheetRoot.layoutSubtreeIfNeeded()
        let pickerButtons = descendants(sheetRoot).compactMap { $0 as? NSButton }
        let calendarChecks = pickerButtons.filter { $0.title.hasPrefix("Local Calendar ") }
        try require(calendarChecks.count == 24, "all local calendars are offered")
        try require(
            calendarChecks.allSatisfy { $0.state == .off }, "no calendars selected implicitly")
        if let last = calendarChecks.last,
            let scroll = descendants(sheetRoot).first(where: { $0 is NSScrollView })
                as? NSScrollView
        {
            last.scrollToVisible(last.bounds)
            sheetRoot.layoutSubtreeIfNeeded()
            let lastFrame = last.convert(last.bounds, to: scroll.documentView)
            try require(
                scroll.documentVisibleRect.intersects(lastFrame),
                "last calendar is reachable by scrolling")
            calendarChecks.first!.scrollToVisible(calendarChecks.first!.bounds)
        }
        calendarChecks.first { $0.title == "Local Calendar 0" }!.state = .on
        let pickerImage = sheetRoot.bitmapImageRepForCachingDisplay(in: sheetRoot.bounds)!
        sheetRoot.cacheDisplay(in: sheetRoot.bounds, to: pickerImage)
        try pickerImage.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAPACAL_UI_OUTPUT"]!)
                .appendingPathComponent("native-local-calendars.png"))
        pickerButtons.first { $0.title == "Save selection" }!.performClick(nil)
        @MainActor func waitForLocalRefresh() async throws {
            let deadline = Date().addingTimeInterval(15)
            while (editorApp.fetching || editorApp.localRefreshPending) && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try require(!editorApp.fetching, "local refresh completed")
        }
        try await waitForLocalRefresh()
        try require(editorApp.subscriptions.count == 1, "only selected local calendar added")
        let localMenuItems = editorApp.sourcePicker.itemArray
        try require(
            localMenuItems.map(\.title) == ["CALENDARS ON THIS MAC", "Local Calendar 0"],
            "local calendars have a labeled menu section")
        try require(localMenuItems[1].image != nil, "local calendar has an icon")
        try require(
            editorApp.selectedSourceIndex == 0, "local menu heading preserves source indexing")
        try require(ui.table.numberOfRows == 1, "local event appears in native checklist")
        try require(
            !editorApp.urlField.isEnabled, "local calendars cannot become URL subscriptions")
        let localID = ui.events[0]["uid"] as! String
        _ = try await editorApp.js(
            "return window.nativeInclude(uid,included)", ["uid": localID, "included": false])
        editorApp.beginRefresh(force: true, localOnly: true)
        try await waitForLocalRefresh()
        try require(
            (ui.editor["excludedEventIds"] as? [String] ?? []).contains(localID),
            "local exclusion survives refresh")
        editorApp.saved["nextCheck"] = Date().addingTimeInterval(3600).timeIntervalSince1970
        let requestCount = fake.requests.count
        editorApp.tick()
        try await Task.sleep(nanoseconds: 750_000_000)
        try require(
            fake.requests.count == requestCount,
            "minute UI tick does not force an EventKit query before the refresh interval")
        editorApp.sourceEnabled.state = .off
        editorApp.toggleSourceEnabled()
        try await waitForLocalRefresh()
        try require(ui.table.numberOfRows == 0, "calendar checkbox hides local events")
        editorApp.sourceEnabled.state = .on
        editorApp.toggleSourceEnabled()
        try await waitForLocalRefresh()
        try require(ui.table.numberOfRows == 1, "calendar checkbox restores local event checklist")
        try require(
            (ui.editor["excludedEventIds"] as? [String] ?? []).contains(localID),
            "calendar toggle preserves local exclusion")
        editorApp.queueEditorPatch(["month": "2035-09"])
        let rangeDeadline = Date().addingTimeInterval(15)
        while fake.requests.last?.1 ?? "" < "2035-09-30" && Date() < rangeDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await waitForLocalRefresh()
        try require(
            fake.requests.last!.1 > "2035-09-30", "native provider loads newly selected date range")
        fake.temporaryFailure = true
        editorApp.beginRefresh(force: true, localOnly: true)
        try await waitForLocalRefresh()
        try require(
            editorApp.subscriptions[0]["snapshot"] != nil, "transient error preserves snapshot")
        fake.temporaryFailure = false
        fake.removed = true
        editorApp.beginRefresh(force: true, localOnly: true)
        try await waitForLocalRefresh()
        let emptySnapshot = editorApp.subscriptions[0]["snapshot"] as! [String: Any]
        try require(
            (emptySnapshot["events"] as! [[String: Any]]).isEmpty,
            "deleted events disappear without ICS history")
        fake.hasAccess = false
        editorApp.beginRefresh(force: true, localOnly: true)
        try await waitForLocalRefresh()
        try require(
            editorApp.subscriptions[0]["snapshot"] == nil, "revocation clears cached private events"
        )
        try require(
            editorApp.status.stringValue.contains("Calendar access"), "revocation explains recovery"
        )
        fake.hasAccess = true
        fake.missing = true
        editorApp.beginRefresh(force: true, localOnly: true)
        try await waitForLocalRefresh()
        try require(
            editorApp.subscriptions[0]["snapshot"] == nil,
            "missing calendars do not keep stale events")
        editorApp.localCalendarTimer?.invalidate()
        editorApp.saveTimer?.invalidate()
        print("Native UI and WebKit integration checks passed")
        hideTestApplication()
        application.terminate(nil)
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        hideTestApplication()
        exit(1)
    }
}
application.run()
