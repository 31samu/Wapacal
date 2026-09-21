# Development

See the [README](../README.md) for prerequisites and the standard build. The [architecture guide](native-interface.md) describes the native interface, shared renderer, storage, and tests.

## Private calendar builds

To embed your own subscriptions and cached events for development, copy `config.example.json` to `config.local.json`. Add these fields to the configuration, replacing the example URLs:

```json
"subscriptions": [
  {"id": "schedule", "name": "TimeEdit", "url": "https://example.com/schedule.ics", "kind": "timeedit"},
  {"id": "deadlines", "name": "Moodle", "url": "https://example.com/calendar/export", "kind": "generic"}
],
"allCalendars": true
```

Then run:

```sh
npm run refresh
npm run build:native:private
```

This replaces `output/Wapacal.app` with a build containing private calendar data. Do not share it. Run `npm run build:native` to replace it with an empty build. Existing app settings take precedence over bundled seed data.

`allCalendars` shows every feed by default; `course` controls course filtering and TimeEdit module suggestions. Private builds also support legacy `subscriptionUrl`, the `CALENDAR_URL` override, and `data/calendar.ics` snapshots. Missing snapshots are allowed; subscriptions can refresh after launch.

Local configuration, downloaded feeds, and generated output are excluded from Git. The standard native build ignores private configuration, snapshots, and `CALENDAR_URL`.

## Browser preview

After configuring and refreshing subscriptions, run `npm run build` and open `output/preview.html` in Firefox. The build generates SVGs, light/dark PNGs, normalized events, validation reports, and `module-appearance.json`. It does not refresh feeds automatically. Set `WAPACAL_TODAY=YYYY-MM-DD` for a reproducible date marker.

The preview is a separate development tool and is not bundled with the Mac app. Browser preferences are separate from native settings. Browser HEIC export produces a `.wapacal` transfer file that the native app can import. Sharp and browser rendering can differ slightly in typography.

## Formatting and tests

Run `npm run format` to format JavaScript, HTML, JSON, and Swift, or `npm run format:check` to check them. Prettier and `xcrun swift-format` use the checked-in configuration files.

After `npm run build:native`, run `npm run test:all`. Native UI and HEIC tests require a logged-in macOS graphical session. The suites use fictional fixtures and isolated app storage. Individual test commands are listed in [package.json](../package.json).

To test wallpaper application on connected displays, quit the regular Wapacal app first so automatic updates cannot interfere, then run `WAPACAL_TEST_WALLPAPER=1 npm run test:native-ui`. This opt-in test briefly replaces desktop wallpapers with fictional calendars, verifies each display's image dimensions and single-display isolation, then restores the original wallpaper files. It requires all original files to be accessible before it starts. Normal test runs render per-display images without changing desktop wallpapers. Physical unplug/reconnect and inactive Spaces require separate manual checks.

[GitHub Actions](../.github/workflows/checks.yml) installs dependencies, checks formatting, builds an empty app, and runs all tests. It runs on macOS 26 with Xcode 26.6 and macOS 27 with Xcode 27.0. The macOS 27 job uses GitHub's `xcode-27` public preview runner label. Its workflow file defines the runner and tool versions.

## Command-line tools

The built executable supports:

```sh
"output/Wapacal.app/Contents/MacOS/Wapacal" encode LIGHT.png DARK.png OUTPUT.heic
"output/Wapacal.app/Contents/MacOS/Wapacal" import EXPORT.wapacal OUTPUT.heic
"output/Wapacal.app/Contents/MacOS/Wapacal" inspect OUTPUT.heic [EXTRACT_DIRECTORY]
"output/Wapacal.app/Contents/MacOS/Wapacal" status
```

The app also opens paired HEIC wallpapers, `.wapacal` exports, and legacy `.timetable` files through **File → Open wallpaper** or Finder.

## Release downloads

Run `npm run package:release` on macOS to rebuild the public app and create a ZIP and SHA-256 checksum under `output/releases/`. The command never reuses an existing private build. It checks the empty calendar seed and CPU architecture, then extracts the ZIP and verifies the app signature. The app uses an ad hoc signature and is not notarized.

The ZIP targets the build machine's architecture: `arm64` for Apple Silicon or `x86_64` for Intel. The GitHub release workflow uses the Apple Silicon `macos-26` runner. Intel downloads can be packaged separately on an Intel Mac from the same release source.

To publish a download:

1. Set the release version in `package.json` and increment `wapacal.bundleVersion` for a new app build.
2. Commit and push the release changes yourself.
3. Create and publish a GitHub Release with a tag matching the package version, such as `v0.4.0`, pointing to that commit. Include the macOS requirement, supported architecture, and unnotarized installation instructions in its notes.
4. The [release workflow](../.github/workflows/release.yml) builds the public app and attaches the ZIP and checksum. Wait for it to succeed and check the release's Assets section. The README download link points to the latest stable release.

For a manual upload, attach the ZIP and its `.sha256` file from `output/releases/` to the matching GitHub Release. Keep the release attached to the exact source commit used for the build. GitHub provides source archives with each release.
