import { readFile } from 'node:fs/promises';

export async function readCalendarResponse(response, limit = 10_000_000) {
  const declaredLength = Number(response.headers.get('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > limit)
    throw new Error('Calendar exceeds 10 MB');
  if (!response.body) return '';

  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > limit) {
        await reader.cancel();
        throw new Error('Calendar exceeds 10 MB');
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    throw new Error('Calendar is not valid UTF-8');
  }
}

export function configuredSubscriptions(config) {
  const sources = config.subscriptions ?? [];
  const ids = new Set(),
    urls = new Set();
  return sources.map((source) => {
    const url = new URL(source.url);
    if (url.protocol !== 'https:') throw new Error('Calendar subscriptions must use HTTPS.');
    if (!source.id || ids.has(source.id) || urls.has(url.href))
      throw new Error('Subscriptions need unique IDs and URLs.');
    ids.add(source.id);
    urls.add(url.href);
    return {
      ...source,
      url: url.href,
      name: source.name || url.hostname,
      kind:
        source.kind ||
        (url.hostname.endsWith('.timeedit.net') || url.hostname === 'timeedit.net'
          ? 'timeedit'
          : 'generic'),
    };
  });
}

export async function loadSnapshots(config) {
  const sources = configuredSubscriptions(config);
  const cache = JSON.parse(
    await readFile('data/calendars.json', 'utf8').catch((error) => {
      if (error.code !== 'ENOENT') throw error;
      return 'null';
    }),
  );
  if (!cache) return sources;
  return sources.map((source) => ({
    ...source,
    ...cache.subscriptions.find((saved) => saved.id === source.id && saved.url === source.url),
    ...source,
  }));
}
