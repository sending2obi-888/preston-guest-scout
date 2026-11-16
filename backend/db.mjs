import { DatabaseSync } from 'node:sqlite';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

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

  CREATE INDEX IF NOT EXISTS idx_guests_created_at ON guests(created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_matches_guest_id ON matches(guest_id, match_score DESC, found_at DESC);
  CREATE INDEX IF NOT EXISTS idx_runs_slot_key ON search_runs(slot_key);
`);

// Safe migrations for existing databases
for (const ddl of [
  `ALTER TABLE guests ADD COLUMN updated_at TEXT`,
  `ALTER TABLE guests ADD COLUMN vehicle_targets_json TEXT DEFAULT '[]'`,
  `ALTER TABLE guests ADD COLUMN client_notes_json TEXT DEFAULT '[]'`,
  `ALTER TABLE guests ADD COLUMN deleted_note_ids_json TEXT DEFAULT '[]'`,
  `ALTER TABLE matches ADD COLUMN target_id TEXT DEFAULT ''`,
  `ALTER TABLE matches ADD COLUMN target_label TEXT DEFAULT ''`,
]) {
  try {
    db.exec(ddl);
  } catch {
    // Column already exists
  }
}

const defaultSettings = {
  timezone: 'America/New_York',
  morning_slot: '07:30',
  afternoon_slot: '14:00',
  gemini_model: 'gemini-2.5-flash',
  gemini_api_key: process.env.GEMINI_API_KEY || '',
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

export function formatVehicleTargetLabel(t) {
  if (!t) return 'Custom Vehicle Requirements';
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
  if (parts.length === 0) {
    if (t.maxPrice) return `Vehicles under $${Number(t.maxPrice).toLocaleString()}`;
    if (t.notes) return String(t.notes).slice(0, 42);
    return 'Custom Vehicle Requirements';
  }
  return parts.join(' ');
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
    .map((t, idx) => ({
      id: String(t.id || `${row.id}-vt-${idx + 1}`),
      condition: String(t.condition || 'Any'),
      minYear: t.minYear != null ? Number(t.minYear) : null,
      maxYear: t.maxYear != null ? Number(t.maxYear) : null,
      make: String(t.make || ''),
      model: String(t.model || ''),
      trim: String(t.trim || ''),
      maxPrice: t.maxPrice != null ? Number(t.maxPrice) : null,
      maxMileage: t.maxMileage != null ? Number(t.maxMileage) : null,
      drivetrain: String(t.drivetrain || 'Any'),
      exteriorColor: String(t.exteriorColor || ''),
      features: Array.isArray(t.features) ? t.features.map(String) : [],
      notes: String(t.notes || ''),
      createdAt: String(t.createdAt || row.created_at),
    }));

  if (normalizedTargets.length === 0) {
    normalizedTargets.push({
      id: `${row.id}-primary`,
      condition: row.condition || 'Any',
      minYear: row.min_year ?? null,
      maxYear: row.max_year ?? null,
      make: row.make || '',
      model: row.model || '',
      trim: row.trim || '',
      maxPrice: row.max_price ?? null,
      maxMileage: row.max_mileage ?? null,
      drivetrain: row.drivetrain || 'Any',
      exteriorColor: row.exterior_color || '',
      features,
      notes: row.notes || '',
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
    maxPrice: primary.maxPrice,
    maxMileage: primary.maxMileage,
    drivetrain: primary.drivetrain || 'Any',
    exteriorColor: primary.exteriorColor || '',
    features: primary.features,
    notes: primary.notes || '',
    vehicleTargets: normalizedTargets,
    clientNotes,
    deletedNoteIds: [...deletedSet],
    active: Boolean(row.active),
    lastSearchedAt: row.last_searched_at,
    lastSearchSummary: row.last_search_summary || '',
    createdAt: row.created_at,
    updatedAt: row.updated_at || row.last_searched_at || row.created_at,
    matchCount: Number(matchStats?.count || 0),
    lowestMatchPrice: matchStats?.lowest_price ?? null,
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
