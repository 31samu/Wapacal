import { readFile } from 'node:fs/promises';
import { loadSnapshots } from '../src/subscriptions.mjs';

// Public builds never read local settings or snapshots.
export async function loadNativeBuildData({ privateSeed = false } = {}) {
  if (!privateSeed) {
    const example = JSON.parse(await readFile('config.example.json', 'utf8'));
    const config = {
      timeZone: example.timeZone,
      width: example.width,
      height: example.height,
      module: { name: 'New module', start: example.module.start, end: example.module.end },
      course: '',
      allCalendars: true,
    };
    return { config, seed: { subscriptions: [], courseCode: '', editor: { mode: 'month' } } };
  }

  const config = JSON.parse(
    await readFile('config.local.json', 'utf8').catch((error) => {
      if (error.code !== 'ENOENT') throw error;
      return readFile('config.example.json', 'utf8');
    }),
  );
  return {
    config,
    seed: { subscriptions: await loadSnapshots(config), courseCode: config.course },
  };
}
