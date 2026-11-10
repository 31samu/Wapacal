import { mkdir, writeFile, readFile, mkdtemp, rename, rm, cp } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import sharp from 'sharp';
import { loadNativeBuildData } from './native-build-data.mjs';
import { compileNative } from './native-compile.mjs';
const args = process.argv.slice(2);
if (args.some((arg) => arg !== '--private-seed'))
  throw new Error('Usage: node scripts/build-native.mjs [--private-seed]');
const { config, seed } = await loadNativeBuildData({
  privateSeed: args.includes('--private-seed'),
});
const packageMetadata = JSON.parse(await readFile('package.json', 'utf8'));
const icalMetadata = JSON.parse(await readFile('node_modules/ical.js/package.json', 'utf8'));
const thirdPartyNotices = await readFile('THIRD-PARTY-NOTICES.txt', 'utf8');
if (
  !thirdPartyNotices.includes(`ICAL.js ${icalMetadata.version}\n`) ||
  !thirdPartyNotices.includes(`https://github.com/kewisch/ical.js/tree/v${icalMetadata.version}\n`)
)
  throw new Error('Update THIRD-PARTY-NOTICES.txt for the installed ICAL.js version.');
const version = packageMetadata.version;
const bundleIdentifier = packageMetadata.wapacal?.bundleIdentifier;
const bundleVersion = packageMetadata.wapacal?.bundleVersion;
if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error('package.json needs an x.y.z version.');
if (!/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(bundleIdentifier))
  throw new Error('package.json needs a reverse-DNS bundle identifier.');
if (!Number.isSafeInteger(bundleVersion) || bundleVersion < 1)
  throw new Error('package.json needs a positive integer bundle version.');
if (args.includes('--private-seed'))
  console.warn('Private development build: the app includes local calendar data. Do not share it.');
const outputBundle = 'output/Wapacal.app';
await mkdir('output', { recursive: true });
const temp = await mkdtemp(join(tmpdir(), 'wapacal-build-'));
const bundle = join(temp, 'Wapacal.app');
const backup = join(resolve('output'), `.Wapacal-backup-${randomUUID()}.app`);
const stagedBundle = join(resolve('output'), `.Wapacal-new-${randomUUID()}.app`);
const failedBundle = join(resolve('output'), `.Wapacal-failed-${randomUUID()}.app`);
try {
  await mkdir(`${bundle}/Contents/MacOS`, { recursive: true });
  await writeFile(
    `${bundle}/Contents/Info.plist`,
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Wapacal</string>
<key>CFBundleIdentifier</key><string>${bundleIdentifier}</string>
<key>CFBundleName</key><string>Wapacal</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Wapacal.icns</string>
<key>CFBundleVersion</key><string>${bundleVersion}</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Samuel Kremer</string>
<key>NSCalendarsUsageDescription</key><string>Wapacal reads calendars you choose to display events on your wallpaper. It never changes your calendars.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>Wapacal reads calendars you choose to display events on your wallpaper. It never changes your calendars.</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Wapacal export</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSItemContentTypes</key><array><string>${bundleIdentifier}.export</string><string>local.timetable.export</string></array></dict></array>
<key>UTExportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>${bundleIdentifier}.export</string><key>UTTypeConformsTo</key><array><string>public.json</string></array><key>UTTypeDescription</key><string>Wapacal light/dark export</string><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>wapacal</string></array></dict></dict></array>
<key>UTImportedTypeDeclarations</key><array><dict><key>UTTypeIdentifier</key><string>local.timetable.export</string><key>UTTypeConformsTo</key><array><string>public.json</string></array><key>UTTypeDescription</key><string>Legacy Wapacal export</string><key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>timetable</string></array></dict></dict></array>
</dict></plist>`,
  );
  compileNative('native/main.swift', `${bundle}/Contents/MacOS/Wapacal`);
  const resources = `${bundle}/Contents/Resources`;
  await mkdir(resources, { recursive: true });
  const iconSource = 'assets/app-icon/Wapacal-iOS-Default-1024x1024@1x.png';
  const iconEntries = [
    ['icp4', 16],
    ['icp5', 32],
    ['icp6', 64],
    ['ic07', 128],
    ['ic08', 256],
    ['ic09', 512],
    ['ic10', 1024],
  ];
  const iconChunks = [];
  let iconLength = 8;
  for (const [type, size] of iconEntries) {
    const png = await sharp(iconSource).resize(size, size).ensureAlpha().png().toBuffer();
    const chunk = Buffer.alloc(8 + png.length);
    chunk.write(type, 0, 4, 'ascii');
    chunk.writeUInt32BE(chunk.length, 4);
    png.copy(chunk, 8);
    iconChunks.push(chunk);
    iconLength += chunk.length;
  }
  const iconHeader = Buffer.alloc(8);
  iconHeader.write('icns', 0, 4, 'ascii');
  iconHeader.writeUInt32BE(iconLength, 4);
  await writeFile(`${resources}/Wapacal.icns`, Buffer.concat([iconHeader, ...iconChunks]));
  const parser = (await readFile('src/calendar.mjs', 'utf8'))
    .replace(/^import .*$/gm, '')
    .replace(/^export /gm, '');
  const engine = await readFile('node_modules/ical.js/dist/ical.es5.min.cjs', 'utf8');
  const layout = (await readFile('src/layout.mjs', 'utf8')).replace(/^export /gm, '');
  const suggestions = (await readFile('src/suggestions.mjs', 'utf8')).replace(/^export /gm, '');
  const editor = await readFile('src/native-editor.js', 'utf8');
  const { subscriptions, ...workerConfig } = config;
  const scriptJson = (value) =>
    JSON.stringify(value)
      .replace(/</g, '\\u003c')
      .replace(/\u2028/g, '\\u2028')
      .replace(/\u2029/g, '\\u2029');
  // The worker has no browser interface.
  await writeFile(
    `${resources}/calendar-worker.html`,
    `<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; img-src blob: data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'">
</head><body><script>${engine}\n${parser}\n${layout}\n${suggestions}\nconst config=${scriptJson(workerConfig)};\n${editor}</script></body></html>`,
  );
  await writeFile(`${resources}/seed.json`, JSON.stringify(seed));
  await writeFile(`${resources}/LICENSE`, await readFile('LICENSE'));
  await writeFile(`${resources}/ICAL-LICENSE`, await readFile('node_modules/ical.js/LICENSE'));
  await writeFile(`${resources}/THIRD-PARTY-NOTICES.txt`, thirdPartyNotices);
  // File Provider can attach metadata anywhere inside the generated bundle.
  execFileSync('xattr', ['-cr', bundle]);
  try {
    execFileSync('xattr', ['-d', 'com.apple.FinderInfo', bundle], { stdio: 'ignore' });
  } catch {}
  execFileSync('codesign', ['--force', '--sign', '-', bundle], { stdio: 'inherit' });
  try {
    await rename(bundle, stagedBundle);
  } catch (error) {
    if (error.code !== 'EXDEV') throw error;
    await cp(bundle, stagedBundle, { recursive: true, errorOnExist: true });
  }
  let replacedExisting = false;
  try {
    await rename(outputBundle, backup);
    replacedExisting = true;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  try {
    await rename(stagedBundle, outputBundle);
  } catch (error) {
    if (replacedExisting) {
      try {
        await rename(backup, outputBundle);
      } catch (restoreError) {
        throw new AggregateError(
          [error, restoreError],
          `Could not install the new app or restore the previous app. The previous app remains at ${backup}.`,
        );
      }
    }
    throw error;
  }
  try {
    let verified = false;
    for (let attempt = 0; attempt < 5 && !verified; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 50));
      execFileSync('xattr', ['-cr', outputBundle]);
      try {
        execFileSync('codesign', ['--verify', '--deep', '--strict', outputBundle], {
          stdio: 'ignore',
        });
        verified = true;
      } catch {}
    }
    if (!verified)
      execFileSync('codesign', ['--verify', '--deep', '--strict', outputBundle], {
        stdio: 'inherit',
      });
  } catch (error) {
    try {
      await rename(outputBundle, failedBundle);
      if (replacedExisting) await rename(backup, outputBundle);
    } catch (restoreError) {
      throw new AggregateError(
        [error, restoreError],
        `The new app failed verification, and the previous app could not be restored from ${backup}.`,
      );
    }
    throw error;
  }
  if (replacedExisting) await rm(backup, { recursive: true });
  console.log(outputBundle);
} finally {
  await rm(temp, { recursive: true, force: true });
  await rm(stagedBundle, { recursive: true, force: true });
  await rm(failedBundle, { recursive: true, force: true });
}
