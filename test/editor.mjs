import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { loadFixtureApp } from './helpers/fixture-app.mjs';
import { parseCalendar } from '../src/calendar.mjs';
import { renderWallpaper } from '../src/layout.mjs';

async function setup() {
  const { editor, seed } = await loadFixtureApp();
  const dom = new JSDOM(editor, { runScripts: 'dangerously', url: 'https://worker.invalid' });
  dom.window.nativeLoad(seed);
  const snapshot = () => JSON.parse(JSON.stringify(dom.window.nativeSnapshot()));
  return { dom, w: dom.window, seed, snapshot };
}
const calendar = (...events) =>
  `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${events.join('')}END:VCALENDAR\r\n`;
const session = (uid, title, date = '20260908') =>
  `BEGIN:VEVENT\r\nUID:${uid}\r\nDTSTART:${date}T080000Z\r\nDTEND:${date}T100000Z\r\nSUMMARY:${title}\r\nEND:VEVENT\r\n`;

test('worker has no visible content, controls, web bridge, or browser persistence', async () => {
  const { dom, w } = await setup();
  assert.equal(w.document.body.children.length, 1);
  assert.equal(w.document.body.firstElementChild.tagName, 'SCRIPT');
  assert.equal(w.document.querySelector('input,button,a,iframe,svg,canvas'), null);
  assert.equal(w.webkit, undefined);
  assert.equal(dom.window.localStorage?.length, 0);
  dom.window.close();
});

test('saved settings, custom dimensions, unknown fields and exclusions survive load and refresh', async () => {
  const { dom, w, seed, snapshot } = await setup();
  assert.equal(snapshot().editor.showTitle, false);
  assert.equal(snapshot().editor.includeWeekends, false);
  const uid = snapshot().events.find((event) => event.title === 'Launch presentation').uid;
  w.nativeInclude(uid, false);
  const editor = {
    ...snapshot().editor,
    name: 'Saved module',
    showTitle: true,
    rooms: false,
    includeWeekends: true,
    theme: 'dark',
    width: 2880,
    height: 1800,
    futureSetting: { enabled: true },
  };
  w.nativeLoad({ ...seed, editor });
  assert.equal(snapshot().editor.name, 'Saved module');
  assert.match(snapshot().svg, />Saved module<\/text>/);
  assert.equal(snapshot().editor.rooms, false);
  assert.equal(snapshot().editor.includeWeekends, true);
  assert.match(snapshot().svg, />SATURDAY<.*>SUNDAY</s);
  assert.equal(snapshot().editor.width, 2880);
  w.nativeFeed(seed.ics, '2026-09-07T12:00:00Z');
  assert.doesNotMatch(snapshot().svg, /Launch presentation/);
  assert.deepEqual(snapshot().editor.futureSetting, { enabled: true });
  const before = snapshot();
  assert.throws(() => w.nativeFeed('invalid ICS', '2026-09-08T12:00:00Z'));
  assert.deepEqual(snapshot(), before);
  dom.window.close();
});

test('system is the default appearance and is a valid preview setting', async () => {
  const { dom, w, snapshot } = await setup();
  assert.equal(snapshot().editor.theme, 'system');
  w.nativeUpdate({ theme: 'system' });
  assert.equal(snapshot().editor.theme, 'system');
  assert.throws(() => w.nativeUpdate({ theme: 'unknown' }));
  dom.window.close();
});

test('wallpaper matches the shared renderer exactly and preserves plain event details', async () => {
  const { dom, seed, snapshot } = await setup();
  const current = snapshot();
  assert.equal(
    current.svg,
    renderWallpaper(parseCalendar(seed.ics, current.editor.timeZone).events, current.editor).svg,
  );
  dom.window.nativeFeed(
    calendar(
      session('markup', '<script>alert(1)</script>').replace(
        'END:VEVENT',
        'DESCRIPTION:Full plain text\r\nLOCATION:Room 12\r\nEND:VEVENT',
      ),
    ),
    '2026-09-08T12:00:00Z',
  );
  dom.window.nativeUpdate({ mode: 'month', month: '2026-09', course: '' });
  const markup = snapshot().events.find((event) => event.uid === 'markup');
  assert.equal(markup.description, 'Full plain text');
  assert.equal(markup.location, 'Room 12');
  assert.equal(markup.title, '<script>alert(1)</script>');
  assert.match(snapshot().svg, /&lt;script&gt;/);
  assert.equal(dom.window.document.querySelectorAll('script').length, 1);
  dom.window.close();
});

test('invalid edits are transactional, and repairing the range permits subsequent edits', async () => {
  const { dom, w, snapshot } = await setup();
  const before = snapshot();
  for (const patch of [
    { start: '2026-11-20', end: '2026-10-05' },
    { width: 100 },
    { height: 99999 },
    { name: '' },
    { mode: 'week' },
    { theme: 'unknown' },
    { includeWeekends: 'yes' },
    { excludedEventIds: [] },
  ]) {
    assert.throws(() => w.nativeUpdate(patch));
    assert.deepEqual(snapshot(), before);
  }
  w.nativeUpdate({ start: '2026-09-01', end: '2026-09-30', name: 'September' });
  assert.equal(snapshot().editor.name, 'September');
  dom.window.close();
});

test('suggestions require an explicit choice and accept edited dates without changing exclusions', async () => {
  const { dom, w, snapshot } = await setup();
  const before = snapshot();
  assert.equal(before.suggestions.length, 2);
  const suggestion = before.suggestions[0];
  assert.ok(suggestion.reasons.length);
  assert.equal(snapshot().editor.name, before.editor.name);
  w.nativeUpdate({
    mode: 'module',
    name: 'My foundations module',
    start: '2026-08-31',
    end: suggestion.end,
    proposed: false,
  });
  assert.equal(snapshot().editor.name, 'My foundations module');
  assert.equal(snapshot().editor.start, '2026-08-31');
  assert.deepEqual(snapshot().editor.excludedEventIds, before.editor.excludedEventIds);
  dom.window.close();
});

test('refresh retains recent completed events, drops future omissions, and persists cancellations', async () => {
  const { dom, w, seed, snapshot } = await setup();
  w.nativeLoad({
    ...seed,
    ics: calendar(
      session('kept', 'Original'),
      session('deleted', 'Completed event'),
      session('future', 'Future event', '20260921'),
    ),
    editor: {
      mode: 'module',
      start: '2026-09-01',
      end: '2026-09-30',
      course: '',
      excludedEventIds: ['kept'],
    },
  });
  assert.equal(snapshot().includedCount, 2);
  assert.equal(snapshot().events.length, 3);
  w.nativeFeed(
    calendar(
      session('kept', 'Moved', '20260909'),
      session('new', 'New session'),
      'BEGIN:VEVENT\r\nUID:cancelled\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n',
    ),
    '2026-09-08T12:00:00Z',
  );
  const before = snapshot();
  assert.match(before.svg, /New session/);
  assert.match(before.svg, /Completed event/);
  assert.doesNotMatch(before.svg, /Moved|Future event/);
  assert.equal(before.events.length, 3);
  assert.equal(before.events.find((e) => e.uid === 'kept').included, false);
  assert.throws(
    () =>
      w.nativeFeed(
        calendar(session('duplicate', 'One'), session('duplicate', 'Two')),
        '2026-09-09T12:00:00Z',
      ),
    /duplicate/,
  );
  assert.deepEqual(snapshot(), before);
  const persistedSources = w.nativeFeed(
    calendar('BEGIN:VEVENT\r\nUID:deleted\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\n'),
    '2026-09-09T12:00:00Z',
  );
  assert.equal(snapshot().includedCount, 1);
  assert.match(snapshot().svg, /New session/);
  assert.doesNotMatch(snapshot().svg, /Completed event/);
  assert.ok(snapshot().editor.excludedEventIds.includes('kept'));
  const savedEditor = snapshot().editor;
  w.nativeLoad({ ...seed, subscriptions: persistedSources, editor: savedEditor });
  assert.equal(snapshot().includedCount, 1);
  assert.match(snapshot().svg, /New session/);
  assert.doesNotMatch(snapshot().svg, /Completed event/);
  dom.window.close();
});

test('wake, startup, and refresh advance a following month across year end and preserve historical months', async () => {
  for (const action of ['day', 'feed', 'load'])
    for (const following of [true, false]) {
      const { dom, w, seed, snapshot } = await setup();
      const RealDate = w.Date;
      let now = '2026-12-31T22:30:00Z';
      w.Date = class extends RealDate {
        constructor(...args) {
          super(...(args.length ? args : [now]));
        }
        static now() {
          return new RealDate(now).getTime();
        }
      };
      w.nativeLoad({
        ...seed,
        ics: calendar(),
        editor: {
          mode: 'month',
          month: following ? '2026-12' : '2026-09',
          today: '2026-12-31',
          course: '',
        },
      });
      const previous = snapshot().editor;
      now = '2026-12-31T23:30:00Z';
      if (action === 'day') assert.equal(w.nativeDay(), true);
      else if (action === 'feed') w.nativeFeed(calendar(), now);
      else w.nativeLoad({ ...seed, ics: calendar(), editor: previous });
      assert.equal(snapshot().editor.today, '2027-01-01');
      assert.equal(snapshot().editor.month, following ? '2027-01' : '2026-09');
      assert.equal(w.nativeDay(), false);
      dom.window.close();
    }
});

test('reset clears cached calendar, exclusions and course filter', async () => {
  const { dom, w, snapshot } = await setup();
  assert.ok(snapshot().events.length > 0);
  assert.equal(w.nativeReset(), true);
  assert.equal(snapshot().events.length, 0);
  assert.equal(snapshot().editor.course, '');
  assert.equal(snapshot().courseCode, '');
  assert.equal(snapshot().editor.name, 'New module');
  assert.equal(snapshot().editor.snapshotDate, 'none');
  assert.equal(snapshot().editor.excludedEventIds.length, 0);
  dom.window.close();
});

test('multiple subscriptions retain independent identities and validate before replacing', async () => {
  const { dom, w, seed, snapshot } = await setup();
  const sources = [
    {
      id: 'legacy',
      legacyIds: true,
      name: 'TimeEdit',
      kind: 'timeedit',
      ics: calendar(session('same', 'Lecture')),
    },
    {
      id: 'moodle',
      name: 'Moodle',
      kind: 'generic',
      ics: calendar(session('same', 'Assignment deadline')),
    },
  ];
  w.nativeLoad({
    ...seed,
    subscriptions: sources,
    editor: {
      course: '',
      mode: 'module',
      start: '2026-09-01',
      end: '2026-09-30',
      excludedEventIds: ['same'],
    },
  });
  assert.match(snapshot().svg, /Assignment deadline/);
  assert.doesNotMatch(snapshot().svg, />Lecture</);
  assert.equal(snapshot().events.length, 2);
  assert.equal(
    snapshot().events.find((e) => e.calendarId === 'moodle')?.sourceName ??
      snapshot().events.find((e) => e.sourceName === 'Moodle').sourceName,
    'Moodle',
  );
  const before = snapshot();
  assert.throws(() =>
    w.nativeCalendars([...sources, { id: 'invalid', ics: 'invalid' }], '2026-09-09T12:00:00Z'),
  );
  assert.deepEqual(snapshot(), before);
  w.nativeCalendars(sources.toReversed(), '2026-09-09T12:00:00Z');
  assert.equal(snapshot().events.find((e) => e.uid === 'same').included, false);
  w.nativeCalendars([sources[1]], '2026-09-09T12:00:00Z');
  assert.equal(snapshot().events.length, 1);
  assert.ok(snapshot().editor.excludedEventIds.includes('same'));
  w.nativeCalendars([], '2026-09-09T12:00:00Z');
  assert.equal(snapshot().events.length, 0);
  dom.window.close();
});

test('both export appearances capture the same revision even if settings change while rasterizing', async () => {
  const { dom, w, snapshot } = await setup();
  const frames = [];
  w.pngBase64 = async (svg) => {
    frames.push(svg);
    w.nativeUpdate({ name: 'Changed during export', showTitle: true });
    return 'UE5H';
  };
  const before = snapshot().editor;
  const pair = await w.nativePair();
  assert.equal(pair.version, 1);
  assert.equal(pair.name, before.name);
  assert.equal(frames.length, 2);
  assert.match(frames[0], /#f0efe9/);
  assert.match(frames[1], /#18231f/);
  assert.doesNotMatch(frames[1], /Changed during export/);
  assert.equal(pair.light, 'UE5H');
  assert.equal(pair.dark, 'UE5H');
  dom.window.close();
});

test('navigating outside the default recurrence window expands events and preserves occurrence exclusions', async () => {
  const { dom, w, snapshot } = await setup();
  w.nativeLoad({
    ics: calendar(
      session('weekly', 'Repeated').replace('END:VEVENT', 'RRULE:FREQ=WEEKLY\r\nEND:VEVENT'),
    ),
    editor: { mode: 'month', month: '2030-09', course: '' },
  });
  const before = snapshot();
  assert.ok(before.events.length >= 4);
  const occurrence = before.events[0].uid;
  w.nativeInclude(occurrence, false);
  w.nativeUpdate({ month: '2035-09' });
  assert.ok(snapshot().events.some((e) => e.date.startsWith('2035-09')));
  w.nativeUpdate({ month: '2030-09' });
  assert.equal(snapshot().events.find((e) => e.uid === occurrence).included, false);
  dom.window.close();
});

test('changing calendar colors updates wallpaper and survives refresh and reload', async () => {
  const { dom, w, snapshot } = await setup();
  const source = {
    id: 'colors',
    name: 'Colors',
    url: 'https://example.invalid/colors',
    ics: calendar(session('color-event', 'Colored event', '20261005')),
  };
  w.nativeUpdate({ mode: 'month', month: '2026-10', theme: 'light', course: '' });
  for (const color of ['blue', '#336699']) {
    const sources = [{ ...source, color }];
    w.nativeSources(sources, false);
    const expected = color === 'blue' ? '#285e9b' : color;
    assert.match(snapshot().svg, new RegExp(`fill="${expected}"[^>]*>Colored event</text>`));
    const refreshed = w.nativeCalendars(sources, '2026-09-10T12:00:00Z');
    assert.equal(refreshed[0].color, color);
    w.nativeLoad({ subscriptions: refreshed, editor: snapshot().editor });
    assert.match(snapshot().svg, new RegExp(`fill="${expected}"[^>]*>Colored event</text>`));
  }
  dom.window.close();
});

test('local calendar selection and individual exclusions survive refresh, moves and reload', async () => {
  const { dom, w, snapshot } = await setup();
  const event = {
    uid: '["series","2026-09-08T08:00:00Z"]',
    start: '2026-09-08T08:00:00Z',
    end: '2026-09-08T09:00:00Z',
    allDay: false,
    title: 'Local appointment',
    summary: 'Local appointment',
    description: 'Private details',
    location: 'Office',
  };
  let source = {
    id: 'local-calendar',
    provider: 'eventkit',
    name: 'Personal',
    snapshot: {
      version: 1,
      coverageStart: '2025-01-01',
      coverageEnd: '2028-01-01',
      events: [event],
    },
  };
  w.nativeSources([source], true);
  w.nativeUpdate({ mode: 'month', month: '2026-09' });
  const uid = snapshot().events[0].uid;
  w.nativeInclude(uid, false);
  assert.equal(snapshot().events[0].included, false);
  assert.doesNotMatch(snapshot().svg, /Local appointment/);
  source = {
    ...source,
    snapshot: {
      ...source.snapshot,
      events: [{ ...event, start: '2026-09-09T08:00:00Z', end: '2026-09-09T09:00:00Z' }],
    },
  };
  w.nativeCalendars([source], '2026-09-09T12:00:00Z');
  assert.equal(snapshot().events[0].uid, uid);
  assert.equal(snapshot().events[0].included, false);
  w.nativeSources([{ ...source, enabled: false }], false);
  assert.equal(snapshot().events.length, 0);
  w.nativeSources([source], false);
  assert.equal(snapshot().events[0].included, false);
  w.nativeLoad({ subscriptions: [source], editor: snapshot().editor });
  assert.equal(snapshot().events[0].included, false);
  w.nativeInclude(uid, true);
  assert.match(snapshot().svg, /Local appointment/);
  w.nativeUpdate({ month: '2035-09' });
  assert.ok(w.nativeCalendarWindow().to > '2035-09-30');
  const before = snapshot();
  assert.throws(() =>
    w.nativeCalendars(
      [{ ...source, snapshot: { ...source.snapshot, events: [{}] } }],
      '2026-09-09T12:00:00Z',
    ),
  );
  assert.deepEqual(snapshot(), before);
  w.nativeSources([{ ...source, snapshot: undefined }], false);
  assert.equal(snapshot().events.length, 0);
  dom.window.close();
});

test('event style defaults to text, switches rendering and survives reload', async () => {
  const { dom, w, seed, snapshot } = await setup();
  const original = snapshot();
  assert.equal(original.editor.eventStyle, 'text');
  w.nativeUpdate({ eventStyle: 'boxes' });
  const boxed = snapshot();
  assert.equal(boxed.editor.eventStyle, 'boxes');
  assert.notEqual(boxed.svg, original.svg);
  w.nativeLoad({ ...seed, editor: boxed.editor });
  assert.equal(snapshot().svg, boxed.svg);
  assert.throws(() => w.nativeUpdate({ eventStyle: 'invalid' }));
  assert.equal(snapshot().editor.eventStyle, 'boxes');
  w.nativeUpdate({ eventStyle: 'text' });
  assert.equal(snapshot().svg, original.svg);
  dom.window.close();
});

test('color themes render in both appearances and custom colors survive reload', async () => {
  const { dom, w, seed, snapshot } = await setup();
  w.nativeUpdate({ mode: 'month', month: '2026-10', course: '' });
  w.nativeSources(
    [
      {
        id: 'colored',
        name: 'Colored calendar',
        color: '#ff0000',
        ics: calendar(session('colored', 'Colored event', '20261005')),
      },
    ],
    false,
  );
  for (const colorTheme of ['forest', 'neutral', 'ocean', 'plum', 'rose', 'sand']) {
    for (const theme of ['light', 'dark']) {
      w.nativeUpdate({ colorTheme, theme, eventStyle: 'boxes', calendarColors: false });
      const current = snapshot();
      assert.ok(current.svg.includes('<svg'));
      if (colorTheme === 'neutral') {
        for (const [, hex] of current.svg.matchAll(/(?:fill|stroke)="(#[0-9a-f]{6})"/gi)) {
          assert.equal(hex.slice(1, 3), hex.slice(3, 5));
          assert.equal(hex.slice(3, 5), hex.slice(5, 7));
        }
      }
      for (const eventStyle of ['text', 'boxes']) {
        w.nativeUpdate({ calendarColors: true, eventStyle });
        assert.match(snapshot().svg, /fill="#ff0000"[^>]*>Colored calendar<\/text>/);
        if (eventStyle === 'text') {
          assert.match(snapshot().svg, /fill="#ff0000"[^>]*>Colored event<\/text>/);
        } else {
          assert.ok(snapshot().svg.includes(theme === 'light' ? '#ff4d4d' : '#b30000'));
        }
      }
    }
  }
  const customColors = {
    light: { bg: '#fafafa', text: '#222222', accent: '#995511' },
    dark: { bg: '#111111', text: '#eeeeee', accent: '#eeaa55' },
  };
  w.nativeUpdate({ colorTheme: 'custom', customColors, calendarColors: false });
  const saved = snapshot().editor;
  w.nativeLoad({ ...seed, editor: saved });
  assert.deepEqual(snapshot().editor.customColors, customColors);
  for (const theme of ['light', 'dark']) {
    w.nativeUpdate({ theme });
    assert.ok(snapshot().svg.includes(`fill="${customColors[theme].bg}"`));
  }
  w.nativeUpdate({ colorTheme: 'ocean' });
  w.nativeUpdate({ colorTheme: 'custom' });
  assert.deepEqual(snapshot().editor.customColors, customColors);
  const before = snapshot();
  for (const patch of [
    { colorTheme: 'unknown' },
    { calendarColors: 'yes' },
    { customColors: null },
    { customColors: { light: { bg: 'red' } } },
    { customColors: { ...customColors, dark: { ...customColors.dark, accent: '#fff\"/>' } } },
  ]) {
    assert.throws(() => w.nativeUpdate(patch));
    assert.deepEqual(snapshot(), before);
  }
  dom.window.close();
});

test('unconfigured custom colors default to neutral and light boxes respect custom text', async () => {
  const { dom, w, snapshot } = await setup();
  for (const colorTheme of ['forest', 'ocean', 'custom']) {
    w.nativeUpdate({ colorTheme });
    assert.deepEqual(snapshot().customColors, {
      light: { bg: '#f2f2f2', text: '#292929', accent: '#555555' },
      dark: { bg: '#202020', text: '#eeeeee', accent: '#bbbbbb' },
    });
  }
  const customColors = snapshot().customColors;
  customColors.light.text = '#123456';
  w.nativeUpdate({ colorTheme: 'custom', theme: 'light', eventStyle: 'boxes', customColors });
  const current = snapshot();
  const doc = new JSDOM(current.svg, { contentType: 'image/svg+xml' }).window.document;
  const boxes = [...doc.querySelectorAll('rect')].filter((rect) => rect.getAttribute('rx') === '5');
  assert.ok(boxes.length > 0);
  for (const box of boxes) {
    let next = box.nextElementSibling;
    if (next.tagName !== 'text') next = next.nextElementSibling;
    assert.equal(next.getAttribute('fill'), '#123456');
  }
  dom.window.close();
});

test('event text size changes rendering, survives reload, and rejects invalid values', async () => {
  const { dom, w, seed, snapshot } = await setup();
  assert.equal(snapshot().editor.eventTextScale, 1);
  for (const eventStyle of ['text', 'boxes']) {
    for (const eventTextScale of [0.75, 1.5]) {
      w.nativeUpdate({ eventStyle, eventTextScale });
      assert.match(snapshot().svg, new RegExp(`font-size="${14 * eventTextScale}"`));
      const editor = snapshot().editor;
      w.nativeLoad({ ...seed, editor });
      assert.equal(snapshot().editor.eventTextScale, eventTextScale);
    }
  }
  const before = snapshot();
  for (const eventTextScale of [0.5, 2, '1', NaN, Infinity]) {
    assert.throws(() => w.nativeUpdate({ eventTextScale }), /event text size/);
    assert.deepEqual(snapshot(), before);
  }
  dom.window.close();
});

test('edge padding changes layout, survives reload, and rejects invalid values', async () => {
  const { dom, w, seed, snapshot } = await setup();
  const position = (label) => {
    const doc = new JSDOM(snapshot().svg, { contentType: 'image/svg+xml' }).window.document;
    const node = [...doc.querySelectorAll('text')].find((node) => node.textContent === label);
    return ['x', 'y'].map((axis) => Number(node.getAttribute(axis)));
  };
  const footerLabel = 'Snapshot ' + snapshot().editor.snapshotDate;
  const footer = position(footerLabel);
  const week = position('WK');
  const zone = position(snapshot().editor.timeZone);
  const patch = { paddingLeft: 96, paddingRight: 96, paddingTop: 44, paddingBottom: 42 };
  w.nativeUpdate(patch);
  assert.deepEqual(position('WK'), [week[0] + 20, week[1] + 20]);
  assert.deepEqual(position(footerLabel), [footer[0] + 20, footer[1] - 20]);
  assert.deepEqual(position(snapshot().editor.timeZone), [zone[0] - 20, zone[1] + 20]);
  const editor = snapshot().editor;
  const svg = snapshot().svg;
  w.nativeLoad({ ...seed, editor });
  assert.equal(snapshot().svg, svg);
  for (const [key, value] of Object.entries(patch)) assert.equal(snapshot().editor[key], value);
  const before = snapshot();
  for (const key of Object.keys(patch)) {
    for (const value of [-1, 201, '20', NaN, Infinity]) {
      assert.throws(() => w.nativeUpdate({ [key]: value }), /padding/);
      assert.deepEqual(snapshot(), before);
    }
  }
  dom.window.close();
});

test('visibility options change rendering and survive reload', async () => {
  const { dom, w, seed, snapshot } = await setup();
  const original = snapshot().svg;
  for (const key of [
    'showTimeZone',
    'showWeekNumbers',
    'highlightToday',
    'showSnapshotDate',
    'showCalendarLegend',
    'showEventTimes',
  ]) {
    assert.equal(snapshot().editor[key], true);
    w.nativeUpdate({ [key]: false });
    const editor = snapshot().editor;
    w.nativeLoad({ ...seed, editor });
    assert.equal(snapshot().editor[key], false);
    const before = snapshot();
    assert.throws(() => w.nativeUpdate({ [key]: 'false' }), /visibility/);
    assert.deepEqual(snapshot(), before);
    w.nativeUpdate({ [key]: true });
    assert.equal(snapshot().svg, original);
  }
  const editor = snapshot().editor;
  const render = (patch) =>
    renderWallpaper([], { ...editor, mode: 'month', month: '2026-09', ...patch });
  const normal = render({});
  const noZone = render({ showTimeZone: false });
  assert.ok(normal.bounds.some((item) => item.text === editor.timeZone));
  assert.ok(!noZone.bounds.some((item) => item.text === editor.timeZone));
  const noWeeks = render({ showWeekNumbers: false });
  assert.ok(!noWeeks.bounds.some((item) => item.text === 'WK'));
  const mondayX = (result) => result.bounds.find((item) => item.text === 'MONDAY').x;
  assert.equal(mondayX(noWeeks), mondayX(normal) - 44);
  for (const today of ['2026-09-08', '2026-09-12']) {
    const highlighted = render({ today });
    assert.ok(highlighted.bounds.some((item) => item.text.startsWith('TODAY')));
    const hidden = render({ today, highlightToday: false });
    assert.ok(!hidden.bounds.some((item) => item.text.startsWith('TODAY')));
    assert.equal(hidden.svg, render({ today: undefined }).svg);
  }
  dom.window.close();
});
