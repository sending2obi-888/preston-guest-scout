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
    active INTEGER DEFAULT 1,
    last_searched_at TEXT,
    last_search_summary TEXT DEFAULT '',
    created_at TEXT NOT NULL
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

  CREATE INDEX IF NOT EXISTS idx_guests_created_at ON guests(created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_matches_guest_id ON matches(guest_id, match_score DESC, found_at DESC);
  CREATE INDEX IF NOT EXISTS idx_runs_slot_key ON search_runs(slot_key);
`);

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

export function mapGuestRow(row) {
  if (!row) return null;
  let features = [];
  try {
    features = JSON.parse(row.features_json || '[]');
  } catch {
    features = [];
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
    condition: row.condition || 'Any',
    minYear: row.min_year,
    maxYear: row.max_year,
    make: row.make || '',
    model: row.model || '',
    trim: row.trim || '',
    maxPrice: row.max_price,
    maxMileage: row.max_mileage,
    drivetrain: row.drivetrain || 'Any',
    exteriorColor: row.exterior_color || '',
    features,
    notes: row.notes || '',
    active: Boolean(row.active),
    lastSearchedAt: row.last_searched_at,
    lastSearchSummary: row.last_search_summary || '',
    createdAt: row.created_at,
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
  };
}
