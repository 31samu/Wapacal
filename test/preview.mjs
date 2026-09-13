import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM, VirtualConsole } from 'jsdom';
import sharp from 'sharp';
import { renderWallpaper, selectEvents, palettes } from '../src/layout.mjs';
import { loadFixtureApp } from './helpers/fixture-app.mjs';

test('sanitized fixture fits the initial module in both appearances', async () => {
  const { data, config } = await loadFixtureApp();
  assert.equal(data.events.length, 12);
  assert.equal(selectEvents(data.events, '1AB101').length, 9);
  const system = renderWallpaper(data.events, {
    ...config,
    ...config.module,
    mode: 'module',
    theme: 'system',
    systemTheme: 'dark',
  });
  const dark = renderWallpaper(data.events, {
    ...config,
    ...config.module,
    mode: 'module',
    theme: 'dark',
  });
  assert.equal(system.svg, dark.svg);
  for (const mode of ['month', 'module'])
    for (const theme of ['light', 'dark']) {
      const options = { ...config, ...config.module, mode, theme, month: '2026-09' };
      const result = renderWallpaper(data.events, options);
      assert.equal(result.grid.visible.length, mode === 'month' ? 5 : 4);
      assert.equal(result.grid.weeks, 5);
      assert.equal(result.grid.columns, 5);
      assert.deepEqual(
        result.warnings,
        [],
        `${mode} ${theme} should fit every source title and event`,
      );
      for (const bound of result.bounds) {
        const left = bound.anchor === 'end' ? bound.x - bound.width : bound.x;
        assert.ok(
          left >= 0 && left + bound.width <= result.logicalWidth,
          `Horizontal text overflow: ${bound.text}`,
        );
        assert.ok(bound.y <= result.logicalHeight, `Vertical text overflow: ${bound.text}`);
      }
    }
  const wallpaper = renderWallpaper(data.events, {
    ...config,
    ...config.module,
    mode: 'module',
    theme: 'light',
    snapshotDate: data.snapshotDate,
  });
  assert.match(wallpaper.svg, new RegExp(`>Snapshot ${data.snapshotDate}</text>`));
  assert.doesNotMatch(wallpaper.svg, /TimeEdit ·/);
  assert.match(wallpaper.svg, /x="76" y="92"[^>]*>Prototype module<\/text>/);
  const noTitle = renderWallpaper(data.events, {
    ...config,
    ...config.module,
    mode: 'module',
    theme: 'light',
    showTitle: false,
  });
  assert.doesNotMatch(noTitle.svg, />Prototype module<\/text>/);
  assert.match(noTitle.svg, /d="M76 92H/);
  const metadata = await sharp(
    Buffer.from(
      renderWallpaper(data.events, { ...config, ...config.module, mode: 'module', theme: 'light' })
        .svg,
    ),
  ).metadata();
  assert.equal(metadata.width, 3024);
  assert.equal(metadata.height, 1964);
});

test('preview switches theme, edits module dates, changes month, reveals details and blocks invalid exports', async () => {
  const { preview: html } = await loadFixtureApp();
  const errors = [];
  const vc = new VirtualConsole();
  vc.on('jsdomError', (error) => errors.push(error));
  const dom = new JSDOM(html, { runScripts: 'dangerously', virtualConsole: vc });
  const { document, Event } = dom.window;
  const el = (id) => document.getElementById(id);
  const change = (id, value, type = 'input') => {
    el(id).value = value;
    el(id).dispatchEvent(new Event(type, { bubbles: true }));
  };
  assert.equal(errors.length, 0);
  assert.equal(document.querySelectorAll('.event').length, 4);
  assert.equal(
    document.querySelector('aside').lastElementChild.classList.contains('export-actions'),
    true,
  );
  assert.equal(el('weekends').checked, false);
  assert.equal(el('theme').value, 'system');
  assert.match(el('wallpaper').innerHTML, /Prototyping/);
  change('theme', 'dark');
  assert.match(el('wallpaper').innerHTML, /#18231f/);
  change('module-name', 'My module');
  assert.match(el('wallpaper').innerHTML, /My module/);
  el('show-title').checked = false;
  el('show-title').dispatchEvent(new Event('change', { bubbles: true }));
  assert.doesNotMatch(el('wallpaper').innerHTML, />My module<\/text>/);
  change('start', '2026-10-12');
  assert.equal(document.querySelectorAll('.event').length, 3);
  change('mode', 'month');
  change('month', '2026-09');
  assert.equal(document.querySelectorAll('.event').length, 5);
  assert.match(el('wallpaper').innerHTML, /September 2026/);
  assert.doesNotMatch(el('wallpaper').innerHTML, /SATURDAY|SUNDAY/);
  el('weekends').checked = true;
  el('weekends').dispatchEvent(new Event('change', { bubbles: true }));
  assert.match(el('wallpaper').innerHTML, /SATURDAY.*SUNDAY/s);
  assert.match(el('event-list').textContent, /R100/);
  assert.ok(document.querySelector('.conflict'));
  change('course', 'all', 'change');
  assert.equal(document.querySelectorAll('.event').length, 7);
  change('mode', 'module');
  change('end', '2026-01-01');
  assert.ok(el('export-png').disabled);
  assert.match(el('error').textContent, /valid/);
  dom.window.close();
});

test('September all-events export fits every fixture event without overlaps in both appearances', async () => {
  const { data } = await loadFixtureApp();
  for (const theme of ['light', 'dark']) {
    const result = renderWallpaper(data.events, {
      mode: 'module',
      name: 'September overview',
      start: '2026-08-31',
      end: '2026-09-30',
      course: '',
      theme,
      width: 3024,
      height: 1964,
    });
    assert.equal(result.grid.visible.length, 7);
    assert.equal(result.placements.length, 7);
    assert.equal(new Set(result.placements.map((p) => p.uid)).size, 7);
    assert.ok(!result.warnings.some((warning) => warning.includes('not fit')));
    for (const placement of result.placements) {
      assert.ok(placement.top >= placement.rowTop);
      assert.ok(
        placement.bottom <= placement.rowBottom,
        `Event crossed its row on ${placement.date}`,
      );
    }
    for (const date of new Set(result.placements.map((p) => p.date))) {
      const day = result.placements.filter((p) => p.date === date);
      for (let i = 1; i < day.length; i++)
        assert.ok(day[i].top > day[i - 1].bottom, `Events overlap on ${date}`);
    }
  }
});

test('event exclusions remain reversible, persist on reload and affect exports', async () => {
  const { preview: html } = await loadFixtureApp();
  const create = (saved) =>
    new JSDOM(html, {
      url: 'https://wapacal.example/preview',
      runScripts: 'dangerously',
      beforeParse(window) {
        if (saved) for (const [key, value] of saved) window.localStorage.setItem(key, value);
      },
    });
  const dom = create();
  const { document, Event } = dom.window;
  const findFinal = () =>
    [...document.querySelectorAll('#event-list input')].find((input) =>
      input.getAttribute('aria-label').includes('Launch presentation'),
    );
  const input = findFinal();
  const uid = input.dataset.eventId;
  input.checked = false;
  input.dispatchEvent(new Event('change'));
  assert.equal(findFinal().checked, false);
  assert.equal(document.querySelectorAll('.event').length, 4);
  assert.match(document.getElementById('detail-count').textContent, /3 included · 1 excluded/);
  assert.doesNotMatch(document.getElementById('wallpaper').innerHTML, /Launch presentation/);
  document.getElementById('theme').value = 'dark';
  document.getElementById('theme').dispatchEvent(new Event('input'));
  assert.equal(findFinal().checked, false);
  assert.equal(document.getElementById('export-svg'), null);
  assert.equal(document.getElementById('export-heic').textContent, 'Export HEIC');
  const saved = Object.entries(dom.window.localStorage);
  const reload = create(saved);
  const check = [...reload.window.document.querySelectorAll('#event-list input')].find(
    (input) => input.dataset.eventId === uid,
  );
  assert.equal(check.checked, false);
  check.checked = true;
  check.dispatchEvent(new reload.window.Event('change'));
  assert.match(reload.window.document.getElementById('wallpaper').innerHTML, /Launch presentation/);
  assert.match(
    reload.window.document.getElementById('detail-count').textContent,
    /4 included · 0 excluded/,
  );
  dom.window.close();
  reload.window.close();
});

test('Mac export freezes both appearances and event exclusions while rendering', async () => {
  const { preview: html } = await loadFixtureApp();
  const dom = new JSDOM(html, { runScripts: 'dangerously' });
  const { document, Event } = dom.window;
  const input = [...document.querySelectorAll('#event-list input')].find((input) =>
    input.getAttribute('aria-label').includes('Launch presentation'),
  );
  input.checked = false;
  input.dispatchEvent(new Event('change'));
  const frames = [];
  let finish;
  const downloaded = new Promise((resolve) => (finish = resolve));
  dom.window.pngBlob = async (svg) => {
    frames.push(svg);
    return new dom.window.Blob(['test PNG bytes']);
  };
  dom.window.download = (blob, extension) => finish({ blob, extension });
  document.getElementById('export-heic').click();
  input.checked = true;
  input.dispatchEvent(new Event('change'));
  const { blob, extension } = await downloaded;
  const payload = JSON.parse(
    await new Promise((resolve) => {
      const reader = new dom.window.FileReader();
      reader.onload = () => resolve(reader.result);
      reader.readAsText(blob);
    }),
  );
  assert.equal(extension, 'wapacal');
  assert.equal(payload.version, 1);
  assert.equal(Buffer.from(payload.light, 'base64').toString(), 'test PNG bytes');
  assert.equal(payload.light, payload.dark);
  assert.equal(frames.length, 2);
  assert.match(frames[0], /#f0efe9/);
  assert.match(frames[1], /#18231f/);
  for (const svg of frames) assert.doesNotMatch(svg, /Launch presentation/);
  dom.window.close();
});

test('browser preview expands subscriptions when navigating to a distant month', async () => {
  const { preview } = await loadFixtureApp();
  const dom = new JSDOM(preview, { runScripts: 'dangerously', url: 'https://preview.invalid' });
  const ics =
    'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:weekly\r\nDTSTART:20260908T080000Z\r\nRRULE:FREQ=WEEKLY\r\nSUMMARY:Repeating\r\nEND:VEVENT\r\nEND:VCALENDAR';
  dom.window.eval(
    `data.subscriptions = ${JSON.stringify([{ id: 'test', ics }])}; state.mode = 'month'; state.month = '2035-09'; state.course = ''; render();`,
  );
  assert.equal(dom.window.document.getElementById('error').textContent, '');
  assert.match(dom.window.document.getElementById('wallpaper').innerHTML, /Repeating/);
  assert.ok(dom.window.eval("data.events.some(event => event.date.startsWith('2035-09'))"));
  dom.window.close();
});

test('boxes lighten or darken calendar colors and use the requested theme text colors', async () => {
  const { data, config } = await loadFixtureApp();
  for (const theme of ['light', 'dark']) {
    for (const color of ['#ffffff', '#000000', '#123abc']) {
      const events = data.events.map((event) => ({ ...event, sourceColor: color }));
      const options = { ...config, ...config.module, mode: 'module', theme };
      const plain = renderWallpaper(events, options);
      const boxed = renderWallpaper(events, { ...options, eventStyle: 'boxes' });
      assert.deepEqual(
        boxed.placements.map(({ uid, date }) => ({ uid, date })),
        plain.placements.map(({ uid, date }) => ({ uid, date })),
      );
      assert.deepEqual(boxed.warnings, plain.warnings);
      const doc = new JSDOM(boxed.svg, { contentType: 'image/svg+xml' }).window.document;
      const boxes = [...doc.querySelectorAll('rect')].filter(
        (rect) =>
          rect.getAttribute('rx') === '5' && rect.getAttribute('fill') !== palettes[theme].tint,
      );
      assert.equal(boxes.length, boxed.placements.length);
      for (const box of boxes) {
        const fill = box.getAttribute('fill');
        for (const offset of [1, 3, 5]) {
          const original = parseInt(color.slice(offset, offset + 2), 16);
          const neutral = theme === 'dark' ? 0 : 255;
          const softened = parseInt(fill.slice(offset, offset + 2), 16);
          assert.equal(softened, Math.round(original * 0.7 + neutral * 0.3));
        }
        const next = box.nextElementSibling;
        const text = next.tagName === 'text' ? next : next.nextElementSibling;
        if (theme === 'light') {
          assert.equal(text.getAttribute('fill'), palettes.dark.text);
          continue;
        }
        const channels = fill
          .slice(1)
          .match(/../g)
          .map((hex) => {
            const value = parseInt(hex, 16) / 255;
            return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
          });
        const luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
        const contrast =
          text.getAttribute('fill') === '#000000'
            ? (luminance + 0.05) / 0.05
            : 1.05 / (luminance + 0.05);
        assert.ok(contrast >= 4.5, 'Dark-theme box text remains readable on custom colors');
      }
    }
  }
});
