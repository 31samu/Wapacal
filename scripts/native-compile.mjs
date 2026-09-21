import { execFileSync } from 'node:child_process';

// App and test executables compile the same production files with separate entry points.
const sources = [
  'native/Wallpaper.swift',
  'native/CalendarEngine.swift',
  'native/EventKitCalendarProvider.swift',
  'native/LocalCalendarSettings.swift',
  'native/EditorView.swift',
  'native/Editor.swift',
];

export function compileNative(entryPoint, output, { stdio = 'inherit' } = {}) {
  // Control events are back-deployed, but their declarations require the macOS 27 SDK.
  const sdkVersion = execFileSync('xcrun', ['--show-sdk-version'], { encoding: 'utf8' });
  const controlEvents = Number.parseInt(sdkVersion, 10) >= 27;
  execFileSync(
    'swiftc',
    [
      ...(controlEvents ? ['-D', 'WAPACAL_CONTROL_EVENTS'] : []),
      '-target',
      `${process.arch === 'arm64' ? 'arm64' : 'x86_64'}-apple-macosx13.0`,
      '-module-cache-path',
      '/tmp/wapacal-swift-cache',
      ...sources,
      entryPoint,
      '-o',
      output,
    ],
    { stdio },
  );
}
