export const palettes = {
  light: {
    bg: '#f0efe9',
    text: '#263b35',
    muted: '#596d63',
    line: '#c4cec4',
    accent: '#356e50',
    tint: '#e2e8dd',
    faint: '#e9ece4',
    orange: '#9b5b2d',
  },
  dark: {
    bg: '#18231f',
    text: '#e4e9dd',
    muted: '#adbcaf',
    line: '#3d4e42',
    accent: '#b3d3a7',
    tint: '#2b4032',
    faint: '#223129',
    orange: '#e7b589',
  },
};
// Each color theme has a light and dark palette for adaptive wallpapers.
export const colorThemes = {
  forest: { name: 'Forest', light: palettes.light, dark: palettes.dark },
  neutral: themePair(
    'Neutral',
    ['#f2f2f2', '#292929', '#555555'],
    ['#202020', '#eeeeee', '#bbbbbb'],
  ),
  ocean: themePair('Ocean', ['#edf3f8', '#20354b', '#28658f'], ['#172532', '#e0edf7', '#95c9ee']),
  plum: themePair('Plum', ['#f3eff7', '#403049', '#76538f'], ['#291f32', '#eee3f5', '#ceb0e5']),
  rose: themePair('Rose', ['#f8efef', '#4b3035', '#9a4c62'], ['#321f26', '#f5e3e7', '#ecaabd']),
  sand: themePair('Sand', ['#f6f1e7', '#473b29', '#876735'], ['#2c261c', '#f0e8d8', '#d9bf87']),
};
function mixColor(a, b, amount) {
  return (
    '#' +
    [1, 3, 5]
      .map((offset) =>
        Math.round(
          parseInt(a.slice(offset, offset + 2), 16) * (1 - amount) +
            parseInt(b.slice(offset, offset + 2), 16) * amount,
        )
          .toString(16)
          .padStart(2, '0'),
      )
      .join('')
  );
}
function derivedPalette([bg, text, accent]) {
  return {
    bg,
    text,
    accent,
    muted: mixColor(bg, text, 0.7),
    line: mixColor(bg, text, 0.22),
    tint: mixColor(bg, accent, 0.14),
    faint: mixColor(bg, accent, 0.07),
    orange: accent,
  };
}
function themePair(name, light, dark) {
  return { name, light: derivedPalette(light), dark: derivedPalette(dark) };
}
export function customThemeColors(options = {}) {
  const preset = colorThemes.neutral;
  return Object.fromEntries(
    ['light', 'dark'].map((appearance) => [
      appearance,
      Object.fromEntries(
        ['bg', 'text', 'accent'].map((key) => [
          key,
          options.customColors?.[appearance]?.[key] || preset[appearance][key],
        ]),
      ),
    ]),
  );
}
export function resolvePalette(options = {}) {
  const name = options.colorTheme ?? 'forest';
  if (name !== 'custom' && !Object.hasOwn(colorThemes, name))
    throw new Error('Choose a valid color theme.');
  if (options.calendarColors !== undefined && typeof options.calendarColors !== 'boolean')
    throw new Error('Choose whether to use calendar colors.');
  if (options.customColors !== undefined) {
    const colors = options.customColors;
    if (
      !colors ||
      typeof colors !== 'object' ||
      Array.isArray(colors) ||
      Object.keys(colors).some((key) => !['light', 'dark'].includes(key)) ||
      ['light', 'dark'].some(
        (appearance) =>
          !colors[appearance] ||
          Object.keys(colors[appearance]).some((key) => !['bg', 'text', 'accent'].includes(key)) ||
          ['bg', 'text', 'accent'].some(
            (key) =>
              typeof colors[appearance][key] !== 'string' ||
              !/^#[0-9a-f]{6}$/i.test(colors[appearance][key]),
          ),
      )
    )
      throw new Error(
        'Choose valid background, text, and accent colors for light and dark appearance.',
      );
  }
  const appearance = resolveTheme(options.theme, options.systemTheme);
  return name === 'custom'
    ? derivedPalette(Object.values(customThemeColors(options)[appearance]))
    : colorThemes[name][appearance];
}
const eventColors = {
  green: ['#356e50', '#b3d3a7'],
  blue: ['#285e9b', '#9fc7ff'],
  purple: ['#754398', '#d5b0f3'],
  pink: ['#9b3e70', '#f3acd0'],
  orange: ['#91501f', '#efbd89'],
  red: ['#a13c38', '#f4aaa4'],
};
function calendarColor(value, theme) {
  if (Object.hasOwn(eventColors, value)) return eventColors[value][theme === 'dark' ? 1 : 0];
  return /^#[0-9a-f]{6}$/i.test(value || '') ? value : null;
}
// Lighten or darken calendar colors without introducing the wallpaper background hue.
function boxColor(color, theme) {
  const base = theme === 'dark' ? 0 : 255;
  return (
    '#' +
    [1, 3, 5]
      .map((offset) => {
        const foreground = parseInt(color.slice(offset, offset + 2), 16);
        return Math.round(base * 0.3 + foreground * 0.7)
          .toString(16)
          .padStart(2, '0');
      })
      .join('')
  );
}
function luminance(color) {
  const channels = color
    .slice(1)
    .match(/../g)
    .map((hex) => {
      const value = parseInt(hex, 16) / 255;
      return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
    });
  return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
}
function boxTextColor(fill) {
  return luminance(fill) > 0.179 ? '#000000' : '#ffffff';
}
function readableTextColor(color, background, minimumContrast = 4.5) {
  const contrast = (candidate) => {
    const a = luminance(candidate),
      b = luminance(background);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  };
  if (contrast(color) >= minimumContrast) return color;
  const target = boxTextColor(background);
  // Move toward black or white only as far as readability requires.
  let low = 0,
    high = 1;
  for (let i = 0; i < 12; i++) {
    const amount = (low + high) / 2;
    if (contrast(mixColor(color, target, amount)) >= minimumContrast) high = amount;
    else low = amount;
  }
  return mixColor(color, target, high);
}
export function resolveTheme(theme, systemTheme = 'light') {
  const resolved = theme === 'system' ? systemTheme : theme;
  return resolved === 'dark' ? 'dark' : 'light';
}
export const escapeXml = (value) =>
  String(value).replace(
    /[<>&"']/g,
    (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[c],
  );
export function dateKey(date) {
  return date.toISOString().slice(0, 10);
}
export function dayAdd(key, amount) {
  const date = new Date(key + 'T12:00:00Z');
  date.setUTCDate(date.getUTCDate() + amount);
  return dateKey(date);
}
export function weekday(key) {
  return (new Date(key + 'T12:00:00Z').getUTCDay() + 6) % 7;
}
export function validDate(key) {
  return (
    /^\d{4}-\d{2}-\d{2}$/.test(key) &&
    Number.isFinite(Date.parse(key)) &&
    dateKey(new Date(key)) === key
  );
}
export function weekNumber(key) {
  const d = new Date(dayAdd(key, 3 - weekday(key)) + 'T12:00:00Z');
  return Math.ceil(((d - new Date(Date.UTC(d.getUTCFullYear(), 0, 1, 12))) / 86400000 + 1) / 7);
}
export function monthRange(month) {
  if (!/^\d{4}-\d{2}$/.test(month) || !validDate(month + '-01'))
    throw new Error('Choose a valid month.');
  const first = month + '-01';
  const d = new Date(first + 'T12:00:00Z');
  d.setUTCMonth(d.getUTCMonth() + 1);
  return { start: first, end: dayAdd(dateKey(d), -1) };
}
export function eventDays(event, start, end) {
  const last =
    event.allDay || event.endTime === '00:00' ? dayAdd(event.endDate, -1) : event.endDate;
  const days = [];
  for (
    let day = event.date > start ? event.date : start;
    day <= end && day <= last;
    day = dayAdd(day, 1)
  )
    days.push(day);
  if (
    !days.length &&
    event.date === event.endDate &&
    !event.allDay &&
    event.date >= start &&
    event.date <= end
  )
    days.push(event.date);
  return days;
}
export function selectEvents(events, course) {
  return course.trim()
    ? events.filter((event) => event.summary.split(/[,\s]+/).includes(course.trim()))
    : events;
}
export function buildGrid(events, options) {
  const range =
    options.mode === 'month'
      ? monthRange(options.month)
      : { start: options.start, end: options.end };
  if (!validDate(range.start) || !validDate(range.end) || range.end < range.start)
    throw new Error('Enter a valid start and end date, in that order.');
  const first = dayAdd(range.start, -weekday(range.start));
  const last = dayAdd(range.end, 6 - weekday(range.end));
  const weeks = Math.floor((new Date(last) - new Date(first)) / 604800000) + 1;
  if (weeks > 12) throw new Error('Choose a range of 12 weeks or fewer for a readable wallpaper.');
  const columns = options.includeWeekends === true ? 7 : 5;
  const byDay = new Map();
  const excluded = new Set(options.excludedEventIds || []);
  const visible = selectEvents(events, options.course).filter((event) => {
    if (excluded.has(event.uid)) return false;
    // The selected dates determine the rows, not which events fill those rows.
    const days = eventDays(event, first, last).filter((day) => weekday(day) < columns);
    days.forEach((day) => {
      if (!byDay.has(day)) byDay.set(day, []);
      byDay.get(day).push(event);
    });
    return days.length;
  });
  return {
    range,
    first,
    last,
    weeks,
    visible,
    columns,
    rows: Array.from({ length: weeks }, (_, w) =>
      Array.from({ length: columns }, (_, d) => {
        const key = dayAdd(first, w * 7 + d);
        return {
          key,
          inside: key >= range.start && key <= range.end,
          events: byDay.get(key) || [],
        };
      }),
    ),
  };
}

// Conservative character widths keep the same wrapping in SVG export and the
// browser preview without requiring a remote font or a running browser.
export function textWidth(text, size) {
  return (
    [...text].reduce(
      (sum, c) =>
        sum +
        (/[ilIjtfr.,:;!|' ]/.test(c)
          ? 0.3
          : /[MW@%&]/.test(c)
            ? 0.9
            : /[A-Z]/.test(c)
              ? 0.67
              : 0.56),
      0,
    ) * size
  );
}
export function wrapText(text, width, size, maxLines = 3) {
  const words = String(text).trim().split(/\s+/);
  const lines = [];
  let line = '';
  for (let word of words) {
    if (textWidth(word, size) > width) {
      if (line) {
        lines.push(line);
        line = '';
      }
      while (textWidth(word, size) > width) {
        let n = 1;
        while (n < word.length && textWidth(word.slice(0, n + 1), size) <= width) n++;
        lines.push(word.slice(0, n));
        word = word.slice(n);
      }
    }
    const combined = line ? line + ' ' + word : word;
    if (textWidth(combined, size) > width && line) {
      lines.push(line);
      line = word;
    } else line = combined;
  }
  if (line) lines.push(line);
  const truncated = lines.length > maxLines;
  const result = lines.slice(0, maxLines);
  if (truncated) {
    let tail = result.at(-1) || '';
    while (tail && textWidth(tail + '…', size) > width) tail = tail.slice(0, -1);
    result[result.length - 1] = tail.trimEnd() + '…';
  }
  return { lines: result, truncated };
}

// Protect quiet weeks at their natural height. Only crowded weeks give up space
// when the content exceeds the page, instead of shrinking every row equally.
export function allocateRows(needed, available) {
  const total = needed.reduce((sum, height) => sum + height, 0);
  if (total <= available) {
    const active = needed.filter((height) => height > 48).length;
    return needed.map(
      (height) =>
        height +
        (active
          ? height > 48
            ? (available - total) / active
            : 0
          : (available - total) / needed.length),
    );
  }
  let low = 0,
    high = Math.max(...needed);
  for (let i = 0; i < 50; i++) {
    const cap = (low + high) / 2;
    if (needed.reduce((sum, height) => sum + Math.min(height, cap), 0) > available) high = cap;
    else low = cap;
  }
  return needed.map((height) => Math.min(height, low));
}

export function renderWallpaper(events, options) {
  const { width = 3024, height = 1964 } = options;
  if (
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    width < 1280 ||
    height < 720 ||
    width > 7680 ||
    height > 4320
  )
    throw new Error('Use an image between 1280 × 720 and 7680 × 4320 pixels.');
  const textScale = options.eventTextScale ?? 1;
  if (
    typeof textScale !== 'number' ||
    !Number.isFinite(textScale) ||
    textScale < 0.75 ||
    textScale > 1.5
  )
    throw new Error('Choose an event text size between 75% and 150%.');
  const padding = {};
  for (const [side, fallback] of Object.entries({ Left: 76, Right: 76, Top: 24, Bottom: 22 })) {
    const value = options[`padding${side}`] ?? fallback;
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 200)
      throw new Error('Choose padding between 0 and 200.');
    padding[side] = value;
  }
  const boxed = options.eventStyle === 'boxes';
  const bottomPadding = boxed ? 4 : 0;
  const grid = buildGrid(events, options);
  const p = resolvePalette(options);
  const eventThemeColor = (value) =>
    options.calendarColors === false
      ? null
      : calendarColor(value, resolveTheme(options.theme, options.systemTheme));
  const W = 1512,
    H = (height / width) * W;
  const menuBarInset = padding.Top;
  const x = padding.Left,
    right = padding.Right,
    gutter = options.showWeekNumbers === false ? 0 : 44,
    cw = (W - x - right - gutter) / grid.columns;
  const legend = [];
  const legendSources = new Set();
  const snapshotLabel = options.snapshotDate
    ? 'Snapshot ' + options.snapshotDate
    : 'Local snapshot';
  const conflicts = grid.visible.some((event) => event.roomConflict);
  const conflictLabel = '* Description mentions another room. Check the event details.';
  const legendStart =
    x + (options.showSnapshotDate === false ? 0 : textWidth(snapshotLabel, 10) + 24);
  const legendEnd = W - right - (conflicts ? textWidth(conflictLabel, 10) + 24 : 0);
  let legendX = legendStart;
  let legendRow = 0;
  for (const event of grid.visible) {
    if (
      options.showCalendarLegend === false ||
      !event.sourceId ||
      legendSources.has(event.sourceId)
    )
      continue;
    legendSources.add(event.sourceId);
    const label = wrapText(event.sourceName || 'Calendar', legendEnd - legendStart, 11, 1).lines[0];
    const labelWidth = textWidth(label, 11);
    if (legendX > legendStart && legendX + labelWidth > legendEnd) {
      legendRow++;
      legendX = legendStart;
    }
    legend.push({
      label,
      x: legendX,
      row: legendRow,
      color: eventThemeColor(event.sourceColor) || p.text,
    });
    legendX += labelWidth + 24;
  }
  const legendHeight = legendRow * 18;
  const title =
    options.mode === 'month'
      ? new Intl.DateTimeFormat('en-GB', {
          month: 'long',
          year: 'numeric',
          timeZone: 'UTC',
        }).format(new Date(grid.range.start))
      : options.name || 'Untitled module';
  const showTitle = options.showTitle !== false;
  const titleLines = showTitle
    ? wrapText(title, W - x - right - 190, 40, 2)
    : { lines: [], truncated: false };
  const tableY = (showTitle ? 108 + (titleLines.lines.length - 1) * 39 : 68) + menuBarInset,
    bottom = H - padding.Bottom - 22 - legendHeight,
    available = bottom - tableY;
  if (available < 290)
    throw new Error('This aspect ratio leaves too little space for the calendar.');
  const titleSize = 14 * textScale;
  const lineHeight = 17 * textScale;
  const timeLabel = (event, day) =>
    event.allDay
      ? 'ALL DAY'
      : event.start === event.end
        ? event.startTime
        : `${day === event.date ? event.startTime : '↳'} – ${day === event.endDate ? event.endTime : 'continues'}`;
  const cardInfo = (event, day, maxLines = 20) => {
    const textInset = boxed && event.kind === 'presentation' ? 7 : 0;
    const contentWidth = cw - 28 - textInset;
    const wrapped = wrapText(event.title, contentWidth, titleSize, maxLines);
    const roomText =
      options.rooms !== false && event.room ? event.room + (event.roomConflict ? ' *' : '') : '';
    const room = wrapText(roomText, contentWidth, 10.5 * textScale, 1);
    const time = options.showEventTimes === false ? '' : timeLabel(event, day);
    const stackedRoom = Boolean(
      time &&
        roomText &&
        textWidth(time, 11 * textScale) + textWidth(room.lines[0], 10.5 * textScale) + 16 >
          contentWidth,
    );
    // The title is larger than the metadata, so its first baseline needs a lower inset.
    const metadataHeight = time || room.lines.length ? 16 * textScale : 3 * textScale;
    return {
      ...wrapped,
      room,
      time,
      stackedRoom,
      textInset,
      metadataHeight,
      height:
        metadataHeight +
        wrapped.lines.length * lineHeight +
        (stackedRoom ? 14 * textScale : 0) +
        4 +
        bottomPadding,
    };
  };
  const needed = grid.rows.map((row) =>
    Math.max(
      48,
      ...row.map(
        (day) =>
          34 +
          11 * (textScale - 1) +
          day.events.reduce((s, e) => s + cardInfo(e, day.key).height, 0),
      ),
    ),
  );
  const rowHeights = allocateRows(needed, available);
  const fmt = (key) =>
    new Intl.DateTimeFormat('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' }).format(
      new Date(key),
    );
  const subtitle =
    options.mode === 'month'
      ? `${grid.visible.length} sessions · Month overview`
      : `${fmt(grid.range.start)} – ${fmt(grid.range.end)} ${grid.range.end.slice(0, 4)} · ${grid.weeks} weeks${options.proposed ? ' · Suggested dates' : ''}`;
  const chunks = [];
  const warnings = [];
  const bounds = [];
  const placements = [];
  function rect(rx, ry, rw, rh, fill, radius = 0) {
    chunks.push(
      `<rect x="${rx}" y="${ry}" width="${rw}" height="${rh}" rx="${radius}" fill="${fill}"/>`,
    );
  }
  let textBackground = p.bg;
  function text(tx, ty, value, size = 12, color = p.text, weight = 400, anchor = 'start') {
    if (options.colorTheme === 'custom' && textBackground !== null)
      color = readableTextColor(color, textBackground);
    chunks.push(
      `<text x="${tx}" y="${ty}" font-size="${size}" fill="${color}" font-weight="${weight}" text-anchor="${anchor}">${escapeXml(value)}</text>`,
    );
    bounds.push({
      text: String(value),
      x: tx,
      y: ty,
      width: textWidth(String(value), size),
      size,
      anchor,
    });
  }
  function line(x1, y1, x2, y2) {
    const color = options.colorTheme === 'custom' ? readableTextColor(p.line, p.bg, 1.5) : p.line;
    chunks.push(`<path d="M${x1} ${y1}H${x2}" stroke="${color}" stroke-width="0.8"/>`);
  }
  rect(0, 0, W, H, p.bg);
  if (titleLines.truncated) warnings.push('The heading was shortened to fit.');
  titleLines.lines.forEach((t, i) => text(x, 68 + menuBarInset + i * 39, t, 40, p.text, 500));
  if (options.showTimeZone !== false)
    text(
      W - right,
      (showTitle ? 68 : 32) + menuBarInset,
      options.timeZone || 'Europe/Stockholm',
      11,
      p.muted,
      400,
      'end',
    );
  const weekdays = ['MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY', 'SUNDAY'];
  if (options.showWeekNumbers !== false) text(x, tableY - 17, 'WK', 10, p.muted);
  for (let d = 0; d < grid.columns; d++)
    text(x + gutter + d * cw + 12, tableY - 17, weekdays[d], 10, p.muted, 500);
  let rowY = tableY;
  grid.rows.forEach((row, w) => {
    const rh = rowHeights[w];
    line(x, rowY, W - right, rowY);
    if (options.showWeekNumbers !== false)
      text(x, rowY + 19, String(weekNumber(row[0].key)).padStart(2, '0'), 12, p.muted);
    row.forEach((day, d) => {
      const dx = x + gutter + d * cw;
      const isToday = options.highlightToday !== false && day.key === options.today;
      if (!day.inside) rect(dx, rowY + 1, cw, rh - 1, p.faint);
      if (isToday) rect(dx + 3, rowY + 3, cw - 6, rh - 6, p.tint, 5);
      const dayBackground = isToday ? p.tint : day.inside ? p.bg : p.faint;
      textBackground = dayBackground;
      const dateLabel = fmt(day.key);
      text(dx + 12, rowY + 19, dateLabel, 12, isToday ? p.accent : p.muted, isToday ? 600 : 400);
      if (isToday) text(dx + 16 + textWidth(dateLabel, 12), rowY + 19, 'TODAY', 9, p.accent, 600);
      let cy = rowY + 36 + 11 * (textScale - 1);
      const fullCards = day.events.map((event) => cardInfo(event, day.key));
      const lineLimits = fullCards.map((card) => Math.min(1, card.lines.length));
      let used = day.events.reduce(
        (sum, event, index) => sum + cardInfo(event, day.key, lineLimits[index]).height,
        0,
      );
      const cardSpace = rh - 34 - 11 * (textScale - 1);
      let expanded = true;
      while (expanded && used + lineHeight <= cardSpace) {
        expanded = false;
        for (let i = 0; i < lineLimits.length && used + lineHeight <= cardSpace; i++) {
          if (lineLimits[i] < fullCards[i].lines.length) {
            lineLimits[i]++;
            used += lineHeight;
            expanded = true;
          }
        }
      }
      const eventCards = day.events.map((event, index) =>
        cardInfo(event, day.key, lineLimits[index]),
      );
      for (let i = 0; i < day.events.length; i++) {
        const event = day.events[i],
          card = eventCards[i],
          remaining = day.events.length - i;
        const remainingHeight = eventCards.slice(i).reduce((sum, item) => sum + item.height, 0);
        const reserve =
          remaining > 1 && cy + remainingHeight - (lineHeight + 4) > rowY + rh - 8 ? 20 : 0;
        if (cy + card.height - (lineHeight + 4) > rowY + rh - 8 - reserve) {
          text(
            dx + 12,
            Math.min(cy + 2, rowY + rh - 10),
            `+ ${remaining} more · see preview`,
            10,
            p.orange,
            500,
          );
          warnings.push(
            `${day.key}: ${remaining} event${remaining === 1 ? ' does' : 's do'} not fit; all details remain in the preview.`,
          );
          break;
        }
        placements.push({
          uid: event.uid,
          date: day.key,
          top: cy - 11 * textScale,
          bottom: cy + card.height - (lineHeight + 4) + 3,
          rowTop: rowY,
          rowBottom: rowY + rh,
        });
        const eventColor = eventThemeColor(event.sourceColor);
        const boxFill = boxColor(
          eventColor || p.accent,
          resolveTheme(options.theme, options.systemTheme),
        );
        const neutralText = boxed
          ? options.colorTheme === 'custom'
            ? p.text
            : resolveTheme(options.theme, options.systemTheme) === 'light'
              ? (colorThemes[options.colorTheme]?.dark.text ?? palettes.dark.text)
              : boxTextColor(boxFill)
          : null;
        textBackground = boxed ? null : dayBackground;
        if (boxed)
          rect(
            dx + 4,
            cy - 11 * textScale - 2,
            cw - 8,
            card.height - 5 - 6 * (textScale - 1),
            boxFill,
            5,
          );
        if (!boxed && event.kind === 'presentation')
          rect(
            dx + 4,
            cy - 11 * textScale,
            3,
            card.height - 10 - 6 * (textScale - 1),
            neutralText || eventColor || p.accent,
            1,
          );
        if (boxed && event.kind === 'presentation')
          rect(
            dx + 9,
            cy - 11 * textScale + 3,
            3,
            card.height - 15 - 6 * (textScale - 1),
            neutralText,
            1,
          );
        if (card.time)
          text(
            dx + 12 + card.textInset,
            cy,
            card.time,
            11 * textScale,
            neutralText || eventColor || p.accent,
            500,
          );
        if (card.room.lines.length) {
          if (card.stackedRoom) {
            cy += 14 * textScale;
            text(
              dx + 12 + card.textInset,
              cy,
              card.room.lines[0],
              10.5 * textScale,
              neutralText || p.muted,
            );
          } else
            text(
              dx + cw - 16,
              cy,
              card.room.lines[0],
              10.5 * textScale,
              neutralText || p.muted,
              400,
              'end',
            );
          if (card.room.truncated) warnings.push(`${day.key}: full location is in the preview.`);
        }
        cy += card.metadataHeight;
        card.lines.forEach((t) => {
          text(
            dx + 12 + card.textInset,
            cy,
            t,
            titleSize,
            neutralText || eventColor || p.text,
            500,
          );
          cy += lineHeight;
        });
        cy += 4 + bottomPadding;
        textBackground = dayBackground;
        if (card.truncated) warnings.push(`${day.key}: full session title is in the preview.`);
      }
      textBackground = p.bg;
    });
    if (
      options.highlightToday !== false &&
      grid.columns === 5 &&
      (options.today === dayAdd(row[0].key, 5) || options.today === dayAdd(row[0].key, 6))
    ) {
      const dayName = weekday(options.today) === 5 ? 'Sat' : 'Sun';
      const label = `TODAY → ${dayName} ${fmt(options.today)}`;
      const badgeWidth = textWidth(label, 9) + 16;
      const badgeRight = W - right - 8;
      chunks.push('<g><title>Today is off-screen because weekends are hidden.</title>');
      rect(badgeRight - badgeWidth, rowY + 6, badgeWidth, 19, p.tint, 5);
      textBackground = p.tint;
      text(badgeRight - 8, rowY + 19, label, 9, p.accent, 600, 'end');
      textBackground = p.bg;
      chunks.push('</g>');
    }
    rowY += rh;
  });
  line(x, rowY, W - right, rowY);
  const footerY = H - padding.Bottom - legendHeight;
  for (const item of legend) text(item.x, footerY + item.row * 18, item.label, 11, item.color, 500);
  if (options.showSnapshotDate !== false) text(x, footerY, snapshotLabel, 10, p.muted);
  if (conflicts) text(W - right, footerY, conflictLabel, 10, p.muted, 400, 'end');
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${W} ${H}" role="img" aria-label="${escapeXml(title)} timetable"><title>${escapeXml(title)}</title><desc>${escapeXml(subtitle)}. ${grid.visible.length} calendar events.</desc><g font-family="Arial, Helvetica, sans-serif">${chunks.join('')}</g></svg>`;
  return {
    svg,
    grid,
    warnings: [...new Set(warnings)],
    bounds,
    placements,
    logicalWidth: W,
    logicalHeight: H,
  };
}
