# Native interface architecture

Wapacal's application interface is AppKit. Its window contains native controls, a raster image preview, an event table with selectable plain-text details, and editable module suggestions. Save and open dialogs, errors, menus, the menu bar item, and the wallpaper import window are also native.

`CalendarEngine` privately owns a detached `WKWebView`. It never exposes that view or adds it to a window, responder chain, or accessibility hierarchy. The worker loads only `calendar-worker.html`, which contains bundled parsing and rendering code and no interface. The app bundle does not contain `preview.html` or the old `editor.html`.

The main window keeps schedule editing beside Preview, Choose events, and Suggested modules. Appearance options expand in the sidebar; the top row provides the display selector, Refresh, Settings, Export, and Apply. Snapshot details remain available in the event-count label's tooltip.

Settings opens in a separate reusable window with Calendars and General tabs. It uses the existing subscription and preference controls, preserving their actions and saved keys. Both windows show the same operation status. Command-comma opens Settings, Command-W closes the key window, and the app stays in the Dock while either window is visible. The import preview also keeps the app in the Dock while visible. Closing the last window keeps the menu bar app running.

The menu bar item offers Open Wapacal, Settings, Refresh calendars, and Quit. File → Open wallpaper opens a file picker without creating an empty preview. The importer builds and shows its window only after successfully validating and decoding a wallpaper, and leaves the editor's main menu intact. Finder imports use the same path; older transfer formats remain supported.

## Responsibilities

| Component | Responsibility |
| --- | --- |
| `native/main.swift` | App startup and command-line dispatch |
| `native/EditorView.swift` | AppKit presentation, native input, date pickers, event inclusion controls, full event details, suggestion drafts, image preview |
| `native/Editor.swift` | Application lifecycle, Settings window, subscriptions and URLSession, persistence, command sequencing, refresh and automatic application, native export sheets |
| `native/EventKitCalendarProvider.swift` | Read-only EventKit access on a serial queue, calendar discovery, concrete event snapshots |
| `native/LocalCalendarSettings.swift` | Local calendar picker, permission recovery, coalesced change notifications |
| `native/CalendarEngine.swift` | Serialized calls to the private worker, load and operation timeouts, navigation restriction, worker failure reporting |
| `src/native-editor.js` | Calendar and editor transactions, serializable snapshots, day rollover, suggestions, PNG and paired image rendering |
| `src/calendar.mjs`, `src/layout.mjs`, `src/suggestions.mjs` | Shared parser, wallpaper layout and module heuristics, also used by development tools |
| `native/Wallpaper.swift` | ImageIO HEIC encoding and validation, desktop application/restoration, recovery records, legacy imports and CLI |

## Data flow

1. AppKit migrates earlier Application Support locations, then loads `app-state.json`, falling back to the bundled seed only when that file does not exist. Single-subscription migration still runs when needed. An unreadable state file is retained and writes are disabled until an explicit reset.
2. Swift passes cached subscriptions and editor settings to the worker as structured JavaScript arguments. Strings are never interpolated into executable code. The worker validates the selected layout before committing a replacement.
3. A native control submits a settings patch or an event ID and inclusion flag. A successful transaction returns editor settings, visible event candidates, warnings, suggestions, and PNG bytes. Swift displays these using AppKit and saves the settings dictionary atomically.
4. EventKit reads selected macOS calendars into versioned snapshots with date-range coverage. URLSession fetches each feed independently. A rejected feed keeps its prior snapshot; valid feeds can still update. Subscription changes use the worker's current editor state, so they cannot overwrite queued edits with an older settings copy.
5. Export and Apply wait for pending native edits. Paired exports capture both SVG strings before asynchronous rasterization. A change during rendering cannot mix appearances from different calendars. Swift writes PNGs or encodes the pair with ImageIO.
6. Reset invalidates operations from the old data generation. Quit waits for pending editor transactions and saves their results before terminating.

The worker uses a nonpersistent website data store, disables inspection and popup creation, and restricts navigation to its bundled file. Its content security policy denies network connections, frames, forms, and external assets. PNG creation uses a detached canvas, never a DOM preview. No JavaScript message handlers, HTML controls, browser local storage, or browser download links are part of the application.

Calls run in order across asynchronous image rendering. Startup and calls have 30-second timeouts. A terminated or timed-out worker disables editor operations and reports a native error; reopening the app starts a fresh worker. No web fallback window is available.

## Local calendars

The existing `subscriptions` array holds both source types. Missing `provider` means ICS for backward compatibility; `provider: "eventkit"` stores a local Wapacal UUID separately from `calendarIdentifier`, plus name, color, and enabled state. Each native snapshot contains `version`, `coverageStart`, `coverageEnd`, and concrete occurrences. Timed boundaries are UTC instants; all-day boundaries are civil dates with an exclusive end. The worker validates these records and adds the same source/event identity namespace used for feeds, so the existing event checklist and exclusions work for either source.

`nativeCalendarWindow` returns the worker's recurrence window with calendar-grid padding. The native provider chunks long ranges into queries shorter than EventKit's four-year predicate limit. Navigation triggers another query. Store notifications are debounced on the main queue; startup, wake, activation, and the minute timer also refresh local sources. A refresh arriving during another source operation is queued. Cloud sync remains macOS's responsibility.

EventKit access is requested only through the explicit calendar picker. The provider uses full access on macOS 14+ and the legacy API on macOS 13. After a denial, macOS will not show its permission prompt again. Wapacal offers to open the Calendar privacy pane and reopens the picker after the user returns with access enabled. The generated bundle includes both privacy descriptions. No save/remove EventKit operations exist. Public builds and the CLI never query the event store. A sandboxed distribution would additionally require the calendar entitlement; the current build is ad-hoc signed without App Sandbox.

Successful local snapshots replace previous events, including deleted past events. They bypass ICS history retention. Transient failures retain the last snapshot and show an error; revoked access and missing calendars clear the snapshot. Startup checks access before loading saved local events into the worker. Already generated wallpaper images remain until replaced or restored.

Occurrence IDs combine the server/local item identifier with the original recurring occurrence date. All-day occurrences use civil dates. Wapacal does not deduplicate calendars connected through multiple providers. Calendar IDs may change after full sync/account recreation; missing calendars require explicit reselection. Removing and re-adding a source creates a new local UUID and may require selecting events again.

## Compatibility

The bundle identifier is `com.samuelkremer.wapacal`. The app stores runtime data in `~/Library/Application Support/Wapacal/` and migrates existing data from the `com.samuelkremer.wapacal`, `local.wapacal.app`, and older `local.timetable.wallpaper` Application Support folders. Bundle-adjacent development data can be migrated explicitly with `WAPACAL_LEGACY_WORKSPACE`; production startup does not inspect the app's containing folder because it may be protected by macOS Files & Folders privacy. Migration preserves source wallpaper files currently in use by macOS. Editor field names, subscription IDs, event IDs, HTTP validators, selected display, refresh intervals, and recovery-file formats remain compatible. Unknown editor fields are retained. Existing exclusions, custom image dimensions, fixed modules, historical months, and following-current-month behavior remain supported. The parser expands recurring events for the selected view and nearby years, with stable IDs for individual occurrences. It accepts embedded and IANA time zones, interprets floating times in the wallpaper's zone, and applies individual recurrence exceptions. The README lists remaining feed limits. The wallpaper uses five weekday columns by default and can include Saturday and Sunday.

Both `.wapacal` and legacy `.timetable` imports, paired HEIC files, the existing CLI commands, and appearance mapping remain supported. The minimum deployment target is macOS 13; actual GUI execution is tested on the development Mac, not on every supported macOS release.

The browser preview remains a separate development and compatibility tool. It is neither bundled nor opened by the app. Its browser-local preferences remain separate from the app's existing saved state.

## Applied wallpaper files

Applied HEIC filenames include a hash of their contents. Different images never overwrite a previously used wallpaper URL, so macOS cannot reuse an older render for new content. Identical files share a URL. Cleanup keeps ten inactive images plus images selected on connected displays or referenced by restoration records. Older per-display files are retained. This favors reliable updates over limiting entries in System Settings' “Your Photos” list; deleting local files does not promise to remove those entries.

## Verification

`scripts/native-compile.mjs` compiles the production Swift files together with an explicit `main.swift` entry point. The app and native tests use this same compiler helper; neither extracts or replaces Swift source text.

`npm run build:native` compiles and signs the app with empty subscriptions and a current-month view, without reading local configuration or calendar snapshots. `npm run build:native:private` explicitly embeds local configuration and snapshots for development. Neither command requires a generated browser preview. `npm run test:all` runs parser, layout, subscriptions, browser compatibility, worker, HEIC/storage, and native UI integration tests.

`test/native-ui.mjs` compiles a temporary application from the production Swift sources and uses the bundled production worker with fictional cached feeds and an isolated Application Support directory. It exercises native target/action controls, validates image dimensions and paired HEIC data, rejects invalid edits and feeds, checks persistence, accepts suggestions, tests reset and close/reopen, and asserts that each tab contains no WebKit view. A fake native calendar provider exercises the picker, calendar toggles, event exclusions, range changes, deletion, transient errors, and revoked access without reading personal calendars. It also checks normal/minimum window geometry, Settings control ownership and persistence, shared status messages, appearance disclosure, export choices, and closing/reopening both windows. The tests never apply wallpaper or register login items.

The AppKit and HEIC suites require a logged-in macOS graphical session with access to WindowServer and ImageIO. Restricted execution sandboxes can prevent these services from working. Full login, wake, inactive Spaces, external displays, and reconnecting monitors still need live lifecycle testing.
