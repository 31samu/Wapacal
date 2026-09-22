import test from 'node:test';
import assert from 'node:assert/strict';
import {
  parseCalendar,
  parseCalendars,
  reconcileSubscriptions,
  localParts,
} from '../src/calendar.mjs';
import { buildGrid, renderWallpaper, wrapText } from '../src/layout.mjs';
const ics = (body) =>
  `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:test@example.com\r\n${body}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`;
test('unfolds and unescapes real ICS text; uses description title and flags room disagreement', () => {
  const {
    events: [event],
  } = parseCalendar(
    ics(
      'DTSTART:20260908T080000Z\r\nDTEND:20260908T100000Z\r\nSUMMARY:Workshop\\, 1DI300\r\nDESCRIPTION:Intro Day 2\\nWorkshop in M10\r\n 99B\\nID 123\r\nLOCATION:M1104V Food lab',
    ),
  );
  assert.equal(event.title, 'Intro Day 2');
  assert.equal(event.startTime, '10:00');
  assert.equal(event.endTime, '12:00');
  assert.equal(event.summary, 'Workshop, 1DI300');
  assert.equal(event.roomConflict, true);
  assert.equal(event.description, 'Intro Day 2\nWorkshop in M1099B');
});
test('Stockholm daylight-saving time is applied on both sides of the October transition', () => {
  assert.equal(localParts('2026-10-23T07:30:00Z', 'Europe/Stockholm').time, '09:30');
  assert.equal(localParts('2026-10-26T12:00:00Z', 'Europe/Stockholm').time, '13:00');
});
test('fallback labels omit course metadata and room codes handle TimeEdit suffixes', () => {
  const {
    events: [event],
  } = parseCalendar(
    ics(
      'DTSTART:20260922T110000Z\r\nDTEND:20260922T130000Z\r\nSUMMARY:Tutoring\\, 1DI300\\, DGVIC\r\nLOCATION:M1099B_V Ateljé 1',
    ),
  );
  assert.equal(event.title, 'Tutoring');
  assert.equal(event.room, 'M1099B');
  assert.equal(event.summary, 'Tutoring, 1DI300, DGVIC');
});
test('date-only end is exclusive and weekend visibility follows the setting', () => {
  const { events } = parseCalendar(
    ics('DTSTART;VALUE=DATE:20261030\r\nDTEND;VALUE=DATE:20261103\r\nSUMMARY:Holiday'),
  );
  const grid = buildGrid(events, {
    mode: 'module',
    start: '2026-10-26',
    end: '2026-11-08',
    course: '',
  });
  assert.equal(grid.columns, 5);
  assert.deepEqual(
    grid.rows
      .flat()
      .filter((day) => day.events.length)
      .map((day) => day.key),
    ['2026-10-30', '2026-11-02'],
  );
  assert.equal(grid.rows.flat().find((day) => day.key === '2026-11-03').events.length, 0);
  const weekendGrid = buildGrid(events, {
    mode: 'module',
    start: '2026-10-26',
    end: '2026-11-08',
    course: '',
    includeWeekends: true,
  });
  assert.equal(weekendGrid.columns, 7);
  assert.deepEqual(
    weekendGrid.rows
      .flat()
      .filter((day) => day.events.length)
      .map((day) => day.key),
    ['2026-10-30', '2026-10-31', '2026-11-01', '2026-11-02'],
  );
  const wallpaper = renderWallpaper(events, {
    mode: 'module',
    start: '2026-10-26',
    end: '2026-11-08',
    name: 'Weekend test',
    course: '',
    theme: 'light',
    includeWeekends: true,
  });
  assert.match(wallpaper.svg, />SATURDAY<.*>SUNDAY</s);
  assert.equal(wallpaper.placements.length, 4);
  for (const bound of wallpaper.bounds) {
    const left = bound.anchor === 'end' ? bound.x - bound.width : bound.x;
    assert.ok(left >= 0 && left + bound.width <= wallpaper.logicalWidth);
  }
});
test('both views fill existing rows beyond the target range and optionally include weekend events', () => {
  const dates = [
    '2026-08-28',
    '2026-08-31',
    '2026-09-01',
    '2026-09-05',
    '2026-09-06',
    '2026-09-30',
    '2026-10-02',
    '2026-10-05',
  ];
  const events = dates.map((date) => {
    const stamp = date.replaceAll('-', '');
    const event = parseCalendar(
      ics(`DTSTART:${stamp}T080000Z\r\nDTEND:${stamp}T100000Z\r\nSUMMARY:Lecture\\, 1DI300`),
    ).events[0];
    return { ...event, uid: date };
  });
  events.push({ ...events[1], uid: 'other-course', summary: 'Lecture, 1DI301' });
  for (const range of [
    { mode: 'month', month: '2026-09' },
    { mode: 'module', start: '2026-09-02', end: '2026-09-29' },
  ]) {
    const grid = buildGrid(events, { ...range, course: '1DI300' });
    assert.equal(grid.weeks, 5);
    assert.equal(grid.columns, 5);
    assert.equal(grid.rows[0][0].key, '2026-08-31');
    assert.equal(grid.rows.at(-1).at(-1).key, '2026-10-02');
    assert.deepEqual(
      grid.visible.map((event) => event.uid),
      ['2026-08-31', '2026-09-01', '2026-09-30', '2026-10-02'],
    );
    assert.deepEqual(
      grid.rows.flat().flatMap((day) => day.events.map((event) => event.uid)),
      grid.visible.map((event) => event.uid),
    );
    const weekendGrid = buildGrid(events, { ...range, course: '1DI300', includeWeekends: true });
    assert.equal(weekendGrid.columns, 7);
    assert.deepEqual(
      weekendGrid.visible.map((event) => event.uid),
      ['2026-08-31', '2026-09-01', '2026-09-05', '2026-09-06', '2026-09-30', '2026-10-02'],
    );
  }
});
test('module aligns to five weeks, month can occupy six, and invalid ranges fail', () => {
  assert.equal(
    buildGrid([], { mode: 'module', start: '2026-10-05', end: '2026-11-08', course: '' }).weeks,
    5,
  );
  assert.equal(buildGrid([], { mode: 'month', month: '2026-08', course: '' }).weeks, 6);
  assert.throws(
    () => buildGrid([], { mode: 'module', start: '2026-02-30', end: '2026-03-01', course: '' }),
    /valid/,
  );
});
test('cancellations need no dates, exact duplicates collapse, conflicting duplicates reject', () => {
  const cancelled = parseCalendar(ics('STATUS:CANCELLED'));
  assert.deepEqual(cancelled.events, []);
  assert.deepEqual(cancelled.cancelledUids, ['test@example.com']);
  const event =
    'BEGIN:VEVENT\r\nUID:same\r\nDTSTART:20260908T080000Z\r\nDTEND:20260908T100000Z\r\nEND:VEVENT\r\n';
  assert.equal(
    parseCalendar(`BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${event}${event}END:VCALENDAR`).events.length,
    1,
  );
  assert.throws(
    () =>
      parseCalendar(
        `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${event}${event.replace('080000', '090000')}END:VCALENDAR`,
      ),
    /duplicate/,
  );
  const exception = parseCalendar(ics('RECURRENCE-ID:20260908T080000Z\r\nSTATUS:CANCELLED'));
  assert.equal(exception.cancelledUids.length, 1);
  assert.deepEqual(exception.events, []);
  assert.throws(
    () => parseCalendar(ics('DTSTART:20260908T080000Z').replace('UID:test@example.com\r\n', '')),
    /UID/,
  );
});
test('refresh keeps two months of completed omissions and drops future, cancelled, and older events', () => {
  const event = (uid, start, end, extra = '') =>
    `BEGIN:VEVENT\r\nUID:${uid}\r\nDTSTART:${start}\r\nDTEND:${end}\r\nSUMMARY:${uid}\r\n${extra}END:VEVENT\r\n`;
  const previous = {
    id: 'calendar',
    url: 'https://example.com/calendar.ics',
    kind: 'generic',
    ics: `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${event('old', '20260630T080000Z', '20260630T100000Z')}${event('past', '20260715T080000Z', '20260715T100000Z')}${event('cancelled', '20260810T080000Z', '20260810T100000Z')}${event('future', '20260920T080000Z', '20260920T100000Z')}END:VCALENDAR\r\n`,
  };
  const next = {
    ...previous,
    ics: `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:cancelled\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n`,
  };
  const [reconciled] = reconcileSubscriptions(
    [previous],
    [next],
    '2026-09-10T12:00:00Z',
    'Europe/Stockholm',
  );
  assert.deepEqual(
    reconciled.history.events.map((item) => item.uid),
    ['past'],
  );
  assert.deepEqual(
    parseCalendars([reconciled]).events.map((item) => item.originalUid),
    ['past'],
  );

  const [pruned] = reconcileSubscriptions(
    [reconciled],
    [{ ...reconciled, ics: 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR\r\n' }],
    '2026-10-01T12:00:00Z',
    'Europe/Stockholm',
  );
  assert.equal(pruned.history, undefined);
});
test('spring and autumn transitions keep UTC instants on the correct local date and time', () => {
  assert.deepEqual(localParts('2026-03-29T00:30:00Z', 'Europe/Stockholm'), {
    date: '2026-03-29',
    time: '01:30',
  });
  assert.deepEqual(localParts('2026-03-29T01:30:00Z', 'Europe/Stockholm'), {
    date: '2026-03-29',
    time: '03:30',
  });
  assert.deepEqual(localParts('2026-10-25T00:30:00Z', 'Europe/Stockholm'), {
    date: '2026-10-25',
    time: '02:30',
  });
  assert.deepEqual(localParts('2026-10-25T01:30:00Z', 'Europe/Stockholm'), {
    date: '2026-10-25',
    time: '02:30',
  });
});
test('dense dates disclose overflow and source text cannot become SVG markup', () => {
  const {
    events: [event],
  } = parseCalendar(
    ics('DTSTART:20261005T080000Z\r\nDTEND:20261005T100000Z\r\nSUMMARY:<script>alert(1)</script>'),
  );
  const events = Array.from({ length: 25 }, (_, i) => ({ ...event, uid: String(i) }));
  const result = renderWallpaper(events, {
    mode: 'module',
    start: '2026-10-05',
    end: '2026-11-08',
    name: '<Test>',
    course: '',
    theme: 'light',
  });
  assert.match(result.svg, /&lt;Test&gt;/);
  assert.doesNotMatch(result.svg, /<script>/);
  assert.ok(result.warnings.some((w) => w.includes('do not fit')));
  assert.equal(result.grid.visible.length, 25);
});
test('long unbroken titles are shortened explicitly', () => {
  const { lines, truncated } = wrapText('x'.repeat(200), 100, 14, 3);
  assert.equal(lines.length, 3);
  assert.equal(truncated, true);
  assert.ok(lines.at(-1).endsWith('…'));
});
test('every date includes its month and long titles use free row height', () => {
  const title =
    'A long event title with enough words to continue across several lines when the row has room available';
  const { events } = parseCalendar(
    ics(`DTSTART:20260908T080000Z\r\nDTEND:20260908T100000Z\r\nSUMMARY:${title}`),
  );
  const result = renderWallpaper(events, {
    mode: 'module',
    start: '2026-08-31',
    end: '2026-10-04',
    name: 'Test',
    showTitle: false,
    course: '',
    theme: 'light',
  });
  for (const label of ['31 Aug', '1 Sept', '7 Sept', '30 Sept', '1 Oct', '2 Oct'])
    assert.match(result.svg, new RegExp(`>${label}<`));
  assert.doesNotMatch(result.warnings.join(' '), /full session title/);
  assert.ok(
    result.bounds.some((item) => item.text.includes('available')),
    'the complete event title is rendered',
  );
});

const feed = (...events) => `BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${events.join('')}END:VCALENDAR\r\n`;
const entry = (uid, body) => `BEGIN:VEVENT\r\nUID:${uid}\r\n${body}\r\nEND:VEVENT\r\n`;
const parseFeed = (source, timeZone = 'Europe/Stockholm', options = {}) =>
  parseCalendar(source, timeZone, 'generic', { today: '2026-09-10', ...options });

test('weekly named-zone and floating recurrences keep their local hour across DST', () => {
  for (const suffix of [';TZID=Europe/Stockholm', '']) {
    const { events } = parseFeed(
      feed(
        entry(
          'weekly',
          `DTSTART${suffix}:20261018T090000\r\nDTEND${suffix}:20261018T100000\r\nRRULE:FREQ=WEEKLY;COUNT=3`,
        ),
      ),
    );
    assert.deepEqual(
      events.map((e) => e.start),
      ['2026-10-18T07:00:00.000Z', '2026-10-25T08:00:00.000Z', '2026-11-01T08:00:00.000Z'],
    );
    assert.deepEqual(
      events.map((e) => e.startTime),
      ['09:00', '09:00', '09:00'],
    );
    assert.equal(new Set(events.map((e) => e.uid)).size, 3);
  }
  const source = feed(entry('float', 'DTSTART:20260908T090000'));
  assert.equal(parseFeed(source, 'America/New_York').events[0].start, '2026-09-08T13:00:00.000Z');
});

test('embedded time zones take precedence and do not leak between feeds', () => {
  const event = entry('custom', 'DTSTART;TZID=Europe/Stockholm:20260908T090000');
  const zone =
    'BEGIN:VTIMEZONE\r\nTZID:Europe/Stockholm\r\nBEGIN:STANDARD\r\nDTSTART:19700101T000000\r\nTZOFFSETFROM:+0300\r\nTZOFFSETTO:+0300\r\nEND:STANDARD\r\nEND:VTIMEZONE\r\n';
  assert.equal(parseFeed(feed(zone, event)).events[0].start, '2026-09-08T06:00:00.000Z');
  assert.equal(parseFeed(feed(event)).events[0].start, '2026-09-08T07:00:00.000Z');
  assert.throws(
    () => parseFeed(feed(event.replace('Europe/Stockholm', 'Unknown/Zone'))),
    /Unknown calendar time zone/,
  );
});

test('explicit IANA times use first overlap and pre-gap offset; end duration stays exact', () => {
  for (const [stamp, expected] of [
    ['20261025T023000', '2026-10-25T00:30:00.000Z'],
    ['20260329T023000', '2026-03-29T01:30:00.000Z'],
  ]) {
    assert.equal(
      parseFeed(feed(entry('dst', `DTSTART;TZID=Europe/Stockholm:${stamp}`))).events[0].start,
      expected,
    );
  }
  const { events } = parseFeed(
    feed(
      entry(
        'overnight',
        'DTSTART;TZID=Europe/Stockholm:20261024T230000\r\nDTEND;TZID=Europe/Stockholm:20261025T040000\r\nRRULE:FREQ=WEEKLY;COUNT=2',
      ),
    ),
  );
  assert.deepEqual(
    events.map((e) => (Date.parse(e.end) - Date.parse(e.start)) / 3600000),
    [6, 6],
  );
});

test('monthly rules, all-day recurrence, RDATE, EXDATE and UTC UNTIL expand', () => {
  const monthly = parseFeed(
    feed(entry('monthly', 'DTSTART;VALUE=DATE:20260901\r\nRRULE:FREQ=MONTHLY;COUNT=3;BYDAY=1TU')),
  ).events;
  assert.deepEqual(
    monthly.map((e) => [e.start, e.end]),
    [
      ['2026-09-01', '2026-09-02'],
      ['2026-10-06', '2026-10-07'],
      ['2026-11-03', '2026-11-04'],
    ],
  );
  const { events } = parseFeed(
    feed(
      entry(
        'dates',
        'DTSTART:20260908T080000Z\r\nDURATION:PT1H\r\nRRULE:FREQ=DAILY;UNTIL=20260910T080000Z\r\nRDATE:20260910T080000Z,20260912T080000Z\r\nEXDATE:20260909T080000Z',
      ),
    ),
  );
  assert.deepEqual(
    events.map((e) => e.date),
    ['2026-09-08', '2026-09-10', '2026-09-12'],
  );
  assert.ok(events.every((e) => e.endTime === '11:00'));
});

test('moved and cancelled exceptions share a series UID but have stable occurrence IDs', () => {
  const master = entry(
    'series',
    'DTSTART:20260908T080000Z\r\nDTEND:20260908T090000Z\r\nRRULE:FREQ=WEEKLY;COUNT=3\r\nSUMMARY:Original',
  );
  const moved = entry(
    'series',
    'RECURRENCE-ID:20260915T080000Z\r\nDTSTART:20260916T110000Z\r\nDTEND:20260916T120000Z\r\nSUMMARY:Moved',
  );
  const cancelled = entry('series', 'RECURRENCE-ID:20260922T080000Z\r\nSTATUS:CANCELLED');
  const original = parseFeed(feed(master)).events;
  for (const source of [feed(master, moved, cancelled), feed(cancelled, moved, master)]) {
    const parsed = parseFeed(source);
    assert.deepEqual(
      parsed.events.map((e) => e.date),
      ['2026-09-08', '2026-09-16'],
    );
    assert.equal(parsed.events[1].uid, original[1].uid);
    assert.equal(parsed.events[1].title, 'Moved');
    assert.ok(parsed.cancelledUids.includes(original[2].uid));
  }
  const other = entry('other', 'DTSTART:20260915T080000Z\r\nRRULE:FREQ=WEEKLY;COUNT=1');
  assert.equal(
    parseFeed(feed(master, moved, other)).events.find((e) => e.seriesUid === 'other').date,
    '2026-09-15',
  );
});

test('refresh never revives removed or cancelled occurrences from history', () => {
  const master = entry('series', 'DTSTART:20260901T080000Z\r\nRRULE:FREQ=DAILY;COUNT=3');
  const previous = { id: 'test', url: 'https://example.com/test', ics: feed(master) };
  const old = parseFeed(previous.ics).events;
  const omitted = {
    ...previous,
    history: { version: 1, events: old },
    ics: feed(master.replace('COUNT=3', 'COUNT=1')),
  };
  const [changed] = reconcileSubscriptions([previous], [omitted], '2026-09-10T12:00:00Z');
  assert.equal(changed.history, undefined);
  const [single] = reconcileSubscriptions(
    [previous],
    [{ ...previous, ics: feed(entry('series', 'DTSTART:20260901T080000Z')) }],
    '2026-09-10T12:00:00Z',
  );
  assert.equal(single.history, undefined);
  assert.equal(
    parseCalendars([omitted], 'Europe/Stockholm', { today: '2026-09-10' }).events.length,
    1,
  );
  const cancellation = { ...omitted, ics: feed(entry('series', 'STATUS:CANCELLED')) };
  assert.equal(parseCalendars([cancellation]).events.length, 0);
  const [cancelled] = reconcileSubscriptions([previous], [cancellation], '2026-09-10T12:00:00Z');
  assert.equal(cancelled.history, undefined);
});

test('unbounded recurrence stops at the view window and dense feeds fail explicitly', () => {
  const recurring = feed(entry('forever', 'DTSTART:20260908T080000Z\r\nRRULE:FREQ=WEEKLY'));
  const events = parseFeed(recurring, 'Europe/Stockholm', {
    from: '2030-09-01',
    to: '2030-09-30',
  }).events;
  assert.ok(events.length >= 4 && events.length < 10);
  assert.ok(events.some((e) => e.date.startsWith('2030-09')));
  assert.throws(
    () => parseFeed(recurring.replace('FREQ=WEEKLY', 'FREQ=SECONDLY')),
    /expansion limit/,
  );
  assert.throws(
    () =>
      parseFeed(
        feed(
          entry(
            'range',
            'RECURRENCE-ID;RANGE=THISANDFUTURE:20260908T080000Z\r\nDTSTART:20260908T090000Z',
          ),
        ),
      ),
    /RANGE/,
  );
  assert.throws(
    () =>
      parseFeed(
        feed(
          entry('period', 'DTSTART:20260908T080000Z\r\nRDATE;VALUE=PERIOD:20260909T080000Z/PT1H'),
        ),
      ),
    /periods/,
  );
});

test('RDATE-only sets include DTSTART, and EXDATE can remove DTSTART itself', () => {
  const base = 'DTSTART:20260908T080000Z\r\n';
  assert.deepEqual(
    parseFeed(feed(entry('rdate', base + 'RDATE:20260910T080000Z'))).events.map((e) => e.date),
    ['2026-09-08', '2026-09-10'],
  );
  assert.deepEqual(parseFeed(feed(entry('exdate', base + 'EXDATE:20260908T080000Z'))).events, []);
  assert.deepEqual(
    parseFeed(
      feed(entry('allday', 'DTSTART;VALUE=DATE:20260908\r\nRDATE;VALUE=DATE:20260910')),
    ).events.map((e) => e.start),
    ['2026-09-08', '2026-09-10'],
  );
});

test('disabled calendars hide their events and restore stable IDs when enabled again', () => {
  const source = {
    id: 'optional',
    ics: ics('DTSTART:20260908T080000Z\r\nDTEND:20260908T100000Z\r\nSUMMARY:Optional'),
  };
  const original = parseCalendars([source]).events;
  assert.equal(original.length, 1);
  const disabled = { ...source, enabled: false };
  assert.deepEqual(parseCalendars([disabled]).events, []);
  assert.deepEqual(parseCalendars([{ ...disabled, enabled: true }]).events, original);
  assert.equal(
    parseCalendars([disabled, { ...source, id: 'active' }]).events[0].sourceId,
    'active',
  );
});

test('calendar colors reach event titles in both themes and unknown colors use the default', () => {
  const sources = ['blue', 'purple', '"/><script>', '#336699'].map((color, index) => ({
    id: String(index),
    color,
    ics: ics(`DTSTART:20261005T080000Z\r\nDTEND:20261005T090000Z\r\nSUMMARY:Calendar ${index}`),
  }));
  const { events } = parseCalendars(sources);
  for (const [theme, colors] of [
    ['light', ['#285e9b', '#754398', '#263b35', '#336699']],
    ['dark', ['#9fc7ff', '#d5b0f3', '#e4e9dd', '#336699']],
  ]) {
    const { svg } = renderWallpaper(events, {
      mode: 'month',
      month: '2026-10',
      theme,
      course: '',
    });
    colors.forEach((color, index) => {
      assert.match(svg, new RegExp(`fill="${color}"[^>]*>Calendar ${index}</text>`));
    });
    assert.doesNotMatch(svg, /<script>/);
  }
});

test('wallpaper legend names only included calendars and reserves footer space', () => {
  const sources = ['blue', '#336699', 'red'].map((color, index) => ({
    id: String(index),
    name: `Source ${index} & calendar`,
    color,
    enabled: index !== 2,
    ics: ics('DTSTART:20261005T080000Z\r\nDTEND:20261005T090000Z\r\nSUMMARY:Event'),
  }));
  const { events } = parseCalendars(sources);
  const options = { mode: 'month', month: '2026-10', theme: 'light', course: '' };
  const result = renderWallpaper(events, options);
  assert.match(result.svg, /fill="#285e9b"[^>]*>Source 0 &amp; calendar<\/text>/);
  assert.match(result.svg, /fill="#336699"[^>]*>Source 1 &amp; calendar<\/text>/);
  assert.doesNotMatch(result.svg, /Source 2/);
  const footer = result.bounds.find((item) => item.text === 'Source 0 & calendar');
  assert.ok(result.placements.every((item) => item.bottom < footer.y - footer.size));
  const snapshot = result.bounds.find((item) => item.text === 'Local snapshot');
  assert.equal(footer.y, snapshot.y);
  assert.ok(footer.x > snapshot.x + snapshot.width);
  assert.equal(footer.y, result.logicalHeight - 22);
  const excluded = renderWallpaper(events, { ...options, excludedEventIds: [events[1].uid] });
  assert.doesNotMatch(excluded.svg, /Source 1/);
});

test('native snapshots combine with ICS and preserve all-day dates across time zones', () => {
  const snapshot = {
    version: 1,
    coverageStart: '2026-01-01',
    coverageEnd: '2027-01-01',
    events: [
      {
        uid: 'holiday',
        start: '2026-10-30',
        end: '2026-11-03',
        allDay: true,
        title: 'Holiday',
        summary: 'Holiday',
        description: '',
        location: '',
      },
      {
        uid: 'meeting',
        start: '2026-10-26T08:00:00Z',
        end: '2026-10-26T09:00:00Z',
        allDay: false,
        title: 'Meeting',
        summary: 'Meeting',
        description: '',
        location: 'Office',
      },
    ],
  };
  const local = { id: 'local', provider: 'eventkit', name: 'Personal', snapshot };
  const subscriptions = [
    local,
    {
      id: 'feed',
      ics: ics('DTSTART:20261026T080000Z\r\nDTEND:20261026T090000Z\r\nSUMMARY:Lecture'),
    },
  ];
  const { events } = parseCalendars(subscriptions, 'Europe/Stockholm');
  assert.equal(events.length, 3);
  const holiday = events.find((e) => e.originalUid === 'holiday');
  assert.equal(holiday.date, '2026-10-30');
  assert.equal(holiday.endDate, '2026-11-03');
  assert.equal(events.find((e) => e.originalUid === 'meeting').startTime, '09:00');
  assert.equal(
    parseCalendars([local], 'America/Los_Angeles').events.find((e) => e.originalUid === 'holiday')
      .date,
    holiday.date,
  );
  assert.equal(parseCalendars([{ ...local, enabled: false }, subscriptions[1]]).events.length, 1);
  const replaced = reconcileSubscriptions(
    [local],
    [{ ...local, snapshot: { ...snapshot, events: [] } }],
    '2026-12-01T00:00:00Z',
  );
  assert.equal(
    parseCalendars(replaced).events.length,
    0,
    'deleted past events must not become retained history',
  );
  for (const event of [
    { ...snapshot.events[0], start: '2026-02-30' },
    { ...snapshot.events[0], end: '2026-01-01' },
    { ...snapshot.events[0], allDay: 'yes' },
  ]) {
    assert.throws(() => parseCalendars([{ ...local, snapshot: { ...snapshot, events: [event] } }]));
  }
  assert.throws(() =>
    parseCalendars([
      { ...local, snapshot: { ...snapshot, events: [snapshot.events[0], snapshot.events[0]] } },
    ]),
  );
});

test('hidden weekends show today beside the correct week without marking Friday as today', () => {
  const options = {
    mode: 'month',
    month: '2026-09',
    course: '',
    width: 1280,
    height: 720,
  };
  for (const theme of ['light', 'dark']) {
    for (const [today, label] of [
      ['2026-09-12', 'TODAY → Sat 12 Sept'],
      ['2026-09-13', 'TODAY → Sun 13 Sept'],
    ]) {
      const result = renderWallpaper([], { ...options, today, theme });
      const badge = result.bounds.find((item) => item.text === label);
      assert.ok(badge);
      const friday = result.bounds.find((item) => item.text === '11 Sept');
      assert.equal(badge.y, friday.y);
      assert.ok(badge.x - badge.width > friday.x + friday.width);
      assert.equal(result.bounds.filter((item) => item.text.startsWith('TODAY')).length, 1);
      assert.match(result.svg, /Today is off-screen because weekends are hidden/);
      const visible = renderWallpaper([], { ...options, today, theme, includeWeekends: true });
      assert.equal(visible.bounds.filter((item) => item.text === 'TODAY').length, 1);
      assert.ok(!visible.svg.includes('TODAY →'));
    }
  }
  for (const today of ['2026-09-11', '2026-10-10', undefined]) {
    assert.ok(!renderWallpaper([], { ...options, today }).svg.includes('TODAY →'));
  }
});
