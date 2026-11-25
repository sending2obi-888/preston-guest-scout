import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import {
  db,
  getSetting,
  setSetting,
  mapGuestRow,
  mapMatchRow,
  mapNotificationRow,
  formatVehicleTargetLabel,
} from './db.mjs';
import { normalizeGuestSpecs } from './preston_scraper.mjs';
import {
  queryAndSyncWithGoogleDrive,
  scheduleAutoSaveToGoogleDrive,
  getDriveSyncStatus,
  mergeRemoteSnapshotIntoLocal,
  exportLocalSnapshot,
} from './drive_sync.mjs';
import {
  getScheduleStatus,
  runSearchForGuest,
  runSearchForAllActiveGuests,
  startTwiceDailyScheduler,
} from './scheduler.mjs';
import { getCalendarStatus } from './calendar_sync.mjs';
import {
  ensureInitialServerBackup,
  listServerBackups,
  recordServerBackup,
  inspectServerBackupConflicts,
  restoreServerBackup,
} from './backups.mjs';
import {
  checkVinRecallsWithGemini,
  listRecentVinRecallChecks,
  scan2026NautilusHybridsRecallFree,
  updateVinRecallCampaignStatus,
} from './nhtsa_recall_agent.mjs';
import { findClosestEquivalentsFromDocument } from './document_equivalents_agent.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WEB_BUILD_DIR = path.resolve(__dirname, '../flutter_app/build/web');
const PORT = Number(process.env.PORT || 8080);

const MIME_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
};

function sendJson(res, status, payload) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  });
  res.end(JSON.stringify(payload));
}

function readJsonBody(req, maxBytes = 2 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > maxBytes) {
        reject(new Error('Payload too large'));
      }
    });
    req.on('end', () => {
      if (!raw.trim()) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(new Error('Invalid JSON payload'));
      }
    });
    req.on('error', reject);
  });
}

function buildNormalizedVehicleTarget(rawSpec, fallbackId, createdAtIso) {
  const features = Array.isArray(rawSpec.features)
    ? rawSpec.features.map((f) => String(f).trim()).filter(Boolean)
    : [];
  const normalized = normalizeGuestSpecs({
    make: (rawSpec.make || '').trim(),
    model: (rawSpec.model || '').trim(),
    trim: (rawSpec.trim || '').trim(),
    doors: (rawSpec.doors || '').trim(),
    bedLength: (rawSpec.bedLength || '').trim(),
    cabStyle: (rawSpec.cabStyle || '').trim(),
    engineSpec: (rawSpec.engineSpec || '').trim(),
    condition: rawSpec.condition || 'Any',
    drivetrain: rawSpec.drivetrain || 'Any',
    minYear: rawSpec.minYear ? Number(rawSpec.minYear) : null,
    maxYear: rawSpec.maxYear ? Number(rawSpec.maxYear) : null,
    maxPrice: rawSpec.maxPrice ? Number(rawSpec.maxPrice) : null,
    maxMileage: rawSpec.maxMileage ? Number(rawSpec.maxMileage) : null,
    exteriorColor: (rawSpec.exteriorColor || '').trim(),
    notes: (rawSpec.notes || '').trim(),
    features,
  });

  return {
    id: String(rawSpec.id || fallbackId),
    condition: normalized.condition || 'Any',
    minYear: normalized.minYear ?? null,
    maxYear: normalized.maxYear ?? null,
    make: normalized.make || '',
    model: normalized.model || '',
    trim: normalized.trim || '',
    doors: normalized.doors || '',
    bedLength: normalized.bedLength || '',
    cabStyle: normalized.cabStyle || '',
    engineSpec: normalized.engineSpec || '',
    maxPrice: normalized.maxPrice ?? null,
    maxMileage: normalized.maxMileage ?? null,
    drivetrain: normalized.drivetrain || 'Any',
    exteriorColor: normalized.exteriorColor || '',
    features,
    notes: (rawSpec.notes || '').trim(),
    createdAt: String(rawSpec.createdAt || createdAtIso),
  };
}

async function seedInitialGuestsIfEmpty() {
  const existingCount = db.prepare('SELECT COUNT(*) AS c FROM guests').get()?.c || 0;
  if (existingCount > 0) return;

  console.log('[Seed] Initializing sample Preston Automotive Group guests and fetching live matches...');
  const insertStmt = db.prepare(`
    INSERT INTO guests (
      id, name, phone, email, condition, min_year, max_year, make, model, trim,
      max_price, max_mileage, drivetrain, exterior_color, features_json, notes,
      active, created_at
    ) VALUES (
      @id, @name, @phone, @email, @condition, @min_year, @max_year, @make, @model, @trim,
      @max_price, @max_mileage, @drivetrain, @exterior_color, @features_json, @notes,
      1, @created_at
    )
  `);

  const now = Date.now();
  const sampleGuests = [
    {
      id: 'guest-rhonda-vanvorst',
      name: 'Rhonda Vanvorst',
      phone: '(302) 555-0148',
      email: 'rhonda.v@example.com',
      condition: 'Pre-Owned',
      min_year: 2020,
      max_year: 2024,
      make: 'Lincoln',
      model: 'Nautilus',
      trim: 'Reserve',
      max_price: 30000,
      max_mileage: 95000,
      drivetrain: 'AWD',
      exterior_color: '',
      features_json: JSON.stringify([
        'Leather Seats',
        'Navigation System',
        'Apple CarPlay',
        'Blind Spot Monitor',
        'Sunroof/Moonroof',
      ]),
      notes: 'Looking for a clean Pre-Owned or CPO Lincoln Nautilus Reserve with AWD, panoramic Vista Roof, and Co-Pilot360 safety features under $30,000.',
      created_at: new Date(now - 7200 * 1000).toISOString(),
    },
    {
      id: 'guest-devon-brooks',
      name: 'Devon Brooks',
      phone: '(410) 555-0192',
      email: 'dbrooks@example.com',
      condition: 'New',
      min_year: 2025,
      max_year: 2027,
      make: 'Ford',
      model: 'Bronco Sport',
      trim: 'Big Bend',
      max_price: 33000,
      max_mileage: null,
      drivetrain: '4WD',
      exterior_color: '',
      features_json: JSON.stringify([
        '4WD/AWD',
        'Apple CarPlay',
        'Android Auto',
        'Blind Spot Monitor',
        'Lane Keep Assist',
      ]),
      notes: 'Targeting a New Ford Bronco Sport Big Bend 4x4 with SYNC 4, heated seats or convenience package under $33,000.',
      created_at: new Date(now - 3600 * 1000).toISOString(),
    },
    {
      id: 'guest-marcus-vance',
      name: 'Marcus Vance',
      phone: '(410) 555-0177',
      email: 'mvance.fleet@example.com',
      condition: 'New',
      min_year: 2026,
      max_year: 2027,
      make: 'Ford',
      model: 'F-250',
      trim: 'XL',
      max_price: 60000,
      max_mileage: null,
      drivetrain: '4WD',
      exterior_color: 'White',
      features_json: JSON.stringify([
        '4WD',
        'Bluetooth',
        'Tow Hitch',
        'Backup Camera',
      ]),
      notes: 'SuperCab (X2B) 4WD work truck, 7.3L V8 gas preferred, Oxford White exterior.',
      created_at: new Date(now - 1200 * 1000).toISOString(),
    },
  ];

  for (const g of sampleGuests) {
    insertStmt.run(g);
  }

  // Kick off live prestonmotor.com initial search in background so startup is instant
  runSearchForAllActiveGuests('Initial Seed Search', null, {
    isInitialSearch: true,
    isSeedSearch: true,
  }).catch((err) => console.error('[Seed] Initial live search error:', err.message));
}

const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    });
    return res.end();
  }

  const parsedUrl = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  const pathname = parsedUrl.pathname;
  const authHeader = req.headers.authorization || '';
  const bearerToken = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';

  try {
    // Health & Scheduler Status
    if (pathname === '/api/status' && req.method === 'GET') {
      const totalGuests = db.prepare('SELECT COUNT(*) AS c FROM guests').get()?.c || 0;
      const totalMatches = db.prepare('SELECT COUNT(*) AS c FROM matches').get()?.c || 0;
      const driveStatus = await getDriveSyncStatus();
      return sendJson(res, 200, {
        ok: true,
        totalGuests,
        totalMatches,
        driveSync: driveStatus,
        ...getScheduleStatus(),
      });
    }

    // Google Drive Cloud Sync endpoints (queried every time app is opened + manual sync)
    if (pathname === '/api/drive-sync/status' && req.method === 'GET') {
      const status = await getDriveSyncStatus();
      return sendJson(res, 200, { ok: true, ...status });
    }

    if (pathname === '/api/drive-sync/sync' && req.method === 'POST') {
      const body = await readJsonBody(req);
      if (body.clientSnapshot && typeof body.clientSnapshot === 'object') {
        mergeRemoteSnapshotIntoLocal(body.clientSnapshot);
      }
      const token = bearerToken || (body.accessToken || '').trim();
      if (token) {
        setSetting('calendar_oauth_access_token', token);
      }
      const syncRes = await queryAndSyncWithGoogleDrive({
        bearerToken: token,
        pushAfterMerge: body.pushAfterMerge !== false,
        deviceLabel: body.deviceLabel || 'Preston Guest Scout Web',
      });
      const rows = db.prepare('SELECT * FROM guests ORDER BY created_at DESC').all();
      return sendJson(res, 200, {
        ...syncRes,
        guests: rows.map(mapGuestRow),
        snapshot: body.includeSnapshot ? exportLocalSnapshot('Preston Guest Scout Server') : undefined,
      });
    }

    // Settings GET / PUT (Gemini API key, model, timezone, Google OAuth Client ID)
    if (pathname === '/api/settings' && req.method === 'GET') {
      const rawKey = getSetting('gemini_api_key');
      return sendJson(res, 200, {
        geminiConfigured: Boolean(rawKey),
        geminiKeyMasked: rawKey
          ? `${rawKey.slice(0, 4)}••••••••${rawKey.slice(-4)}`
          : '',
        geminiModel: getSetting('gemini_model') || 'gemini-2.5-flash',
        timezone: getSetting('timezone') || 'America/New_York',
        googleOAuthClientId: getSetting('google_oauth_client_id') || '',
        morningSlot: '07:30',
        afternoonSlot: '14:00',
      });
    }

    if (pathname === '/api/settings' && (req.method === 'PUT' || req.method === 'POST')) {
      const body = await readJsonBody(req);
      if (typeof body.geminiApiKey === 'string') {
        setSetting('gemini_api_key', body.geminiApiKey.trim());
      }
      if (typeof body.geminiModel === 'string' && body.geminiModel.trim()) {
        setSetting('gemini_model', body.geminiModel.trim());
      }
      if (typeof body.timezone === 'string' && body.timezone.trim()) {
        setSetting('timezone', body.timezone.trim());
      }
      if (typeof body.googleOAuthClientId === 'string') {
        setSetting('google_oauth_client_id', body.googleOAuthClientId.trim());
      }
      scheduleAutoSaveToGoogleDrive(bearerToken);
      return sendJson(res, 200, {
        ok: true,
        geminiConfigured: Boolean(getSetting('gemini_api_key')),
        googleOAuthClientId: getSetting('google_oauth_client_id') || '',
      });
    }

    // Backups endpoints (Last 5 rolling backups + conflict detection + Overwrite/Duplicate restore)
    if (pathname === '/api/backups' && req.method === 'GET') {
      const backups = listServerBackups();
      return sendJson(res, 200, { ok: true, backups });
    }

    if (pathname === '/api/backups' && req.method === 'POST') {
      const body = await readJsonBody(req);
      const created = recordServerBackup({
        label: String(body.label || 'Manual Backup').trim() || 'Manual Backup',
        deviceLabel: String(body.deviceLabel || 'Preston Guest Scout Web'),
        force: true,
      });
      scheduleAutoSaveToGoogleDrive(bearerToken);
      return sendJson(res, 201, {
        ok: true,
        backup: created,
        backups: listServerBackups(),
      });
    }

    const backupRouteMatch = pathname.match(/^\/api\/backups\/([^/]+)\/([^/]+)$/);
    if (backupRouteMatch) {
      const backupId = decodeURIComponent(backupRouteMatch[1]);
      const action = backupRouteMatch[2];

      if (action === 'check-conflicts' && req.method === 'GET') {
        const preview = inspectServerBackupConflicts(backupId);
        return sendJson(res, 200, { ok: true, ...preview });
      }

      if (action === 'restore' && req.method === 'POST') {
        const body = await readJsonBody(req);
        try {
          const result = restoreServerBackup(backupId, {
            resolution: body.resolution || null,
          });
          scheduleAutoSaveToGoogleDrive(bearerToken);
          return sendJson(res, 200, {
            ok: true,
            result,
            backups: listServerBackups(),
          });
        } catch (err) {
          if (err.code === 'CONFLICT_RESOLUTION_REQUIRED') {
            const preview = inspectServerBackupConflicts(backupId);
            return sendJson(res, 409, {
              error: err.message,
              code: err.code,
              ...preview,
            });
          }
          throw err;
        }
      }
    }

    // Launcher Widget endpoint: strictly returns ONLY the last 10 guests input
    if (pathname === '/api/widget/recent-guests' && req.method === 'GET') {
      const rows = db
        .prepare('SELECT * FROM guests ORDER BY created_at DESC LIMIT 10')
        .all();
      const guests = rows.map(mapGuestRow);
      return sendJson(res, 200, {
        limit: 10,
        count: guests.length,
        guests: guests.map((g) => ({
          id: g.id,
          name: g.name,
          targetSummary: (g.vehicleTargets || [])
            .map(formatVehicleTargetLabel)
            .join(' + '),
          matchCount: g.matchCount,
          createdAt: g.createdAt,
        })),
      });
    }

    // List ALL guests (Unlimited guest inputs)
    if (pathname === '/api/guests' && req.method === 'GET') {
      const rows = db
        .prepare('SELECT * FROM guests ORDER BY created_at DESC')
        .all();
      return sendJson(res, 200, {
        guests: rows.map(mapGuestRow),
      });
    }

    // Create new guest + trigger initial Gemini Agent search on prestonmotor.com + auto-save to Drive
    if (pathname === '/api/guests' && req.method === 'POST') {
      const body = await readJsonBody(req);
      const name = (body.name || '').trim();
      if (!name) {
        return sendJson(res, 400, { error: 'Guest name is required.' });
      }

      const id = crypto.randomUUID();
      const nowIso = new Date().toISOString();

      let vehicleTargets = [];
      if (Array.isArray(body.vehicleTargets) && body.vehicleTargets.length > 0) {
        vehicleTargets = body.vehicleTargets.map((vt, idx) =>
          buildNormalizedVehicleTarget(vt, `${id}-vt-${idx + 1}`, nowIso)
        );
      } else {
        vehicleTargets = [
          buildNormalizedVehicleTarget(body, `${id}-primary`, nowIso),
        ];
      }
      const primary = vehicleTargets[0];

      db.prepare(`
        INSERT INTO guests (
          id, name, phone, email, condition, min_year, max_year, make, model, trim,
          max_price, max_mileage, drivetrain, exterior_color, features_json, notes,
          vehicle_targets_json, active, created_at, updated_at
        ) VALUES (
          @id, @name, @phone, @email, @condition, @min_year, @max_year, @make, @model, @trim,
          @max_price, @max_mileage, @drivetrain, @exterior_color, @features_json, @notes,
          @vehicle_targets_json, 1, @created_at, @updated_at
        )
      `).run({
        id,
        name,
        phone: (body.phone || '').trim(),
        email: (body.email || '').trim(),
        condition: primary.condition || 'Any',
        min_year: primary.minYear,
        max_year: primary.maxYear,
        make: primary.make || '',
        model: primary.model || '',
        trim: primary.trim || '',
        max_price: primary.maxPrice,
        max_mileage: primary.maxMileage,
        drivetrain: primary.drivetrain || 'Any',
        exterior_color: primary.exteriorColor || '',
        features_json: JSON.stringify(primary.features || []),
        notes: primary.notes || '',
        vehicle_targets_json: JSON.stringify(vehicleTargets),
        created_at: nowIso,
        updated_at: nowIso,
      });

      let searchResult = null;
      if (body.runImmediateSearch !== false) {
        try {
          searchResult = await runSearchForGuest(id, 'Initial Intake Search', {
            isInitialSearch: true,
            isSeedSearch: false,
            calendarAccessToken: bearerToken,
          });
        } catch (err) {
          searchResult = { error: err.message };
        }
      }

      recordServerBackup({
        label: `Auto-Backup • Added ${name}`,
      });
      scheduleAutoSaveToGoogleDrive(bearerToken);

      const created = mapGuestRow(
        db.prepare('SELECT * FROM guests WHERE id = ?').get(id)
      );
      return sendJson(res, 201, { guest: created, searchResult });
    }

    // Match Notifications endpoints (for new matches found AFTER the initial search)
    if (pathname === '/api/notifications' && req.method === 'GET') {
      const rows = db
        .prepare(
          'SELECT * FROM match_notifications ORDER BY created_at DESC LIMIT 100'
        )
        .all();
      const notifications = rows.map(mapNotificationRow);
      const unreadCount = notifications.filter((n) => !n.read).length;
      return sendJson(res, 200, { ok: true, unreadCount, notifications });
    }

    if (pathname === '/api/notifications/mark-read' && req.method === 'POST') {
      db.prepare('UPDATE match_notifications SET read = 1 WHERE read = 0').run();
      return sendJson(res, 200, { ok: true });
    }

    if (pathname === '/api/notifications' && req.method === 'DELETE') {
      db.prepare('DELETE FROM match_notifications').run();
      return sendJson(res, 200, { ok: true });
    }

    // Calendar Permissions & Same-Day "Call Guest" Event endpoints
    if (pathname === '/api/calendar/status' && req.method === 'GET') {
      const status = await getCalendarStatus();
      return sendJson(res, 200, { ok: true, ...status });
    }

    if (pathname === '/api/calendar/permission' && req.method === 'POST') {
      const body = await readJsonBody(req);
      if (typeof body.granted === 'boolean') {
        setSetting('calendar_permission_granted', body.granted ? '1' : '0');
        if (body.granted) {
          setSetting('calendar_prompt_dismissed', '1');
        }
      }
      if (typeof body.dismissed === 'boolean') {
        setSetting('calendar_prompt_dismissed', body.dismissed ? '1' : '0');
      }
      const token = bearerToken || (body.accessToken || '').trim();
      if (token) {
        setSetting('calendar_oauth_access_token', token);
      }
      if (typeof body.providerMode === 'string') {
        setSetting('calendar_provider_mode', body.providerMode.trim());
      }
      const status = await getCalendarStatus();
      return sendJson(res, 200, { ok: true, ...status });
    }

    if (pathname === '/api/calendar/events' && req.method === 'DELETE') {
      db.prepare('DELETE FROM calendar_call_events').run();
      return sendJson(res, 200, { ok: true });
    }

    // Trigger batch search across all active guests
    if (pathname === '/api/search-all' && req.method === 'POST') {
      const result = await runSearchForAllActiveGuests(
        'Manual All-Guests Search',
        null,
        { calendarAccessToken: bearerToken }
      );
      scheduleAutoSaveToGoogleDrive(bearerToken);
      return sendJson(res, 200, { ok: true, ...result });
    }

    // Single guest routes: /api/guests/:id, /api/guests/:id/matches, /api/guests/:id/search, /api/guests/:id/vehicles(/:targetId)
    const guestRouteMatch = pathname.match(
      /^\/api\/guests\/([^/]+)(?:\/([^/]+))?(?:\/([^/]+))?$/
    );
    if (guestRouteMatch) {
      const guestId = decodeURIComponent(guestRouteMatch[1]);
      const subResource = guestRouteMatch[2];
      const subId = guestRouteMatch[3] ? decodeURIComponent(guestRouteMatch[3]) : null;

      if (!subResource && req.method === 'GET') {
        const row = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        if (!row) return sendJson(res, 404, { error: 'Guest not found' });
        const matchRows = db
          .prepare(
            'SELECT * FROM matches WHERE guest_id = ? ORDER BY match_score DESC, found_at DESC'
          )
          .all(guestId);
        return sendJson(res, 200, {
          guest: mapGuestRow(row),
          matches: matchRows.map(mapMatchRow),
        });
      }

      if (!subResource && req.method === 'DELETE') {
        const preRow = db.prepare('SELECT name FROM guests WHERE id = ?').get(guestId);
        if (preRow?.name) {
          recordServerBackup({
            label: `Auto-Backup • Before Deleting ${preRow.name}`,
          });
        }
        const deletedIso = new Date().toISOString();
        db.prepare(
          `INSERT INTO deleted_guests (id, deleted_at) VALUES (?, ?)
           ON CONFLICT(id) DO UPDATE SET deleted_at = excluded.deleted_at`
        ).run(guestId, deletedIso);
        db.prepare('DELETE FROM guests WHERE id = ?').run(guestId);
        scheduleAutoSaveToGoogleDrive(bearerToken);
        return sendJson(res, 200, { ok: true });
      }

      if (!subResource && req.method === 'PATCH') {
        const body = await readJsonBody(req);
        if (typeof body.active === 'boolean') {
          db.prepare('UPDATE guests SET active = ?, updated_at = ? WHERE id = ?').run(
            body.active ? 1 : 0,
            new Date().toISOString(),
            guestId
          );
          scheduleAutoSaveToGoogleDrive(bearerToken);
        }
        const updated = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        return sendJson(res, 200, { guest: mapGuestRow(updated) });
      }

      if (subResource === 'matches' && !subId && req.method === 'GET') {
        const row = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        if (!row) return sendJson(res, 404, { error: 'Guest not found' });
        const matchRows = db
          .prepare(
            'SELECT * FROM matches WHERE guest_id = ? ORDER BY match_score DESC, found_at DESC'
          )
          .all(guestId);
        return sendJson(res, 200, {
          guest: mapGuestRow(row),
          matches: matchRows.map(mapMatchRow),
        });
      }

      if (
        subResource === 'matches' &&
        subId &&
        (req.method === 'PATCH' || req.method === 'POST')
      ) {
        const guestRow = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        if (!guestRow) return sendJson(res, 404, { error: 'Guest not found' });

        const targetMatch = db
          .prepare('SELECT * FROM matches WHERE guest_id = ? AND (vin = ? OR id = ?)')
          .get(guestId, subId, subId);
        if (!targetMatch) {
          return sendJson(res, 404, { error: 'Vehicle match not found' });
        }

        const body = await readJsonBody(req);
        const nextSelected =
          typeof body.selected === 'boolean'
            ? body.selected
            : typeof body.isSelectedCandidate === 'boolean'
              ? body.isSelectedCandidate
              : !Boolean(targetMatch.is_selected_candidate);
        const nowIso = new Date().toISOString();

        db.prepare(
          `UPDATE matches
              SET is_selected_candidate = ?,
                  selected_at = ?,
                  selected_updated_at = ?
            WHERE id = ?`
        ).run(
          nextSelected ? 1 : 0,
          nextSelected ? nowIso : null,
          nowIso,
          targetMatch.id
        );

        db.prepare('UPDATE guests SET updated_at = ? WHERE id = ?').run(nowIso, guestId);

        recordServerBackup({
          label: nextSelected
            ? `Auto-Backup • Selected ${targetMatch.title || targetMatch.vin}`
            : `Auto-Backup • Unselected ${targetMatch.title || targetMatch.vin}`,
        });
        scheduleAutoSaveToGoogleDrive(bearerToken);

        const updatedGuestRow = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        const matchRows = db
          .prepare(
            'SELECT * FROM matches WHERE guest_id = ? ORDER BY match_score DESC, found_at DESC'
          )
          .all(guestId);
        const updatedMatchRow = db
          .prepare('SELECT * FROM matches WHERE id = ?')
          .get(targetMatch.id);

        return sendJson(res, 200, {
          ok: true,
          guest: mapGuestRow(updatedGuestRow),
          matches: matchRows.map(mapMatchRow),
          match: mapMatchRow(updatedMatchRow),
        });
      }

      if (subResource === 'search' && !subId && req.method === 'POST') {
        const result = await runSearchForGuest(guestId, 'On-Demand Gemini Search', {
          calendarAccessToken: bearerToken,
        });
        const row = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        const matchRows = db
          .prepare(
            'SELECT * FROM matches WHERE guest_id = ? ORDER BY match_score DESC, found_at DESC'
          )
          .all(guestId);
        return sendJson(res, 200, {
          ok: true,
          result,
          guest: mapGuestRow(row),
          matches: matchRows.map(mapMatchRow),
        });
      }

      // Add an additional vehicle criteria target to an existing guest & immediately search prestonmotor.com
      if (subResource === 'vehicles' && !subId && req.method === 'POST') {
        const existingRow = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        if (!existingRow) return sendJson(res, 404, { error: 'Guest not found' });

        const body = await readJsonBody(req);
        const nowIso = new Date().toISOString();
        const currentGuest = mapGuestRow(existingRow);
        const newTarget = buildNormalizedVehicleTarget(
          body,
          `vt-${crypto.randomUUID()}`,
          nowIso
        );

        const hasAnyCriteria = Boolean(
          newTarget.make ||
            newTarget.model ||
            newTarget.trim ||
            newTarget.doors ||
            newTarget.bedLength ||
            newTarget.exteriorColor ||
            newTarget.maxPrice ||
            newTarget.minYear ||
            newTarget.maxYear ||
            newTarget.notes ||
            (newTarget.features && newTarget.features.length > 0) ||
            newTarget.condition !== 'Any' ||
            newTarget.drivetrain !== 'Any'
        );
        if (!hasAnyCriteria) {
          return sendJson(res, 400, {
            error: 'Please enter at least a make, model, budget, color, or requirement for the vehicle.',
          });
        }

        // Backfill target_id/target_label on legacy single-vehicle matches before adding 2nd vehicle
        if ((currentGuest.vehicleTargets || []).length === 1) {
          const primaryTarget = currentGuest.vehicleTargets[0];
          db.prepare(
            `UPDATE matches
             SET target_id = ?, target_label = ?
             WHERE guest_id = ? AND (target_id IS NULL OR target_id = '')`
          ).run(
            primaryTarget.id,
            formatVehicleTargetLabel(primaryTarget),
            guestId
          );
        }

        const updatedTargets = [...(currentGuest.vehicleTargets || []), newTarget];
        db.prepare(
          `UPDATE guests
           SET vehicle_targets_json = ?, updated_at = ?
           WHERE id = ?`
        ).run(JSON.stringify(updatedTargets), nowIso, guestId);

        let result = null;
        if (body.runImmediateSearch !== false) {
          result = await runSearchForGuest(
            guestId,
            `Added Vehicle Search (${formatVehicleTargetLabel(newTarget)})`,
            {
              onlyTargetId: newTarget.id,
              isInitialSearch: true,
              isSeedSearch: false,
              calendarAccessToken: bearerToken,
            }
          );
        }

        recordServerBackup({
          label: `Auto-Backup • Added Vehicle (${currentGuest.name})`,
        });
        scheduleAutoSaveToGoogleDrive(bearerToken);

        const row = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        const matchRows = db
          .prepare(
            'SELECT * FROM matches WHERE guest_id = ? ORDER BY match_score DESC, found_at DESC'
          )
          .all(guestId);

        return sendJson(res, 201, {
          ok: true,
          addedTarget: newTarget,
          result,
          guest: mapGuestRow(row),
          matches: matchRows.map(mapMatchRow),
        });
      }

      // Edit an existing vehicle search target on a guest after initial search & immediately re-search prestonmotor.com
      if (
        subResource === 'vehicles' &&
        subId &&
        (req.method === 'PUT' || req.method === 'PATCH')
      ) {
        const existingRow = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        if (!existingRow) return sendJson(res, 404, { error: 'Guest not found' });

        const currentGuest = mapGuestRow(existingRow);
        const currentTargets = [...(currentGuest.vehicleTargets || [])];
        let targetIdx = currentTargets.findIndex((t) => t.id === subId);
        if (targetIdx === -1 && currentTargets.length === 1) {
          targetIdx = 0;
        }
        if (targetIdx === -1) {
          return sendJson(res, 404, { error: 'Vehicle target not found on guest.' });
        }

        const existingTarget = currentTargets[targetIdx];
        const body = await readJsonBody(req);
        const nowIso = new Date().toISOString();

        const updatedTarget = buildNormalizedVehicleTarget(
          {
            ...body,
            id: existingTarget.id,
            createdAt: existingTarget.createdAt || currentGuest.createdAt,
          },
          existingTarget.id,
          existingTarget.createdAt || nowIso
        );

        const hasAnyCriteria = Boolean(
          updatedTarget.make ||
            updatedTarget.model ||
            updatedTarget.trim ||
            updatedTarget.doors ||
            updatedTarget.bedLength ||
            updatedTarget.exteriorColor ||
            updatedTarget.maxPrice ||
            updatedTarget.minYear ||
            updatedTarget.maxYear ||
            updatedTarget.notes ||
            (updatedTarget.features && updatedTarget.features.length > 0) ||
            updatedTarget.condition !== 'Any' ||
            updatedTarget.drivetrain !== 'Any'
        );
        if (!hasAnyCriteria) {
          return sendJson(res, 400, {
            error: 'Please enter at least a make, model, budget, color, or requirement for the vehicle.',
          });
        }

        currentTargets[targetIdx] = updatedTarget;
        const primary = currentTargets[0];

        // Clear stale matches belonging to this edited target (including legacy blank target_id when editing primary target)
        if (targetIdx === 0) {
          db.prepare(
            `DELETE FROM matches
             WHERE guest_id = ? AND (target_id = ? OR target_id IS NULL OR target_id = '')`
          ).run(guestId, existingTarget.id);
        } else {
          db.prepare('DELETE FROM matches WHERE guest_id = ? AND target_id = ?').run(
            guestId,
            existingTarget.id
          );
        }

        db.prepare(
          `UPDATE guests SET
             condition = ?, min_year = ?, max_year = ?, make = ?, model = ?, trim = ?,
             max_price = ?, max_mileage = ?, drivetrain = ?, exterior_color = ?,
             features_json = ?, notes = ?, vehicle_targets_json = ?, updated_at = ?
           WHERE id = ?`
        ).run(
          primary.condition || 'Any',
          primary.minYear,
          primary.maxYear,
          primary.make || '',
          primary.model || '',
          primary.trim || '',
          primary.maxPrice,
          primary.maxMileage,
          primary.drivetrain || 'Any',
          primary.exteriorColor || '',
          JSON.stringify(primary.features || []),
          primary.notes || '',
          JSON.stringify(currentTargets),
          nowIso,
          guestId
        );

        let result = null;
        if (body.runImmediateSearch !== false) {
          result = await runSearchForGuest(
            guestId,
            `Edited Search (${formatVehicleTargetLabel(updatedTarget)})`,
            {
              onlyTargetId: existingTarget.id,
              isInitialSearch: true,
              isSeedSearch: false,
              calendarAccessToken: bearerToken,
            }
          );
        }

        recordServerBackup({
          label: `Auto-Backup • Edited Search (${currentGuest.name})`,
        });
        scheduleAutoSaveToGoogleDrive(bearerToken);

        const row = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        const matchRows = db
          .prepare(
            'SELECT * FROM matches WHERE guest_id = ? ORDER BY match_score DESC, found_at DESC'
          )
          .all(guestId);

        return sendJson(res, 200, {
          ok: true,
          updatedTarget,
          result,
          guest: mapGuestRow(row),
          matches: matchRows.map(mapMatchRow),
        });
      }

      // Remove a specific vehicle target from an existing guest (requires >= 1 target remaining)
      if (subResource === 'vehicles' && subId && req.method === 'DELETE') {
        const existingRow = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        if (!existingRow) return sendJson(res, 404, { error: 'Guest not found' });

        const currentGuest = mapGuestRow(existingRow);
        const currentTargets = currentGuest.vehicleTargets || [];
        if (currentTargets.length <= 1) {
          return sendJson(res, 400, {
            error: 'A guest must have at least one vehicle target. Delete the guest instead if no longer needed.',
          });
        }

        const remaining = currentTargets.filter((t) => t.id !== subId);
        if (remaining.length === currentTargets.length) {
          return sendJson(res, 404, { error: 'Vehicle target not found on guest.' });
        }

        const primary = remaining[0];
        const nowIso = new Date().toISOString();

        db.prepare('DELETE FROM matches WHERE guest_id = ? AND target_id = ?').run(
          guestId,
          subId
        );

        db.prepare(
          `UPDATE guests SET
             condition = ?, min_year = ?, max_year = ?, make = ?, model = ?, trim = ?,
             max_price = ?, max_mileage = ?, drivetrain = ?, exterior_color = ?,
             features_json = ?, notes = ?, vehicle_targets_json = ?, updated_at = ?
           WHERE id = ?`
        ).run(
          primary.condition || 'Any',
          primary.minYear,
          primary.maxYear,
          primary.make || '',
          primary.model || '',
          primary.trim || '',
          primary.maxPrice,
          primary.maxMileage,
          primary.drivetrain || 'Any',
          primary.exteriorColor || '',
          JSON.stringify(primary.features || []),
          primary.notes || '',
          JSON.stringify(remaining),
          nowIso,
          guestId
        );

        recordServerBackup({
          label: `Auto-Backup • Removed Vehicle (${currentGuest.name})`,
        });
        scheduleAutoSaveToGoogleDrive(bearerToken);

        const row = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        const matchRows = db
          .prepare(
            'SELECT * FROM matches WHERE guest_id = ? ORDER BY match_score DESC, found_at DESC'
          )
          .all(guestId);

        return sendJson(res, 200, {
          ok: true,
          guest: mapGuestRow(row),
          matches: matchRows.map(mapMatchRow),
        });
      }

      // Add a dated client note to an existing guest + auto-save to Google Drive
      if (subResource === 'notes' && !subId && req.method === 'POST') {
        const existingRow = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        if (!existingRow) return sendJson(res, 404, { error: 'Guest not found' });

        const body = await readJsonBody(req);
        const text = String(body.text || '').trim();
        if (!text) {
          return sendJson(res, 400, { error: 'Note text cannot be empty.' });
        }

        const currentGuest = mapGuestRow(existingRow);
        const nowIso = new Date().toISOString();
        const newNote = {
          id: `note-${crypto.randomUUID()}`,
          text,
          createdAt: nowIso,
        };
        const updatedNotes = [newNote, ...(currentGuest.clientNotes || [])];

        db.prepare(
          'UPDATE guests SET client_notes_json = ?, updated_at = ? WHERE id = ?'
        ).run(JSON.stringify(updatedNotes), nowIso, guestId);

        recordServerBackup({
          label: `Auto-Backup • Added Note (${currentGuest.name})`,
        });
        scheduleAutoSaveToGoogleDrive(bearerToken);

        const row = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        return sendJson(res, 201, {
          ok: true,
          addedNote: newNote,
          guest: mapGuestRow(row),
        });
      }

      // Delete a specific client note from a guest + record tombstone for multi-device sync
      if (subResource === 'notes' && subId && req.method === 'DELETE') {
        const existingRow = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        if (!existingRow) return sendJson(res, 404, { error: 'Guest not found' });

        const currentGuest = mapGuestRow(existingRow);
        const nowIso = new Date().toISOString();
        const remainingNotes = (currentGuest.clientNotes || []).filter(
          (n) => n.id !== subId
        );
        const updatedDeletedIds = [
          ...new Set([...(currentGuest.deletedNoteIds || []), subId]),
        ];

        db.prepare(
          'UPDATE guests SET client_notes_json = ?, deleted_note_ids_json = ?, updated_at = ? WHERE id = ?'
        ).run(
          JSON.stringify(remainingNotes),
          JSON.stringify(updatedDeletedIds),
          nowIso,
          guestId
        );

        recordServerBackup({
          label: `Auto-Backup • Removed Note (${currentGuest.name})`,
        });
        scheduleAutoSaveToGoogleDrive(bearerToken);

        const row = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
        return sendJson(res, 200, {
          ok: true,
          guest: mapGuestRow(row),
        });
      }
    }

    // Single match detail route: /api/matches/:matchId
    const matchDetailRoute = pathname.match(/^\/api\/matches\/([^/]+)$/);
    if (matchDetailRoute && req.method === 'GET') {
      const matchId = decodeURIComponent(matchDetailRoute[1]);
      const row = db.prepare('SELECT * FROM matches WHERE id = ?').get(matchId);
      if (!row) return sendJson(res, 404, { error: 'Match not found' });
      const guestRow = db
        .prepare('SELECT * FROM guests WHERE id = ?')
        .get(row.guest_id);
      return sendJson(res, 200, {
        match: mapMatchRow(row),
        guest: mapGuestRow(guestRow),
      });
    }

    // NHTSA + Gemini VIN Recall Check endpoints (www.nhtsa.gov/recalls)
    if (pathname === '/api/recalls/recent' && req.method === 'GET') {
      return sendJson(res, 200, {
        ok: true,
        recent: listRecentVinRecallChecks(),
      });
    }

    if (pathname === '/api/recalls/check' && (req.method === 'POST' || req.method === 'GET')) {
      const body = req.method === 'POST' ? await readJsonBody(req) : {};
      const vin = String(body.vin || parsedUrl.searchParams.get('vin') || '').trim();
      try {
        const result = await checkVinRecallsWithGemini(vin);
        return sendJson(res, 200, {
          ok: true,
          result,
          recent: listRecentVinRecallChecks(),
        });
      } catch (err) {
        const code = Number(err.statusCode) || 500;
        return sendJson(res, code, {
          error: err.message || 'Unable to complete NHTSA VIN recall check.',
        });
      }
    }

    if (pathname === '/api/recalls/status' && (req.method === 'POST' || req.method === 'PATCH')) {
      const body = await readJsonBody(req);
      try {
        const result = await updateVinRecallCampaignStatus({
          vin: body.vin,
          campaignNumber: body.campaignNumber,
          status: body.status,
        });
        return sendJson(res, 200, {
          ok: true,
          result,
          recent: listRecentVinRecallChecks(),
        });
      } catch (err) {
        const code = Number(err.statusCode) || 500;
        return sendJson(res, code, {
          error: err.message || 'Unable to update recall completion status.',
        });
      }
    }

    if (
      pathname === '/api/recalls/nautilus-hybrids' &&
      (req.method === 'GET' || req.method === 'POST')
    ) {
      const body = req.method === 'POST' ? await readJsonBody(req) : {};
      const forceRefresh =
        body.forceRefresh === true ||
        parsedUrl.searchParams.get('refresh') === '1' ||
        parsedUrl.searchParams.get('forceRefresh') === 'true';
      try {
        const scan = await scan2026NautilusHybridsRecallFree({ forceRefresh });
        return sendJson(res, 200, { ok: true, ...scan });
      } catch (err) {
        const code = Number(err.statusCode) || 500;
        return sendJson(res, code, {
          error:
            err.message ||
            'Unable to scan 2026 Lincoln Nautilus Hybrid recall-free inventory.',
        });
      }
    }

    // Upload a guest/vehicle document & find closest equivalent vehicles across entire prestonmotor.com inventory
    if (pathname === '/api/intake/document-equivalents' && req.method === 'POST') {
      const body = await readJsonBody(req, 28 * 1024 * 1024);
      try {
        const result = await findClosestEquivalentsFromDocument({
          fileName: String(body.fileName || 'uploaded-document').trim(),
          mimeType: String(body.mimeType || '').trim(),
          base64Data: String(body.base64Data || ''),
          extraNotes: String(body.extraNotes || '').trim(),
        });
        return sendJson(res, 200, { ok: true, result });
      } catch (err) {
        const code = Number(err.statusCode) || 500;
        return sendJson(res, code, {
          error:
            err.message ||
            'Unable to analyze uploaded document for closest prestonmotor.com vehicles.',
        });
      }
    }

    // Safe image proxy strictly for prestonmotor.com vehicle photos (for Flutter Web CanvasKit CORS)
    if (pathname === '/api/image-proxy' && req.method === 'GET') {
      const targetUrl = parsedUrl.searchParams.get('url') || '';
      let parsedTarget;
      try {
        parsedTarget = new URL(targetUrl);
      } catch {
        res.writeHead(400);
        return res.end('Invalid URL');
      }
      if (!parsedTarget.hostname.endsWith('prestonmotor.com')) {
        res.writeHead(403);
        return res.end('Forbidden host');
      }

      const upstream = await fetch(parsedTarget.toString(), {
        headers: { 'User-Agent': 'Mozilla/5.0' },
        signal: AbortSignal.timeout(10000),
      });
      if (!upstream.ok) {
        res.writeHead(upstream.status);
        return res.end();
      }
      const buf = Buffer.from(await upstream.arrayBuffer());
      res.writeHead(200, {
        'Content-Type': upstream.headers.get('content-type') || 'image/jpeg',
        'Cache-Control': 'public, max-age=86400',
        'Access-Control-Allow-Origin': '*',
      });
      return res.end(buf);
    }

    // Direct download endpoint for compiled Android / Googlebook APK
    if (pathname === '/download/preston-guest-scout.apk' && (req.method === 'GET' || req.method === 'HEAD')) {
      const apkPath = path.resolve(__dirname, '../preston-guest-scout.apk');
      if (!fs.existsSync(apkPath)) {
        return sendJson(res, 404, { error: 'APK file not found' });
      }
      const stat = fs.statSync(apkPath);
      res.writeHead(200, {
        'Content-Type': 'application/vnd.android.package-archive',
        'Content-Disposition': 'attachment; filename="preston-guest-scout.apk"',
        'Content-Length': stat.size,
        'Access-Control-Allow-Origin': '*',
      });
      if (req.method === 'HEAD') return res.end();
      return fs.createReadStream(apkPath).pipe(res);
    }

    // Serve compiled Flutter Web static files
    if (fs.existsSync(WEB_BUILD_DIR)) {
      let safeRel = path.normalize(pathname).replace(/^(\.\.(\/|\\|$))+/, '');
      if (safeRel === '/' || safeRel === '') safeRel = '/index.html';
      let filePath = path.join(WEB_BUILD_DIR, safeRel);

      if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
        filePath = path.join(WEB_BUILD_DIR, 'index.html');
      }

      if (fs.existsSync(filePath)) {
        const ext = path.extname(filePath).toLowerCase();
        res.writeHead(200, {
          'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
          'Access-Control-Allow-Origin': '*',
        });
        return fs.createReadStream(filePath).pipe(res);
      }
    }

    sendJson(res, 404, { error: 'Not found' });
  } catch (err) {
    console.error('[Server Error]', err);
    sendJson(res, 500, { error: err.message || 'Internal server error' });
  }
});

await seedInitialGuestsIfEmpty();
ensureInitialServerBackup();
queryAndSyncWithGoogleDrive({
  pushAfterMerge: true,
  deviceLabel: 'Preston Guest Scout Server Startup',
}).catch((err) => console.error('[DriveSync] Startup sync warning:', err.message));
startTwiceDailyScheduler();

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Preston Guest Scout server listening on http://localhost:${PORT}`);
});
