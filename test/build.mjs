import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, copyFile, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const buildModule = pathToFileURL(resolve('scripts/native-build-data.mjs')).href;
const snapshotsModule = pathToFileURL(resolve('src/subscriptions.mjs')).href;

test('public build data is identical in fresh and private workspaces', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wapacal-build-data-'));
  const run = (body) => {
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', body], {
      cwd: dir,
      encoding: 'utf8',
      env: process.env,
    });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  const build = (privateSeed) =>
    run(`import {loadNativeBuildData} from ${JSON.stringify(buildModule)};
    console.log(JSON.stringify(await loadNativeBuildData({privateSeed:${privateSeed}})));`);
  const snapshots = (config) =>
    run(`import {loadSnapshots} from ${JSON.stringify(snapshotsModule)};
    console.log(JSON.stringify(await loadSnapshots(${JSON.stringify(config)})));`);
  try {
    await copyFile('config.example.json', join(dir, 'config.example.json'));
    const clean = build(false);
    assert.deepEqual(clean.seed, { subscriptions: [], courseCode: '', editor: { mode: 'month' } });
    assert.equal(clean.config.course, '');
    assert.deepEqual(snapshots({}), []);
    const source = {
      id: 'private',
      name: 'PRIVATE_NAME',
      url: 'https://example.invalid/PRIVATE_TOKEN',
    };
    assert.equal(snapshots({ subscriptions: [source] })[0].url, source.url);
    assert.deepEqual(build(true).seed.subscriptions, []);

    await mkdir(join(dir, 'data'));
    await writeFile(
      join(dir, 'config.local.json'),
      JSON.stringify({ course: 'PRIVATE_COURSE', subscriptions: [source] }),
    );
    await writeFile(
      join(dir, 'data/calendars.json'),
      JSON.stringify({ subscriptions: [{ ...source, ics: 'PRIVATE_EVENTS' }] }),
    );
    assert.deepEqual(build(false), clean);
    assert.equal(build(true).seed.subscriptions[0].ics, 'PRIVATE_EVENTS');

    await writeFile(join(dir, 'config.local.json'), 'invalid json');
    await writeFile(join(dir, 'data/calendars.json'), 'invalid json');
    assert.deepEqual(build(false), clean);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
