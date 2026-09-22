# Wapacal agent guide

## Project direction

Wapacal is a local macOS calendar-to-wallpaper app. This project is open sourced on GitHub. Keep that in mind when changing code, build scripts, fixtures, and documentation: public builds must be reproducible without the developer's calendars, local settings, or machine-specific files.

Wapacal is supposed to be light, fast and reliable, don't hang on to unnecessary code or outdated tests.

The repository is the source of truth. Verify comments, plans, and assumptions against the code before relying on them. Do not treat generated output or old design notes as authoritative when they disagree with the implementation.

If you make a change, rebuild the app so I can review it.

Do not stage, commit, or push changes unless the user explicitly asks. Leave those steps to the project owner.
