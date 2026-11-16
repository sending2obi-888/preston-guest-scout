import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { db, getSetting, setSetting, mapGuestRow, mapMatchRow } from './db.mjs';
import { normalizeGuestSpecs } from './preston_scraper.mjs';
import {
  queryAndSyncWithGoogleDrive,
  scheduleAutoSaveToGoogleDrive,
  getDriveSyncStatus,
} from './drive_sync.mjs';
import {
  getScheduleStatus,
  runSearchForGuest,
  runSearchForAllActiveGuests,
  startTwiceDailyScheduler,
} from './scheduler.mjs';

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

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', (chunk) => {
      raw += chunk;
      if (raw.length > 2 * 1024 * 1024) {
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
  runSearchForAllActiveGuests('7:30 AM Daily Search').catch((err) =>
    console.error('[Seed] Initial live search error:', err.message)
  );
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
      const token = bearerToken || (body.accessToken || '').trim();
      const syncRes = await queryAndSyncWithGoogleDrive({
        bearerToken: token,
        pushAfterMerge: body.pushAfterMerge !== false,
        deviceLabel: body.deviceLabel || 'Preston Guest Scout Web',
      });
      const rows = db.prepare('SELECT * FROM guests ORDER BY created_at DESC').all();
      return sendJson(res, 200, {
        ...syncRes,
        guests: rows.map(mapGuestRow),
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
          targetSummary: [
            g.condition !== 'Any' ? g.condition : null,
            g.minYear && g.maxYear
              ? `${g.minYear}–${g.maxYear}`
              : g.minYear || g.maxYear || null,
            g.make,
            g.model,
            g.trim,
          ]
            .filter(Boolean)
            .join(' '),
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
      const features = Array.isArray(body.features)
        ? body.features.map((f) => String(f).trim()).filter(Boolean)
        : [];
      const normalized = normalizeGuestSpecs({
        make: (body.make || '').trim(),
        model: (body.model || '').trim(),
        trim: (body.trim || '').trim(),
        condition: body.condition || 'Any',
        drivetrain: body.drivetrain || 'Any',
        maxPrice: body.maxPrice ? Number(body.maxPrice) : null,
        notes: (body.notes || '').trim(),
        features,
      });

      db.prepare(`
        INSERT INTO guests (
          id, name, phone, email, condition, min_year, max_year, make, model, trim,
          max_price, max_mileage, drivetrain, exterior_color, features_json, notes,
          active, created_at, updated_at
        ) VALUES (
          @id, @name, @phone, @email, @condition, @min_year, @max_year, @make, @model, @trim,
          @max_price, @max_mileage, @drivetrain, @exterior_color, @features_json, @notes,
          1, @created_at, @updated_at
        )
      `).run({
        id,
        name,
        phone: (body.phone || '').trim(),
        email: (body.email || '').trim(),
        condition: normalized.condition || 'Any',
        min_year: body.minYear ? Number(body.minYear) : null,
        max_year: body.maxYear ? Number(body.maxYear) : null,
        make: normalized.make || '',
        model: normalized.model || '',
        trim: normalized.trim || '',
        max_price: normalized.maxPrice ?? null,
        max_mileage: body.maxMileage ? Number(body.maxMileage) : null,
        drivetrain: normalized.drivetrain || 'Any',
        exterior_color: (body.exteriorColor || '').trim(),
        features_json: JSON.stringify(features),
        notes: (body.notes || '').trim(),
        created_at: nowIso,
        updated_at: nowIso,
      });

      let searchResult = null;
      if (body.runImmediateSearch !== false) {
        try {
          searchResult = await runSearchForGuest(id, 'Initial Intake Search');
        } catch (err) {
          searchResult = { error: err.message };
        }
      }

      scheduleAutoSaveToGoogleDrive(bearerToken);

      const created = mapGuestRow(
        db.prepare('SELECT * FROM guests WHERE id = ?').get(id)
      );
      return sendJson(res, 201, { guest: created, searchResult });
    }

    // Trigger batch search across all active guests
    if (pathname === '/api/search-all' && req.method === 'POST') {
      const result = await runSearchForAllActiveGuests('Manual All-Guests Search');
      scheduleAutoSaveToGoogleDrive(bearerToken);
      return sendJson(res, 200, { ok: true, ...result });
    }

    // Single guest routes: /api/guests/:id, /api/guests/:id/matches, /api/guests/:id/search
    const guestRouteMatch = pathname.match(/^\/api\/guests\/([^/]+)(?:\/([^/]+))?$/);
    if (guestRouteMatch) {
      const guestId = decodeURIComponent(guestRouteMatch[1]);
      const subResource = guestRouteMatch[2];

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

      if (subResource === 'matches' && req.method === 'GET') {
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

      if (subResource === 'search' && req.method === 'POST') {
        const result = await runSearchForGuest(guestId, 'On-Demand Gemini Search');
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
queryAndSyncWithGoogleDrive({
  pushAfterMerge: true,
  deviceLabel: 'Preston Guest Scout Server Startup',
}).catch((err) => console.error('[DriveSync] Startup sync warning:', err.message));
startTwiceDailyScheduler();

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Preston Guest Scout server listening on http://localhost:${PORT}`);
});
