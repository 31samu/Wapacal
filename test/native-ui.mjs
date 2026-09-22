import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { writeFile, readFile, mkdir, mkdtemp, copyFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { loadFixtureApp } from './helpers/fixture-app.mjs';
import { compileNative } from '../scripts/native-compile.mjs';

test(
  'AppKit interface and detached WebKit worker integrate using isolated fixture data',
  { timeout: 120000 },
  async () => {
    const temp = await mkdtemp(join(tmpdir(), 'wapacal-native-ui-'));
    const bundle = join(temp, 'WapacalUITest.app'),
      resources = join(bundle, 'Contents/Resources');
    await mkdir(resources, { recursive: true });
    await mkdir(join(bundle, 'Contents/MacOS'), { recursive: true });
    await writeFile(
      join(bundle, 'Contents/Info.plist'),
      `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>WapacalUITest</string><key>CFBundleIdentifier</key><string>local.wapacal.uitest</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`,
    );
    await copyFile(
      'output/Wapacal.app/Contents/Resources/calendar-worker.html',
      join(resources, 'calendar-worker.html'),
    );
    for (const name of ['LICENSE', 'THIRD-PARTY-NOTICES.txt']) {
      await copyFile(name, join(resources, name));
    }
    const { seed, config } = await loadFixtureApp();
    await writeFile(
      join(resources, 'seed.json'),
      JSON.stringify({
        ...seed,
        subscriptions: [
          {
            id: 'legacy',
            legacyIds: true,
            name: 'Fixture calendar',
            kind: 'timeedit',
            url: 'https://example.invalid/calendar.ics',
            ics: seed.ics,
            fetchedAt: seed.fetchedAt,
          },
        ],
        refreshInterval: 1800,
        nextCheck: Date.now() / 1000 + 86400,
        editor: {
          ...config.module,
          mode: 'module',
          theme: 'light',
          course: config.course,
          timeZone: config.timeZone,
          width: 2880,
          height: 1800,
          futureSetting: 'kept',
        },
      }),
    );
    await copyFile('test/native-ui.swift', join(temp, 'main.swift'));
    const binary = join(bundle, 'Contents/MacOS/WapacalUITest');
    compileNative(join(temp, 'main.swift'), binary, { stdio: 'pipe' });
    execFileSync('xattr', ['-cr', bundle]);
    execFileSync('codesign', ['--force', '--sign', '-', bundle], { stdio: 'pipe' });
    const stdout = join(temp, 'stdout.log'),
      stderr = join(temp, 'stderr.log');
    await writeFile(stdout, '');
    await writeFile(stderr, '');
    // AppKit applications must be registered and launched through Launch Services.
    // Starting the executable directly can make WindowServer abort it during startup.
    // Launch in the foreground so keyboard-focus and Close Window checks have a key window.
    execFileSync(
      'open',
      [
        '-W',
        '-n',
        '--env',
        `WAPACAL_APP_SUPPORT=${join(temp, 'support')}`,
        '--env',
        `WAPACAL_LEGACY_WORKSPACE=${join(temp, 'legacy')}`,
        '--env',
        `WAPACAL_UI_OUTPUT=${temp}`,
        '--env',
        `WAPACAL_TEST_WALLPAPER=${process.env.WAPACAL_TEST_WALLPAPER === '1' ? '1' : '0'}`,
        '-o',
        stdout,
        '--stderr',
        stderr,
        bundle,
      ],
      { timeout: 90000 },
    );
    const output = await readFile(stdout, 'utf8'),
      errors = await readFile(stderr, 'utf8');
    assert.match(output, /integration checks passed/, errors || 'Native UI test did not finish.');
    console.log(output.trim());
    console.log(`Native UI screenshots and exports: ${temp}`);
  },
);
