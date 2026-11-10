// Internal worker API. No interface, DOM event handlers, storage, or network access.
// AppKit owns presentation and persistence.
const nativeDefaults = (() => {
  const today = localParts(new Date(), config.timeZone).date;
  return {
    mode: 'module',
    theme: 'system',
    colorTheme: 'forest',
    calendarColors: true,
    eventStyle: 'text',
    eventTextScale: 1,
    paddingLeft: 76,
    paddingRight: 76,
    paddingTop: 24,
    paddingBottom: 22,
    month: today.slice(0, 7),
    ...config.module,
    course: config.allCalendars ? '' : config.course,
    timeZone: config.timeZone,
    width: config.width,
    height: config.height,
    showTitle: false,
    rooms: true,
    showTimeZone: true,
    showSnapshotDate: true,
    showCalendarLegend: true,
    showEventTimes: true,
    showWeekNumbers: true,
    highlightToday: true,
    includeWeekends: config.includeWeekends === true,
    today,
    snapshotDate: 'none',
    excludedEventIds: Array.isArray(config.excludedEventIds)
      ? config.excludedEventIds.filter((id) => typeof id === 'string')
      : [],
  };
})();
let nativeAppearance;
window.nativeAppearance = function (theme) {
  if (!['light', 'dark'].includes(theme)) throw new Error('Invalid system appearance.');
  nativeAppearance = theme;
};
function preferredTheme() {
  if (nativeAppearance) return nativeAppearance;
  return typeof matchMedia === 'function' && matchMedia('(prefers-color-scheme: dark)').matches
    ? 'dark'
    : 'light';
}
function renderOptions(options) {
  return { ...options, systemTheme: preferredTheme() };
}
let state = { ...nativeDefaults };
let data = { name: 'Calendar', events: [] };
let calendarSources = [];
let courseCode = config.course || '';
let revision = 0;
function advancedDay(previous) {
  const today = localParts(new Date(), previous.timeZone).date;
  return {
    ...previous,
    today,
    month:
      previous.mode === 'month' && previous.month === previous.today.slice(0, 7)
        ? today.slice(0, 7)
        : previous.month,
  };
}
function commit(nextData, next) {
  // All replacements are transactional, including invalid date ranges and dimensions.
  renderWallpaper(nextData.events, renderOptions(next));
  data = nextData;
  state = next;
  revision++;
  return true;
}
window.nativeLoad = function (payload) {
  const next = advancedDay({ ...nativeDefaults, ...payload.editor });
  next.includeWeekends = next.includeWeekends === true;
  next.excludedEventIds = Array.isArray(next.excludedEventIds)
    ? next.excludedEventIds.filter((id) => typeof id === 'string')
    : [];
  const subscriptions = payload.subscriptions || [];
  const parsed = parseCalendars(subscriptions, next.timeZone, next);
  const fetchedAt = subscriptions
    .map((s) => s.fetchedAt)
    .filter(Boolean)
    .sort()[0];
  if (fetchedAt) next.snapshotDate = localParts(fetchedAt, next.timeZone).date;
  commit(parsed, next);
  calendarSources = subscriptions;
  if (Object.hasOwn(payload, 'courseCode')) courseCode = payload.courseCode || '';
  return true;
};
window.nativeUpdate = function (patch) {
  const editable = [
    'mode',
    'theme',
    'colorTheme',
    'customColors',
    'calendarColors',
    'eventStyle',
    'eventTextScale',
    'paddingLeft',
    'paddingRight',
    'paddingTop',
    'paddingBottom',
    'month',
    'name',
    'start',
    'end',
    'proposed',
    'course',
    'width',
    'height',
    'showTitle',
    'rooms',
    'showTimeZone',
    'showSnapshotDate',
    'showCalendarLegend',
    'showEventTimes',
    'showWeekNumbers',
    'highlightToday',
    'includeWeekends',
  ];
  if (Object.keys(patch).some((key) => !editable.includes(key)))
    throw new Error('Unknown editor setting.');
  const next = { ...state, ...patch };
  if (!['module', 'month'].includes(next.mode) || !['system', 'light', 'dark'].includes(next.theme))
    throw new Error('Choose a valid view and appearance.');
  if (!['text', 'boxes'].includes(next.eventStyle)) throw new Error('Choose a valid event style.');
  for (const key of [
    'showTimeZone',
    'showWeekNumbers',
    'highlightToday',
    'showSnapshotDate',
    'showCalendarLegend',
    'showEventTimes',
  ]) {
    if (typeof next[key] !== 'boolean') throw new Error('Choose a valid visibility setting.');
  }
  if (typeof next.includeWeekends !== 'boolean')
    throw new Error('Choose whether to include weekends.');
  if (typeof next.name !== 'string' || !next.name.trim()) throw new Error('Enter a module name.');
  if (['name', 'start', 'end'].some((key) => Object.hasOwn(patch, key))) next.proposed = false;
  const rangeChanged = ['mode', 'month', 'start', 'end'].some((key) => next[key] !== state[key]);
  return commit(rangeChanged ? parseCalendars(calendarSources, next.timeZone, next) : data, next);
};
window.nativeCalendarWindow = function () {
  const range = recurrenceWindow(state, state.timeZone);
  return { from: dayAdd(range.from, -8), to: dayAdd(range.to, 8) };
};
window.nativeInclude = function (uid, included) {
  if (
    typeof uid !== 'string' ||
    typeof included !== 'boolean' ||
    !data.events.some((event) => event.uid === uid)
  )
    throw new Error('The event is no longer available.');
  const excluded = new Set(state.excludedEventIds);
  if (included) excluded.delete(uid);
  else excluded.add(uid);
  return commit(data, { ...state, excludedEventIds: [...excluded] });
};
window.nativeSources = function (subscriptions, clearCourse) {
  const committed = commit(parseCalendars(subscriptions, state.timeZone, state), {
    ...state,
    ...(clearCourse ? { course: '' } : {}),
  });
  calendarSources = subscriptions;
  return committed;
};
window.nativeReset = function () {
  const today = localParts(new Date(), nativeDefaults.timeZone).date;
  commit(
    { name: 'Calendar', events: [] },
    {
      ...nativeDefaults,
      mode: 'month',
      month: today.slice(0, 7),
      name: 'New module',
      start: today,
      end: dayAdd(today, 34),
      proposed: false,
      course: '',
      excludedEventIds: [],
      today,
    },
  );
  calendarSources = [];
  courseCode = '';
  return true;
};
window.nativeCalendars = function (subscriptions, fetchedAt) {
  const reconciled = reconcileSubscriptions(
    calendarSources,
    subscriptions,
    fetchedAt,
    state.timeZone,
  );
  const next = { ...advancedDay(state), snapshotDate: localParts(fetchedAt, state.timeZone).date };
  commit(parseCalendars(reconciled, next.timeZone, next), next);
  calendarSources = reconciled;
  return reconciled;
};
window.nativeDay = function () {
  const next = advancedDay(state);
  return next.today === state.today
    ? false
    : commit(parseCalendars(calendarSources, next.timeZone, next), next);
};
window.nativeSnapshot = function () {
  const result = renderWallpaper(data.events, renderOptions(state));
  const candidates = buildGrid(data.events, { ...state, excludedEventIds: [] }).visible;
  return {
    revision,
    editor: { ...state, excludedEventIds: [...state.excludedEventIds] },
    colorThemes: Object.entries(colorThemes).map(([id, theme]) => ({
      id,
      name: theme.name,
      accent: theme.light.accent,
    })),
    customColors: customThemeColors(state),
    courseCode,
    events: candidates.map((event) => ({
      ...event,
      included: !state.excludedEventIds.includes(event.uid),
    })),
    suggestions: suggestModules(data.events, courseCode, state.excludedEventIds),
    warnings: result.warnings,
    includedCount: result.grid.visible.length,
    svg: result.svg,
  };
};
async function pngBase64(svg) {
  const url = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }));
  try {
    const image = new Image();
    await new Promise((resolve, reject) => {
      image.onload = resolve;
      image.onerror = () => reject(new Error('Could not render the wallpaper image.'));
      image.src = url;
    });
    if (typeof image.decode === 'function') {
      try {
        await image.decode();
      } catch {}
    }
    const canvas = document.createElement('canvas');
    canvas.width = image.naturalWidth;
    canvas.height = image.naturalHeight;
    canvas.getContext('2d').drawImage(image, 0, 0);
    return canvas.toDataURL('image/png').split(',')[1];
  } finally {
    URL.revokeObjectURL(url);
  }
}
window.nativePNG = async function (theme) {
  const currentRevision = revision;
  const png = await pngBase64(
    renderWallpaper(data.events, renderOptions(theme ? { ...state, theme } : state)).svg,
  );
  return { revision: currentRevision, png };
};
function renderPair(size) {
  // Capture both SVGs before yielding so edits cannot mix two different calendars.
  const options = {
    ...state,
    width: size.width ?? state.width,
    height: size.height ?? state.height,
  };
  const lightSVG = renderWallpaper(data.events, { ...options, theme: 'light' }).svg;
  const darkSVG = renderWallpaper(data.events, { ...options, theme: 'dark' }).svg;
  return { name: state.name, lightSVG, darkSVG };
}
async function rasterizePair({ name, lightSVG, darkSVG }) {
  return { version: 1, name, light: await pngBase64(lightSVG), dark: await pngBase64(darkSVG) };
}
window.nativePair = async function (size = {}) {
  return rasterizePair(renderPair(size));
};
window.nativeWallpaper = async function (size, installedFingerprint) {
  const images = renderPair(size);
  const input = new TextEncoder().encode(JSON.stringify([images.lightSVG, images.darkSVG]));
  const digest = await crypto.subtle.digest('SHA-256', input);
  const fingerprint = btoa(String.fromCharCode(...new Uint8Array(digest)));
  return fingerprint === installedFingerprint
    ? { fingerprint }
    : { fingerprint, pair: await rasterizePair(images) };
};
