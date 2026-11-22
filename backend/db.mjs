import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  formatBedLengthLabel,
  formatDoorsLabel,
  parseNaturalLanguageCriteria,
} from './natural_language_parser.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = path.join(__dirname, 'data');
fs.mkdirSync(DATA_DIR, { recursive: true });

const DB_PATH = path.join(DATA_DIR, 'preston_scout.db');
export const db = new DatabaseSync(DB_PATH);

db.exec(`
  PRAGMA journal_mode = WAL;
  PRAGMA foreign_keys = ON;

  CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS guests (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    phone TEXT DEFAULT '',
    email TEXT DEFAULT '',
    condition TEXT DEFAULT 'Any',
    min_year INTEGER,
    max_year INTEGER,
    make TEXT DEFAULT '',
    model TEXT DEFAULT '',
    trim TEXT DEFAULT '',
    max_price REAL,
    max_mileage INTEGER,
    drivetrain TEXT DEFAULT 'Any',
    exterior_color TEXT DEFAULT '',
      features_json TEXT DEFAULT '[]',
    notes TEXT DEFAULT '',
    vehicle_targets_json TEXT DEFAULT '[]',
    client_notes_json TEXT DEFAULT '[]',
    deleted_note_ids_json TEXT DEFAULT '[]',
    initial_search_completed INTEGER DEFAULT 0,
    seen_match_vins_json TEXT DEFAULT '[]',
    active INTEGER DEFAULT 1,
    last_searched_at TEXT,
    last_search_summary TEXT DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT
  );

  CREATE TABLE IF NOT EXISTS matches (
    id TEXT PRIMARY KEY,
    guest_id TEXT NOT NULL REFERENCES guests(id) ON DELETE CASCADE,
    vin TEXT NOT NULL,
    stock_number TEXT DEFAULT '',
    title TEXT NOT NULL,
    year INTEGER,
    make TEXT DEFAULT '',
    model TEXT DEFAULT '',
    trim TEXT DEFAULT '',
    condition TEXT DEFAULT '',
    price REAL,
    msrp REAL,
    dealer_fee REAL,
    location TEXT NOT NULL,
    mileage INTEGER,
    drivetrain TEXT DEFAULT '',
    engine TEXT DEFAULT '',
    exterior_color TEXT DEFAULT '',
    interior_color TEXT DEFAULT '',
    photo_url TEXT DEFAULT '',
    listing_url TEXT DEFAULT '',
    matched_features_json TEXT DEFAULT '[]',
    all_highlights_json TEXT DEFAULT '[]',
    agent_summary TEXT DEFAULT '',
    match_score INTEGER DEFAULT 85,
    found_at TEXT NOT NULL,
    search_slot TEXT DEFAULT 'Initial Search',
    last_seen_at TEXT NOT NULL,
    target_id TEXT DEFAULT '',
    target_label TEXT DEFAULT '',
    UNIQUE(guest_id, vin)
  );

  CREATE TABLE IF NOT EXISTS match_notifications (
    id TEXT PRIMARY KEY,
    guest_id TEXT NOT NULL REFERENCES guests(id) ON DELETE CASCADE,
    guest_name TEXT NOT NULL,
    vin TEXT NOT NULL,
    vehicle_model TEXT NOT NULL,
    message TEXT NOT NULL,
    location TEXT DEFAULT '',
    price REAL,
    created_at TEXT NOT NULL,
    read INTEGER DEFAULT 0,
    UNIQUE(guest_id, vin)
  );

  CREATE TABLE IF NOT EXISTS calendar_call_events (
    id TEXT PRIMARY KEY,
    guest_id TEXT NOT NULL REFERENCES guests(id) ON DELETE CASCADE,
    guest_name TEXT NOT NULL,
    guest_phone TEXT DEFAULT '',
    event_date TEXT NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT DEFAULT '',
    location TEXT DEFAULT '',
    vehicle_summary TEXT DEFAULT '',
    external_event_id TEXT DEFAULT '',
    calendar_link TEXT DEFAULT '',
    provider TEXT DEFAULT 'local',
    created_at TEXT NOT NULL,
    UNIQUE(guest_id, event_date)
  );

  CREATE TABLE IF NOT EXISTS search_runs (
    id TEXT PRIMARY KEY,
    guest_id TEXT,
    slot_key TEXT,
    slot_label TEXT NOT NULL,
    guests_checked INTEGER DEFAULT 0,
    candidates_scanned INTEGER DEFAULT 0,
    matches_found INTEGER DEFAULT 0,
    agent_mode TEXT DEFAULT 'gemini',
    started_at TEXT NOT NULL,
    completed_at TEXT,
    error TEXT
  );

  CREATE TABLE IF NOT EXISTS deleted_guests (
    id TEXT PRIMARY KEY,
    deleted_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS backups (
    id TEXT PRIMARY KEY,
    label TEXT NOT NULL,
    device_label TEXT DEFAULT '',
    signature TEXT DEFAULT '',
    guest_count INTEGER DEFAULT 0,
    match_count INTEGER DEFAULT 0,
    snapshot_json TEXT NOT NULL,
    created_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS vin_recall_checks (
    vin TEXT PRIMARY KEY,
    vehicle_title TEXT DEFAULT '',
    has_recalls INTEGER DEFAULT 0,
    recall_count INTEGER DEFAULT 0,
    incomplete_count INTEGER DEFAULT 0,
    complete_count INTEGER DEFAULT 0,
    verdict_headline TEXT DEFAULT '',
    result_json TEXT NOT NULL,
    checked_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS vin_recall_overrides (
    vin TEXT NOT NULL,
    campaign_number TEXT NOT NULL,
    status TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (vin, campaign_number)
  );

  CREATE INDEX IF NOT EXISTS idx_guests_created_at ON guests(created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_matches_guest_id ON matches(guest_id, match_score DESC, found_at DESC);
  CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON match_notifications(created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_calendar_events_start_at ON calendar_call_events(start_at DESC);
  CREATE INDEX IF NOT EXISTS idx_runs_slot_key ON search_runs(slot_key);
  CREATE INDEX IF NOT EXISTS idx_backups_created_at ON backups(created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_vin_recalls_checked_at ON vin_recall_checks(checked_at DESC);
`);

// Safe migrations for existing databases
for (const ddl of [
  `ALTER TABLE guests ADD COLUMN updated_at TEXT`,
  `ALTER TABLE guests ADD COLUMN vehicle_targets_json TEXT DEFAULT '[]'`,
  `ALTER TABLE guests ADD COLUMN client_notes_json TEXT DEFAULT '[]'`,
  `ALTER TABLE guests ADD COLUMN deleted_note_ids_json TEXT DEFAULT '[]'`,
  `ALTER TABLE guests ADD COLUMN initial_search_completed INTEGER DEFAULT 0`,
  `ALTER TABLE guests ADD COLUMN seen_match_vins_json TEXT DEFAULT '[]'`,
  `ALTER TABLE guests ADD COLUMN scheduled_call_vins_json TEXT DEFAULT '[]'`,
  `ALTER TABLE guests ADD COLUMN doors TEXT DEFAULT ''`,
  `ALTER TABLE matches ADD COLUMN target_id TEXT DEFAULT ''`,
  `ALTER TABLE matches ADD COLUMN target_label TEXT DEFAULT ''`,
  `ALTER TABLE vin_recall_checks ADD COLUMN incomplete_count INTEGER DEFAULT 0`,
  `ALTER TABLE vin_recall_checks ADD COLUMN complete_count INTEGER DEFAULT 0`,
]) {
  try {
    db.exec(ddl);
  } catch {
    // Column already exists
  }
}

// Backfill initial_search_completed for existing guests that already completed a search
try {
  db.exec(
    `UPDATE guests SET initial_search_completed = 1 WHERE last_searched_at IS NOT NULL AND initial_search_completed = 0`
  );
} catch {}

// Backfill scheduled_call_vins_json for already-seeded existing matches so old seed rows don't retroactively schedule
try {
  const existingGuests = db
    .prepare(`SELECT id, scheduled_call_vins_json FROM guests WHERE last_searched_at IS NOT NULL`)
    .all();
  const getVinsStmt = db.prepare(`SELECT vin FROM matches WHERE guest_id = ?`);
  const updateSchedStmt = db.prepare(`UPDATE guests SET scheduled_call_vins_json = ? WHERE id = ?`);
  for (const g of existingGuests) {
    let parsed = [];
    try {
      parsed = JSON.parse(g.scheduled_call_vins_json || '[]');
    } catch {}
    if (!Array.isArray(parsed) || parsed.length === 0) {
      const vins = getVinsStmt.all(g.id).map((r) => r.vin).filter(Boolean);
      if (vins.length > 0) {
        updateSchedStmt.run(JSON.stringify(vins), g.id);
      }
    }
  }
} catch {}

const defaultSettings = {
  timezone: 'America/New_York',
  morning_slot: '07:30',
  afternoon_slot: '14:00',
  gemini_model: 'gemini-2.5-flash',
  gemini_api_key: process.env.GEMINI_API_KEY || '',
  calendar_permission_granted: '0',
  calendar_prompt_dismissed: '0',
};

const insertDefault = db.prepare(
  'INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)'
);
for (const [k, v] of Object.entries(defaultSettings)) {
  insertDefault.run(k, v);
}

export function getSetting(key) {
  const row = db.prepare('SELECT value FROM settings WHERE key = ?').get(key);
  if (key === 'gemini_api_key') {
    return (row?.value || process.env.GEMINI_API_KEY || '').trim();
  }
  return row ? row.value : defaultSettings[key] ?? '';
}

export function setSetting(key, value) {
  db.prepare(
    'INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value'
  ).run(key, String(value ?? ''));
}

export function formatVehicleTargetLabel(rawTarget) {
  if (!rawTarget) return 'Custom Vehicle Requirements';
  const t = parseNaturalLanguageCriteria(rawTarget);
  const parts = [];
  if (t.condition && t.condition !== 'Any') parts.push(t.condition);
  if (t.minYear != null && t.maxYear != null) {
    parts.push(t.minYear === t.maxYear ? `${t.minYear}` : `${t.minYear}–${t.maxYear}`);
  } else if (t.minYear != null) {
    parts.push(`${t.minYear}+`);
  } else if (t.maxYear != null) {
    parts.push(`Up to ${t.maxYear}`);
  }
  if (t.make) parts.push(t.make);
  if (t.model) parts.push(t.model);
  if (t.trim) parts.push(t.trim);

  const qualifiers = [];
  if (t.doors) qualifiers.push(formatDoorsLabel(t.doors));
  if (t.cabStyle) qualifiers.push(t.cabStyle);
  if (t.bedLength) qualifiers.push(formatBedLengthLabel(t.bedLength));

  if (parts.length === 0 && qualifiers.length === 0) {
    if (t.maxPrice) return `Vehicles under $${Number(t.maxPrice).toLocaleString()}`;
    if (t.notes) return String(t.notes).slice(0, 42);
    return 'Custom Vehicle Requirements';
  }

  const base = parts.join(' ');
  if (qualifiers.length === 0) return base;
  if (!base) return qualifiers.join(' • ');
  return `${base} • ${qualifiers.join(' • ')}`;
}

export function mapGuestRow(row) {
  if (!row) return null;
  let features = [];
  try {
    features = JSON.parse(row.features_json || '[]');
  } catch {
    features = [];
  }

  let parsedTargets = [];
  try {
    parsedTargets = JSON.parse(row.vehicle_targets_json || '[]');
    if (!Array.isArray(parsedTargets)) parsedTargets = [];
  } catch {
    parsedTargets = [];
  }

  const normalizedTargets = parsedTargets
    .filter((t) => t && typeof t === 'object')
    .map((t, idx) => {
      const norm = parseNaturalLanguageCriteria(t);
      return {
        id: String(t.id || `${row.id}-vt-${idx + 1}`),
        condition: String(norm.condition || 'Any'),
        minYear: norm.minYear != null ? Number(norm.minYear) : null,
        maxYear: norm.maxYear != null ? Number(norm.maxYear) : null,
        make: String(norm.make || ''),
        model: String(norm.model || ''),
        trim: String(norm.trim || ''),
        doors: String(norm.doors || ''),
        bedLength: String(norm.bedLength || ''),
        cabStyle: String(norm.cabStyle || ''),
        engineSpec: String(norm.engineSpec || ''),
        maxPrice: norm.maxPrice != null ? Number(norm.maxPrice) : null,
        maxMileage: norm.maxMileage != null ? Number(norm.maxMileage) : null,
        drivetrain: String(norm.drivetrain || 'Any'),
        exteriorColor: String(norm.exteriorColor || ''),
        features: Array.isArray(norm.features) ? norm.features.map(String) : [],
        notes: String(norm.notes || ''),
        createdAt: String(t.createdAt || row.created_at),
      };
    });

  if (normalizedTargets.length === 0) {
    const normPrimary = parseNaturalLanguageCriteria({
      condition: row.condition || 'Any',
      minYear: row.min_year ?? null,
      maxYear: row.max_year ?? null,
      make: row.make || '',
      model: row.model || '',
      trim: row.trim || '',
      doors: row.doors || '',
      maxPrice: row.max_price ?? null,
      maxMileage: row.max_mileage ?? null,
      drivetrain: row.drivetrain || 'Any',
      exteriorColor: row.exterior_color || '',
      features,
      notes: row.notes || '',
    });
    normalizedTargets.push({
      id: `${row.id}-primary`,
      condition: normPrimary.condition || 'Any',
      minYear: normPrimary.minYear ?? null,
      maxYear: normPrimary.maxYear ?? null,
      make: normPrimary.make || '',
      model: normPrimary.model || '',
      trim: normPrimary.trim || '',
      doors: normPrimary.doors || '',
      bedLength: normPrimary.bedLength || '',
      cabStyle: normPrimary.cabStyle || '',
      engineSpec: normPrimary.engineSpec || '',
      maxPrice: normPrimary.maxPrice ?? null,
      maxMileage: normPrimary.maxMileage ?? null,
      drivetrain: normPrimary.drivetrain || 'Any',
      exteriorColor: normPrimary.exteriorColor || '',
      features: normPrimary.features,
      notes: normPrimary.notes || '',
      createdAt: row.created_at,
    });
  }

  const primary = normalizedTargets[0];

  let parsedClientNotes = [];
  try {
    parsedClientNotes = JSON.parse(row.client_notes_json || '[]');
    if (!Array.isArray(parsedClientNotes)) parsedClientNotes = [];
  } catch {
    parsedClientNotes = [];
  }

  let deletedNoteIds = [];
  try {
    deletedNoteIds = JSON.parse(row.deleted_note_ids_json || '[]');
    if (!Array.isArray(deletedNoteIds)) deletedNoteIds = [];
  } catch {
    deletedNoteIds = [];
  }
  const deletedSet = new Set(deletedNoteIds.map(String));

  const clientNotes = parsedClientNotes
    .filter((n) => n && typeof n === 'object' && String(n.text || '').trim().length > 0)
    .map((n, idx) => ({
      id: String(n.id || `${row.id}-note-${idx + 1}`),
      text: String(n.text || '').trim(),
      createdAt: String(n.createdAt || row.created_at),
    }))
    .filter((n) => !deletedSet.has(n.id))
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));

  let seenMatchVins = [];
  try {
    seenMatchVins = JSON.parse(row.seen_match_vins_json || '[]');
    if (!Array.isArray(seenMatchVins)) seenMatchVins = [];
  } catch {
    seenMatchVins = [];
  }

  let scheduledCallVins = [];
  try {
    scheduledCallVins = JSON.parse(row.scheduled_call_vins_json || '[]');
    if (!Array.isArray(scheduledCallVins)) scheduledCallVins = [];
  } catch {
    scheduledCallVins = [];
  }

  const matchStats = db
    .prepare(
      'SELECT COUNT(*) AS count, MIN(price) AS lowest_price FROM matches WHERE guest_id = ?'
    )
    .get(row.id);

  return {
    id: row.id,
    name: row.name,
    phone: row.phone || '',
    email: row.email || '',
    condition: primary.condition || 'Any',
    minYear: primary.minYear,
    maxYear: primary.maxYear,
    make: primary.make || '',
    model: primary.model || '',
    trim: primary.trim || '',
    doors: primary.doors || '',
    bedLength: primary.bedLength || '',
    cabStyle: primary.cabStyle || '',
    engineSpec: primary.engineSpec || '',
    maxPrice: primary.maxPrice,
    maxMileage: primary.maxMileage,
    drivetrain: primary.drivetrain || 'Any',
    exteriorColor: primary.exteriorColor || '',
    features: primary.features,
    notes: primary.notes || '',
    vehicleTargets: normalizedTargets,
    clientNotes,
    deletedNoteIds: [...deletedSet],
    initialSearchCompleted: Boolean(row.initial_search_completed || row.last_searched_at),
    seenMatchVins: [...new Set(seenMatchVins.map(String).filter(Boolean))],
    scheduledCallVins: [...new Set(scheduledCallVins.map(String).filter(Boolean))],
    active: Boolean(row.active),
    lastSearchedAt: row.last_searched_at,
    lastSearchSummary: row.last_search_summary || '',
    createdAt: row.created_at,
    updatedAt: row.updated_at || row.last_searched_at || row.created_at,
    matchCount: Number(matchStats?.count || 0),
    lowestMatchPrice: matchStats?.lowest_price ?? null,
  };
}

export function extractVehicleModelLabel({ make = '', model = '', title = '' } = {}) {
  const cleanMake = String(make || '').trim();
  const cleanModel = String(model || '').trim();
  if (cleanMake && cleanModel) {
    if (cleanModel.toLowerCase().startsWith(cleanMake.toLowerCase())) {
      return cleanModel;
    }
    return `${cleanMake} ${cleanModel}`;
  }
  if (cleanModel) return cleanModel;
  const cleanTitle = String(title || '').trim();
  if (cleanTitle) {
    const stripped = cleanTitle
      .replace(/^(?:new|used|pre-owned|certified(?:\s+pre-owned)?|cpo)\s+/i, '')
      .replace(/^\d{4}\s+/, '')
      .trim();
    if (stripped) return stripped;
    return cleanTitle;
  }
  if (cleanMake) return cleanMake;
  return 'Vehicle';
}

export function formatMatchNotificationMessage(clientName, vehicle = {}) {
  const cleanClient = String(clientName || 'Client').trim() || 'Client';
  const modelLabel = extractVehicleModelLabel(vehicle);
  return `${cleanClient} - Match Found - ${modelLabel}`;
}

export function mapNotificationRow(row) {
  if (!row) return null;
  return {
    id: row.id,
    guestId: row.guest_id,
    guestName: row.guest_name,
    vin: row.vin,
    vehicleModel: row.vehicle_model,
    message: row.message,
    location: row.location || '',
    price: row.price ?? null,
    createdAt: row.created_at,
    read: Boolean(row.read),
  };
}

export function mapCalendarEventRow(row) {
  if (!row) return null;
  return {
    id: row.id,
    guestId: row.guest_id,
    guestName: row.guest_name,
    guestPhone: row.guest_phone || '',
    eventDate: row.event_date,
    startAt: row.start_at,
    endAt: row.end_at,
    title: row.title,
    description: row.description || '',
    location: row.location || '',
    vehicleSummary: row.vehicle_summary || '',
    externalEventId: row.external_event_id || '',
    calendarLink: row.calendar_link || '',
    provider: row.provider || 'local',
    createdAt: row.created_at,
  };
}

export function mapMatchRow(row) {
  if (!row) return null;
  let matchedFeatures = [];
  let allHighlights = [];
  try {
    matchedFeatures = JSON.parse(row.matched_features_json || '[]');
  } catch {
    matchedFeatures = [];
  }
  try {
    allHighlights = JSON.parse(row.all_highlights_json || '[]');
  } catch {
    allHighlights = [];
  }

  return {
    id: row.id,
    guestId: row.guest_id,
    vin: row.vin,
    stockNumber: row.stock_number || '',
    title: row.title,
    year: row.year,
    make: row.make || '',
    model: row.model || '',
    trim: row.trim || '',
    condition: row.condition || '',
    price: row.price,
    msrp: row.msrp,
    dealerFee: row.dealer_fee,
    location: row.location,
    mileage: row.mileage,
    drivetrain: row.drivetrain || '',
    engine: row.engine || '',
    exteriorColor: row.exterior_color || '',
    interiorColor: row.interior_color || '',
    photoUrl: row.photo_url || '',
    listingUrl: row.listing_url || '',
    matchedFeatures,
    allHighlights,
    agentSummary: row.agent_summary || '',
    matchScore: row.match_score ?? 85,
    foundAt: row.found_at,
    searchSlot: row.search_slot || 'Scheduled Search',
    lastSeenAt: row.last_seen_at,
    targetId: row.target_id || '',
    targetLabel: row.target_label || '',
  };
}

