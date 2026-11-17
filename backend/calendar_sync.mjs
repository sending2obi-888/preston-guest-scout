import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import crypto from 'node:crypto';
import {
  db,
  getSetting,
  extractVehicleModelLabel,
  mapCalendarEventRow,
} from './db.mjs';

const execFileAsync = promisify(execFile);

let cachedGcalAvailable = null;
let cachedGcalCheckedAt = 0;

export async function checkGcalendarCliAvailable() {
  const now = Date.now();
  if (cachedGcalAvailable !== null && now - cachedGcalCheckedAt < 30_000) {
    return cachedGcalAvailable;
  }
  try {
    const { stdout, stderr } = await execFileAsync('gcalendar', ['auth', 'status'], {
      timeout: 8000,
    });
    const combined = `${stdout || ''}\n${stderr || ''}`;
    cachedGcalAvailable = /Authentication Status:\s*Logged in/i.test(combined);
  } catch {
    cachedGcalAvailable = false;
  }
  cachedGcalCheckedAt = now;
  return cachedGcalAvailable;
}

function getZonedDateTimeParts(date, timeZone) {
  const safeTz = (() => {
    try {
      Intl.DateTimeFormat('en-US', { timeZone });
      return timeZone;
    } catch {
      return 'America/New_York';
    }
  })();

  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: safeTz,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
    timeZoneName: 'longOffset',
  });

  const parts = {};
  for (const p of fmt.formatToParts(date)) {
    parts[p.type] = p.value;
  }

  const hour = Number(parts.hour === '24' ? 0 : parts.hour);
  const minute = Number(parts.minute);
  const second = Number(parts.second);

  // Parse GMT-05:00 / GMT+02:00 / GMT -> RFC3339 offset
  let offsetStr = 'Z';
  let offsetMinutes = 0;
  const rawOffset = String(parts.timeZoneName || '');
  const m = rawOffset.match(/GMT([+-])(\d{1,2})(?::?(\d{2}))?/i);
  if (m) {
    const sign = m[1] === '-' ? -1 : 1;
    const hh = String(m[2]).padStart(2, '0');
    const mm = String(m[3] || '00').padStart(2, '0');
    offsetStr = `${m[1]}${hh}:${mm}`;
    offsetMinutes = sign * (Number(hh) * 60 + Number(mm));
  } else if (/^GMT$/i.test(rawOffset) || /^UTC$/i.test(rawOffset)) {
    offsetStr = '+00:00';
    offsetMinutes = 0;
  }

  return {
    timeZone: safeTz,
    year: Number(parts.year),
    month: Number(parts.month),
    day: Number(parts.day),
    dateStr: `${parts.year}-${parts.month}-${parts.day}`,
    hour,
    minute,
    second,
    offsetStr,
    offsetMinutes,
  };
}

function wallClockToEpochMs(year, month, day, hour, minute, timeZone) {
  // Initial guess using UTC, refined with actual zone offset at that instant
  const approxUtcMs = Date.UTC(year, month - 1, day, hour, minute, 0, 0);
  const p1 = getZonedDateTimeParts(new Date(approxUtcMs), timeZone);
  const refinedMs = approxUtcMs - p1.offsetMinutes * 60_000;
  const p2 = getZonedDateTimeParts(new Date(refinedMs), timeZone);
  return approxUtcMs - p2.offsetMinutes * 60_000;
}

function formatEpochAsRfc3339InZone(epochMs, timeZone) {
  const p = getZonedDateTimeParts(new Date(epochMs), timeZone);
  const yyyy = String(p.year).padStart(4, '0');
  const mo = String(p.month).padStart(2, '0');
  const dd = String(p.day).padStart(2, '0');
  const hh = String(p.hour).padStart(2, '0');
  const mi = String(p.minute).padStart(2, '0');
  const ss = String(p.second).padStart(2, '0');
  return `${yyyy}-${mo}-${dd}T${hh}:${mi}:${ss}${p.offsetStr}`;
}

/**
 * Computes a conflict-free 30-minute "Call Guest" slot strictly on THAT SAME DAY
 * in the configured timezone.
 */
export function computeSameDayCallSlot({
  now = new Date(),
  timeZone = 'America/New_York',
  busyIntervals = [],
} = {}) {
  const zonedNow = getZonedDateTimeParts(now, timeZone);
  const tz = zonedNow.timeZone;
  const { year, month, day, dateStr } = zonedNow;
  const nowMinutesOfDay = zonedNow.hour * 60 + zonedNow.minute;

  // Pick ideal start minute-of-day on the SAME calendar day:
  // - Early morning (< 9:30 AM, e.g. 7:30 AM scan): 10:00 AM today
  // - Business hours (9:30 AM - 5:00 PM, e.g. 2:00 PM scan): now + 30 min (rounded up to 15 min)
  // - Evening (5:00 PM - 11:15 PM): now + 15 min (rounded up to 5 min)
  // - Late night (11:15 PM - 11:59 PM): clamped inside today before 23:58
  let candidateStartMin;
  let durationMin = 30;

  if (nowMinutesOfDay < 9 * 60 + 30) {
    candidateStartMin = 10 * 60; // 10:00 AM same day
  } else if (nowMinutesOfDay <= 17 * 60) {
    const plus30 = nowMinutesOfDay + 30;
    candidateStartMin = Math.ceil(plus30 / 15) * 15;
  } else if (nowMinutesOfDay <= 23 * 60 + 15) {
    const plus15 = nowMinutesOfDay + 15;
    candidateStartMin = Math.ceil(plus15 / 5) * 5;
  } else {
    candidateStartMin = Math.min(nowMinutesOfDay + 1, 23 * 60 + 45);
    durationMin = Math.max(10, 23 * 60 + 58 - candidateStartMin);
  }

  // Latest start minute on the same day that keeps end <= 23:55
  const maxSameDayStartMin = Math.max(candidateStartMin, 23 * 60 + 25);
  const parsedBusy = busyIntervals
    .map((b) => ({
      startMs: new Date(b.start).getTime(),
      endMs: new Date(b.end).getTime(),
    }))
    .filter((b) => Number.isFinite(b.startMs) && Number.isFinite(b.endMs) && b.endMs > b.startMs);

  let chosenStartMs = wallClockToEpochMs(
    year,
    month,
    day,
    Math.floor(candidateStartMin / 60),
    candidateStartMin % 60,
    tz
  );
  let chosenEndMs = chosenStartMs + durationMin * 60_000;

  if (parsedBusy.length > 0) {
    const searchLimitMin = nowMinutesOfDay < 19 * 60 + 30 ? 19 * 60 + 30 : maxSameDayStartMin;
    for (let m = candidateStartMin; m <= searchLimitMin; m += 15) {
      const sMs = wallClockToEpochMs(year, month, day, Math.floor(m / 60), m % 60, tz);
      const eMs = sMs + durationMin * 60_000;
      const overlaps = parsedBusy.some((b) => sMs < b.endMs && eMs > b.startMs);
      if (!overlaps) {
        chosenStartMs = sMs;
        chosenEndMs = eMs;
        break;
      }
    }
  }

  return {
    eventDate: dateStr,
    timeZone: tz,
    startEpochMs: chosenStartMs,
    endEpochMs: chosenEndMs,
    startRfc3339: formatEpochAsRfc3339InZone(chosenStartMs, tz),
    endRfc3339: formatEpochAsRfc3339InZone(chosenEndMs, tz),
  };
}

export function buildGuestCallEventContent(guest, matchedVehicles = []) {
  const cleanName = String(guest?.name || 'Client').trim() || 'Client';
  const primaryVehicle = matchedVehicles[0] || {};
  const primaryModel = extractVehicleModelLabel(primaryVehicle);

  const title =
    matchedVehicles.length > 1
      ? `Call ${cleanName} — ${matchedVehicles.length} Vehicle Matches Found (${primaryModel})`
      : `Call ${cleanName} — Match Found: ${primaryModel}`;

  const lines = [
    `Same-day follow-up call scheduled automatically by Preston Motor Guest Scout.`,
    ``,
    `Client: ${cleanName}`,
  ];
  if (guest?.phone) lines.push(`Phone: ${guest.phone}`);
  if (guest?.email) lines.push(`Email: ${guest.email}`);
  if (Array.isArray(guest?.clientNotes) && guest.clientNotes.length > 0) {
    lines.push(`Latest Client Note: ${guest.clientNotes[0].text}`);
  }

  lines.push(``, `Matched Vehicle(s) Found Today (${matchedVehicles.length}):`);
  for (const v of matchedVehicles.slice(0, 8)) {
    const priceStr =
      v.price != null && Number(v.price) > 0
        ? `$${Number(v.price).toLocaleString()}`
        : 'Call for Price';
    const locStr = v.location || 'Preston Automotive Group';
    const stockStr = v.stockNumber ? ` • Stock #${v.stockNumber}` : '';
    lines.push(`• ${v.title || extractVehicleModelLabel(v)} — ${priceStr} at ${locStr}${stockStr}`);
    if (v.listingUrl) {
      lines.push(`  ${v.listingUrl}`);
    }
  }

  const vehicleSummary =
    matchedVehicles.length > 1
      ? `${primaryModel} (+${matchedVehicles.length - 1} more)`
      : primaryModel;

  return {
    title,
    description: lines.join('\n'),
    location: primaryVehicle.location || 'Preston Automotive Group',
    vehicleSummary,
  };
}

async function fetchBusyIntervalsViaOAuth(accessToken, dateStr, timeZone) {
  try {
    const dayStartMs = wallClockToEpochMs(
      Number(dateStr.slice(0, 4)),
      Number(dateStr.slice(5, 7)),
      Number(dateStr.slice(8, 10)),
      0,
      0,
      timeZone
    );
    const dayEndMs = dayStartMs + 24 * 3600 * 1000 - 1000;
    const url = new URL('https://www.googleapis.com/calendar/v3/calendars/primary/events');
    url.searchParams.set('singleEvents', 'true');
    url.searchParams.set('timeMin', new Date(dayStartMs).toISOString());
    url.searchParams.set('timeMax', new Date(dayEndMs).toISOString());
    url.searchParams.set('maxResults', '50');

    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!res.ok) return [];
    const data = await res.json();
    return (data.items || [])
      .filter((ev) => ev.status !== 'cancelled' && ev.start?.dateTime && ev.end?.dateTime)
      .map((ev) => ({ start: ev.start.dateTime, end: ev.end.dateTime }));
  } catch {
    return [];
  }
}

async function createEventViaOAuth({
  accessToken,
  title,
  description,
  location,
  startRfc3339,
  endRfc3339,
  timeZone,
}) {
  const res = await fetch(
    'https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=none',
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        summary: title,
        description,
        location,
        start: { dateTime: startRfc3339, timeZone },
        end: { dateTime: endRfc3339, timeZone },
        reminders: {
          useDefault: false,
          overrides: [{ method: 'popup', minutes: 15 }],
        },
      }),
    }
  );
  if (!res.ok) {
    throw new Error(`Google Calendar API HTTP ${res.status}`);
  }
  const data = await res.json();
  return {
    externalEventId: data.id || '',
    calendarLink: data.htmlLink || '',
    provider: 'google_calendar_oauth',
  };
}

async function fetchBusyIntervalsViaGcalendarCli(dateStr, timeZone) {
  try {
    const { stdout } = await execFileAsync(
      'gcalendar',
      ['readonly', 'events', '--date', dateStr, '--timezone', timeZone, '--max', '50', '--json'],
      { timeout: 12_000 }
    );
    const parsed = JSON.parse(stdout || '[]');
    const items = Array.isArray(parsed) ? parsed : parsed?.items || parsed?.events || [];
    return items
      .map((ev) => ({
        start: ev?.start?.dateTime || ev?.start || '',
        end: ev?.end?.dateTime || ev?.end || '',
      }))
      .filter((b) => typeof b.start === 'string' && b.start.includes('T') && typeof b.end === 'string');
  } catch {
    return [];
  }
}

async function createEventViaGcalendarCli({
  title,
  description,
  location,
  startRfc3339,
  endRfc3339,
  timeZone,
}) {
  const { stdout } = await execFileAsync(
    'gcalendar',
    [
      'mutate',
      'create',
      '--summary',
      title,
      '--description',
      description,
      '--location',
      location,
      '--start',
      startRfc3339,
      '--end',
      endRfc3339,
      '--send-updates',
      'none',
      '--timezone',
      timeZone,
      '--json',
    ],
    { timeout: 15_000 }
  );

  let externalEventId = '';
  let calendarLink = '';
  try {
    const parsed = JSON.parse(stdout || '{}');
    externalEventId = parsed.id || parsed.eventId || '';
    calendarLink = parsed.htmlLink || parsed.link || '';
  } catch {
    const linkMatch = String(stdout || '').match(/Link:\s*(\S+)/i);
    if (linkMatch) calendarLink = linkMatch[1];
  }
  return {
    externalEventId,
    calendarLink,
    provider: 'gcalendar_cli',
  };
}

const upsertCalendarEventStmt = db.prepare(`
  INSERT INTO calendar_call_events (
    id, guest_id, guest_name, guest_phone, event_date, start_at, end_at,
    title, description, location, vehicle_summary, external_event_id,
    calendar_link, provider, created_at
  ) VALUES (
    @id, @guest_id, @guest_name, @guest_phone, @event_date, @start_at, @end_at,
    @title, @description, @location, @vehicle_summary, @external_event_id,
    @calendar_link, @provider, @created_at
  )
  ON CONFLICT(guest_id, event_date) DO UPDATE SET
    title = excluded.title,
    description = excluded.description,
    location = excluded.location,
    vehicle_summary = excluded.vehicle_summary
`);

/**
 * Automatically creates (or updates if already scheduled earlier today) a same-day
 * calendar event to call the guest when a match is found and Calendar permission is granted.
 */
export async function scheduleSameDayGuestCallEvent({
  guest,
  matchedVehicles = [],
  accessToken = '',
} = {}) {
  if (!guest || !Array.isArray(matchedVehicles) || matchedVehicles.length === 0) {
    return { created: false, reason: 'NO_MATCHES' };
  }

  const permGranted = getSetting('calendar_permission_granted') === '1';
  if (!permGranted) {
    return { created: false, reason: 'CALENDAR_PERMISSION_NOT_GRANTED' };
  }

  const timeZone = getSetting('timezone') || 'America/New_York';
  const now = new Date();
  const todayParts = getZonedDateTimeParts(now, timeZone);
  const eventDate = todayParts.dateStr;

  // Check if a same-day call event was already created for this guest today
  const existingToday = db
    .prepare('SELECT * FROM calendar_call_events WHERE guest_id = ? AND event_date = ?')
    .get(guest.id, eventDate);

  // Gather all matched vehicles for this guest to produce a comprehensive call sheet
  const allGuestMatchRows = db
    .prepare('SELECT * FROM matches WHERE guest_id = ? ORDER BY match_score DESC, found_at DESC')
    .all(guest.id);
  const vehiclesForDescription =
    allGuestMatchRows.length > 0
      ? allGuestMatchRows.map((r) => ({
          vin: r.vin,
          stockNumber: r.stock_number,
          title: r.title,
          make: r.make,
          model: r.model,
          price: r.price,
          location: r.location,
          listingUrl: r.listing_url,
        }))
      : matchedVehicles;

  const content = buildGuestCallEventContent(guest, vehiclesForDescription);
  const localOnlyMode =
    getSetting('calendar_provider_mode') === 'local_only' ||
    process.env.PRESTON_CALENDAR_PROVIDER === 'local_only';

  if (existingToday) {
    if (
      !localOnlyMode &&
      existingToday.provider === 'gcalendar_cli' &&
      existingToday.external_event_id
    ) {
      try {
        await execFileAsync(
          'gcalendar',
          [
            'mutate',
            'update',
            existingToday.external_event_id,
            '--summary',
            content.title,
            '--description',
            content.description,
            '--send-updates',
            'none',
          ],
          { timeout: 12_000 }
        );
      } catch {}
    }

    db.prepare(
      `UPDATE calendar_call_events
       SET title = ?, description = ?, vehicle_summary = ?
       WHERE id = ?`
    ).run(content.title, content.description, content.vehicleSummary, existingToday.id);

    const updatedRow = db
      .prepare('SELECT * FROM calendar_call_events WHERE id = ?')
      .get(existingToday.id);
    return { created: false, updatedExisting: true, event: mapCalendarEventRow(updatedRow) };
  }

  let busyIntervals = [];
  const token = String(accessToken || getSetting('calendar_oauth_access_token') || '').trim();
  const gcalCliReady = !localOnlyMode && (await checkGcalendarCliAvailable());

  if (!localOnlyMode && token) {
    busyIntervals = await fetchBusyIntervalsViaOAuth(token, eventDate, todayParts.timeZone);
  } else if (gcalCliReady) {
    busyIntervals = await fetchBusyIntervalsViaGcalendarCli(eventDate, todayParts.timeZone);
  }

  const slot = computeSameDayCallSlot({
    now,
    timeZone: todayParts.timeZone,
    busyIntervals,
  });

  let externalInfo = {
    externalEventId: '',
    calendarLink: '',
    provider: 'in_app_calendar',
  };

  if (!localOnlyMode && token) {
    try {
      externalInfo = await createEventViaOAuth({
        accessToken: token,
        title: content.title,
        description: content.description,
        location: content.location,
        startRfc3339: slot.startRfc3339,
        endRfc3339: slot.endRfc3339,
        timeZone: slot.timeZone,
      });
    } catch (oauthErr) {
      if (gcalCliReady) {
        try {
          externalInfo = await createEventViaGcalendarCli({
            title: content.title,
            description: content.description,
            location: content.location,
            startRfc3339: slot.startRfc3339,
            endRfc3339: slot.endRfc3339,
            timeZone: slot.timeZone,
          });
        } catch (cliErr) {
          console.error('[Calendar] CLI fallback error:', cliErr.message);
        }
      } else {
        console.error('[Calendar] OAuth event create error:', oauthErr.message);
      }
    }
  } else if (gcalCliReady) {
    try {
      externalInfo = await createEventViaGcalendarCli({
        title: content.title,
        description: content.description,
        location: content.location,
        startRfc3339: slot.startRfc3339,
        endRfc3339: slot.endRfc3339,
        timeZone: slot.timeZone,
      });
    } catch (cliErr) {
      console.error('[Calendar] gcalendar create error:', cliErr.message);
    }
  }

  const eventId = `cal-${crypto.randomUUID()}`;
  const nowIso = now.toISOString();
  upsertCalendarEventStmt.run({
    id: eventId,
    guest_id: guest.id,
    guest_name: guest.name,
    guest_phone: guest.phone || '',
    event_date: slot.eventDate,
    start_at: slot.startRfc3339,
    end_at: slot.endRfc3339,
    title: content.title,
    description: content.description,
    location: content.location,
    vehicle_summary: content.vehicleSummary,
    external_event_id: externalInfo.externalEventId,
    calendar_link: externalInfo.calendarLink,
    provider: externalInfo.provider,
    created_at: nowIso,
  });

  const savedRow = db
    .prepare('SELECT * FROM calendar_call_events WHERE guest_id = ? AND event_date = ?')
    .get(guest.id, slot.eventDate);
  return { created: true, event: mapCalendarEventRow(savedRow) };
}

export async function getCalendarStatus() {
  const permissionGranted = getSetting('calendar_permission_granted') === '1';
  const promptDismissed = getSetting('calendar_prompt_dismissed') === '1';
  const gcalendarConnected = await checkGcalendarCliAvailable();
  const rows = db
    .prepare('SELECT * FROM calendar_call_events ORDER BY start_at DESC LIMIT 100')
    .all();
  return {
    permissionGranted,
    promptDismissed,
    gcalendarConnected,
    events: rows.map(mapCalendarEventRow),
  };
}
