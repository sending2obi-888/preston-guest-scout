import crypto from 'node:crypto';
import {
  db,
  mapGuestRow,
  mapMatchRow,
  formatVehicleTargetLabel,
} from './db.mjs';

export const MAX_BACKUPS = 5;

function computeSnapshotSignature(guests, matches) {
  const gSig = [...guests]
    .map((g) => ({
      id: g.id,
      name: g.name,
      phone: g.phone || '',
      email: g.email || '',
      targets: (g.vehicleTargets || []).map((t) => ({
        id: t.id,
        condition: t.condition,
        minYear: t.minYear,
        maxYear: t.maxYear,
        make: t.make,
        model: t.model,
        trim: t.trim,
        doors: t.doors || '',
        bedLength: t.bedLength || '',
        cabStyle: t.cabStyle || '',
        maxPrice: t.maxPrice,
        maxMileage: t.maxMileage,
        drivetrain: t.drivetrain,
        exteriorColor: t.exteriorColor,
        features: t.features || [],
        notes: t.notes || '',
      })),
      notes: (g.clientNotes || []).map((n) => ({ id: n.id, text: n.text })),
    }))
    .sort((a, b) => String(a.id).localeCompare(String(b.id)));

  const mSig = [...matches]
    .map((m) => `${m.guestId}::${m.vin}::${m.price ?? ''}`)
    .sort();

  return crypto
    .createHash('sha1')
    .update(JSON.stringify({ gSig, mSig }))
    .digest('hex');
}

function buildGuestComparableSignature(g, matchCount) {
  return JSON.stringify({
    name: String(g.name || '').trim(),
    phone: String(g.phone || '').trim(),
    email: String(g.email || '').trim(),
    targets: (g.vehicleTargets || []).map((t) => ({
      condition: t.condition || 'Any',
      minYear: t.minYear ?? null,
      maxYear: t.maxYear ?? null,
      make: t.make || '',
      model: t.model || '',
      trim: t.trim || '',
      doors: t.doors || '',
      bedLength: t.bedLength || '',
      cabStyle: t.cabStyle || '',
      maxPrice: t.maxPrice ?? null,
      maxMileage: t.maxMileage ?? null,
      drivetrain: t.drivetrain || 'Any',
      exteriorColor: t.exteriorColor || '',
      features: t.features || [],
      notes: t.notes || '',
    })),
    notes: (g.clientNotes || []).map((n) => String(n.text || '').trim()),
    matchCount,
  });
}

function buildBackupEntrySummary(row) {
  let parsed = { guests: [], matches: [] };
  try {
    parsed = JSON.parse(row.snapshot_json || '{}');
  } catch {}
  const guests = Array.isArray(parsed.guests) ? parsed.guests : [];
  const matches = Array.isArray(parsed.matches) ? parsed.matches : [];
  const matchCountByGuest = new Map();
  for (const m of matches) {
    const gid = String(m?.guestId || '');
    if (!gid) continue;
    matchCountByGuest.set(gid, (matchCountByGuest.get(gid) || 0) + 1);
  }

  const guestsPreview = guests.map((g) => {
    const targets = Array.isArray(g.vehicleTargets) ? g.vehicleTargets : [];
    const targetSummary =
      targets.length > 0
        ? targets.map(formatVehicleTargetLabel).join(' + ')
        : formatVehicleTargetLabel(g);
    const notes = Array.isArray(g.clientNotes) ? g.clientNotes : [];
    return {
      id: String(g.id || ''),
      name: String(g.name || 'Guest'),
      phone: String(g.phone || ''),
      email: String(g.email || ''),
      targetSummary,
      noteCount: notes.length,
      matchCount: matchCountByGuest.get(String(g.id || '')) ?? Number(g.matchCount || 0),
    };
  });

  return {
    id: row.id,
    createdAt: row.created_at,
    label: row.label,
    deviceLabel: row.device_label || '',
    guestCount: guests.length,
    matchCount: matches.length,
    guestsPreview,
  };
}

function pruneToLastFiveBackups() {
  db.prepare(
    `DELETE FROM backups
     WHERE id NOT IN (
       SELECT id FROM backups ORDER BY created_at DESC LIMIT ?
     )`
  ).run(MAX_BACKUPS);
}

export function recordServerBackup({
  label = 'Auto-Backup',
  deviceLabel = 'Preston Guest Scout Server',
  force = false,
} = {}) {
  const guestRows = db
    .prepare('SELECT * FROM guests ORDER BY created_at DESC')
    .all();
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

  const signature = computeSnapshotSignature(guests, matches);

  if (!force) {
    const latest = db
      .prepare('SELECT id, signature FROM backups ORDER BY created_at DESC LIMIT 1')
      .get();
    if (latest && latest.signature === signature) {
      return null;
    }
  }

  const id = `backup-${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;
  const createdAt = new Date().toISOString();
  const snapshotJson = JSON.stringify({
    guests,
    matches,
  });

  db.prepare(
    `INSERT INTO backups (
       id, label, device_label, signature, guest_count, match_count, snapshot_json, created_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    id,
    String(label || 'Data Backup'),
    String(deviceLabel || 'Preston Guest Scout Server'),
    signature,
    guests.length,
    matches.length,
    snapshotJson,
    createdAt
  );

  pruneToLastFiveBackups();

  const inserted = db.prepare('SELECT * FROM backups WHERE id = ?').get(id);
  return inserted ? buildBackupEntrySummary(inserted) : null;
}

export function ensureInitialServerBackup() {
  const backupCount = db.prepare('SELECT COUNT(*) AS c FROM backups').get()?.c || 0;
  if (backupCount > 0) return;
  const guestCount = db.prepare('SELECT COUNT(*) AS c FROM guests').get()?.c || 0;
  if (guestCount === 0) return;
  recordServerBackup({
    label: 'Initial Data Backup',
    deviceLabel: 'Preston Guest Scout Server',
    force: true,
  });
}

export function listServerBackups() {
  ensureInitialServerBackup();
  const rows = db
    .prepare('SELECT * FROM backups ORDER BY created_at DESC LIMIT ?')
    .all(MAX_BACKUPS);
  return rows.map(buildBackupEntrySummary);
}

function findMatchingCurrentGuest(bg, currentGuests) {
  const bgId = String(bg.id || '').trim();
  const bgNameLower = String(bg.name || '').trim().toLowerCase();
  if (bgId) {
    const byId = currentGuests.find((cg) => String(cg.id || '') === bgId);
    if (byId) return byId;
  }
  if (bgNameLower) {
    const byName = currentGuests.find(
      (cg) => String(cg.name || '').trim().toLowerCase() === bgNameLower
    );
    if (byName) return byName;
  }
  return null;
}

export function inspectServerBackupConflicts(backupId) {
  const row = db.prepare('SELECT * FROM backups WHERE id = ?').get(backupId);
  if (!row) {
    throw new Error('Selected backup was not found.');
  }

  let parsed = { guests: [], matches: [] };
  try {
    parsed = JSON.parse(row.snapshot_json || '{}');
  } catch {}
  const backupGuests = Array.isArray(parsed.guests) ? parsed.guests : [];
  const backupMatches = Array.isArray(parsed.matches) ? parsed.matches : [];

  const backupMatchCountByGuest = new Map();
  for (const m of backupMatches) {
    const gid = String(m?.guestId || '');
    if (gid) {
      backupMatchCountByGuest.set(gid, (backupMatchCountByGuest.get(gid) || 0) + 1);
    }
  }

  const currentGuests = db
    .prepare('SELECT * FROM guests ORDER BY created_at DESC')
    .all()
    .map(mapGuestRow);

  const conflictingGuestNames = [];
  const modifiedConflictNames = [];
  const nonConflictingGuestNames = [];

  for (const bg of backupGuests) {
    if (!bg || !bg.name) continue;
    const match = findMatchingCurrentGuest(bg, currentGuests);
    if (match) {
      conflictingGuestNames.push(String(bg.name));
      const bSig = buildGuestComparableSignature(
        bg,
        backupMatchCountByGuest.get(String(bg.id || '')) ?? Number(bg.matchCount || 0)
      );
      const cSig = buildGuestComparableSignature(match, Number(match.matchCount || 0));
      if (bSig !== cSig) {
        modifiedConflictNames.push(String(bg.name));
      }
    } else {
      nonConflictingGuestNames.push(String(bg.name));
    }
  }

  return {
    backup: buildBackupEntrySummary(row),
    hasConflicts: conflictingGuestNames.length > 0,
    conflictingGuestNames,
    modifiedConflictNames,
    nonConflictingGuestNames,
  };
}

function makeUniqueDuplicateName(baseName, takenLowerSet) {
  const clean = String(baseName || 'Guest').trim();
  const firstCandidate = `${clean} (Copy)`;
  if (!takenLowerSet.has(firstCandidate.toLowerCase())) {
    takenLowerSet.add(firstCandidate.toLowerCase());
    return firstCandidate;
  }
  let idx = 2;
  while (idx < 1000) {
    const candidate = `${clean} (Copy ${idx})`;
    if (!takenLowerSet.has(candidate.toLowerCase())) {
      takenLowerSet.add(candidate.toLowerCase());
      return candidate;
    }
    idx++;
  }
  return `${clean} (${Date.now()})`;
}

export function restoreServerBackup(backupId, { resolution = null } = {}) {
  const row = db.prepare('SELECT * FROM backups WHERE id = ?').get(backupId);
  if (!row) {
    throw new Error('Selected backup was not found.');
  }

  let parsed = { guests: [], matches: [] };
  try {
    parsed = JSON.parse(row.snapshot_json || '{}');
  } catch {}
  const backupGuests = Array.isArray(parsed.guests) ? parsed.guests : [];
  const backupMatches = Array.isArray(parsed.matches) ? parsed.matches : [];

  const currentGuests = db
    .prepare('SELECT * FROM guests ORDER BY created_at DESC')
    .all()
    .map(mapGuestRow);

  const conflicts = backupGuests.filter(
    (bg) => bg && bg.name && findMatchingCurrentGuest(bg, currentGuests)
  );

  const normRes = String(resolution || '').trim().toLowerCase();
  if (conflicts.length > 0 && normRes !== 'overwrite' && normRes !== 'duplicate') {
    const err = new Error(
      'Conflicting guest entries exist. Please choose Overwrite or Duplicate.'
    );
    err.code = 'CONFLICT_RESOLUTION_REQUIRED';
    throw err;
  }

  // Save a non-forced pre-restore snapshot if current state differs from latest backup
  if (currentGuests.length > 0) {
    recordServerBackup({
      label: 'Auto-Backup • Pre-Restore Snapshot',
      deviceLabel: 'Preston Guest Scout Server',
      force: false,
    });
  }

  const nowIso = new Date().toISOString();
  const takenLowerNames = new Set(
    currentGuests.map((g) => String(g.name || '').trim().toLowerCase()).filter(Boolean)
  );

  let restoredGuests = 0;
  let overwrittenGuests = 0;
  let duplicatedGuests = 0;

  const matchesByGuestId = new Map();
  for (const m of backupMatches) {
    const gid = String(m?.guestId || '');
    if (!gid) continue;
    if (!matchesByGuestId.has(gid)) matchesByGuestId.set(gid, []);
    matchesByGuestId.get(gid).push(m);
  }

  const upsertGuestStmt = db.prepare(`
    INSERT INTO guests (
      id, name, phone, email, condition, min_year, max_year, make, model, trim,
      max_price, max_mileage, drivetrain, exterior_color, features_json, notes,
      vehicle_targets_json, client_notes_json, deleted_note_ids_json,
      initial_search_completed, seen_match_vins_json, scheduled_call_vins_json,
      active, last_searched_at, last_search_summary, created_at, updated_at
    ) VALUES (
      @id, @name, @phone, @email, @condition, @min_year, @max_year, @make, @model, @trim,
      @max_price, @max_mileage, @drivetrain, @exterior_color, @features_json, @notes,
      @vehicle_targets_json, @client_notes_json, @deleted_note_ids_json,
      @initial_search_completed, @seen_match_vins_json, @scheduled_call_vins_json,
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
      vehicle_targets_json = excluded.vehicle_targets_json,
      client_notes_json = excluded.client_notes_json,
      deleted_note_ids_json = excluded.deleted_note_ids_json,
      initial_search_completed = excluded.initial_search_completed,
      seen_match_vins_json = excluded.seen_match_vins_json,
      scheduled_call_vins_json = excluded.scheduled_call_vins_json,
      active = excluded.active,
      last_searched_at = excluded.last_searched_at,
      last_search_summary = excluded.last_search_summary,
      updated_at = excluded.updated_at
  `);

  const insertMatchStmt = db.prepare(`
    INSERT OR REPLACE INTO matches (
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
  `);

  const deleteTombstoneStmt = db.prepare('DELETE FROM deleted_guests WHERE id = ?');
  const deleteMatchesForGuestStmt = db.prepare('DELETE FROM matches WHERE guest_id = ?');
  const deleteGuestByIdStmt = db.prepare('DELETE FROM guests WHERE id = ?');

  db.exec('BEGIN IMMEDIATE');
  try {
    for (const bg of backupGuests) {
      if (!bg || !bg.name) continue;
      const origId = String(bg.id || crypto.randomUUID());
      const guestMatches = matchesByGuestId.get(origId) || [];
      const existing = findMatchingCurrentGuest(bg, currentGuests);

      let targetGuestId = origId;
      let targetName = String(bg.name).trim();
      let createdAtToUse = String(bg.createdAt || nowIso);
      const targetIdRemap = new Map();

      if (!existing) {
        restoredGuests++;
        takenLowerNames.add(targetName.toLowerCase());
        deleteTombstoneStmt.run(targetGuestId);
      } else if (normRes === 'overwrite') {
        overwrittenGuests++;
        targetGuestId = String(existing.id);
        deleteTombstoneStmt.run(targetGuestId);
        deleteTombstoneStmt.run(origId);
        if (origId !== targetGuestId) {
          deleteGuestByIdStmt.run(origId);
        }
        deleteMatchesForGuestStmt.run(targetGuestId);
      } else {
        // duplicate
        duplicatedGuests++;
        targetGuestId = `guest-dup-${crypto.randomUUID()}`;
        targetName = makeUniqueDuplicateName(bg.name, takenLowerNames);
        createdAtToUse = nowIso;
      }

      const rawTargets = Array.isArray(bg.vehicleTargets) && bg.vehicleTargets.length > 0
        ? bg.vehicleTargets
        : [
            {
              id: `${targetGuestId}-primary`,
              condition: bg.condition || 'Any',
              minYear: bg.minYear ?? null,
              maxYear: bg.maxYear ?? null,
              make: bg.make || '',
              model: bg.model || '',
              trim: bg.trim || '',
              maxPrice: bg.maxPrice ?? null,
              maxMileage: bg.maxMileage ?? null,
              drivetrain: bg.drivetrain || 'Any',
              exteriorColor: bg.exteriorColor || '',
              features: Array.isArray(bg.features) ? bg.features : [],
              notes: bg.notes || '',
              createdAt: createdAtToUse,
            },
          ];

      const remappedTargets = rawTargets.map((t, idx) => {
        const oldTid = String(t.id || `${origId}-vt-${idx + 1}`);
        const newTid =
          existing && normRes === 'duplicate'
            ? `${targetGuestId}-vt-${idx + 1}`
            : oldTid;
        targetIdRemap.set(oldTid, newTid);
        return {
          ...t,
          id: newTid,
        };
      });

      const primary = remappedTargets[0];
      const remappedNotes = (Array.isArray(bg.clientNotes) ? bg.clientNotes : []).map(
        (n, idx) => ({
          id:
            existing && normRes === 'duplicate'
              ? `${targetGuestId}-note-${idx + 1}`
              : String(n.id || `${targetGuestId}-note-${idx + 1}`),
          text: String(n.text || ''),
          createdAt: String(n.createdAt || createdAtToUse),
        })
      );

      const matchVins = guestMatches
        .map((m) => String(m?.vin || '').trim())
        .filter(Boolean);
      const seenVins = [
        ...new Set([
          ...(Array.isArray(bg.seenMatchVins) ? bg.seenMatchVins.map(String) : []),
          ...matchVins,
        ]),
      ];
      const schedVins = [
        ...new Set([
          ...(Array.isArray(bg.scheduledCallVins)
            ? bg.scheduledCallVins.map(String)
            : []),
          ...matchVins,
        ]),
      ];

      upsertGuestStmt.run({
        id: targetGuestId,
        name: targetName,
        phone: String(bg.phone || ''),
        email: String(bg.email || ''),
        condition: String(primary.condition || 'Any'),
        min_year: primary.minYear != null ? Number(primary.minYear) : null,
        max_year: primary.maxYear != null ? Number(primary.maxYear) : null,
        make: String(primary.make || ''),
        model: String(primary.model || ''),
        trim: String(primary.trim || ''),
        max_price: primary.maxPrice != null ? Number(primary.maxPrice) : null,
        max_mileage: primary.maxMileage != null ? Number(primary.maxMileage) : null,
        drivetrain: String(primary.drivetrain || 'Any'),
        exterior_color: String(primary.exteriorColor || ''),
        features_json: JSON.stringify(
          Array.isArray(primary.features) ? primary.features : []
        ),
        notes: String(primary.notes || ''),
        vehicle_targets_json: JSON.stringify(remappedTargets),
        client_notes_json: JSON.stringify(remappedNotes),
        deleted_note_ids_json: JSON.stringify(
          existing && normRes === 'duplicate'
            ? []
            : Array.isArray(bg.deletedNoteIds)
              ? bg.deletedNoteIds
              : []
        ),
        initial_search_completed:
          bg.initialSearchCompleted || bg.lastSearchedAt || matchVins.length > 0
            ? 1
            : 0,
        seen_match_vins_json: JSON.stringify(seenVins),
        scheduled_call_vins_json: JSON.stringify(schedVins),
        active: bg.active === false ? 0 : 1,
        last_searched_at: bg.lastSearchedAt || (matchVins.length > 0 ? nowIso : null),
        last_search_summary: String(bg.lastSearchSummary || ''),
        created_at: createdAtToUse,
        updated_at: nowIso,
      });

      for (const m of guestMatches) {
        if (!m || !m.vin) continue;
        const oldTid = String(m.targetId || '');
        const mappedTid = targetIdRemap.get(oldTid) || oldTid;
        insertMatchStmt.run({
          id:
            existing && normRes === 'duplicate'
              ? `match-${crypto.randomUUID()}`
              : String(m.id || `match-${crypto.randomUUID()}`),
          guest_id: targetGuestId,
          vin: String(m.vin),
          stock_number: String(m.stockNumber || ''),
          title: String(m.title || 'Vehicle Match'),
          year: m.year != null ? Number(m.year) : null,
          make: String(m.make || ''),
          model: String(m.model || ''),
          trim: String(m.trim || ''),
          condition: String(m.condition || ''),
          price: m.price != null ? Number(m.price) : null,
          msrp: m.msrp != null ? Number(m.msrp) : null,
          dealer_fee: m.dealerFee != null ? Number(m.dealerFee) : null,
          location: String(m.location || 'Preston Automotive Group'),
          mileage: Number(m.mileage || 0),
          drivetrain: String(m.drivetrain || ''),
          engine: String(m.engine || ''),
          exterior_color: String(m.exteriorColor || ''),
          interior_color: String(m.interiorColor || ''),
          photo_url: String(m.photoUrl || ''),
          listing_url: String(m.listingUrl || ''),
          matched_features_json: JSON.stringify(
            Array.isArray(m.matchedFeatures) ? m.matchedFeatures : []
          ),
          all_highlights_json: JSON.stringify(
            Array.isArray(m.allHighlights) ? m.allHighlights.slice(0, 8) : []
          ),
          agent_summary: String(m.agentSummary || ''),
          match_score: Number(m.matchScore || 85),
          found_at: String(m.foundAt || nowIso),
          search_slot: String(m.searchSlot || 'Restored Backup'),
          last_seen_at: nowIso,
          target_id: mappedTid,
          target_label: String(m.targetLabel || ''),
        });
      }
    }
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    throw err;
  }

  const totalGuests = db.prepare('SELECT COUNT(*) AS c FROM guests').get()?.c || 0;
  const totalMatches = db.prepare('SELECT COUNT(*) AS c FROM matches').get()?.c || 0;

  const parts = [];
  if (overwrittenGuests > 0) parts.push(`${overwrittenGuests} overwritten`);
  if (duplicatedGuests > 0) parts.push(`${duplicatedGuests} duplicated`);
  if (restoredGuests > 0) parts.push(`${restoredGuests} restored`);
  const detail = parts.length > 0 ? parts.join(', ') : '0 changes';

  return {
    backupId,
    resolution: conflicts.length > 0 ? normRes : 'none',
    restoredGuests,
    overwrittenGuests,
    duplicatedGuests,
    totalGuests,
    totalMatches,
    summary: `Backup loaded (${detail}) • ${totalGuests} active guest(s), ${totalMatches} match(es).`,
  };
}

export function exportServerBackupsForDrive() {
  ensureInitialServerBackup();
  const rows = db
    .prepare('SELECT * FROM backups ORDER BY created_at DESC LIMIT ?')
    .all(MAX_BACKUPS);
  return rows.map((r) => {
    let parsed = { guests: [], matches: [] };
    try {
      parsed = JSON.parse(r.snapshot_json || '{}');
    } catch {}
    return {
      id: r.id,
      label: r.label,
      deviceLabel: r.device_label || '',
      signature: r.signature || '',
      createdAt: r.created_at,
      guests: Array.isArray(parsed.guests) ? parsed.guests : [],
      matches: Array.isArray(parsed.matches) ? parsed.matches : [],
    };
  });
}

export function mergeRemoteBackupsIntoLocal(remoteBackups) {
  if (!Array.isArray(remoteBackups) || remoteBackups.length === 0) return;

  const insertStmt = db.prepare(
    `INSERT OR IGNORE INTO backups (
       id, label, device_label, signature, guest_count, match_count, snapshot_json, created_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  );

  for (const rb of remoteBackups) {
    if (!rb || typeof rb !== 'object' || !rb.id || !rb.createdAt) continue;
    const guests = Array.isArray(rb.guests) ? rb.guests : [];
    const matches = Array.isArray(rb.matches) ? rb.matches : [];
    const sig = rb.signature || computeSnapshotSignature(guests, matches);
    insertStmt.run(
      String(rb.id),
      String(rb.label || 'Cloud Backup'),
      String(rb.deviceLabel || 'Synced Device'),
      String(sig),
      guests.length,
      matches.length,
      JSON.stringify({ guests, matches }),
      String(rb.createdAt)
    );
  }

  pruneToLastFiveBackups();
}
