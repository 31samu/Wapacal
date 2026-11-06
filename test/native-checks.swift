import AppKit

switch CommandLine.arguments[1] {
case "backup":

    let missing = URL(fileURLWithPath: "/nonexistent/wapacal-test-wallpaper.png")
    for url in [nil, missing, URL(string: "https://example.com/image.png")] as [URL?] {
        let record = WallpaperBackup(
            screenID: "test", url: url, options: [.imageScaling: 3, .allowClipping: true])
        let decoded = try JSONDecoder().decode(
            WallpaperBackup.self, from: JSONEncoder().encode(record))
        assert(!decoded.canRestore)
        assert(decoded.url == url)
        assert(decoded.scaling == 3 && decoded.clipping == true)
    }
    let old =
        #"{"screen":"test","url":"file:///System/Library/CoreServices/SystemVersion.plist","scaling":3,"clipping":true}"#
        .data(using: .utf8)!
    let decoded = try JSONDecoder().decode(WallpaperBackup.self, from: old)
    assert(decoded.canRestore)
    print("Backup regression checks passed")
case "refresh-interval":

    assert(savedRefreshInterval(nil) == 3600)
    assert(savedRefreshInterval(900) == 900)
    assert(savedRefreshInterval(1800) == 1800)
    assert(savedRefreshInterval(86400) == 86400)
    assert(savedRefreshInterval(0) == 3600)
    assert(savedRefreshInterval(-1) == 3600)
    assert(savedRefreshInterval(.nan) == 3600)
    assert(savedRefreshInterval(.infinity) == 3600)
    print("Cache policy checks passed")
case "migration":

    try migrateLegacyWorkspace()
    let files = FileManager.default
    assert(files.fileExists(atPath: stateDirectory().appendingPathComponent("app-state.json").path))
    assert(
        files.fileExists(
            atPath: recoveryDirectory().appendingPathComponent("restore-display.json").path))
    assert(
        files.fileExists(
            atPath: recoveryDirectory().appendingPathComponent("restore-flat.json").path))
    assert(
        files.fileExists(
            atPath: recoveryDirectory().appendingPathComponent("restored-old.json").path))
    assert(files.fileExists(atPath: appliedDirectory().appendingPathComponent("old.heic").path))
    let legacy = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["WAPACAL_LEGACY_WORKSPACE"]!)
    assert(!files.fileExists(atPath: legacy.appendingPathComponent("state/app-state.json").path))
    try resetInactiveRuntimeData()
    assert(
        !files.fileExists(atPath: stateDirectory().appendingPathComponent("app-state.json").path))
    assert(
        files.fileExists(
            atPath: recoveryDirectory().appendingPathComponent("restore-display.json").path))
    assert(
        !files.fileExists(
            atPath: recoveryDirectory().appendingPathComponent("restored-old.json").path))
    assert(!files.fileExists(atPath: appliedDirectory().appendingPathComponent("old.heic").path))
    print("Storage migration checks passed")
case "migration-scope":

    assert(legacyWorkspaceDirectories().isEmpty)
    print("Storage migration scope checks passed")
case "wallpaper-storage":

    try ensureWorkspaceDirectories()
    let firstData = Data("first image".utf8)
    let first = try storeAppliedWallpaper(firstData)
    let second = try storeAppliedWallpaper(Data("second image".utf8))
    let third = try storeAppliedWallpaper(Data("third image".utf8))
    assert(Set([first, second, third]).count == 3)
    let oldDate = Date(timeIntervalSince1970: 1)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: first.path)
    let repeated = try storeAppliedWallpaper(firstData)
    assert(repeated == first)
    let retained = try Data(contentsOf: first)
    assert(retained == firstData)
    let modified = try first.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
    assert(modified == oldDate, "identical images must not rewrite a cached URL")
    let backup = WallpaperBackup(screenID: "fixture", url: first, options: [:])
    try JSONEncoder().encode(backup).write(
        to: recoveryDirectory().appendingPathComponent("restore-fixture.json"))
    for index in 0..<15 { _ = try storeAppliedWallpaper(Data("image \(index)".utf8)) }
    try cleanupRuntimeFiles()
    assert(
        FileManager.default.fileExists(atPath: first.path),
        "cleanup must preserve the restore image")
    let files = try FileManager.default.contentsOfDirectory(
        at: appliedDirectory(), includingPropertiesForKeys: nil)
    assert(files.count == 11, "keep ten inactive images plus the protected restore image")
    print("Wallpaper storage checks passed")
default: fatalError("Unknown native check")
}
