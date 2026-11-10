import ICAL from 'ical.js';

const localFormatters = new Map();

export function localParts(instant, timeZone) {
  let formatter = localFormatters.get(timeZone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat('en-GB', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      hourCycle: 'h23',
    });
    // An omitted zone follows the system default, which can change while the app runs.
    if (typeof timeZone === 'string') localFormatters.set(timeZone, formatter);
  }
  const parts = Object.fromEntries(
    formatter.formatToParts(new Date(instant)).map((p) => [p.type, p.value]),
  );
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    time: `${parts.hour}:${parts.minute}`,
  };
}

export function cleanDescription(value = '') {
  return (value || '').replace(/(?:^|\n)\s*ID\s+\d+\s*$/i, '').trim();
}

const HISTORY_VERSION = 1;
const HISTORY_MONTHS = 2;

function historyEvents(source, timeZone) {
  if (source.history?.version !== HISTORY_VERSION || !Array.isArray(source.history.events))
    return [];
  const keys = new Set();
  return source.history.events.map((event) => {
    if (
      !event ||
      typeof event.uid !== 'string' ||
      !event.uid ||
      keys.has(event.uid) ||
      typeof event.start !== 'string' ||
      typeof event.end !== 'string' ||
      typeof event.allDay !== 'boolean'
    )
      throw new Error('Saved calendar history is invalid.');
    keys.add(event.uid);
    const startLocal = event.allDay
      ? { date: event.start, time: '' }
      : localParts(event.start, timeZone);
    const endLocal = event.allDay ? { date: event.end, time: '' } : localParts(event.end, timeZone);
    return {
      ...event,
      date: startLocal.date,
      startTime: startLocal.time,
      endDate: endLocal.date,
      endTime: endLocal.time,
    };
  });
}

function monthStartMonthsAgo(date, months) {
  const [year, month] = date.slice(0, 7).split('-').map(Number);
  const shifted = year * 12 + month - 1 - months;
  const shiftedYear = Math.floor(shifted / 12);
  const shiftedMonth = ((shifted % 12) + 12) % 12;
  return `${shiftedYear}-${String(shiftedMonth + 1).padStart(2, '0')}-01`;
}

function completedBy(event, instant, localDate) {
  return event.allDay ? event.end <= localDate : event.end <= instant;
}

function withinHistoryWindow(event, cutoff, timeZone) {
  return event.allDay ? event.end > cutoff : localParts(event.end, timeZone).date >= cutoff;
}

// Resolve wall-clock times with the host's IANA database. At a fall-back
// overlap use the first occurrence; in a spring gap use the pre-transition
// offset, as RFC 5545 specifies for explicit local date-times.
function ianaZone(tzid) {
  let formatter;
  try {
    formatter = new Intl.DateTimeFormat('en-GB', {
      timeZone: tzid,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hourCycle: 'h23',
    });
  } catch {
    throw new Error(`Unknown calendar time zone: ${tzid}. Include its VTIMEZONE definition.`);
  }
  const offsetAt = (instant) => {
    const parts = Object.fromEntries(
      formatter.formatToParts(new Date(instant)).map((p) => [p.type, p.value]),
    );
    return (
      (Date.UTC(
        +parts.year,
        +parts.month - 1,
        +parts.day,
        +parts.hour,
        +parts.minute,
        +parts.second,
      ) -
        instant) /
      1000
    );
  };
  const zone = new ICAL.Timezone({ tzid });
  zone.utcOffset = (time) => {
    const wall = Date.UTC(time.year, time.month - 1, time.day, time.hour, time.minute, time.second);
    const before = offsetAt(wall - 2 * 86400000);
    const after = offsetAt(wall + 2 * 86400000);
    const matches = [...new Set([before, after])].filter(
      (offset) => offsetAt(wall - offset * 1000) === offset,
    );
    return matches.length ? Math.max(...matches) : before;
  };
  return zone;
}

export function recurrenceWindow(options = {}, timeZone = 'Europe/Stockholm') {
  const year = Number(localParts(options.today || new Date(), timeZone).date.slice(0, 4));
  // Keep nearby events available for module suggestions, and include any selected
  // historical/future view. Callers can request an exact window with from/to.
  const month = options.mode === 'month' || !options.start ? options.month : null;
  const start = month ? `${month}-01` : options.start || '';
  const end = month
    ? new Date(Date.UTC(Number(month.slice(0, 4)), Number(month.slice(5, 7)), 0))
        .toISOString()
        .slice(0, 10)
    : options.end || '';
  return {
    from: options.from || (start && start < `${year - 1}-01-01` ? start : `${year - 1}-01-01`),
    to: options.to || (end && end > `${year + 2}-01-01` ? end : `${year + 2}-01-01`),
  };
}

const calendarStamp = (time) => (time.isDate ? time.toString() : time.toJSDate().toISOString());
const occurrenceUid = (uid, recurrenceId) =>
  JSON.stringify(['occurrence', uid, calendarStamp(recurrenceId)]);
const isCancelled = (component) =>
  String(component.getFirstPropertyValue('status')).toUpperCase() === 'CANCELLED';

function concreteEvents(calendar, timeZone, options) {
  const originalLookup = calendar.getTimeZoneByID.bind(calendar);
  const zones = new Map();
  calendar.getTimeZoneByID = (tzid) => {
    const embedded = originalLookup(tzid);
    if (embedded) return embedded;
    if (!zones.has(tzid)) zones.set(tzid, ianaZone(tzid));
    return zones.get(tzid);
  };
  let floatingZone;
  const groups = new Map();
  for (const component of calendar.getAllSubcomponents('vevent')) {
    // Hydrate before expansion so floating dates recur in the wallpaper's zone.
    for (const property of component.getAllProperties()) {
      if (property.type === 'period')
        throw new Error('RDATE periods are not supported; use date-times and event durations.');
      if (property.type !== 'date-time') continue;
      for (const value of property.getValues()) {
        if (value.zone.tzid === 'floating') value.zone = floatingZone ??= ianaZone(timeZone);
      }
    }
    const event = new ICAL.Event(component, { exceptions: [] });
    if (!event.uid) throw new Error('Missing event UID; resolve before rendering.');
    if (component.getFirstProperty('recurrence-id')?.getParameter('range'))
      throw new Error(
        'Recurrence RANGE exceptions are not supported; export individual changed occurrences.',
      );
    if (!groups.has(event.uid)) groups.set(event.uid, new Map());
    const records = groups.get(event.uid);
    const key = event.recurrenceId ? calendarStamp(event.recurrenceId) : 'master';
    if (records.has(key)) {
      if (records.get(key).component.toString() === component.toString()) continue;
      throw new Error(
        'Conflicting duplicate event UID and recurrence ID; resolve before rendering.',
      );
    }
    records.set(key, event);
  }
  const result = [];
  const cancelledUids = [];
  const seriesUids = [];
  const { from, to } = recurrenceWindow(options, timeZone);
  // Padding includes the rest of the first and last calendar rows and zone offsets.
  const lower = new Date(`${from}T00:00:00Z`).getTime() - 8 * 86400000;
  const upper = new Date(`${to}T00:00:00Z`).getTime() + 8 * 86400000;
  if (!Number.isFinite(lower) || !Number.isFinite(upper) || upper < lower)
    throw new Error('Invalid recurrence expansion window.');
  let iterations = 0;
  function append(event, startDate, endDate, uid, seriesUid) {
    if (!startDate || !endDate) throw new Error('An event is missing its dates.');
    if (startDate.isDate !== endDate.isDate)
      throw new Error('Mixed date and time values in an event.');
    if (calendarStamp(endDate) < calendarStamp(startDate))
      throw new Error('An event ends before it starts.');
    if (
      seriesUid &&
      (endDate.toJSDate().getTime() < lower || startDate.toJSDate().getTime() > upper)
    )
      return;
    if (result.length >= 20000)
      throw new Error('Calendar exceeds the 20,000-event expansion limit.');
    result.push({ event, startDate, endDate, uid, ...(seriesUid ? { seriesUid } : {}) });
  }
  for (const [uid, records] of groups) {
    const master = records.get('master');
    const recurring =
      master?.isRecurring() ||
      master?.component.hasProperty('exdate') ||
      records.size > (master ? 1 : 0);
    if (recurring) seriesUids.push(uid);
    if (master && isCancelled(master.component)) {
      cancelledUids.push(uid);
      continue;
    }
    for (const [key, exception] of records) {
      if (key === 'master') continue;
      const id = occurrenceUid(uid, exception.recurrenceId);
      if (isCancelled(exception.component)) cancelledUids.push(id);
      else
        append(exception, exception.startDate, exception.startDate && exception.endDate, id, uid);
    }
    if (!master) continue;
    if (!master.startDate) throw new Error('An event is missing its dates.');
    if (!recurring) {
      append(master, master.startDate, master.endDate, uid);
      continue;
    }
    if (master.startDate.isDate !== master.endDate.isDate)
      throw new Error('Mixed date and time values in an event.');
    if (calendarStamp(master.endDate) < calendarStamp(master.startDate))
      throw new Error('An event ends before it starts.');
    // DTSTART belongs to the recurrence set even when the feed has only RDATE.
    // Adding it here also lets the expander apply EXDATE to a lone DTSTART.
    master.component.addPropertyWithValue('rdate', master.startDate);
    const iterator = master.iterator();
    const seen = new Set();
    let occurrence;
    while ((occurrence = iterator.next())) {
      if (++iterations > 50000)
        throw new Error('Calendar exceeds the 50,000-step recurrence expansion limit.');
      if (occurrence.toJSDate().getTime() > upper) break;
      const stamp = calendarStamp(occurrence);
      if (records.has(stamp) || seen.has(stamp)) continue;
      seen.add(stamp);
      const details = master.getOccurrenceDetails(occurrence);
      // DTEND defines an exact duration; DURATION retains nominal calendar days.
      if (!master.startDate.isDate && master.component.hasProperty('dtend')) {
        details.endDate = ICAL.Time.fromJSDate(
          new Date(occurrence.toJSDate().getTime() + master.duration.toSeconds() * 1000),
          true,
        );
      }
      append(master, details.startDate, details.endDate, occurrenceUid(uid, occurrence), uid);
    }
  }
  if (new Set(result.map((item) => item.uid)).size !== result.length)
    throw new Error('Conflicting duplicate expanded event UID.');
  return { records: result, cancelledUids, seriesUids };
}

export function parseCalendar(source, timeZone = 'Europe/Stockholm', kind = 'auto', options = {}) {
  const calendar = new ICAL.Component(ICAL.parse(source));
  if (calendar.name !== 'vcalendar') throw new Error('Expected an iCalendar VCALENDAR.');
  const timeEdit =
    kind === 'timeedit' ||
    (kind === 'auto' && /timeedit/i.test(calendar.getFirstPropertyValue('prodid') || source));
  const { records, cancelledUids, seriesUids } = concreteEvents(calendar, timeZone, options);
  const events = records
    .map(({ event, startDate, endDate, uid, seriesUid }) => {
      const component = event.component;
      const allDay = startDate.isDate;
      const start = calendarStamp(startDate);
      const end = calendarStamp(endDate);
      const startLocal = allDay ? { date: start, time: '' } : localParts(start, timeZone);
      const endLocal = allDay ? { date: end, time: '' } : localParts(end, timeZone);
      const summary = event.summary || 'Untitled event';
      const specialized = timeEdit || (kind === 'auto' && /,\s*\d[A-Z]{2}\d{3}\b/.test(summary));
      const description = specialized
        ? cleanDescription(event.description)
        : (event.description || '').trim();
      const summaryParts = summary.split(',').map((part) => part.trim());
      const courseIndex = summaryParts.findIndex((part) => /^\d[A-Z]{2}\d{3}$/.test(part));
      const fallbackTitle =
        courseIndex > 0 ? summaryParts.slice(0, courseIndex).join(', ') : summary;
      const title = specialized
        ? description
            .split('\n')
            .find((line) => line.trim())
            ?.trim() || fallbackTitle
        : summary;
      const location = (event.location || '').replace(/\s+/g, ' ').trim();
      const room = !specialized
        ? location
        : location.match(/\b[A-Z]\d{3,4}[A-Z]?(?=\b|_)/)?.[0] || location;
      const mentionedRooms = [...description.matchAll(/\b[A-Z]\d{3,4}[A-Z]?\b/g)].map(
        (match) => match[0],
      );
      const roomConflict = Boolean(
        specialized && room && mentionedRooms.some((value) => value !== room),
      );
      return {
        uid,
        ...(seriesUid ? { seriesUid } : {}),
        calendarKind: specialized ? 'timeedit' : 'generic',
        start,
        end,
        allDay,
        date: startLocal.date,
        startTime: startLocal.time,
        endDate: endLocal.date,
        endTime: endLocal.time,
        title,
        summary,
        description,
        location,
        room: room + (/zoom/i.test(location) && !/zoom/i.test(room) ? ' · Zoom' : ''),
        roomConflict,
        kind: /examination|presentation/i.test(summary + ' ' + title)
          ? 'presentation'
          : /workshop|\bWS\b/i.test(summary)
            ? 'workshop'
            : 'session',
        cancelled: String(component.getFirstPropertyValue('status')).toUpperCase() === 'CANCELLED',
      };
    })
    .filter(Boolean);
  events.sort((a, b) => a.start.localeCompare(b.start) || a.uid.localeCompare(b.uid));
  return {
    name: calendar.getFirstPropertyValue('x-wr-calname') || 'Calendar',
    timeZone,
    events,
    cancelledUids,
    seriesUids,
  };
}

export function reconcileSubscriptions(
  previousSubscriptions,
  nextSubscriptions,
  fetchedAt,
  timeZone = 'Europe/Stockholm',
) {
  const instant = new Date(fetchedAt).toISOString();
  const localDate = localParts(instant, timeZone).date;
  const cutoff = monthStartMonthsAgo(localDate, HISTORY_MONTHS);
  const previousById = new Map(previousSubscriptions.map((source) => [source.id, source]));

  return nextSubscriptions.map((source) => {
    if (source.provider === 'eventkit') {
      snapshotEvents(source, timeZone);
      const { history, ...snapshotSource } = source;
      return snapshotSource;
    }
    const fresh = source.ics
      ? parseCalendar(source.ics, timeZone, source.kind || 'auto', { today: fetchedAt })
      : { events: [], cancelledUids: [] };
    const previous = previousById.get(source.id);
    const sameCalendar = previous && String(previous.url || '') === String(source.url || '');
    const priorEvents = new Map();
    if (sameCalendar) {
      for (const event of historyEvents(previous, timeZone)) priorEvents.set(event.uid, event);
      if (previous.ics && (previous.ics !== source.ics || previous.kind !== source.kind))
        for (const event of parseCalendar(previous.ics, timeZone, previous.kind || 'auto', {
          today: fetchedAt,
        }).events)
          priorEvents.set(event.uid, event);
    }
    const freshUids = new Set(fresh.events.map((event) => event.uid));
    const cancelledUids = new Set(fresh.cancelledUids);
    const retained = [...priorEvents.values()]
      .filter(
        (event) =>
          !freshUids.has(event.uid) &&
          !cancelledUids.has(event.uid) &&
          !(
            event.seriesUid &&
            (cancelledUids.has(event.seriesUid) ||
              freshUids.has(event.seriesUid) ||
              fresh.seriesUids?.includes(event.seriesUid))
          ) &&
          completedBy(event, instant, localDate) &&
          withinHistoryWindow(event, cutoff, timeZone),
      )
      .sort((a, b) => a.start.localeCompare(b.start) || a.uid.localeCompare(b.uid));
    const reconciled = { ...source };
    if (retained.length) reconciled.history = { version: HISTORY_VERSION, events: retained };
    else delete reconciled.history;
    return reconciled;
  });
}

// Native providers supply concrete occurrences, with date-only all-day boundaries.
function snapshotEvents(source, timeZone) {
  const snapshot = source.snapshot;
  if (!snapshot) return [];
  const validDay = (value) =>
    typeof value === 'string' &&
    /^\d{4}-\d{2}-\d{2}$/.test(value) &&
    Number.isFinite(Date.parse(value)) &&
    new Date(value).toISOString().slice(0, 10) === value;
  if (
    snapshot.version !== 1 ||
    !Array.isArray(snapshot.events) ||
    !validDay(snapshot.coverageStart) ||
    !validDay(snapshot.coverageEnd) ||
    snapshot.coverageEnd <= snapshot.coverageStart
  )
    throw new Error('Invalid local calendar snapshot.');
  const ids = new Set();
  return snapshot.events.map((event) => {
    if (
      !event ||
      typeof event.uid !== 'string' ||
      !event.uid ||
      ids.has(event.uid) ||
      typeof event.allDay !== 'boolean' ||
      !['title', 'summary', 'description', 'location'].every(
        (key) => typeof event[key] === 'string',
      )
    )
      throw new Error('Invalid local calendar event.');
    ids.add(event.uid);
    const validInstant = (value) =>
      typeof value === 'string' &&
      /^\d{4}-\d{2}-\d{2}T.*Z$/.test(value) &&
      Number.isFinite(Date.parse(value));
    const valid = event.allDay ? validDay : validInstant;
    if (!valid(event.start) || !valid(event.end) || Date.parse(event.end) < Date.parse(event.start))
      throw new Error('Invalid local calendar event dates.');
    const start = event.allDay ? event.start : new Date(event.start).toISOString();
    const end = event.allDay ? event.end : new Date(event.end).toISOString();
    const startLocal = event.allDay ? { date: start, time: '' } : localParts(start, timeZone);
    const endLocal = event.allDay ? { date: end, time: '' } : localParts(end, timeZone);
    return {
      uid: event.uid,
      start,
      end,
      allDay: event.allDay,
      title: event.title || 'Untitled event',
      summary: event.summary,
      description: event.description,
      location: event.location,
      date: startLocal.date,
      startTime: startLocal.time,
      endDate: endLocal.date,
      endTime: endLocal.time,
      calendarKind: 'generic',
      room: event.location,
      roomConflict: false,
      kind: 'session',
      cancelled: false,
    };
  });
}

function parseCalendarSource(source, timeZone, options) {
  const native = source.provider === 'eventkit';
  const parsed = native
    ? {
        name: source.name || 'Calendar',
        events: snapshotEvents(source, timeZone),
        cancelledUids: [],
      }
    : parseCalendar(source.ics, timeZone, source.kind || 'auto', options);
  const liveUids = new Set(parsed.events.map((event) => event.uid));
  const sourceEvents = new Map(
    (native ? [] : historyEvents(source, timeZone))
      .filter(
        (event) =>
          !parsed.cancelledUids.includes(event.uid) &&
          !(
            event.seriesUid &&
            (parsed.seriesUids.includes(event.seriesUid) ||
              liveUids.has(event.seriesUid) ||
              parsed.cancelledUids.includes(event.seriesUid))
          ),
      )
      .map((event) => [event.uid, event]),
  );
  for (const event of parsed.events) sourceEvents.set(event.uid, event);
  return {
    name: parsed.name,
    events: Array.from(sourceEvents.values(), (event) => ({
      ...event,
      uid: source.legacyIds ? event.uid : JSON.stringify([source.id, event.uid]),
      sourceId: source.id,
      sourceName: source.name || parsed.name,
      sourceColor: source.color,
      originalUid: event.uid,
    })),
  };
}

// Source IDs stay local and never contain the subscription URL or its credentials.
// A source cache may be shared within one time zone and recurrence window.
export function parseCalendars(subscriptions, timeZone = 'Europe/Stockholm', options = {}, cache) {
  const ids = new Set();
  const events = [];
  let name = 'Calendars';
  for (const source of subscriptions) {
    if (!source.id || ids.has(source.id)) throw new Error('Missing or duplicate subscription ID.');
    ids.add(source.id);
    if (source.provider && !['ics', 'eventkit'].includes(source.provider))
      throw new Error('Unknown calendar provider.');
    if (source.enabled === false || (source.provider !== 'eventkit' && !source.ics)) continue;
    let parsed = cache?.get(source);
    if (!parsed) {
      parsed = parseCalendarSource(source, timeZone, options);
      cache?.set(source, parsed);
    }
    if (source.legacyIds) name = parsed.name;
    for (const event of parsed.events) events.push(event);
  }
  if (new Set(events.map((event) => event.uid)).size !== events.length)
    throw new Error('Duplicate combined event ID.');
  events.sort((a, b) => a.start.localeCompare(b.start) || a.uid.localeCompare(b.uid));
  return { name, timeZone, events };
}
