import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum WallpaperError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case .invalid(let text) = self { return text }
        return nil
    }
}

func loadImage(_ data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
        width > 0, height > 0, width <= 7680, height <= 4320,
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw WallpaperError.invalid("Cannot read this image, or it exceeds 7680 × 4320 pixels.")
    }
    return image
}

func readBounded(_ url: URL) throws -> Data {
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 100_000_000 else { throw WallpaperError.invalid("The file exceeds 100 MB.") }
    return try Data(contentsOf: url)
}

// Appearance mapping follows the format documented by wallpapper:
// https://github.com/mczachurski/wallpapper#appearance
// apple_desktop:apr contains a base64 binary plist, with l/d frame indices.
func encodePair(light: CGImage, dark: CGImage, to url: URL) throws {
    guard light.width == dark.width, light.height == dark.height else {
        throw WallpaperError.invalid("Light and dark images must have the same dimensions.")
    }
    let metadata = CGImageMetadataCreateMutable()
    let namespace = "http://ns.apple.com/namespace/1.0/" as CFString
    let mapping = try PropertyListSerialization.data(
        fromPropertyList: ["l": 0, "d": 1], format: .binary, options: 0
    ).base64EncodedString()
    guard
        CGImageMetadataRegisterNamespaceForPrefix(
            metadata, namespace, "apple_desktop" as CFString, nil),
        let tag = CGImageMetadataTagCreate(
            namespace, "apple_desktop" as CFString, "apr" as CFString, .string, mapping as CFString),
        CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:apr" as CFString, tag)
    else {
        throw WallpaperError.invalid("Could not write the appearance metadata.")
    }
    let buffer = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            buffer, UTType.heic.identifier as CFString, 2, nil)
    else {
        throw WallpaperError.invalid("HEIC encoding is unavailable on this Mac.")
    }
    let options = [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary
    CGImageDestinationAddImageAndMetadata(destination, light, metadata, options)
    CGImageDestinationAddImage(destination, dark, options)
    guard CGImageDestinationFinalize(destination) else {
        throw WallpaperError.invalid("HEIC encoding failed.")
    }
    _ = try inspectData(buffer as Data)
    try (buffer as Data).write(to: url, options: .atomic)
}

struct HEICInfo: Codable {
    let frameCount: Int
    let width: Int
    let height: Int
    let lightIndex: Int
    let darkIndex: Int
}

func inspectData(_ data: Data) throws -> HEICInfo {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        CGImageSourceGetType(source) as String? == UTType.heic.identifier,
        CGImageSourceGetCount(source) == 2,
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
        let encoded = CGImageMetadataCopyStringValueWithPath(
            metadata, nil, "apple_desktop:apr" as CFString) as String?,
        let plist = Data(base64Encoded: encoded),
        let mapping = try PropertyListSerialization.propertyList(
            from: plist, options: [], format: nil) as? [String: Int],
        mapping["l"] == 0, mapping["d"] == 1,
        let light = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let dark = CGImageSourceCreateImageAtIndex(source, 1, nil),
        light.width == dark.width, light.height == dark.height
    else {
        throw WallpaperError.invalid(
            "Expected a two-image HEIC with light frame 0 and dark frame 1.")
    }
    return HEICInfo(
        frameCount: 2, width: light.width, height: light.height, lightIndex: 0, darkIndex: 1)
}

struct PairExport: Decodable {
    let version: Int
    let name: String
    let light: String
    let dark: String
}

func importPair(_ url: URL, to destination: URL) throws {
    let pair = try JSONDecoder().decode(PairExport.self, from: readBounded(url))
    guard pair.version == 1, let light = Data(base64Encoded: pair.light),
        let dark = Data(base64Encoded: pair.dark)
    else {
        throw WallpaperError.invalid("Invalid Wapacal export.")
    }
    try encodePair(light: loadImage(light), dark: loadImage(dark), to: destination)
}

func screenID(_ screen: NSScreen) -> String {
    let number =
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
        .uint32Value ?? 0
    if let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() {
        return CFUUIDCreateString(nil, uuid) as String
    }
    return String(number)
}

func wallpaperPixelSize(_ screen: NSScreen) -> NSSize {
    // Use the current backing pixels, not the scaled desktop size in points.
    screen.convertRectToBacking(NSRect(origin: .zero, size: screen.frame.size)).size
}

struct WallpaperBackup: Codable {
    let screen: String
    let url: URL?
    let scaling: Int?
    let clipping: Bool?
    let color: [Double]?
    init(screen: NSScreen) {
        self.init(
            screenID: screenID(screen), url: NSWorkspace.shared.desktopImageURL(for: screen),
            options: NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
    }
    init(screenID: String, url: URL?, options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        self.screen = screenID
        self.url = url
        scaling = (options[.imageScaling] as? NSNumber)?.intValue
        clipping = (options[.allowClipping] as? NSNumber)?.boolValue
        if let c = (options[.fillColor] as? NSColor)?.usingColorSpace(.deviceRGB) {
            color = [
                Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent),
                Double(c.alphaComponent),
            ]
        } else {
            color = nil
        }
    }
    var canRestore: Bool {
        Self.canRestore(url)
    }
    static func canRestore(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    var options: [NSWorkspace.DesktopImageOptionKey: Any] {
        var result: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling { result[.imageScaling] = scaling }
        if let clipping { result[.allowClipping] = clipping }
        if let c = color, c.count == 4 {
            result[.fillColor] = NSColor(deviceRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        }
        return result
    }
}

func workspaceDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["WAPACAL_APP_SUPPORT"], !override.isEmpty
    {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    if Bundle.main.bundleURL.pathExtension == "app" {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0]
        return root.appendingPathComponent("Wapacal", isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
        "output", isDirectory: true)
}

func stateDirectory() -> URL {
    workspaceDirectory().appendingPathComponent("state", isDirectory: true)
}
func recoveryDirectory() -> URL {
    workspaceDirectory().appendingPathComponent("recovery", isDirectory: true)
}
func wallpapersDirectory() -> URL {
    workspaceDirectory().appendingPathComponent("wallpapers", isDirectory: true)
}

func wallpaperSharesAllSpacesAndDisplays() -> Bool {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
    guard let data = try? Data(contentsOf: url) else { return false }
    return wallpaperSharesAllSpacesAndDisplays(in: data)
}

func wallpaperSharesAllSpacesAndDisplays(in data: Data) -> Bool {
    guard
        let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil),
        let root = plist as? [String: Any],
        let shared = root["AllSpacesAndDisplays"]
    else { return false }
    // WallpaperAgent uses the literal string "$null" when sharing is disabled.
    return shared is [String: Any]
}
func appliedDirectory() -> URL {
    wallpapersDirectory().appendingPathComponent("applied", isDirectory: true)
}

func storeAppliedWallpaper(_ data: Data) throws -> URL {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let file = appliedDirectory().appendingPathComponent("wapacal-\(digest).heic")
    // A URL must always identify the same image, even when it is no longer selected.
    // macOS can retain cached renders of previously selected wallpaper URLs.
    if !FileManager.default.fileExists(atPath: file.path) {
        try data.write(to: file, options: .atomic)
    }
    return file
}

func ensureWorkspaceDirectories() throws {
    for directory in [
        stateDirectory(), recoveryDirectory(), wallpapersDirectory(), appliedDirectory(),
    ] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

func legacyWorkspaceDirectories() -> [URL] {
    if let override = ProcessInfo.processInfo.environment["WAPACAL_LEGACY_WORKSPACE"],
        !override.isEmpty
    {
        return [URL(fileURLWithPath: override, isDirectory: true)]
    }
    // Older development builds stored data beside the app. Automatically inspecting that folder
    // can ask for Documents, Desktop, or Downloads access based only on where the app was launched.
    // Keep the explicit override for migration tests and one-off developer recovery.
    return []
}

private struct MigrationItem {
    let source: URL
    let destination: URL
}

func previousApplicationSupportDirectories() -> [URL] {
    // An explicit workspace override is an isolated runtime, including migrations.
    if ProcessInfo.processInfo.environment["WAPACAL_APP_SUPPORT"] != nil { return [] }
    guard Bundle.main.bundleURL.pathExtension == "app" else { return [] }
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return ["com.samuelkremer.wapacal", "local.wapacal.app", "local.timetable.wallpaper"].map {
        root.appendingPathComponent($0, isDirectory: true)
    }
}

func migrateLegacyWorkspace() throws {
    try ensureWorkspaceDirectories()
    let files = FileManager.default
    let candidates = previousApplicationSupportDirectories() + legacyWorkspaceDirectories()
    for legacy in candidates
    where legacy.standardizedFileURL != workspaceDirectory().standardizedFileURL
        && files.fileExists(atPath: legacy.path)
    {
        var items = [
            MigrationItem(
                source: legacy.appendingPathComponent("state/app-state.json"),
                destination: stateDirectory().appendingPathComponent("app-state.json")),
            MigrationItem(
                source: legacy.appendingPathComponent("app-state.json"),
                destination: stateDirectory().appendingPathComponent("app-state.json")),
            MigrationItem(
                source: legacy.appendingPathComponent("wallpapers/editor-wallpaper.heic"),
                destination: wallpapersDirectory().appendingPathComponent("editor-wallpaper.heic")),
            MigrationItem(
                source: legacy.appendingPathComponent("editor-wallpaper.heic"),
                destination: wallpapersDirectory().appendingPathComponent("editor-wallpaper.heic")),
        ]
        for directory in [legacy, legacy.appendingPathComponent("recovery", isDirectory: true)]
        where files.fileExists(atPath: directory.path) {
            for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            {
                let name = url.lastPathComponent
                if name.hasPrefix("restore-") || name.hasPrefix("restored-")
                    || name.hasPrefix("unavailable-")
                {
                    items.append(
                        MigrationItem(
                            source: url,
                            destination: recoveryDirectory().appendingPathComponent(name)))
                }
            }
        }
        let legacyAppliedDirectories = [
            legacy.appendingPathComponent("wallpapers/applied", isDirectory: true),
            legacy.appendingPathComponent("applied", isDirectory: true),
        ]
        for directory in legacyAppliedDirectories where files.fileExists(atPath: directory.path) {
            for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            {
                items.append(
                    MigrationItem(
                        source: url,
                        destination: appliedDirectory().appendingPathComponent(
                            url.lastPathComponent)))
            }
        }
        let active = Set(
            NSScreen.screens.compactMap {
                NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL.path
            })
        var copied: [MigrationItem] = []
        do {
            for item in items
            where files.fileExists(atPath: item.source.path)
                && !files.fileExists(atPath: item.destination.path)
            {
                try files.copyItem(at: item.source, to: item.destination)
                copied.append(item)
            }
        } catch {
            for item in copied { try? files.removeItem(at: item.destination) }
            throw error
        }
        for item in copied where !active.contains(item.source.standardizedFileURL.path) {
            try files.removeItem(at: item.source)
        }
        for directory in legacyAppliedDirectories {
            if let remaining = try? files.contentsOfDirectory(atPath: directory.path),
                remaining.isEmpty
            {
                try? files.removeItem(at: directory)
            }
        }
    }
}

private func trimFiles(
    in directory: URL, matching: (String) -> Bool, keeping limit: Int, protected: Set<String> = []
) throws {
    let files = FileManager.default
    guard files.fileExists(atPath: directory.path) else { return }
    let candidates = try files.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
    )
    .filter { matching($0.lastPathComponent) && !protected.contains($0.standardizedFileURL.path) }
    .sorted {
        let left =
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        let right =
            (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        return left > right
    }
    for url in candidates.dropFirst(limit) { try files.removeItem(at: url) }
}

func cleanupRuntimeFiles() throws {
    try ensureWorkspaceDirectories()
    var active = Set(
        NSScreen.screens.compactMap {
            NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL.path
        })
    for file in try FileManager.default.contentsOfDirectory(
        at: recoveryDirectory(), includingPropertiesForKeys: nil)
    where file.lastPathComponent.hasPrefix("restore-") {
        if let data = try? Data(contentsOf: file),
            let backup = try? JSONDecoder().decode(WallpaperBackup.self, from: data),
            let url = backup.url
        {
            active.insert(url.standardizedFileURL.path)
        }
    }
    try trimFiles(
        in: appliedDirectory(),
        matching: { $0.hasSuffix(".heic") && !$0.hasPrefix("display-") },
        keeping: 10, protected: active)
    try trimFiles(
        in: recoveryDirectory(),
        matching: { $0.hasPrefix("restored-") || $0.hasPrefix("unavailable-") }, keeping: 20)
}

func resetInactiveRuntimeData() throws {
    try ensureWorkspaceDirectories()
    let files = FileManager.default
    let active = Set(
        NSScreen.screens.compactMap {
            NSWorkspace.shared.desktopImageURL(for: $0)?.standardizedFileURL.path
        })
    let state = stateDirectory().appendingPathComponent("app-state.json")
    if files.fileExists(atPath: state.path) { try files.removeItem(at: state) }
    for directory in [wallpapersDirectory(), appliedDirectory()]
    where files.fileExists(atPath: directory.path) {
        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where !url.hasDirectoryPath && !active.contains(url.standardizedFileURL.path) {
            try files.removeItem(at: url)
        }
    }
    for url in try files.contentsOfDirectory(
        at: recoveryDirectory(), includingPropertiesForKeys: nil)
    where url.lastPathComponent.hasPrefix("restored-")
        || url.lastPathComponent.hasPrefix("unavailable-")
    {
        try files.removeItem(at: url)
    }
}

func backupURL(_ screen: NSScreen) -> URL {
    recoveryDirectory().appendingPathComponent("restore-\(screenID(screen)).json")
}

func applyWallpaper(_ url: URL, screen: NSScreen) throws -> Bool {
    try ensureWorkspaceDirectories()
    let data = try readBounded(url)
    _ = try inspectData(data)
    let backup = backupURL(screen)
    if FileManager.default.fileExists(atPath: backup.path) {
        let previous = try JSONDecoder().decode(
            WallpaperBackup.self, from: Data(contentsOf: backup))
        if !previous.canRestore && WallpaperBackup(screen: screen).canRestore {
            try FileManager.default.moveItem(
                at: backup,
                to: recoveryDirectory().appendingPathComponent(
                    "unavailable-\(UUID().uuidString).json"))
        }
    }
    if !FileManager.default.fileExists(atPath: backup.path) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(WallpaperBackup(screen: screen)).write(to: backup, options: .atomic)
    }
    let previous = WallpaperBackup(screen: screen)
    let copy = try storeAppliedWallpaper(data)
    do {
        try NSWorkspace.shared.setDesktopImageURL(
            copy, for: screen,
            options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: false,
            ])
        // WallpaperAgent applies the request asynchronously. Do not let a later
        // screen change race this assignment or report success before macOS has it.
        let deadline = Date().addingTimeInterval(3)
        while NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL
            != copy.standardizedFileURL && Date() < deadline
        {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard
            NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL
                == copy.standardizedFileURL
        else {
            throw WallpaperError.invalid(
                "macOS did not confirm the wallpaper for \(screen.localizedName).")
        }
    } catch {
        // Restore the previous selection if macOS rejects the update.
        if let original = previous.url, previous.canRestore {
            try? NSWorkspace.shared.setDesktopImageURL(
                original, for: screen, options: previous.options)
        }
        throw error
    }
    let record = try JSONDecoder().decode(WallpaperBackup.self, from: Data(contentsOf: backup))
    try? cleanupRuntimeFiles()
    return record.canRestore
}

func restoreWallpaper(screen: NSScreen) throws {
    let backup = backupURL(screen)
    let record = try JSONDecoder().decode(WallpaperBackup.self, from: Data(contentsOf: backup))
    guard record.screen == screenID(screen), record.canRestore, let original = record.url else {
        throw WallpaperError.invalid(
            "The previous wallpaper file is unavailable. Choose another wallpaper in System Settings."
        )
    }
    try NSWorkspace.shared.setDesktopImageURL(original, for: screen, options: record.options)
    // WallpaperAgent applies the request asynchronously, after the API returns.
    let deadline = Date().addingTimeInterval(3)
    while NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL
        != original.standardizedFileURL && Date() < deadline
    {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard
        NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL
            == original.standardizedFileURL
    else {
        throw WallpaperError.invalid(
            "macOS did not confirm restoration. The recovery file was retained.")
    }
    let archive = recoveryDirectory().appendingPathComponent("restored-\(UUID().uuidString).json")
    try FileManager.default.moveItem(at: backup, to: archive)
    try? cleanupRuntimeFiles()
}

final class WallpaperApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "")
    var onError: ((Error) -> Void)?
    let picker = NSPopUpButton(frame: .zero)
    let lightView = NSImageView()
    let darkView = NSImageView()
    var applyButton: NSButton!
    var selected: URL?
    var screens: [NSScreen] = []
    var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let submenu = NSMenu()
        submenu.addItem(
            withTitle: "Quit Wapacal", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = submenu
        NSApp.mainMenu = menu
        if pendingFiles.isEmpty {
            openFile()
        } else {
            for url in pendingFiles { openURL(url) }
            pendingFiles.removeAll()
        }
    }

    private func buildWindow() {
        guard window == nil else { return }
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 510),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wapacal"
        window.center()
        window.isReleasedWhenClosed = false
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let title = NSTextField(labelWithString: "Wallpaper preview")
        title.font = .systemFont(ofSize: 24, weight: .medium)
        root.addArrangedSubview(title)
        let previews = NSStackView()
        previews.orientation = .horizontal
        previews.spacing = 16
        for (label, view) in [("Light", lightView), ("Dark", darkView)] {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            view.imageScaling = .scaleProportionallyUpOrDown
            view.widthAnchor.constraint(equalToConstant: 378).isActive = true
            view.heightAnchor.constraint(equalToConstant: 246).isActive = true
            stack.addArrangedSubview(NSTextField(labelWithString: label))
            stack.addArrangedSubview(view)
            previews.addArrangedSubview(stack)
        }
        root.addArrangedSubview(previews)
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.addArrangedSubview(
            NSButton(title: "Open wallpaper or export…", target: self, action: #selector(openFile)))
        controls.addArrangedSubview(picker)
        applyButton = NSButton(title: "Apply wallpaper", target: self, action: #selector(apply))
        applyButton.isEnabled = false
        controls.addArrangedSubview(applyButton)
        controls.addArrangedSubview(
            NSButton(title: "Restore previous", target: self, action: #selector(restore)))
        root.addArrangedSubview(controls)
        status.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(status)
        window.contentView = root
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateScreens),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        updateScreens()
    }

    @objc func updateScreens() {
        let old = picker.selectedItem?.representedObject as? String
        screens = NSScreen.screens
        picker.removeAllItems()
        for screen in screens {
            picker.addItem(withTitle: screen.localizedName)
            picker.lastItem?.representedObject = screenID(screen)
        }
        if let old, let index = screens.firstIndex(where: { screenID($0) == old }) {
            picker.selectItem(at: index)
        }
        applyButton?.isEnabled = selected != nil && !screens.isEmpty
    }
    func targetScreen() throws -> NSScreen {
        guard let id = picker.selectedItem?.representedObject as? String,
            let screen = NSScreen.screens.first(where: { screenID($0) == id })
        else { throw WallpaperError.invalid("The selected display is disconnected.") }
        return screen
    }
    func showError(_ error: Error) {
        status.stringValue = error.localizedDescription
        if let onError { onError(error) } else { NSAlert(error: error).runModal() }
    }

    @objc func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message =
            "Select a paired HEIC or a .wapacal export. Legacy .timetable exports also work."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openURL(url)
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if window == nil {
            pendingFiles.append(contentsOf: urls)
        } else {
            for url in urls { openURL(url) }
        }
        sender.reply(toOpenOrPrint: .success)
    }
    func openURL(_ url: URL) {
        do {
            var wallpaper = url
            if url.pathExtension.lowercased() != "heic" {
                let save = NSSavePanel()
                save.allowedContentTypes = [.heic]
                save.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".heic"
                guard save.runModal() == .OK, let destination = save.url else { return }
                try importPair(url, to: destination)
                wallpaper = destination
            }
            let data = try readBounded(wallpaper)
            let info = try inspectData(data)
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            guard let light = CGImageSourceCreateImageAtIndex(source, 0, nil),
                let dark = CGImageSourceCreateImageAtIndex(source, 1, nil)
            else {
                throw WallpaperError.invalid("Could not read wallpaper previews.")
            }
            buildWindow()
            lightView.image = NSImage(cgImage: light, size: .zero)
            darkView.image = NSImage(cgImage: dark, size: .zero)
            selected = wallpaper
            applyButton.isEnabled = !screens.isEmpty
            status.stringValue =
                "\(wallpaper.lastPathComponent) · \(info.width) × \(info.height) · Verified light/dark pair."
            window.title = wallpaper.lastPathComponent
            NSApp.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch { showError(error) }
    }
    @objc func apply() {
        guard let selected else { return }
        do {
            guard !wallpaperSharesAllSpacesAndDisplays() else {
                throw WallpaperError.invalid(
                    "macOS is set to show one wallpaper on all Spaces and displays. Turn off “Show on all Spaces” in System Settings → Wallpaper before applying separate display wallpapers."
                )
            }
            let canRestore = try applyWallpaper(selected, screen: targetScreen())
            status.stringValue =
                canRestore
                ? "Applied. macOS controls the appearance. Your previous wallpaper is saved for restoration."
                : "Applied. The previous wallpaper file is unavailable, so it cannot be restored by this app."
        } catch { showError(error) }
    }
    @objc func restore() {
        do {
            try restoreWallpaper(screen: targetScreen())
            status.stringValue = "Previous wallpaper and display options restored."
        } catch { showError(error) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(value), encoding: .utf8)!)
}
