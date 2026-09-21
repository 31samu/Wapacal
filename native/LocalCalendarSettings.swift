import AppKit
import EventKit

extension EditorApp {
    func observeLocalCalendars() {
        localCalendarObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.localCalendarsChanged() }
        }
    }
    @objc func localCalendarsChanged() {
        guard subscriptions.contains(where: { $0["provider"] as? String == "eventkit" }) else {
            return
        }
        localCalendarTimer?.invalidate()
        localCalendarTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.beginRefresh(force: true, localOnly: true) }
        }
    }
    // Never load saved private events into the worker after calendar permission is revoked.
    func clearInaccessibleLocalSnapshots() {
        guard subscriptions.contains(where: { $0["provider"] as? String == "eventkit" }),
            !localCalendars.hasAccess
        else { return }
        saved["subscriptions"] = subscriptions.map { source in
            var source = source
            if source["provider"] as? String == "eventkit" {
                source.removeValue(forKey: "snapshot")
            }
            return source
        }
    }
    @objc func chooseLocalCalendars() {
        guard ready, !fetching else {
            status.stringValue = "Wait for the current refresh to finish."
            return
        }
        fetching = true
        let generation = dataGeneration
        Task { @MainActor in
            defer {
                if generation == dataGeneration {
                    fetching = false
                    finishLocalRefresh()
                }
            }
            do {
                guard try await localCalendars.requestAccess() else {
                    await showCalendarAccessRecovery()
                    return
                }
                let available = try await localCalendars.calendars()
                guard generation == dataGeneration else { return }
                let alert = NSAlert()
                alert.messageText = "Calendars on this Mac"
                alert.informativeText =
                    available.isEmpty
                    ? "No calendars are available. Add an account in Apple Calendar, then try again."
                    : "Choose the calendars to show. You can exclude individual events in the wallpaper editor. Wapacal never changes your calendars. Google accounts added to Apple Calendar appear here too."
                alert.addButton(withTitle: "Save selection")
                alert.addButton(withTitle: "Cancel")
                let checks = available.map { calendar -> NSButton in
                    let check = NSButton(
                        checkboxWithTitle: calendar.title, target: nil, action: nil)
                    check.setAccessibilityLabel("\(calendar.account), \(calendar.title)")
                    check.state =
                        subscriptions.contains {
                            $0["provider"] as? String == "eventkit"
                                && $0["calendarIdentifier"] as? String == calendar.identifier
                                && $0["enabled"] as? Bool != false
                        } ? .on : .off
                    return check
                }
                var rows: [NSView] = []
                var previousAccount: String?
                for (calendar, check) in zip(available, checks) {
                    if calendar.account != previousAccount {
                        let heading = NSTextField(labelWithString: calendar.account)
                        heading.font = .systemFont(ofSize: 11, weight: .semibold)
                        heading.textColor = .secondaryLabelColor
                        if previousAccount != nil {
                            heading.setContentHuggingPriority(.defaultLow, for: .vertical)
                        }
                        rows.append(heading)
                        previousAccount = calendar.account
                    }
                    rows.append(check)
                }
                let list = NSStackView(views: rows)
                list.orientation = .vertical
                list.alignment = .leading
                list.spacing = 5
                list.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
                let accountCount = Set(available.map(\.account)).count
                let listHeight = max(88, checks.count * 25 + accountCount * 21 + 20)
                let scroll = NSScrollView(
                    frame: NSRect(
                        x: 0, y: 0, width: 400, height: min(260, listHeight)))
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = true
                scroll.borderType = .bezelBorder
                scroll.drawsBackground = true
                scroll.backgroundColor = .controlBackgroundColor
                scroll.documentView = list
                list.frame = NSRect(x: 0, y: 0, width: 400, height: listHeight)
                list.autoresizingMask = [.width]
                alert.accessoryView = scroll
                guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
                    generation == dataGeneration
                else { return }
                var sources = subscriptions
                for (calendar, check) in zip(available, checks) {
                    if let index = sources.firstIndex(where: {
                        $0["provider"] as? String == "eventkit"
                            && $0["calendarIdentifier"] as? String == calendar.identifier
                    }) {
                        sources[index]["enabled"] = check.state == .on
                    } else if check.state == .on {
                        sources.append([
                            "id": UUID().uuidString, "provider": "eventkit",
                            "calendarIdentifier": calendar.identifier, "name": calendar.title,
                            "accountName": calendar.account, "color": calendar.color,
                            "enabled": true,
                        ])
                    }
                }
                _ = try await js(
                    "return window.nativeSources(subscriptions,clearCourse)",
                    ["subscriptions": sources, "clearCourse": true])
                guard generation == dataGeneration else { return }
                saved["subscriptions"] = sources
                persist()
                reloadSources()
                localRefreshPending = true
                status.stringValue = "Calendar selection saved. Loading events…"
            } catch {
                if localCalendars.hasAccess {
                    status.stringValue = error.localizedDescription
                } else {
                    await showCalendarAccessRecovery()
                }
            }
        }
    }
    func showCalendarAccessRecovery() async {
        status.stringValue =
            "Calendar access is off. Enable Wapacal in System Settings to use calendars on this Mac."
        let alert = NSAlert()
        alert.messageText = "Calendar access is off"
        alert.informativeText =
            "macOS only shows the permission prompt once. Enable Wapacal under Privacy & Security → Calendars, then return here."
        alert.addButton(withTitle: "Open Calendar Settings")
        alert.addButton(withTitle: "Cancel")
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else {
            waitingForCalendarAccess = false
            return
        }
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"),
            NSWorkspace.shared.open(url)
        else {
            waitingForCalendarAccess = false
            status.stringValue =
                "Open System Settings → Privacy & Security → Calendars and enable Wapacal."
            return
        }
        waitingForCalendarAccess = true
        status.stringValue = "Enable Wapacal in Calendar settings, then return to Wapacal."
    }
    func resumeLocalCalendarAccessIfNeeded() -> Bool {
        guard waitingForCalendarAccess, localCalendars.hasAccess else { return false }
        waitingForCalendarAccess = false
        Task { @MainActor in chooseLocalCalendars() }
        return true
    }
    func finishLocalRefresh() {
        guard localRefreshPending, !fetching else { return }
        localRefreshPending = false
        beginRefresh(force: true, localOnly: true)
    }
}
