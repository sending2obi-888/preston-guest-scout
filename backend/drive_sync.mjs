import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { db, getSetting, setSetting, mapGuestRow, mapMatchRow } from './db.mjs';

const execFileAsync = promisify(execFile);
export const DRIVE_SYNC_FILENAME = 'preston_guest_scout_cloud_sync.json';

let lastSyncedAt = null;
let lastPushedAt = null;
let lastSyncError = null;
let syncInFlight = null;
let autoPushTimer = null;
let cachedGdriveFileId = getSetting('drive_sync_file_id') || '';

let cachedConnectedUser = null;

async function checkGdriveCliAvailable() {
  try {
    const { stdout, stderr } = await execFileAsync('gdrive', ['auth', 'status'], {
      timeout: 8000,
    });
    const combined = `${stdout || ''}\n${stderr || ''}`;
    const available = /Authentication Status:\s*Logged in/i.test(combined);
    if (!available) {
      return { available: false, email: '', displayName: '', photoUrl: '' };
    }
    if (!cachedConnectedUser) {
      try {
        const { stdout: recentOut } = await execFileAsync(
          'gdrive',
          ['readonly', 'recent', '--max', '10', '--json'],
          { timeout: 10000 }
        );
        const files = JSON.parse(recentOut || '[]');
        const list = Array.isArray(files) ? files : files?.files || [];
        for (const f of list) {
          const meOwner = Array.isArray(f?.owners) ? f.owners.find((o) => o?.me) : null;
          if (meOwner?.emailAddress) {
            cachedConnectedUser = {
              email: meOwner.emailAddress,
              displayName: meOwner.displayName || meOwner.emailAddress,
              photoUrl: meOwner.photoLink || '',
            };
            break;
          }
        }
      } catch {}
    }
    return {
      available: true,
      email: cachedConnectedUser?.email || 'Connected Google Account',
      displayName: cachedConnectedUser?.displayName || 'Google Drive Connected',
      photoUrl: cachedConnectedUser?.photoUrl || '',
    };
  } catch {
    return { available: false, email: '', displayName: '', photoUrl: '' };
  }
}

export function exportLocalSnapshot(deviceLabel = 'Preston Guest Scout Server') {
  const guestRows = db.prepare('SELECT * FROM guests ORDER BY created_at DESC').all();
  const guests = guestRows.map(mapGuestRow);

  const matchRows = db
    .prepare('SELECT * FROM matches ORDER BY match_score DESC, found_at DESC')
    .all();
  const matches = matchRows.map((r) => {
    const m = mapMatchRow(r);
    return {
      ...m,
      allHighlights: (m.allHighlights || []).slice(0, 8),
    };
  });

  const deletedRows = db.prepare('SELECT id, deleted_at FROM deleted_guests').all();
  const deletedGuestIds = {};
  for (const r of deletedRows) {
    deletedGuestIds[r.id] = r.deleted_at;
  }

  return {
    schemaVersion: 2,
    updatedAt: new Date().toISOString(),
    updatedByDevice: deviceLabel,
    guests,
    deletedGuestIds,
    matches,
    settings: {
      geminiModel: getSetting('gemini_model') || 'gemini-2.5-flash',
      timezone: getSetting('timezone') || 'America/New_York',
      geminiApiKey: getSetting('gemini_api_key') || '',
    },
  };
}

/**
 * Merges a remote Google Drive snapshot into SQLite using conflict-free timestamps
 * and tombstones so guests/matches added or deleted on any device stay in sync.
 */
export function mergeRemoteSnapshotIntoLocal(remote) {
  if (!remote || typeof remote !== 'object') {
    return { mergedGuests: 0, mergedMatches: 0, localChanged: false };
  }

  let localChanged = false;
  const remoteDeleted =
    remote.deletedGuestIds && typeof remote.deletedGuestIds === 'object'
      ? remote.deletedGuestIds
      : {};

  db.exec('BEGIN IMMEDIATE');
  try {
    // 1. Apply remote tombstones
    const upsertDeletedStmt = db.prepare(
      `INSERT INTO deleted_guests (id, deleted_at) VALUES (?, ?)
       ON CONFLICT(id) DO UPDATE SET deleted_at = CASE
         WHEN excluded.deleted_at > deleted_guests.deleted_at THEN excluded.deleted_at
         ELSE deleted_guests.deleted_at
       END`
    );
    const deleteGuestStmt = db.prepare('DELETE FROM guests WHERE id = ?');

    for (const [delId, delIso] of Object.entries(remoteDeleted)) {
      if (!delId || !delIso) continue;
      upsertDeletedStmt.run(delId, String(delIso));
      const existing = db.prepare('SELECT created_at, updated_at FROM guests WHERE id = ?').get(delId);
      if (existing) {
        const localStamp = existing.updated_at || existing.created_at || '';
        if (String(delIso) >= localStamp) {
          deleteGuestStmt.run(delId);
          localChanged = true;
        }
      }
    }

    const allDeletedRows = db.prepare('SELECT id, deleted_at FROM deleted_guests').all();
    const localDeletedMap = new Map(allDeletedRows.map((r) => [r.id, r.deleted_at]));

    // 2. Merge remote guests (including conflict-free union merge of dated clientNotes & seenMatchVins)
    const upsertGuestStmt = db.prepare(`
      INSERT INTO guests (
        id, name, phone, email, condition, min_year, max_year, make, model, trim,
        max_price, max_mileage, drivetrain, exterior_color, features_json, notes,
        vehicle_targets_json, client_notes_json, deleted_note_ids_json,
        initial_search_completed, seen_match_vins_json,
        active, last_searched_at, last_search_summary, created_at, updated_at
      ) VALUES (
        @id, @name, @phone, @email, @condition, @min_year, @max_year, @make, @model, @trim,
        @max_price, @max_mileage, @drivetrain, @exterior_color, @features_json, @notes,
        @vehicle_targets_json, @client_notes_json, @deleted_note_ids_json,
        @initial_search_completed, @seen_match_vins_json,
        @active, @last_searched_at, @last_search_summary, @created_at, @updated_at
      )
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        phone = excluded.phone,
        email = excluded.email,
        condition = excluded.condition,
        min_year = excluded.min_year,
        max_year = excluded.max_year,
        make = excluded.make,
        model = excluded.model,
        trim = excluded.trim,
        max_price = excluded.max_price,
        max_mileage = excluded.max_mileage,
        drivetrain = excluded.drivetrain,
        exterior_color = excluded.exterior_color,
        features_json = excluded.features_json,
        notes = excluded.notes,
        vehicle_targets_json = CASE
          WHEN excluded.vehicle_targets_json != '[]' THEN excluded.vehicle_targets_json
          ELSE guests.vehicle_targets_json
        END,
        client_notes_json = excluded.client_notes_json,
        deleted_note_ids_json = excluded.deleted_note_ids_json,
        initial_search_completed = MAX(guests.initial_search_completed, excluded.initial_search_completed),
        seen_match_vins_json = excluded.seen_match_vins_json,
        active = excluded.active,
        last_searched_at = COALESCE(excluded.last_searched_at, guests.last_searched_at),
        last_search_summary = CASE
          WHEN excluded.last_search_summary != '' THEN excluded.last_search_summary
          ELSE guests.last_search_summary
        END,
        updated_at = excluded.updated_at
    `);

    const updateOnlyNotesStmt = db.prepare(
      'UPDATE guests SET client_notes_json = ?, deleted_note_ids_json = ?, initial_search_completed = MAX(initial_search_completed, ?), seen_match_vins_json = ?, updated_at = ? WHERE id = ?'
    );

    const mergeClientNotes = (localNotesArr, remoteNotesArr, localDelArr, remoteDelArr) => {
      const delSet = new Set([
        ...(Array.isArray(localDelArr) ? localDelArr.map(String) : []),
        ...(Array.isArray(remoteDelArr) ? remoteDelArr.map(String) : []),
      ]);
      const byId = new Map();
      for (const n of [
        ...(Array.isArray(localNotesArr) ? localNotesArr : []),
        ...(Array.isArray(remoteNotesArr) ? remoteNotesArr : []),
      ]) {
        if (!n || typeof n !== 'object') continue;
        const text = String(n.text || '').trim();
        const id = String(n.id || '');
        if (!id || !text || delSet.has(id)) continue;
        const createdAt = String(n.createdAt || new Date().toISOString());
        byId.set(id, { id, text, createdAt });
      }
      const notes = [...byId.values()].sort((a, b) =>
        b.createdAt.localeCompare(a.createdAt)
      );
      return { notes, deletedNoteIds: [...delSet] };
    };

    const remoteGuests = Array.isArray(remote.guests) ? remote.guests : [];
    for (const rg of remoteGuests) {
      if (!rg || !rg.id || !rg.name) continue;
      const rgStamp = rg.updatedAt || rg.lastSearchedAt || rg.createdAt || new Date().toISOString();
      const tomb = localDeletedMap.get(rg.id);
      if (tomb && tomb >= rgStamp) continue;

      const existing = db
        .prepare(
          'SELECT updated_at, last_searched_at, created_at, client_notes_json, deleted_note_ids_json, initial_search_completed, seen_match_vins_json FROM guests WHERE id = ?'
        )
        .get(rg.id);
      const localStamp = existing
        ? existing.updated_at || existing.last_searched_at || existing.created_at || ''
        : '';

      let localNotes = [];
      let localDelNotes = [];
      let localSeenVins = [];
      if (existing) {
        try {
          localNotes = JSON.parse(existing.client_notes_json || '[]');
        } catch {}
        try {
          localDelNotes = JSON.parse(existing.deleted_note_ids_json || '[]');
        } catch {}
        try {
          localSeenVins = JSON.parse(existing.seen_match_vins_json || '[]');
        } catch {}
      }

      const mergedSeenVins = [
        ...new Set([
          ...(Array.isArray(localSeenVins) ? localSeenVins.map(String) : []),
          ...(Array.isArray(rg.seenMatchVins) ? rg.seenMatchVins.map(String) : []),
        ].filter(Boolean)),
      ];
      const mergedInitialDone =
        Boolean(existing?.initial_search_completed) ||
        Boolean(existing?.last_searched_at) ||
        Boolean(rg.initialSearchCompleted) ||
        Boolean(rg.lastSearchedAt)
          ? 1
          : 0;

      const mergedNotes = mergeClientNotes(
        localNotes,
        rg.clientNotes,
        localDelNotes,
        rg.deletedNoteIds
      );

      if (!existing || rgStamp > localStamp) {
        const rgTargets = Array.isArray(rg.vehicleTargets) ? rg.vehicleTargets : [];
        upsertGuestStmt.run({
          id: String(rg.id),
          name: String(rg.name),
          phone: String(rg.phone || ''),
          email: String(rg.email || ''),
          condition: String(rg.condition || 'Any'),
          min_year: rg.minYear != null ? Number(rg.minYear) : null,
          max_year: rg.maxYear != null ? Number(rg.maxYear) : null,
          make: String(rg.make || ''),
          model: String(rg.model || ''),
          trim: String(rg.trim || ''),
          max_price: rg.maxPrice != null ? Number(rg.maxPrice) : null,
          max_mileage: rg.maxMileage != null ? Number(rg.maxMileage) : null,
          drivetrain: String(rg.drivetrain || 'Any'),
          exterior_color: String(rg.exteriorColor || ''),
          features_json: JSON.stringify(Array.isArray(rg.features) ? rg.features : []),
          notes: String(rg.notes || ''),
          vehicle_targets_json: JSON.stringify(rgTargets),
          client_notes_json: JSON.stringify(mergedNotes.notes),
          deleted_note_ids_json: JSON.stringify(mergedNotes.deletedNoteIds),
          initial_search_completed: mergedInitialDone,
          seen_match_vins_json: JSON.stringify(mergedSeenVins),
          active: rg.active === false ? 0 : 1,
          last_searched_at: rg.lastSearchedAt || null,
          last_search_summary: String(rg.lastSearchSummary || ''),
          created_at: String(rg.createdAt || rgStamp),
          updated_at: String(rgStamp),
        });
        localChanged = true;
      } else if (
        mergedNotes.notes.length !== (Array.isArray(localNotes) ? localNotes.length : 0) ||
        mergedNotes.deletedNoteIds.length !==
          (Array.isArray(localDelNotes) ? localDelNotes.length : 0) ||
        mergedSeenVins.length !== (Array.isArray(localSeenVins) ? localSeenVins.length : 0)
      ) {
        updateOnlyNotesStmt.run(
          JSON.stringify(mergedNotes.notes),
          JSON.stringify(mergedNotes.deletedNoteIds),
          mergedInitialDone,
          JSON.stringify(mergedSeenVins),
          localStamp > rgStamp ? localStamp : rgStamp,
          String(rg.id)
        );
        localChanged = true;
      }
    }

    // 3. Merge remote matches for active guests
    const activeGuestIds = new Set(
      db
        .prepare('SELECT id FROM guests')
        .all()
        .map((r) => r.id)
    );

    const existingMatches = db
      .prepare('SELECT guest_id, vin, found_at, last_seen_at FROM matches')
      .all();
    const localMatchMap = new Map(
      existingMatches.map((m) => [`${m.guest_id}::${m.vin}`, m])
    );

    const upsertMatchStmt = db.prepare(`
      INSERT INTO matches (
        id, guest_id, vin, stock_number, title, year, make, model, trim, condition,
        price, msrp, dealer_fee, location, mileage, drivetrain, engine,
        exterior_color, interior_color, photo_url, listing_url,
        matched_features_json, all_highlights_json, agent_summary, match_score,
        found_at, search_slot, last_seen_at, target_id, target_label
      ) VALUES (
        @id, @guest_id, @vin, @stock_number, @title, @year, @make, @model, @trim, @condition,
        @price, @msrp, @dealer_fee, @location, @mileage, @drivetrain, @engine,
        @exterior_color, @interior_color, @photo_url, @listing_url,
        @matched_features_json, @all_highlights_json, @agent_summary, @match_score,
        @found_at, @search_slot, @last_seen_at, @target_id, @target_label
      )
      ON CONFLICT(guest_id, vin) DO UPDATE SET
        price = excluded.price,
        msrp = excluded.msrp,
        dealer_fee = excluded.dealer_fee,
        location = excluded.location,
        mileage = excluded.mileage,
        photo_url = excluded.photo_url,
        listing_url = excluded.listing_url,
        matched_features_json = excluded.matched_features_json,
        all_highlights_json = excluded.all_highlights_json,
        agent_summary = excluded.agent_summary,
        match_score = excluded.match_score,
        found_at = CASE
          WHEN excluded.found_at < matches.found_at THEN excluded.found_at
          ELSE matches.found_at
        END,
        last_seen_at = excluded.last_seen_at,
        target_id = CASE
          WHEN excluded.target_id != '' THEN excluded.target_id
          ELSE matches.target_id
        END,
        target_label = CASE
          WHEN excluded.target_label != '' THEN excluded.target_label
          ELSE matches.target_label
        END
    `);

    const remoteMatches = Array.isArray(remote.matches) ? remote.matches : [];
    for (const rm of remoteMatches) {
      if (!rm || !rm.guestId || !rm.vin || !activeGuestIds.has(rm.guestId)) continue;
      const key = `${rm.guestId}::${rm.vin}`;
      const existing = localMatchMap.get(key);
      const rmSeen = rm.lastSeenAt || rm.foundAt || '';
      if (!existing || rmSeen > (existing.last_seen_at || '')) {
        upsertMatchStmt.run({
          id: String(rm.id || crypto.randomUUID()),
          guest_id: String(rm.guestId),
          vin: String(rm.vin),
          stock_number: String(rm.stockNumber || ''),
          title: String(rm.title || ''),
          year: rm.year != null ? Number(rm.year) : null,
          make: String(rm.make || ''),
          model: String(rm.model || ''),
          trim: String(rm.trim || ''),
          condition: String(rm.condition || ''),
          price: rm.price != null ? Number(rm.price) : null,
          msrp: rm.msrp != null ? Number(rm.msrp) : null,
          dealer_fee: rm.dealerFee != null ? Number(rm.dealerFee) : null,
          location: String(rm.location || 'Preston Automotive Group'),
          mileage: rm.mileage != null ? Number(rm.mileage) : 0,
          drivetrain: String(rm.drivetrain || ''),
          engine: String(rm.engine || ''),
          exterior_color: String(rm.exteriorColor || ''),
          interior_color: String(rm.interiorColor || ''),
          photo_url: String(rm.photoUrl || ''),
          listing_url: String(rm.listingUrl || 'https://www.prestonmotor.com'),
          matched_features_json: JSON.stringify(
            Array.isArray(rm.matchedFeatures) ? rm.matchedFeatures : []
          ),
          all_highlights_json: JSON.stringify(
            Array.isArray(rm.allHighlights) ? rm.allHighlights.slice(0, 8) : []
          ),
          agent_summary: String(rm.agentSummary || ''),
          match_score: rm.matchScore != null ? Number(rm.matchScore) : 85,
          found_at: String(rm.foundAt || rmSeen || new Date().toISOString()),
          search_slot: String(rm.searchSlot || 'Cloud Sync'),
          last_seen_at: String(rmSeen || new Date().toISOString()),
          target_id: String(rm.targetId || ''),
          target_label: String(rm.targetLabel || ''),
        });
        localChanged = true;
      }
    }

    // 4. Merge settings if remote provides non-empty values
    if (remote.settings && typeof remote.settings === 'object') {
      if (remote.settings.geminiApiKey && !getSetting('gemini_api_key')) {
        setSetting('gemini_api_key', String(remote.settings.geminiApiKey).trim());
        localChanged = true;
      }
      if (remote.settings.geminiModel) {
        setSetting('gemini_model', String(remote.settings.geminiModel).trim());
      }
      if (remote.settings.timezone) {
        setSetting('timezone', String(remote.settings.timezone).trim());
      }
    }

    db.exec('COMMIT');
  } catch (err) {
    try {
      db.exec('ROLLBACK');
    } catch {}
    throw err;
  }

  const totalGuests = db.prepare('SELECT COUNT(*) AS c FROM guests').get()?.c || 0;
  const totalMatches = db.prepare('SELECT COUNT(*) AS c FROM matches').get()?.c || 0;
  return { mergedGuests: totalGuests, mergedMatches: totalMatches, localChanged };
}

// --- Google Drive REST v3 Helpers (when Bearer token is supplied by Google SSO) ---

async function findDriveFileWithBearer(accessToken) {
  const q = encodeURIComponent(`name = '${DRIVE_SYNC_FILENAME}' and trashed = false`);
  const url = `https://www.googleapis.com/drive/v3/files?q=${q}&spaces=drive&fields=files(id,name,modifiedTime)&orderBy=modifiedTime%20desc&pageSize=5`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) {
    throw new Error(`Drive search HTTP ${res.status}`);
  }
  const data = await res.json();
  return data?.files?.[0] || null;
}

async function downloadDriveFileWithBearer(accessToken, fileId) {
  const url = `https://www.googleapis.com/drive/v3/files/${encodeURIComponent(fileId)}?alt=media`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
    signal: AbortSignal.timeout(20000),
  });
  if (!res.ok) {
    throw new Error(`Drive download HTTP ${res.status}`);
  }
  return res.json();
}

async function uploadDriveFileWithBearer(accessToken, existingFileId, snapshotObj) {
  const jsonBody = JSON.stringify(snapshotObj);
  if (existingFileId) {
    const url = `https://www.googleapis.com/upload/drive/v3/files/${encodeURIComponent(
      existingFileId
    )}?uploadType=media`;
    const res = await fetch(url, {
      method: 'PATCH',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json; charset=utf-8',
      },
      body: jsonBody,
      signal: AbortSignal.timeout(25000),
    });
    if (!res.ok) throw new Error(`Drive update HTTP ${res.status}`);
    return res.json();
  }

  const boundary = `preston_sync_${Date.now()}`;
  const metadata = JSON.stringify({
    name: DRIVE_SYNC_FILENAME,
    mimeType: 'application/json',
    description: 'Preston Motor Guest Scout multi-device search & vehicle match sync file',
  });
  const multipart =
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n` +
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${jsonBody}\r\n` +
    `--${boundary}--`;

  const res = await fetch(
    'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,modifiedTime',
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': `multipart/related; boundary=${boundary}`,
      },
      body: multipart,
      signal: AbortSignal.timeout(25000),
    }
  );
  if (!res.ok) throw new Error(`Drive create HTTP ${res.status}`);
  return res.json();
}

// --- Connected gdrive CLI Helpers (for seamless cloud workspace Drive sync) ---

async function findGdriveCliFileId() {
  if (cachedGdriveFileId) {
    try {
      await execFileAsync('gdrive', ['readonly', 'info', cachedGdriveFileId, '--json'], {
        timeout: 10000,
      });
      return cachedGdriveFileId;
    } catch {
      cachedGdriveFileId = '';
    }
  }

  const { stdout } = await execFileAsync(
    'gdrive',
    ['readonly', 'search', '--name-contains', DRIVE_SYNC_FILENAME, '--json'],
    { timeout: 15000 }
  );
  const parsed = JSON.parse(stdout || '[]');
  const list = Array.isArray(parsed) ? parsed : parsed?.files || [];
  const exact = list.find((f) => f?.name === DRIVE_SYNC_FILENAME && !f?.trashed);
  if (exact?.id) {
    cachedGdriveFileId = exact.id;
    setSetting('drive_sync_file_id', cachedGdriveFileId);
    return cachedGdriveFileId;
  }
  return '';
}

async function pullViaGdriveCli() {
  const fileId = await findGdriveCliFileId();
  if (!fileId) return null;
  const tmpFile = path.join(os.tmpdir(), `preston_pull_${Date.now()}_${process.pid}.json`);
  try {
    await execFileAsync('gdrive', ['readonly', 'download', fileId, '--out', tmpFile], {
      timeout: 20000,
    });
    const raw = fs.readFileSync(tmpFile, 'utf8');
    return JSON.parse(raw);
  } finally {
    try {
      fs.unlinkSync(tmpFile);
    } catch {}
  }
}

async function pushViaGdriveCli(snapshotObj) {
  let fileId = await findGdriveCliFileId();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'preston-drive-'));
  const tmpPath = path.join(tmpDir, DRIVE_SYNC_FILENAME);
  try {
    fs.writeFileSync(tmpPath, JSON.stringify(snapshotObj), 'utf8');
    if (fileId) {
      await execFileAsync(
        'gdrive',
        ['mutate', 'update', fileId, tmpPath, '--mime-type', 'application/json'],
        { timeout: 25000 }
      );
    } else {
      const { stdout } = await execFileAsync(
        'gdrive',
        ['mutate', 'upload', tmpPath, '--mime-type', 'application/json'],
        { timeout: 25000 }
      );
      try {
        const uploaded = JSON.parse(stdout || '{}');
        if (uploaded?.id) {
          fileId = uploaded.id;
        }
      } catch {}
      if (!fileId) {
        fileId = await findGdriveCliFileId();
      }
      if (fileId) {
        cachedGdriveFileId = fileId;
        setSetting('drive_sync_file_id', fileId);
      }
    }
    return fileId;
  } finally {
    try {
      fs.rmSync(tmpDir, { recursive: true, force: true });
    } catch {}
  }
}

/**
 * Queries Google Drive on app open (pull + conflict-free merge) and ensures Google Drive
 * holds the complete up-to-date multi-device snapshot.
 */
export async function queryAndSyncWithGoogleDrive({
  bearerToken = '',
  pushAfterMerge = true,
  deviceLabel = 'Preston Guest Scout Web',
} = {}) {
  if (syncInFlight) return syncInFlight;

  syncInFlight = (async () => {
    try {
      lastSyncError = null;
      if (bearerToken) {
        const remoteFile = await findDriveFileWithBearer(bearerToken);
        if (remoteFile?.id) {
          const remoteJson = await downloadDriveFileWithBearer(bearerToken, remoteFile.id);
          mergeRemoteSnapshotIntoLocal(remoteJson);
          if (pushAfterMerge) {
            const merged = exportLocalSnapshot(deviceLabel);
            await uploadDriveFileWithBearer(bearerToken, remoteFile.id, merged);
            lastPushedAt = merged.updatedAt;
          }
        } else {
          const initial = exportLocalSnapshot(deviceLabel);
          const created = await uploadDriveFileWithBearer(bearerToken, null, initial);
          if (created?.id) setSetting('drive_sync_file_id', created.id);
          lastPushedAt = initial.updatedAt;
        }
        lastSyncedAt = new Date().toISOString();
        return { ok: true, mode: 'google-sso-bearer', lastSyncedAt, lastPushedAt };
      }

      const cli = await checkGdriveCliAvailable();
      if (!cli.available) {
        return { ok: false, mode: 'unauthenticated', reason: 'Not signed in to Google Drive yet.' };
      }

      const remoteJson = await pullViaGdriveCli();
      if (remoteJson) {
        mergeRemoteSnapshotIntoLocal(remoteJson);
      }
      if (pushAfterMerge || !remoteJson) {
        const snapshot = exportLocalSnapshot(deviceLabel);
        await pushViaGdriveCli(snapshot);
        lastPushedAt = snapshot.updatedAt;
      }
      lastSyncedAt = new Date().toISOString();
      return {
        ok: true,
        mode: 'connected-google-drive',
        fileId: cachedGdriveFileId,
        lastSyncedAt,
        lastPushedAt,
      };
    } catch (err) {
      lastSyncError = err.message;
      return { ok: false, error: err.message };
    } finally {
      syncInFlight = null;
    }
  })();

  return syncInFlight;
}

/**
 * Automatically saves the latest guest & vehicle search info to Google Drive in the background
 * whenever guests, matches, or settings change.
 */
export function scheduleAutoSaveToGoogleDrive(bearerToken = '') {
  if (autoPushTimer) clearTimeout(autoPushTimer);
  autoPushTimer = setTimeout(() => {
    queryAndSyncWithGoogleDrive({
      bearerToken,
      pushAfterMerge: true,
      deviceLabel: 'Preston Guest Scout Auto-Save',
    }).catch((err) => console.error('[DriveSync] Auto-save error:', err.message));
  }, 600);
}

export async function getDriveSyncStatus() {
  const cli = await checkGdriveCliAvailable();
  return {
    connectedDriveAvailable: cli.available,
    connectedAccountEmail: cli.email || '',
    connectedAccountName: cli.displayName || '',
    connectedAccountPhotoUrl: cli.photoUrl || '',
    fileName: DRIVE_SYNC_FILENAME,
    fileId: cachedGdriveFileId || getSetting('drive_sync_file_id') || '',
    googleWebClientId: getSetting('google_oauth_client_id') || '',
    lastSyncedAt,
    lastPushedAt,
    lastSyncError,
  };
}
