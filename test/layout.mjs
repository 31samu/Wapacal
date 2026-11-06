import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import sharp from 'sharp';
import { renderWallpaper, selectEvents, palettes, colorThemes } from '../src/layout.mjs';
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

test('boxes lighten or darken calendar colors and use the requested theme text colors', async () => {
  const { data, config } = await loadFixtureApp();
  for (const theme of ['light', 'dark']) {
    for (const colorTheme of [...Object.keys(colorThemes), 'custom']) {
      for (const color of ['#ffffff', '#000000', '#123abc']) {
        const events = data.events.map((event) => ({ ...event, sourceColor: color }));
        const options = { ...config, ...config.module, mode: 'module', theme, colorTheme };
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
          if (colorTheme === 'custom') {
            assert.equal(text.getAttribute('fill'), colorThemes.neutral[theme].text);
            continue;
          }
          if (theme === 'light') {
            assert.equal(text.getAttribute('fill'), colorThemes[colorTheme].dark.text);
            continue;
          }
          assert.ok(textContrast(text.getAttribute('fill'), fill) >= 4.5);
        }
      }
    }
  }
});

test('custom grid stays readable while event boxes preserve the selected text color', async () => {
  const { data, config } = await loadFixtureApp();
  const customColors = {
    light: { bg: '#f6f1e7', text: '#dfedd2', accent: '#f6f1e7' },
    dark: { bg: '#202020', text: '#222222', accent: '#202020' },
  };
  const saved = structuredClone(customColors);
  for (const theme of ['light', 'dark']) {
    for (const eventStyle of ['text', 'boxes']) {
      const { svg } = renderWallpaper(data.events, {
        ...config,
        ...config.module,
        mode: 'module',
        theme,
        eventStyle,
        colorTheme: 'custom',
        customColors,
        today: data.events[0].date,
      });
      const dom = new JSDOM(svg, { contentType: 'image/svg+xml' });
      for (const line of dom.window.document.querySelectorAll('path')) {
        assert.ok(textContrast(line.getAttribute('stroke'), customColors[theme].bg) >= 1.5);
      }
      const backgrounds = [];
      for (const element of dom.window.document.querySelectorAll('rect, text')) {
        const n = (key) => Number(element.getAttribute(key));
        if (element.tagName === 'rect') {
          backgrounds.push(element);
          continue;
        }
        const background = backgrounds.findLast((rect) => {
          const x = Number(rect.getAttribute('x')),
            y = Number(rect.getAttribute('y'));
          return (
            n('x') >= x &&
            n('x') <= x + Number(rect.getAttribute('width')) &&
            n('y') >= y &&
            n('y') <= y + Number(rect.getAttribute('height'))
          );
        });
        if (eventStyle === 'boxes' && background.getAttribute('fill') !== customColors[theme].bg) {
          assert.equal(element.getAttribute('fill'), customColors[theme].text);
          continue;
        }
        assert.ok(
          textContrast(element.getAttribute('fill'), background.getAttribute('fill')) >= 4.5,
          `${theme} ${eventStyle}: ${element.textContent}`,
        );
      }
      dom.window.close();
    }
  }
  assert.deepEqual(customColors, saved);
});

test('snapshot, legend, and event times can be hidden independently', async () => {
  const { data, config } = await loadFixtureApp();
  const events = data.events.map((event) => ({
    ...event,
    sourceId: 'fixture',
    sourceName: 'Fixture legend',
  }));
  const options = { ...config, ...config.module, mode: 'module', snapshotDate: '2026-09-01' };
  const render = (patch) => renderWallpaper(events, { ...options, ...patch });
  const texts = (result) => result.bounds.map((item) => item.text);
  const normal = render({});
  assert.ok(texts(normal).includes('Snapshot 2026-09-01'));
  assert.ok(texts(normal).includes('Fixture legend'));
  const noSnapshot = render({ showSnapshotDate: false });
  assert.ok(!texts(noSnapshot).includes('Snapshot 2026-09-01'));
  assert.equal(noSnapshot.bounds.find((item) => item.text === 'Fixture legend').x, 76);
  const noLegend = render({ showCalendarLegend: false });
  assert.ok(!texts(noLegend).includes('Fixture legend'));
  assert.ok(texts(noLegend).includes('Snapshot 2026-09-01'));
  const times = texts(normal).filter((text) => /^\d{2}:\d{2}/.test(text));
  assert.ok(times.length > 0);
  for (const eventStyle of ['text', 'boxes']) {
    for (const rooms of [true, false]) {
      const hidden = render({ showEventTimes: false, eventStyle, rooms });
      assert.ok(times.every((time) => !texts(hidden).includes(time)));
      assert.equal(hidden.grid.visible.length, normal.grid.visible.length);
      assert.ok(hidden.bounds.every((item) => Number.isFinite(item.x) && Number.isFinite(item.y)));
      if (!rooms) {
        const shown = render({ eventStyle, rooms });
        assert.ok(hidden.placements[0].bottom < shown.placements[0].bottom);
      }
    }
  }
});

test('event titles keep their top inset when times and locations are hidden', async () => {
  const { data, config } = await loadFixtureApp();
  for (const eventTextScale of [0.75, 1, 1.5]) {
    const result = renderWallpaper(data.events, {
      ...config,
      ...config.module,
      mode: 'module',
      eventStyle: 'boxes',
      showEventTimes: false,
      rooms: false,
      eventTextScale,
    });
    const dom = new JSDOM(result.svg, { contentType: 'image/svg+xml' });
    const boxes = [...dom.window.document.querySelectorAll('rect[rx="5"]')];
    let checked = 0;
    for (const box of boxes) {
      let title = box.nextElementSibling;
      if (title?.tagName === 'rect') title = title.nextElementSibling;
      if (
        title?.tagName !== 'text' ||
        Number(title.getAttribute('font-size')) !== 14 * eventTextScale
      )
        continue;
      const inset =
        Number(title.getAttribute('y')) -
        Number(title.getAttribute('font-size')) -
        Number(box.getAttribute('y'));
      assert.ok(Math.abs(inset - 2) < 0.001, `Title top inset is ${inset}`);
      checked++;
    }
    assert.ok(checked > 0);
    dom.window.close();
  }
});
function textContrast(a, b) {
  const luminance = (color) => {
    const channels = color
      .slice(1)
      .match(/../g)
      .map((hex) => {
        const value = parseInt(hex, 16) / 255;
        return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
      });
    return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
  };
  const values = [luminance(a), luminance(b)];
  return (Math.max(...values) + 0.05) / (Math.min(...values) + 0.05);
}
