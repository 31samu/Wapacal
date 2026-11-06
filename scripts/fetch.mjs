import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { parseCalendars, reconcileSubscriptions } from '../src/calendar.mjs';
import {
  configuredSubscriptions,
  loadSnapshots,
  readCalendarResponse,
} from '../src/subscriptions.mjs';
await mkdir('data', { recursive: true });
const config = JSON.parse(
  await readFile('config.local.json', 'utf8').catch(() => readFile('config.example.json', 'utf8')),
);
const configured = configuredSubscriptions(config);
if (!configured.length) throw new Error('Add subscriptions to config.local.json.');
const sources = await loadSnapshots(config).catch((error) => {
  if (error.code === 'ENOENT') return configured;
  throw error;
});
let failed = 0;
for (let index = 0; index < sources.length; index++) {
  const source = sources[index];
  if (source.enabled === false) continue;
  try {
    const headers = {};
    if (source.ics && source.etag) headers['If-None-Match'] = source.etag;
    if (source.ics && source.modified) headers['If-Modified-Since'] = source.modified;
    const response = await fetch(source.url, { headers, signal: AbortSignal.timeout(30000) });
    if (response.status === 304 && source.ics) continue;
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const ics = await readCalendarResponse(response);
    const fetchedAt = new Date().toISOString();
    const candidate = {
      ...source,
      ics,
      fetchedAt,
      etag: response.headers.get('etag'),
      modified: response.headers.get('last-modified'),
    };
    const [reconciled] = reconcileSubscriptions([source], [candidate], fetchedAt, config.timeZone);
    const next = sources.with(index, reconciled);
    parseCalendars(next, config.timeZone);
    sources[index] = reconciled;
    console.log(`${source.name}: refreshed.`);
  } catch {
    failed++;
    console.error(`${source.name}: refresh failed; previous snapshot retained.`);
  }
}
await writeFile('data/calendars.json.tmp', JSON.stringify({ subscriptions: sources }, null, 2));
await rename('data/calendars.json.tmp', 'data/calendars.json');
console.log(
  `Saved ${parseCalendars(sources, config.timeZone).events.length} events from ${sources.length} subscriptions. Run npm run build:native:private to embed them in the app.`,
);
if (failed) process.exitCode = 1;
