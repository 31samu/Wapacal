<br><div align="center"><img src="assets/app-icon/Wapacal-iOS-Default-1024x1024@1x.png" alt="Wapacal App Icon" width="150"> </div> <br>

# Wapacal


Turn your calendar into a Mac desktop wallpaper. Wapacal combines calendars on your Mac and ICS subscriptions, including TimeEdit and Moodle feeds, into a month view or a custom date range.

- Choose which events appear and adjust the layout.
- Export PNGs or a HEIC wallpaper that switches between light and dark with macOS.
- Refresh calendars and update your wallpaper automatically while the app runs.
- Restore your previous wallpaper from Settings.

<p class="showcase" align="center">
  <img src="assets/screenshots/wapacal-wallpaper.jpg" alt="A Wapacal calendar used as a Mac desktop wallpaper" width="500">
</p>

## Download and install

[**Download Wapacal for Mac**](../../releases/latest)

Wapacal is an early macOS app. Download the ZIP from the release's **Assets** section. Requires macOS 13 or later. The automated download is for **Apple Silicon** Macs, with `arm64` in the filename. Intel users can build from source below, or use an `x86_64` ZIP if one is attached to the release.

1. Unzip the download and drag **Wapacal.app** into **Applications**.
2. Open Wapacal. It is **not notarized by Apple**, so macOS may block the first launch.
3. If blocked, open **System Settings → Privacy & Security**, choose **Open Anyway**, and confirm. Only do this if you trust the download. See [Apple's instructions](https://support.apple.com/en-ie/102445).
4. In **Settings → Calendars**, choose **Calendars on this Mac…** or add an ICS subscription URL.

The download includes no personal calendars or settings. Node.js and Xcode are not needed to run it.

### Note from maker:
I wanted a calendar desktop wallpaper that updates automatically, so I made it. The project was largely slopped together and I don't have experience maintaining something open source, but I expect to update the app until it has all features I'd want or fix it when it breaks. Feel free to reach out, suggest something or fork the project. <br>
At the moment, I don't want to pay 100$ for a developer license, so the app will stay unnotorized (yes that sucks, I know), it's just not in my budget.

## Build and run

You need macOS, Xcode Command Line Tools, and Node.js 22.14 or newer. The built app targets macOS 13 and later and runs without Node.

From the project directory:

```sh
npm ci
npm run build:native
open output/Wapacal.app
```

The default build includes no private calendars or settings. On first launch, choose calendars on your Mac or add an ICS subscription URL in **Settings → Calendars**. Existing installations keep their saved settings. <br>
When installing an updated version, the calendar permissions may need to be reapplied.

## Connect calendars

In **Settings → Calendars**, click **Calendars on this Mac…**, allow calendar access, and check the calendars you want to use. Nothing is selected automatically. Apple asks for full calendar access because EventKit has no read-only permission; Wapacal only reads events and never changes your calendars. If you deny access, Wapacal can open **System Settings → Privacy & Security → Calendars** so you can enable it later.

Calendars synced to the Mac appear here, including Google accounts added in Apple Calendar. macOS handles account login and cloud synchronization. To connect a Google account, follow [Google's Apple Calendar setup instructions](https://support.google.com/calendar/answer/99358?co=GENIE.Platform%3DDesktop&hl=en). Alternatively, add Google's [secret iCal address](https://support.google.com/calendar/answer/37648?hl=en) as a subscription. Keep that URL private. Direct Google login inside Wapacal is not implemented.

Uncheck a calendar in the picker or turn off **Enable calendar** to hide all of its events. In the editor's **Choose events** tab, uncheck individual events. Disabling and re-enabling a calendar preserves those event choices. Avoid connecting the same calendar through both macOS and an ICS URL, which would show two copies.

While running, Wapacal refreshes local calendars after macOS reports changes, on wake/activation, and with a periodic fallback. Changing the displayed date range also loads local events for that range. Preview changes reach your desktop when you choose **Apply wallpaper**, or automatically if that option is enabled. Successful refreshes remove deleted local events. Temporary failures retain the previous snapshot; removing a source or losing permission clears its cached events. An already applied wallpaper remains until you apply another one or restore the previous wallpaper.

## Make your wallpaper

Choose **Month** or **Module** in the sidebar. A module is a named date range, such as a course block. Enable **Include Saturdays and Sundays** when you want a seven-day calendar. Use **Choose events** to hide individual events and **Appearance** to adjust the image size, theme, and layout.

Under **Appearance**, choose Forest, Neutral, Ocean, Plum, Rose, Sand, or Custom in **Color theme**. Each theme has light and dark variants. Neutral uses a grayscale palette. Like every theme, it can respect calendar colors; turn off **Use calendar colors** for a fully grayscale wallpaper. Custom lets you pick background, text, and accent colors separately for light and dark appearance; grid lines and highlights follow those colors. Turn off **Use calendar colors** to use the theme for events as well. Custom colors stay saved when you try another preset.

In **Settings → Calendars**, choose an **Event color** for each calendar. Changes save and update the preview immediately. Preset colors adjust for light and dark appearance; **Custom** opens the color picker to choose an exact color for both. The wallpaper footer lists included calendars in their colors. Click **Apply wallpaper** to update your desktop, or enable automatic updates. Choose **Default** to use the standard theme colors.

Click **Apply wallpaper** to use it on the selected display, or **Export** to save an image. Settings also offers automatic updates and launch at login. Closing the window keeps Wapacal running in the menu bar; choose **Quit** there to stop it.

For one display, open **Appearance** and use the suggested pixel dimensions below **Image size**. Choose **All connected displays** to render the calendar separately at each display's resolution. Image size then shows **Use screen sizes** and lists each screen's dimensions; the preview and exports retain their previous size. Each display remembers its chosen image size. Switching displays restores that size and updates the preview; a display without a saved size starts at its own resolution. Selecting a display does not apply a wallpaper. Automatic updates also handle calendar and display changes while Wapacal is running. Restore applies to the selected display or all currently connected displays. Turn off macOS's **Show on all Spaces** setting to use separate wallpapers per display.

From the menu bar, you can reopen Wapacal, change settings, refresh and apply the wallpaper, or quit the app.

<p align="center">
  <img src="assets/screenshots/wapacal-editor-and-menubar.jpg" alt="Wapacal editor showing a calendar preview with the menu bar menu open" width="500">
</p>

Your settings and cached calendars stay on your Mac under `~/Library/Application Support/Wapacal/`. Existing data migrates automatically from earlier Application Support folders. Wallpaper files still in use by macOS remain at their original paths. Wapacal does not need general access to your Documents folder.

## Current limits

- Feeds support UTC times, all-day dates, named time zones, and floating times interpreted in the wallpaper's time zone. Repeating events, added/excluded dates, and individually moved or cancelled occurrences are supported. Identical duplicate records are ignored.
- Conflicting records with the same event and occurrence ID, unknown time zones without a `VTIMEZONE` definition, `RANGE=THISANDFUTURE` exceptions, and `RDATE` periods still cause the feed to be rejected. Recurrence expansion covers the selected view and nearby years, with limits of 20,000 events and 50,000 recurrence steps per feed.
- Applying and restoring wallpapers has been tested with a built-in Retina screen and a 4K external display. Physical disconnect/reconnect, inactive Spaces, and older macOS versions still need live testing. The all-display option targets connected screens; it does not control macOS's “Show on all Spaces” setting. Restoring Apple's dynamic or aerial wallpaper settings is not guaranteed.
- Calendar and event identifiers can change when accounts are removed or fully resynced. Wapacal reports missing calendars instead of guessing a replacement by name. Reselect the calendar in Settings and remove the unavailable entry; event choices may need to be made again. Local snapshots are limited to 100,000 events per calendar in the requested range.
- EventKit permission and calendar discovery have been tested manually on current macOS. macOS 13 and provider-specific recurrence behavior still need live testing. Automated tests use a fake provider and do not read personal calendars.

## Development

```sh
npm run format:check
npm run test:all
```

Build the app before running all tests. Native UI and HEIC tests need a logged-in macOS graphical session. Tests use fictional calendar fixtures.

See the [development guide](docs/development.md) for private builds, the Firefox preview, and command-line tools, or the [architecture guide](docs/native-interface.md) for how the app works.

## License

Copyright (C) 2026 Samuel Kremer. Wapacal is licensed under the [GNU General Public License version 3](LICENSE), GPL-3.0-only. Third-party dependencies retain their own licenses.

The app includes ICAL.js under MPL-2.0. See [third-party notices and source downloads](THIRD-PARTY-NOTICES.txt). The notice and ICAL.js license are also bundled in `Wapacal.app/Contents/Resources`, accessible through Finder's **Show Package Contents**.
