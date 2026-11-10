import { readFile } from 'node:fs/promises';
import { parseCalendar, localParts } from '../../src/calendar.mjs';

const fixtureRoot = 'test/fixtures';
const scriptJson = (value) =>
  JSON.stringify(value)
    .replace(/</g, '\\u003c')
    .replace(/\u2028/g, '\\u2028')
    .replace(/\u2029/g, '\\u2029');

let fixturePromise;

export function loadFixtureApp() {
  fixturePromise ??= (async () => {
    const [config, ics, metadata, layout, suggestions, nativeEditor, engine] = await Promise.all([
      readFile(`${fixtureRoot}/config.json`, 'utf8').then(JSON.parse),
      readFile(`${fixtureRoot}/calendar.ics`, 'utf8'),
      readFile(`${fixtureRoot}/source.json`, 'utf8').then(JSON.parse),
      readFile('src/layout.mjs', 'utf8').then((value) => value.replace(/^export /gm, '')),
      readFile('src/suggestions.mjs', 'utf8').then((value) => value.replace(/^export /gm, '')),
      readFile('src/native-editor.js', 'utf8'),
      readFile('node_modules/ical.js/dist/ical.es5.min.cjs', 'utf8'),
    ]);
    const parsed = parseCalendar(ics, config.timeZone);
    const today = '2026-09-08';
    const snapshotDate = localParts(metadata.fetchedAt, config.timeZone).date;
    const data = { ...parsed, today, snapshotDate };
    const parser = (await readFile('src/calendar.mjs', 'utf8'))
      .replace(/^import .*$/gm, '')
      .replace(/^export /gm, '');

    const editor = `<!doctype html><html><body><script>${engine}\n${parser}\n${layout}\n${suggestions}\nconst config=${scriptJson(config)};\n${nativeEditor}</script></body></html>`;
    const seed = {
      courseCode: config.course,
      subscriptions: [{ id: 'legacy', legacyIds: true, ics, fetchedAt: metadata.fetchedAt }],
    };
    return { config, data, editor, ics, seed };
  })();
  return fixturePromise;
}
