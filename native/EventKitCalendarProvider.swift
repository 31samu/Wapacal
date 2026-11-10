import AppKit
import EventKit

struct LocalCalendarInfo {
    let identifier: String
    let title: String
    let account: String
    let color: String
}

enum LocalCalendarError: LocalizedError {
    case accessUnavailable
    case calendarMissing
    var errorDescription: String? {
        switch self {
        case .accessUnavailable:
            return
                "Calendar access is unavailable. Allow Wapacal in System Settings → Privacy & Security → Calendars."
        case .calendarMissing:
            return
                "This calendar is no longer available. Choose Calendars on this Mac to select it again."
        }
    }
}

protocol LocalCalendarProviding {
    var hasAccess: Bool { get }
    var canPromptForAccess: Bool { get }
    func requestAccess() async throws -> Bool
    func calendars() async throws -> [LocalCalendarInfo]
    func snapshot(identifier: String, from: String, to: String) async throws -> [String: Any]
}

// All EventKit objects stay on this queue. Only value snapshots cross into the editor.
final class EventKitCalendarProvider: LocalCalendarProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.samuelkremer.wapacal.eventkit")
    private lazy var store = EKEventStore()
    var canPromptForAccess: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *), status == .writeOnly { return true }
        return status == .notDetermined
    }
    var hasAccess: Bool {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        }
        return EKEventStore.authorizationStatus(for: .event) == .authorized
    }
    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let completion: EKEventStoreRequestAccessCompletionHandler = { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
                if #available(macOS 14.0, *) {
                    self.store.requestFullAccessToEvents(completion: completion)
                } else {
                    self.store.requestAccess(to: .event, completion: completion)
                }
            }
        }
    }
    func calendars() async throws -> [LocalCalendarInfo] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.hasAccess else {
                    continuation.resume(throwing: LocalCalendarError.accessUnavailable)
                    return
                }
                self.store.reset()
                let calendars = self.store.calendars(for: .event).map { calendar in
                    let color =
                        (calendar.cgColor as CGColor?).flatMap { NSColor(cgColor: $0) }?
                        .usingColorSpace(.sRGB)
                        ?? NSColor.systemBlue.usingColorSpace(.sRGB)!
                    return LocalCalendarInfo(
                        identifier: calendar.calendarIdentifier, title: calendar.title,
                        account: calendar.source.title.isEmpty
                            ? "On this Mac" : calendar.source.title,
                        color: String(
                            format: "#%02x%02x%02x", Int(color.redComponent * 255),
                            Int(color.greenComponent * 255), Int(color.blueComponent * 255)))
                }.sorted { ($0.account, $0.title) < ($1.account, $1.title) }
                continuation.resume(returning: calendars)
            }
        }
    }
    func snapshot(identifier: String, from: String, to: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard self.hasAccess else { throw LocalCalendarError.accessUnavailable }
                    self.store.reset()
                    guard let calendar = self.store.calendar(withIdentifier: identifier) else {
                        throw LocalCalendarError.calendarMissing
                    }
                    let iso = ISO8601DateFormatter()
                    guard let lower = iso.date(from: from + "T00:00:00Z"),
                        let upper = iso.date(from: to + "T00:00:00Z"), lower < upper
                    else {
                        throw WallpaperError.invalid("Invalid local calendar date range.")
                    }
                    var events: [String: [String: Any]] = [:]
                    var start = lower
                    // EventKit limits a predicate to four years. Small chunks also bound each query.
                    while start < upper {
                        let end = min(start.addingTimeInterval(366 * 86400), upper)
                        let predicate = self.store.predicateForEvents(
                            withStart: start, end: end, calendars: [calendar])
                        for event in self.store.events(matching: predicate) {
                            guard event.status != .canceled else { continue }
                            let record = try Self.record(event, iso: iso)
                            let uid = record["uid"] as! String
                            if let previous = events[uid],
                                !NSDictionary(dictionary: previous).isEqual(to: record)
                            {
                                throw WallpaperError.invalid(
                                    "Conflicting local events share an identifier. Refresh the calendar and try again."
                                )
                            }
                            events[uid] = record
                            guard events.count <= 100_000 else {
                                throw WallpaperError.invalid(
                                    "Local calendar exceeds 100,000 events in this date range.")
                            }
                        }
                        start = end
                    }
                    guard self.hasAccess else { throw LocalCalendarError.accessUnavailable }
                    continuation.resume(returning: [
                        "version": 1, "coverageStart": from, "coverageEnd": to,
                        "events": events.values.sorted {
                            ($0["uid"] as! String) < ($1["uid"] as! String)
                        },
                    ])
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func record(_ event: EKEvent, iso: ISO8601DateFormatter) throws -> [String: Any]
    {
        // The original occurrence date survives moving one instance of a recurring event.
        // External IDs help survive resyncs; the source ID added by JS separates calendars.
        guard let startDate = event.startDate, let endDate = event.endDate else {
            throw WallpaperError.invalid("A local calendar event is missing its dates.")
        }
        let identity = event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = NSTimeZone.default
        day.dateFormat = "yyyy-MM-dd"
        let occurrence =
            (event.hasRecurrenceRules || event.isDetached)
            ? event.occurrenceDate.map {
                event.isAllDay ? day.string(from: $0) : iso.string(from: $0)
            } ?? ""
            : ""
        let uid = String(
            data: try JSONSerialization.data(withJSONObject: [identity, occurrence]),
            encoding: .utf8)!
        return [
            "uid": uid,
            "start": event.isAllDay
                ? day.string(from: startDate) : iso.string(from: startDate),
            "end": event.isAllDay
                ? day.string(from: endDate) : iso.string(from: endDate),
            "allDay": event.isAllDay,
            "title": event.title ?? "Untitled event", "summary": event.title ?? "Untitled event",
            "description": event.notes ?? "", "location": event.location ?? "",
        ]
    }
}
