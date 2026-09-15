import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { readFile, writeFile, mkdtemp, mkdir, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import sharp from 'sharp';
import { renderWallpaper } from '../src/layout.mjs';
import { loadFixtureApp } from './helpers/fixture-app.mjs';
import { compileNative } from '../scripts/native-compile.mjs';
const binary = resolve('output/Wapacal.app/Contents/MacOS/Wapacal');
const bundle = resolve('output/Wapacal.app');

test('native bundle ships only a headless worker, with no browser interface', async () => {
  const resources = await readdir(join(bundle, 'Contents', 'Resources'));
  assert.ok(resources.includes('calendar-worker.html'));
  assert.ok(!resources.includes('editor.html'));
  assert.ok(!resources.includes('preview.html'));
  const worker = await readFile(
    join(bundle, 'Contents', 'Resources', 'calendar-worker.html'),
    'utf8',
  );
  assert.match(worker, /connect-src 'none'/);
  assert.match(worker, /<body><script>/);
  assert.doesNotMatch(worker, /webkit\.messageHandlers|localStorage|addEventListener/);
});

test('native bundle contains a rounded app icon at every macOS scale', async () => {
  const plist = await readFile(join(bundle, 'Contents', 'Info.plist'), 'utf8');
  const packageMetadata = JSON.parse(await readFile('package.json', 'utf8'));
  assert.match(plist, /<key>CFBundleIconFile<\/key><string>Wapacal\.icns<\/string>/);
  assert.match(
    plist,
    new RegExp(
      `<key>CFBundleIdentifier<\\/key><string>${packageMetadata.wapacal.bundleIdentifier}<\\/string>`,
    ),
  );
  assert.match(
    plist,
    new RegExp(
      `<key>CFBundleShortVersionString<\\/key><string>${packageMetadata.version}<\\/string>`,
    ),
  );
  assert.match(
    plist,
    new RegExp(
      `<key>CFBundleVersion<\\/key><string>${packageMetadata.wapacal.bundleVersion}<\\/string>`,
    ),
  );
  assert.match(plist, /com\.samuelkremer\.wapacal\.export/);
  const icon = await readFile(join(bundle, 'Contents', 'Resources', 'Wapacal.icns'));
  assert.equal(icon.subarray(0, 4).toString(), 'icns');
  assert.equal(icon.readUInt32BE(4), icon.length);
  const entries = new Map();
  for (let offset = 8; offset < icon.length; ) {
    const type = icon.subarray(offset, offset + 4).toString();
    const length = icon.readUInt32BE(offset + 4);
    assert.ok(length > 8, `${type} has an invalid chunk length`);
    entries.set(type, icon.subarray(offset + 8, offset + length));
    offset += length;
    assert.ok(offset <= icon.length, `${type} extends past the ICNS file`);
  }
  const expected = new Map([
    ['icp4', 16],
    ['icp5', 32],
    ['icp6', 64],
    ['ic07', 128],
    ['ic08', 256],
    ['ic09', 512],
    ['ic10', 1024],
  ]);
  assert.deepEqual(new Set(entries.keys()), new Set(expected.keys()));
  for (const [type, size] of expected) {
    const metadata = await sharp(entries.get(type)).metadata();
    assert.equal(metadata.width, size, type);
    assert.equal(metadata.height, size, type);
    assert.equal(metadata.hasAlpha, true, type);
  }
  const { data, info } = await sharp(entries.get('ic10'))
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const alpha = (x, y) => data[(y * info.width + x) * info.channels + 3];
  assert.equal(alpha(0, 0), 0, 'the icon must not have opaque square corners');
  assert.equal(alpha(512, 512), 255, 'the center artwork must remain opaque');
});

test('native export imports, validates both frames, and rejects invalid inputs without overwriting', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wapacal-heic-'));
  const { data, config } = await loadFixtureApp();
  const images = {};
  for (const theme of ['light', 'dark']) {
    images[theme] = join(dir, `${theme}.png`);
    const rendered = renderWallpaper(data.events, {
      ...config,
      ...config.module,
      mode: 'module',
      theme,
    });
    await sharp(Buffer.from(rendered.svg)).png().toFile(images[theme]);
  }
  const pair = {
    version: 1,
    name: 'Test',
    light: (await readFile(images.light)).toString('base64'),
    dark: (await readFile(images.dark)).toString('base64'),
  };
  const source = join(dir, 'test.wapacal'),
    output = join(dir, 'test.heic');
  await writeFile(source, JSON.stringify(pair));
  const info = JSON.parse(execFileSync(binary, ['import', source, output], { encoding: 'utf8' }));
  assert.deepEqual(info, { frameCount: 2, width: 3024, height: 1964, lightIndex: 0, darkIndex: 1 });
  execFileSync(binary, ['inspect', output, dir]);
  for (const theme of ['light', 'dark']) {
    const actual = await sharp(join(dir, theme + '.png'))
      .removeAlpha()
      .raw()
      .toBuffer();
    const expected = await sharp(images[theme]).removeAlpha().raw().toBuffer();
    assert.equal(actual.length, expected.length);
    let error = 0;
    for (let i = 0; i < actual.length; i++) error += Math.abs(actual[i] - expected[i]);
    assert.ok(
      error / actual.length < 3,
      `${theme}: average channel error ${error / actual.length}`,
    );
  }
  const original = await readFile(output);
  pair.version = 99;
  await writeFile(source, JSON.stringify(pair));
  assert.notEqual(spawnSync(binary, ['import', source, output]).status, 0);
  assert.deepEqual(await readFile(output), original);
  const small = join(dir, 'small.png');
  await sharp({ create: { width: 10, height: 10, channels: 3, background: '#fff' } })
    .png()
    .toFile(small);
  const failed = spawnSync(binary, ['encode', small, images.dark, output]);
  assert.notEqual(failed.status, 0);
  assert.match(failed.stderr.toString(), /same dimensions/);
  assert.deepEqual(await readFile(output), original);
  assert.notEqual(spawnSync(binary, ['inspect', small]).status, 0);
});

test('missing wallpaper sources can be recorded without blocking Apply and old backups still decode', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wapacal-backup-'));
  const file = join(dir, 'main.swift');
  await writeFile(
    file,
    `import AppKit

let missing = URL(fileURLWithPath: "/nonexistent/wapacal-test-wallpaper.png")
for url in [nil, missing, URL(string: "https://example.com/image.png")] as [URL?] {
 let record = WallpaperBackup(screenID: "test", url: url, options: [.imageScaling: 3, .allowClipping: true])
 let decoded = try JSONDecoder().decode(WallpaperBackup.self, from: JSONEncoder().encode(record))
 assert(!decoded.canRestore)
 assert(decoded.url == url)
 assert(decoded.scaling == 3 && decoded.clipping == true)
}
let old = #"{"screen":"test","url":"file:///System/Library/CoreServices/SystemVersion.plist","scaling":3,"clipping":true}"#.data(using: .utf8)!
let decoded = try JSONDecoder().decode(WallpaperBackup.self, from: old)
assert(decoded.canRestore)
print("Backup regression checks passed")
`,
  );
  const executable = join(dir, 'checks');
  compileNative(file, executable, { stdio: 'pipe' });
  assert.match(execFileSync(executable, [], { encoding: 'utf8' }), /checks passed/);
});

test('refresh frequency accepts only the choices shown in the app', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wapacal-cache-'));
  const file = join(dir, 'main.swift');
  await writeFile(
    file,
    `import Foundation

assert(savedRefreshInterval(nil) == 3600)
assert(savedRefreshInterval(900) == 900)
assert(savedRefreshInterval(1800) == 1800)
assert(savedRefreshInterval(86400) == 86400)
assert(savedRefreshInterval(0) == 3600)
assert(savedRefreshInterval(-1) == 3600)
assert(savedRefreshInterval(.nan) == 3600)
assert(savedRefreshInterval(.infinity) == 3600)
print("Cache policy checks passed")
`,
  );
  const executable = join(dir, 'checks');
  compileNative(file, executable, { stdio: 'pipe' });
  assert.match(execFileSync(executable, [], { encoding: 'utf8' }), /checks passed/);
});

test('legacy and previous-bundle data migrate while reset preserves active recovery records', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wapacal-storage-'));
  const legacy = join(dir, 'legacy'),
    support = join(dir, 'support');
  await Promise.all([
    mkdir(join(legacy, 'state'), { recursive: true }),
    mkdir(join(legacy, 'recovery'), { recursive: true }),
    mkdir(join(legacy, 'wallpapers', 'applied'), { recursive: true }),
  ]);
  await Promise.all([
    writeFile(join(legacy, 'state', 'app-state.json'), '{}'),
    writeFile(join(legacy, 'wallpapers', 'editor-wallpaper.heic'), 'editor'),
    writeFile(join(legacy, 'recovery', 'restore-display.json'), '{}'),
    writeFile(join(legacy, 'recovery', 'restored-old.json'), '{}'),
    writeFile(join(legacy, 'wallpapers', 'applied', 'old.heic'), 'wallpaper'),
    writeFile(join(legacy, 'restore-flat.json'), '{}'),
  ]);
  const file = join(dir, 'main.swift');
  await writeFile(
    file,
    `import AppKit

try migrateLegacyWorkspace()
let files = FileManager.default
assert(files.fileExists(atPath: stateDirectory().appendingPathComponent("app-state.json").path))
assert(files.fileExists(atPath: recoveryDirectory().appendingPathComponent("restore-display.json").path))
assert(files.fileExists(atPath: recoveryDirectory().appendingPathComponent("restore-flat.json").path))
assert(files.fileExists(atPath: recoveryDirectory().appendingPathComponent("restored-old.json").path))
assert(files.fileExists(atPath: appliedDirectory().appendingPathComponent("old.heic").path))
let legacy = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAPACAL_LEGACY_WORKSPACE"]!)
assert(!files.fileExists(atPath: legacy.appendingPathComponent("state/app-state.json").path))
try resetInactiveRuntimeData()
assert(!files.fileExists(atPath: stateDirectory().appendingPathComponent("app-state.json").path))
assert(files.fileExists(atPath: recoveryDirectory().appendingPathComponent("restore-display.json").path))
assert(!files.fileExists(atPath: recoveryDirectory().appendingPathComponent("restored-old.json").path))
assert(!files.fileExists(atPath: appliedDirectory().appendingPathComponent("old.heic").path))
print("Storage migration checks passed")
`,
  );
  const executable = join(dir, 'checks');
  compileNative(file, executable, { stdio: 'pipe' });
  const output = execFileSync(executable, [], {
    encoding: 'utf8',
    env: { ...process.env, WAPACAL_APP_SUPPORT: support, WAPACAL_LEGACY_WORKSPACE: legacy },
  });
  assert.match(output, /checks passed/);
});

test('production migration does not inspect the folder containing the app', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wapacal-storage-scope-'));
  const file = join(dir, 'main.swift');
  await writeFile(
    file,
    `import AppKit

assert(legacyWorkspaceDirectories().isEmpty)
print("Storage migration scope checks passed")
`,
  );
  const executable = join(dir, 'checks');
  compileNative(file, executable, { stdio: 'pipe' });
  const environment = { ...process.env };
  delete environment.WAPACAL_LEGACY_WORKSPACE;
  assert.match(
    execFileSync(executable, [], { encoding: 'utf8', env: environment }),
    /checks passed/,
  );
});

test('wallpaper storage keeps image URLs immutable and protects restoration during cleanup', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wapacal-image-storage-'));
  const file = join(dir, 'main.swift');
  await writeFile(
    file,
    `import AppKit

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
let modified = try first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
assert(modified == oldDate, "identical images must not rewrite a cached URL")
let backup = WallpaperBackup(screenID: "fixture", url: first, options: [:])
try JSONEncoder().encode(backup).write(to: recoveryDirectory().appendingPathComponent("restore-fixture.json"))
for index in 0..<15 { _ = try storeAppliedWallpaper(Data("image \\(index)".utf8)) }
try cleanupRuntimeFiles()
assert(FileManager.default.fileExists(atPath: first.path), "cleanup must preserve the restore image")
let files = try FileManager.default.contentsOfDirectory(at: appliedDirectory(), includingPropertiesForKeys: nil)
assert(files.count == 11, "keep ten inactive images plus the protected restore image")
print("Wallpaper storage checks passed")
`,
  );
  const executable = join(dir, 'checks');
  compileNative(file, executable, { stdio: 'pipe' });
  assert.match(
    execFileSync(executable, [], {
      encoding: 'utf8',
      env: { ...process.env, WAPACAL_APP_SUPPORT: join(dir, 'support') },
    }),
    /checks passed/,
  );
});
