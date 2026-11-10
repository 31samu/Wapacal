import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { parseCalendar, parseCalendars } from '../src/calendar.mjs';
import { configuredSubscriptions, readCalendarResponse } from '../src/subscriptions.mjs';
import { suggestModules } from '../src/suggestions.mjs';
import { renderWallpaper } from '../src/layout.mjs';
const calendar = (title = 'Deadline', extra = '') =>
  `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:same\r\nDTSTART:20260908T080000Z\r\nSUMMARY:${title}\r\nDESCRIPTION:Instructions\\nID 123\r\n${extra}END:VEVENT\r\nEND:VCALENDAR\r\n`;

test('calendar response size is enforced while streaming', async () => {
  let cancelled = false;
  const response = new Response(
    new ReadableStream({
      pull(controller) {
        controller.enqueue(new Uint8Array(6));
      },
      cancel() {
        cancelled = true;
      },
    }),
  );
  await assert.rejects(readCalendarResponse(response, 10), /exceeds/);
  assert.equal(cancelled, true);
  await assert.rejects(
    readCalendarResponse(new Response('short', { headers: { 'content-length': '11' } }), 10),
    /exceeds/,
  );
  assert.equal(await readCalendarResponse(new Response('calendar'), 10), 'calendar');
});

test('generic calendars use SUMMARY and preserve description; deadlines need no end time', () => {
  const {
    events: [event],
  } = parseCalendar(calendar(), 'Europe/Stockholm', 'generic');
  assert.equal(event.title, 'Deadline');
  assert.equal(event.description, 'Instructions\nID 123');
  assert.equal(event.start, event.end);
  const rendered = renderWallpaper([event], {
    mode: 'month',
    month: '2026-09',
    course: '',
    theme: 'light',
  });
  assert.equal(rendered.grid.visible.length, 1);
  assert.match(rendered.svg, />10:00<\/text>/);
  assert.equal(
    suggestModules([
      { ...event, title: 'Introduction' },
      { ...event, uid: 'second', date: '2026-09-09', title: 'Examination' },
    ]).length,
    0,
  );
});

test('same UID across calendars stays independent and legacy exclusions keep their identity', () => {
  const sources = [
    { id: 'legacy', legacyIds: true, name: 'TimeEdit', kind: 'timeedit', ics: calendar('Lecture') },
    { id: 'moodle', name: 'Moodle', kind: 'generic', ics: calendar() },
  ];
  const parsed = parseCalendars(sources);
  assert.equal(new Set(parsed.events.map((e) => e.uid)).size, 2);
  assert.equal(parsed.events.find((e) => e.sourceId === 'legacy').uid, 'same');
  assert.equal(parsed.events.find((e) => e.sourceId === 'moodle').title, 'Deadline');
  const options = {
    mode: 'month',
    month: '2026-09',
    course: '',
    theme: 'light',
    excludedEventIds: ['same'],
  };
  assert.equal(renderWallpaper(parsed.events, options).grid.visible[0].sourceId, 'moodle');
  const reordered = parseCalendars(sources.toReversed());
  assert.deepEqual(
    reordered.events.map((e) => e.uid),
    parsed.events.map((e) => e.uid),
  );
  assert.throws(() => parseCalendars([sources[0], sources[0]]), /subscription ID/);
  assert.equal(parseCalendars([]).events.length, 0);
});

test('configuration detects TimeEdit and rejects duplicate subscriptions and HTTP', () => {
  const source = configuredSubscriptions({
    subscriptions: [{ id: 'schedule', url: 'https://cloud.timeedit.net/example.ics' }],
  })[0];
  assert.equal(source.kind, 'timeedit');
  assert.throws(
    () =>
      configuredSubscriptions({ subscriptions: [{ id: 'a', url: 'http://example.com/calendar' }] }),
    /HTTPS/,
  );
  assert.throws(
    () => configuredSubscriptions({ subscriptions: [source, { ...source, id: 'b' }] }),
    /unique/,
  );
  assert.deepEqual(configuredSubscriptions({}), []);
});

test('refresh retains a failed feed, updates another, reuses validators, and drops removed feeds', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wapacal-subscriptions-'));
  try {
    await mkdir(join(dir, 'data'));
    const sources = [
      { id: 'a', name: 'A', url: 'https://example.com/a', ics: calendar('Old A'), etag: '"a"' },
      { id: 'b', name: 'B', url: 'https://example.com/b', ics: calendar('Old B'), etag: '"b"' },
    ];
    await writeFile(
      join(dir, 'config.local.json'),
      JSON.stringify({ subscriptions: sources.map(({ ics, etag, ...source }) => source) }),
    );
    await writeFile(join(dir, 'data/calendars.json'), JSON.stringify({ subscriptions: sources }));
    const script = resolve('scripts/fetch.mjs');
    const run = (code) =>
      spawnSync(
        process.execPath,
        ['--input-type=module', '-e', `${code};await import(${JSON.stringify(script)})`],
        { cwd: dir, encoding: 'utf8', env: process.env },
      );
    const first = run(
      `globalThis.fetch=async(url,{headers})=>{if(url.endsWith('/a'))throw Error('offline');if(headers['If-None-Match']!=='"b"')throw Error('missing validator');return new Response(${JSON.stringify(calendar('New B'))},{headers:{etag:'"new"'}})}`,
    );
    assert.equal(first.status, 1, first.stderr);
    const saved = JSON.parse(await readFile(join(dir, 'data/calendars.json'))).subscriptions;
    assert.match(saved[0].ics, /Old A/);
    assert.match(saved[1].ics, /New B/);
    assert.equal(saved[1].etag, '"new"');
    await writeFile(
      join(dir, 'config.local.json'),
      JSON.stringify({ subscriptions: [{ id: 'b', name: 'B', url: 'https://example.com/b' }] }),
    );
    const second = run(`globalThis.fetch=async()=>new Response(null,{status:304})`);
    assert.equal(second.status, 0, second.stderr);
    const remaining = JSON.parse(await readFile(join(dir, 'data/calendars.json'))).subscriptions;
    assert.equal(remaining.length, 1);
    assert.match(remaining[0].ics, /New B/);
    const invalid = run(`globalThis.fetch=async()=>new Response('not ICS')`);
    assert.equal(invalid.status, 1);
    assert.match(
      JSON.parse(await readFile(join(dir, 'data/calendars.json'))).subscriptions[0].ics,
      /New B/,
    );
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
