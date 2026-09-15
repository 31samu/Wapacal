import { readFile, writeFile, mkdir } from 'node:fs/promises';
import sharp from 'sharp';
import { parseCalendars, localParts } from '../src/calendar.mjs';
import { loadSnapshots } from '../src/subscriptions.mjs';
import { renderWallpaper, selectEvents } from '../src/layout.mjs';

const config = JSON.parse(
  await readFile('config.local.json', 'utf8').catch(() => readFile('config.example.json', 'utf8')),
);
const subscriptions = await loadSnapshots(config);
const parsed = parseCalendars(subscriptions, config.timeZone, {
  ...config.module,
  today: process.env.WAPACAL_TODAY,
});
const metadata = {
  fetchedAt: subscriptions
    .map((source) => source.fetchedAt)
    .filter(Boolean)
    .sort()[0],
};
const today = process.env.WAPACAL_TODAY || localParts(new Date(), config.timeZone).date;
const snapshotDate = metadata.fetchedAt
  ? localParts(metadata.fetchedAt, config.timeZone).date
  : 'unknown';
const defaultCourse = config.allCalendars ? '' : config.course;
const shared = {
  ...config,
  ...config.module,
  course: defaultCourse,
  today,
  snapshotDate,
  rooms: true,
};
await mkdir('output', { recursive: true });
const reports = [];
for (const mode of ['month', 'module'])
  for (const theme of ['light', 'dark']) {
    const options = { ...shared, mode, theme, month: today.slice(0, 7) };
    const result = renderWallpaper(parsed.events, options);
    const name =
      mode === 'month'
        ? `month-${today.slice(0, 7)}-${theme}`
        : `module-${config.module.start}-${theme}`;
    await writeFile(`output/${name}.svg`, result.svg);
    await sharp(Buffer.from(result.svg)).png().toFile(`output/${name}.png`);
    reports.push({
      name,
      width: config.width,
      height: config.height,
      eventCount: result.grid.visible.length,
      weeks: result.grid.weeks,
      warnings: result.warnings,
    });
  }
// Embed only trusted layout code. Calendar data is JSON-escaped before entering
// the script element; the renderer separately escapes every SVG text value.
const scriptJson = (value) =>
  JSON.stringify(value)
    .replace(/</g, '\\u003c')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');
const layout = (await readFile('src/layout.mjs', 'utf8')).replace(/^export /gm, '');
const suggestions = (await readFile('src/suggestions.mjs', 'utf8')).replace(/^export /gm, '');
const parser = (await readFile('src/calendar.mjs', 'utf8'))
  .replace(/^import .*$/gm, '')
  .replace(/^export /gm, '');
const engine = await readFile('node_modules/ical.js/dist/ical.es5.min.cjs', 'utf8');
const data = {
  ...parsed,
  today,
  snapshotDate,
  subscriptions: subscriptions.map(({ id, name, kind, legacyIds, enabled, ics, history }) => ({
    id,
    name,
    kind,
    legacyIds,
    enabled,
    ics,
    history,
  })),
};
const { subscriptionUrl, subscriptions: privateSubscriptions, ...previewConfig } = config;
const template = await readFile('src/preview.html', 'utf8');
const html = template
  .replace('/*__PARSER__*/', () => engine + '\n' + parser)
  .replace('/*__LAYOUT__*/', () => layout + '\n' + suggestions)
  .replace('__WAPACAL_DATA__', () => scriptJson(data))
  .replace('__WAPACAL_CONFIG__', () => scriptJson(previewConfig));
await writeFile('output/preview.html', html);
await writeFile('output/events.json', JSON.stringify(data, null, 2));
await writeFile(
  'output/validation.json',
  JSON.stringify(
    {
      generatedAt: new Date().toISOString(),
      totalEvents: parsed.events.length,
      courseEvents: selectEvents(parsed.events, config.course).length,
      reports,
    },
    null,
    2,
  ),
);
await writeFile(
  'output/module-appearance.json',
  JSON.stringify(
    [
      { fileName: `module-${config.module.start}-light.png`, isPrimary: true, isForLight: true },
      { fileName: `module-${config.module.start}-dark.png`, isForDark: true },
    ],
    null,
    2,
  ),
);
console.log(
  JSON.stringify(
    {
      totalEvents: parsed.events.length,
      courseEvents: selectEvents(parsed.events, config.course).length,
      reports,
      preview: 'output/preview.html',
    },
    null,
    2,
  ),
);
