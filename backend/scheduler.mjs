import crypto from 'node:crypto';
import {
  db,
  getSetting,
  mapGuestRow,
  mapMatchRow,
  formatVehicleTargetLabel,
  extractVehicleModelLabel,
  formatMatchNotificationMessage,
  mapNotificationRow,
} from './db.mjs';
import {
  searchPrestonInventoryWithMeta,
  verifyVinsOnPrestonWebsite,
} from './preston_scraper.mjs';
import {
  evaluateInventoryWithGeminiAgent,
  resolveMatchingTargetForStoredMatch,
} from './gemini_agent.mjs';
import { scheduleAutoSaveToGoogleDrive } from './drive_sync.mjs';
import { scheduleSameDayGuestCallEvent } from './calendar_sync.mjs';

let isRunningBatch = false;

function getZonedParts(date, timeZone) {
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  });
  const parts = {};
  for (const p of fmt.formatToParts(date)) {
    parts[p.type] = p.value;
  }
  const hour = Number(parts.hour === '24' ? 0 : parts.hour);
  const minute = Number(parts.minute);
  return {
    dateStr: `${parts.year}-${parts.month}-${parts.day}`,
    hour,
    minute,
    minutesOfDay: hour * 60 + minute,
  };
}

export function getScheduleStatus() {
  const timeZone = getSetting('timezone') || 'America/New_York';
  const now = new Date();
  let zoned;
  try {
    zoned = getZonedParts(now, timeZone);
  } catch {
    zoned = getZonedParts(now, 'America/New_York');
  }

  const morningMinutes = 7 * 60 + 30; // 7:30 AM
  const afternoonMinutes = 14 * 60; // 2:00 PM

  let nextSlotLabel = '';
  if (zoned.minutesOfDay < morningMinutes) {
    nextSlotLabel = `Today at 7:30 AM (${timeZone})`;
  } else if (zoned.minutesOfDay < afternoonMinutes) {
    nextSlotLabel = `Today at 2:00 PM (${timeZone})`;
  } else {
    nextSlotLabel = `Tomorrow at 7:30 AM (${timeZone})`;
  }

  const lastRun = db
    .prepare('SELECT * FROM search_runs ORDER BY started_at DESC LIMIT 1')
    .get();

  const recentRuns = db
    .prepare('SELECT * FROM search_runs ORDER BY started_at DESC LIMIT 10')
    .all();

  return {
    schedule: ['7:30 AM Daily', '2:00 PM Daily'],
    timeZone,
    nextScheduledRunLabel: nextSlotLabel,
    isRunning: isRunningBatch,
    geminiConfigured: Boolean(getSetting('gemini_api_key')),
    geminiModel: getSetting('gemini_model') || 'gemini-2.5-flash',
    lastRun: lastRun || null,
    recentRuns,
  };
}

const upsertMatchStmt = db.prepare(`
  INSERT INTO matches (
    id, guest_id, vin, stock_number, title, year, make, model, trim, condition,
    price, msrp, dealer_fee, location, mileage, drivetrain, engine,
    doors, bed_length, body_style, comments_summary,
    exterior_color, interior_color, photo_url, listing_url,
    matched_features_json, all_highlights_json, agent_summary, match_score,
    found_at, search_slot, last_seen_at, target_id, target_label,
    is_selected_candidate, selected_at, selected_updated_at
  ) VALUES (
    @id, @guest_id, @vin, @stock_number, @title, @year, @make, @model, @trim, @condition,
    @price, @msrp, @dealer_fee, @location, @mileage, @drivetrain, @engine,
    @doors, @bed_length, @body_style, @comments_summary,
    @exterior_color, @interior_color, @photo_url, @listing_url,
    @matched_features_json, @all_highlights_json, @agent_summary, @match_score,
    @found_at, @search_slot, @last_seen_at, @target_id, @target_label,
    @is_selected_candidate, @selected_at, @selected_updated_at
  )
  ON CONFLICT(guest_id, vin) DO UPDATE SET
    price = excluded.price,
    msrp = excluded.msrp,
    dealer_fee = excluded.dealer_fee,
    location = excluded.location,
    mileage = excluded.mileage,
    doors = CASE WHEN excluded.doors != '' THEN excluded.doors ELSE matches.doors END,
    bed_length = CASE WHEN excluded.bed_length != '' THEN excluded.bed_length ELSE matches.bed_length END,
    body_style = CASE WHEN excluded.body_style != '' THEN excluded.body_style ELSE matches.body_style END,
    comments_summary = CASE WHEN excluded.comments_summary != '' THEN excluded.comments_summary ELSE matches.comments_summary END,
    photo_url = excluded.photo_url,
    listing_url = excluded.listing_url,
    matched_features_json = excluded.matched_features_json,
    all_highlights_json = excluded.all_highlights_json,
    agent_summary = excluded.agent_summary,
    match_score = excluded.match_score,
    last_seen_at = excluded.last_seen_at,
    target_id = excluded.target_id,
    target_label = excluded.target_label
`);

const insertNotificationStmt = db.prepare(`
  INSERT OR IGNORE INTO match_notifications (
    id, guest_id, guest_name, vin, vehicle_model, message, location, price, created_at, read
  ) VALUES (
    @id, @guest_id, @guest_name, @vin, @vehicle_model, @message, @location, @price, @created_at, 0
  )
`);

export function pruneNonMatchingMatchesForGuest(guestId) {
  const rawGuest = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
  if (!rawGuest) return 0;
  const guest = mapGuestRow(rawGuest);
  const rows = db.prepare('SELECT * FROM matches WHERE guest_id = ?').all(guestId);
  if (rows.length === 0) return 0;

  const delStmt = db.prepare('DELETE FROM matches WHERE id = ?');
  const relinkStmt = db.prepare(
    'UPDATE matches SET target_id = ?, target_label = ? WHERE id = ?'
  );
  let removed = 0;

  for (const row of rows) {
    const mapped = mapMatchRow(row);
    const matchedTarget = resolveMatchingTargetForStoredMatch(mapped, guest);
    if (!matchedTarget) {
      delStmt.run(row.id);
      removed++;
    } else if (
      matchedTarget.id &&
      row.target_id &&
      row.target_id !== matchedTarget.id
    ) {
      relinkStmt.run(
        matchedTarget.id,
        formatVehicleTargetLabel(matchedTarget),
        row.id
      );
    }
  }
  return removed;
}

const upsertDelistedVinStmt = db.prepare(`
  INSERT INTO delisted_website_vins (vin, delisted_at)
  VALUES (?, ?)
  ON CONFLICT(vin) DO UPDATE SET
    delisted_at = CASE
      WHEN excluded.delisted_at >= delisted_website_vins.delisted_at THEN excluded.delisted_at
      ELSE delisted_website_vins.delisted_at
    END
`);

const deleteDelistedVinStmt = db.prepare(`
  DELETE FROM delisted_website_vins WHERE vin = ?
`);

function capDelistedVinsTable() {
  try {
    db.exec(`
      DELETE FROM delisted_website_vins
       WHERE vin NOT IN (
         SELECT vin FROM delisted_website_vins ORDER BY delisted_at DESC LIMIT 2000
       )
    `);
  } catch {}
}

let lastGlobalWebsiteReconcileMs = 0;

/**
 * Verifies stored match VINs directly against live prestonmotor.com New & Pre-Owned inventory
 * and removes any vehicle that is no longer listed on the website across ALL searches.
 */
export async function reconcileWebsiteMatches({ guestId = null, force = false } = {}) {
  const nowMs = Date.now();
  if (!guestId && !force && nowMs - lastGlobalWebsiteReconcileMs < 45_000) {
    return { verified: true, throttled: true, removedCount: 0, removedVins: [] };
  }

  const rows = guestId
    ? db.prepare('SELECT id, guest_id, vin FROM matches WHERE guest_id = ?').all(guestId)
    : db.prepare('SELECT id, guest_id, vin FROM matches').all();

  if (rows.length === 0) {
    if (!guestId) lastGlobalWebsiteReconcileMs = nowMs;
    return { verified: true, removedCount: 0, removedVins: [] };
  }

  const uniqueVins = [
    ...new Set(
      rows
        .map((r) => String(r.vin || '').trim().toUpperCase())
        .filter(Boolean)
    ),
  ];

  const { verified, liveByVin } = await verifyVinsOnPrestonWebsite(uniqueVins);
  if (!verified) {
    return { verified: false, removedCount: 0, removedVins: [] };
  }

  if (!guestId) {
    lastGlobalWebsiteReconcileMs = Date.now();
  }

  const nowIso = new Date().toISOString();
  const delistedVins = uniqueVins.filter((vin) => !liveByVin.has(vin));
  const affectedGuestIds = new Set(rows.map((r) => r.guest_id));
  let removedCount = 0;

  const delAcrossAllByVinStmt = db.prepare(
    'DELETE FROM matches WHERE UPPER(TRIM(vin)) = ?'
  );
  const refreshLiveMatchStmt = db.prepare(`
    UPDATE matches
       SET price = ?,
           msrp = ?,
           dealer_fee = ?,
           location = ?,
           mileage = ?,
           photo_url = CASE WHEN ? != '' THEN ? ELSE photo_url END,
           listing_url = CASE WHEN ? != '' THEN ? ELSE listing_url END,
           last_seen_at = ?
     WHERE UPPER(TRIM(vin)) = ?
  `);

  db.exec('BEGIN IMMEDIATE');
  try {
    for (const goneVin of delistedVins) {
      upsertDelistedVinStmt.run(goneVin, nowIso);
      const affected = db
        .prepare('SELECT DISTINCT guest_id FROM matches WHERE UPPER(TRIM(vin)) = ?')
        .all(goneVin);
      for (const a of affected) {
        if (a.guest_id) affectedGuestIds.add(a.guest_id);
      }
      const info = delAcrossAllByVinStmt.run(goneVin);
      removedCount += Number(info.changes || 0);
    }

    for (const [liveVin, v] of liveByVin.entries()) {
      deleteDelistedVinStmt.run(liveVin);
      refreshLiveMatchStmt.run(
        v.price ?? null,
        v.msrp ?? null,
        v.dealerFee ?? null,
        v.location || 'Preston Automotive Group',
        v.mileage ?? 0,
        v.photoUrl || '',
        v.photoUrl || '',
        v.listingUrl || '',
        v.listingUrl || '',
        nowIso,
        liveVin
      );
    }

    capDelistedVinsTable();
    db.exec('COMMIT');
  } catch (err) {
    try {
      db.exec('ROLLBACK');
    } catch {}
    throw err;
  }

  for (const gid of affectedGuestIds) {
    removedCount += pruneNonMatchingMatchesForGuest(gid);
  }

  if (removedCount > 0) {
    const touchGuestStmt = db.prepare('UPDATE guests SET updated_at = ? WHERE id = ?');
    for (const gid of affectedGuestIds) {
      touchGuestStmt.run(nowIso, gid);
    }
    scheduleAutoSaveToGoogleDrive();
  }

  return {
    verified: true,
    removedCount,
    removedVins: delistedVins,
  };
}

async function purgeConfirmedDelistedVinsAcrossAllSearches(candidateGoneVins, nowIso) {
  const unique = [
    ...new Set(
      Array.from(candidateGoneVins || [])
        .map((v) => String(v || '').trim().toUpperCase())
        .filter((v) => v.length >= 8)
    ),
  ];
  if (unique.length === 0) return 0;

  const { verified, liveByVin } = await verifyVinsOnPrestonWebsite(unique);
  if (!verified) return 0;

  const trulyGone = unique.filter((vin) => !liveByVin.has(vin));
  if (trulyGone.length === 0) return 0;

  const delAcrossAllStmt = db.prepare('DELETE FROM matches WHERE UPPER(TRIM(vin)) = ?');
  const touchGuestStmt = db.prepare('UPDATE guests SET updated_at = ? WHERE id = ?');
  let purgedOtherRows = 0;

  db.exec('BEGIN IMMEDIATE');
  try {
    for (const goneVin of trulyGone) {
      upsertDelistedVinStmt.run(goneVin, nowIso);
      const otherGuests = db
        .prepare('SELECT DISTINCT guest_id FROM matches WHERE UPPER(TRIM(vin)) = ?')
        .all(goneVin);
      const info = delAcrossAllStmt.run(goneVin);
      purgedOtherRows += Number(info.changes || 0);
      for (const og of otherGuests) {
        if (og.guest_id) touchGuestStmt.run(nowIso, og.guest_id);
      }
    }
    capDelistedVinsTable();
    db.exec('COMMIT');
  } catch {
    try {
      db.exec('ROLLBACK');
    } catch {}
  }
  return purgedOtherRows;
}

async function evaluateTargetsForGuest(guest, targetsToRun) {
  let totalCandidatesScanned = 0;
  let anyFetchSucceeded = false;
  const succeededTargetIds = new Set();
  const scannedCandidateVins = new Set();
  let modeUsed = getSetting('gemini_api_key') ? 'gemini' : 'smart-matcher';
  const bestByVin = new Map();
  const targetSummaries = [];

  for (const target of targetsToRun) {
    const targetLabel = formatVehicleTargetLabel(target);
    const virtualGuestSpec = {
      id: guest.id,
      name: guest.name,
      condition: target.condition || 'Any',
      minYear: target.minYear,
      maxYear: target.maxYear,
      make: target.make || '',
      model: target.model || '',
      trim: target.trim || '',
      bedLength: target.bedLength || '',
      cabStyle: target.cabStyle || '',
      doors: target.doors || '',
      engineSpec: target.engineSpec || '',
      maxPrice: target.maxPrice,
      maxMileage: target.maxMileage,
      drivetrain: target.drivetrain || 'Any',
      exteriorColor: target.exteriorColor || '',
      features: Array.isArray(target.features) ? target.features : [],
      notes: target.notes || '',
    };

    const { vehicles: candidates, fetchSucceeded } =
      await searchPrestonInventoryWithMeta(virtualGuestSpec);
    if (fetchSucceeded) {
      anyFetchSucceeded = true;
      if (target.id) succeededTargetIds.add(target.id);
    }
    for (const c of candidates) {
      const cv = String(c?.vin || '').trim().toUpperCase();
      if (cv) scannedCandidateVins.add(cv);
    }

    const evaluation = await evaluateInventoryWithGeminiAgent(virtualGuestSpec, candidates);
    totalCandidatesScanned += candidates.length;
    modeUsed = evaluation.mode;
    targetSummaries.push(`${targetLabel}: ${evaluation.matches.length} match(es)`);

    for (const m of evaluation.matches) {
      const vin = m?.vehicle?.vin;
      if (!vin) continue;
      const prev = bestByVin.get(vin);
      if (!prev || (m.matchScore || 0) >= (prev.matchScore || 0)) {
        bestByVin.set(vin, {
          ...m,
          targetId: target.id,
          targetLabel,
        });
      }
    }
  }

  const combinedMatches = Array.from(bestByVin.values());
  const locCount = new Set(combinedMatches.map((m) => m.vehicle.location)).size;
  const summary =
    targetsToRun.length > 1
      ? `Scanned ${targetsToRun.length} vehicle criteria (${targetSummaries.join(' • ')}) — ${combinedMatches.length} total match(es) across ${locCount} Preston dealership location(s).`
      : `Scanned ${totalCandidatesScanned} live prestonmotor.com vehicles for ${formatVehicleTargetLabel(targetsToRun[0])}; verified ${combinedMatches.length} match(es) across ${locCount} Preston location(s).`;

  return {
    candidatesScanned: totalCandidatesScanned,
    anyFetchSucceeded,
    succeededTargetIds,
    scannedCandidateVins,
    matches: combinedMatches,
    mode: modeUsed,
    summary,
  };
}

function persistEvaluatedMatchesAndNotifications({
  rawGuest,
  guest,
  evalRes,
  slotLabel,
  nowIso,
  onlyTargetId = null,
  isInitialSearch = false,
  isSeedSearch = false,
  preservedMatchesByVin = null,
}) {
  const allTargets = guest.vehicleTargets || [];
  const validTargetIds = new Set(allTargets.map((t) => t.id));
  const isPrimaryTarget =
    Boolean(onlyTargetId) && allTargets.length > 0 && allTargets[0].id === onlyTargetId;
  const existingRows = db
    .prepare(
      'SELECT id, vin, target_id, found_at, is_selected_candidate, selected_at, selected_updated_at FROM matches WHERE guest_id = ?'
    )
    .all(guest.id);
  const existingByVin = new Map(
    existingRows.map((r) => [String(r.vin || ''), r]).filter(([k]) => Boolean(k))
  );
  const existingVins = new Set(existingByVin.keys());
  const seenVins = new Set([
    ...(guest.seenMatchVins || []),
    ...existingVins,
    ...(preservedMatchesByVin instanceof Map ? preservedMatchesByVin.keys() : []),
  ]);
  const scheduledCallVins = new Set(guest.scheduledCallVins || []);
  const calendarPermissionGranted = getSetting('calendar_permission_granted') === '1';

  const hadCompletedInitialSearch =
    !isInitialSearch &&
    (Boolean(rawGuest.initial_search_completed) || Boolean(rawGuest.last_searched_at));

  const createdNotifications = [];
  const vehiclesNeedingCallEvent = [];
  const removedVins = new Set();
  const canPruneLive = Boolean(evalRes.anyFetchSucceeded || evalRes.candidatesScanned > 0);
  const foundVinsUpper = new Set(
    evalRes.matches.map((m) => String(m?.vehicle?.vin || '').trim().toUpperCase()).filter(Boolean)
  );

  if (preservedMatchesByVin instanceof Map && canPruneLive) {
    for (const prevVin of preservedMatchesByVin.keys()) {
      const upper = String(prevVin || '').trim().toUpperCase();
      if (upper && !foundVinsUpper.has(upper)) {
        removedVins.add(upper);
      }
    }
  }

  db.exec('BEGIN IMMEDIATE');
  try {
    if (!onlyTargetId && canPruneLive) {
      const foundVins = new Set(evalRes.matches.map((m) => m.vehicle.vin));
      const delStmt = db.prepare('DELETE FROM matches WHERE id = ?');
      for (const r of existingRows) {
        if (
          (r.target_id && !validTargetIds.has(r.target_id)) ||
          !foundVins.has(r.vin)
        ) {
          delStmt.run(r.id);
          if (r.vin) removedVins.add(String(r.vin).trim().toUpperCase());
        }
      }
    } else if (onlyTargetId && canPruneLive) {
      const foundVins = new Set(evalRes.matches.map((m) => m.vehicle.vin));
      const delStmt = db.prepare('DELETE FROM matches WHERE id = ?');
      for (const r of existingRows) {
        const belongsToEdited =
          allTargets.length <= 1 ||
          r.target_id === onlyTargetId ||
          (isPrimaryTarget && !r.target_id) ||
          (r.target_id && !validTargetIds.has(r.target_id));
        if (belongsToEdited && !foundVins.has(r.vin)) {
          delStmt.run(r.id);
          if (r.vin) removedVins.add(String(r.vin).trim().toUpperCase());
        }
      }
    }

    for (const m of evalRes.matches) {
      const v = m.vehicle;
      const vin = String(v.vin || '').trim();
      if (!vin) continue;

      deleteDelistedVinStmt.run(vin.toUpperCase());

      const isBrandNewMatch = !seenVins.has(vin);
      seenVins.add(vin);

      const needsCallEvent = !scheduledCallVins.has(vin);
      scheduledCallVins.add(vin);
      if (!isSeedSearch && calendarPermissionGranted && needsCallEvent) {
        vehiclesNeedingCallEvent.push(v);
      }

      const prev =
        existingByVin.get(vin) ||
        (preservedMatchesByVin instanceof Map ? preservedMatchesByVin.get(vin) : null);

      upsertMatchStmt.run({
        id: prev?.id || crypto.randomUUID(),
        guest_id: guest.id,
        vin,
        stock_number: v.stockNumber || '',
        title: v.title,
        year: v.year,
        make: v.make || '',
        model: v.model || '',
        trim: v.trim || '',
        condition: v.condition || '',
        price: v.price ?? null,
        msrp: v.msrp ?? null,
        dealer_fee: v.dealerFee ?? null,
        location: v.location || 'Preston Automotive Group',
        mileage: v.mileage ?? 0,
        drivetrain: v.drivetrain || '',
        engine: v.engine || '',
        doors: String(v.doors || ''),
        bed_length: String(v.bedLength || ''),
        body_style: String(v.bodyStyle || ''),
        comments_summary: String(v.commentsSummary || ''),
        exterior_color: v.exteriorColor || '',
        interior_color: v.interiorColor || '',
        photo_url: v.photoUrl || '',
        listing_url: v.listingUrl || 'https://www.prestonmotor.com',
        matched_features_json: JSON.stringify(m.matchedFeatures || []),
        all_highlights_json: JSON.stringify(v.highlights || []),
        agent_summary: m.agentSummary || '',
        match_score: m.matchScore || 85,
        found_at: prev?.found_at || nowIso,
        search_slot: slotLabel,
        last_seen_at: nowIso,
        target_id: m.targetId || '',
        target_label: m.targetLabel || '',
        is_selected_candidate: prev?.is_selected_candidate ? 1 : 0,
        selected_at: prev?.selected_at || null,
        selected_updated_at: prev?.selected_updated_at || null,
      });

      if (hadCompletedInitialSearch && isBrandNewMatch) {
        const vehicleModel = extractVehicleModelLabel(v);
        const message = formatMatchNotificationMessage(guest.name, v);
        const notifId = `notif-${crypto.randomUUID()}`;
        const info = insertNotificationStmt.run({
          id: notifId,
          guest_id: guest.id,
          guest_name: guest.name,
          vin,
          vehicle_model: vehicleModel,
          message,
          location: v.location || 'Preston Automotive Group',
          price: v.price ?? null,
          created_at: nowIso,
        });
        if (info.changes > 0) {
          const savedRow = db
            .prepare('SELECT * FROM match_notifications WHERE id = ?')
            .get(notifId);
          if (savedRow) {
            createdNotifications.push(mapNotificationRow(savedRow));
          }
        }
      }
    }

    const updatedTargets = allTargets.map((t) =>
      canPruneLive && evalRes.succeededTargetIds?.has(t.id)
        ? { ...t, lastSearchedAt: nowIso }
        : t
    );
    const isFullGuestScan =
      canPruneLive &&
      (!onlyTargetId || allTargets.length <= 1) &&
      allTargets.every((t) => evalRes.succeededTargetIds?.has(t.id));

    // Cap seen_match_vins_json and scheduled_call_vins_json at 2,500 entries per guest
    const cappedSeen = [...seenVins].slice(-2500);
    const cappedSched = [...scheduledCallVins].slice(-2500);
    db.prepare(
      `UPDATE guests
       SET initial_search_completed = 1,
           vehicle_targets_json = ?,
           seen_match_vins_json = ?,
           scheduled_call_vins_json = ?,
           last_searched_at = ?,
           last_full_scan_at = CASE WHEN ? IS NOT NULL THEN ? ELSE last_full_scan_at END,
           last_search_summary = ?,
           updated_at = ?
       WHERE id = ?`
    ).run(
      JSON.stringify(updatedTargets),
      JSON.stringify(cappedSeen),
      JSON.stringify(cappedSched),
      nowIso,
      isFullGuestScan ? nowIso : null,
      isFullGuestScan ? nowIso : null,
      evalRes.summary,
      nowIso,
      guest.id
    );

    db.exec('COMMIT');
  } catch (txErr) {
    try {
      db.exec('ROLLBACK');
    } catch {}
    throw txErr;
  }

  pruneNonMatchingMatchesForGuest(guest.id);
  return { createdNotifications, vehiclesNeedingCallEvent, removedVins };
}

export async function runSearchForGuest(
  guestId,
  slotLabel = 'Manual Gemini Search',
  {
    onlyTargetId = null,
    isInitialSearch = false,
    isSeedSearch = false,
    calendarAccessToken = '',
    preservedMatchesByVin = null,
  } = {}
) {
  const rawGuest = db.prepare('SELECT * FROM guests WHERE id = ?').get(guestId);
  if (!rawGuest) {
    throw new Error('Guest not found');
  }
  const guest = mapGuestRow(rawGuest);
  const allTargets = guest.vehicleTargets || [];
  const targetsToRun = onlyTargetId
    ? allTargets.filter((t) => t.id === onlyTargetId)
    : allTargets;

  if (targetsToRun.length === 0) {
    return {
      guestId: guest.id,
      candidatesScanned: 0,
      matchesFound: 0,
      newNotifications: [],
      calendarEvent: null,
      mode: 'smart-matcher',
      summary: 'No vehicle criteria specified.',
    };
  }

  const startedAt = new Date().toISOString();
  const runId = crypto.randomUUID();

  db.prepare(
    `INSERT INTO search_runs (id, guest_id, slot_key, slot_label, guests_checked, started_at)
     VALUES (?, ?, NULL, ?, 1, ?)`
  ).run(runId, guest.id, slotLabel, startedAt);

  try {
    const evalRes = await evaluateTargetsForGuest(guest, targetsToRun);
    const nowIso = new Date().toISOString();

    const { createdNotifications, vehiclesNeedingCallEvent, removedVins } =
      persistEvaluatedMatchesAndNotifications({
        rawGuest,
        guest,
        evalRes,
        slotLabel,
        nowIso,
        onlyTargetId,
        isInitialSearch,
        isSeedSearch,
        preservedMatchesByVin,
      });

    // Verify any VINs that disappeared (and weren't seen in live candidates) so if a vehicle
    // left prestonmotor.com it is immediately removed from ALL other searches as well.
    if (evalRes.anyFetchSucceeded && removedVins.size > 0) {
      const unverifiedGone = [...removedVins].filter(
        (vin) => !evalRes.scannedCandidateVins?.has(vin)
      );
      if (unverifiedGone.length > 0) {
        await purgeConfirmedDelistedVinsAcrossAllSearches(unverifiedGone, nowIso);
      }
    }

    // If only a single target on a multi-target guest was scanned, also verify remaining targets'
    // stored matches against prestonmotor.com so delisted vehicles on sibling targets are removed too.
    if (onlyTargetId && allTargets.length > 1) {
      await reconcileWebsiteMatches({ guestId: guest.id, force: true });
    }

    let calendarEvent = null;
    if (!isSeedSearch && vehiclesNeedingCallEvent.length > 0) {
      try {
        const freshGuest = mapGuestRow(
          db.prepare('SELECT * FROM guests WHERE id = ?').get(guest.id)
        );
        const calRes = await scheduleSameDayGuestCallEvent({
          guest: freshGuest,
          matchedVehicles: vehiclesNeedingCallEvent,
          accessToken: calendarAccessToken,
        });
        calendarEvent = calRes.event || null;
      } catch (calErr) {
        console.error('[Scheduler] Calendar event error:', calErr.message);
      }
    }

    db.prepare(
      `UPDATE search_runs
       SET candidates_scanned = ?, matches_found = ?, agent_mode = ?, completed_at = ?
       WHERE id = ?`
    ).run(
      evalRes.candidatesScanned,
      evalRes.matches.length,
      evalRes.mode,
      nowIso,
      runId
    );

    scheduleAutoSaveToGoogleDrive();

    return {
      guestId: guest.id,
      candidatesScanned: evalRes.candidatesScanned,
      matchesFound: evalRes.matches.length,
      newNotifications: createdNotifications,
      calendarEvent,
      mode: evalRes.mode,
      summary: evalRes.summary,
    };
  } catch (err) {
    const nowIso = new Date().toISOString();
    db.prepare(
      'UPDATE search_runs SET completed_at = ?, error = ? WHERE id = ?'
    ).run(nowIso, err.message, runId);
    throw err;
  }
}

export async function runSearchForAllActiveGuests(
  slotLabel = 'Scheduled Search',
  slotKey = null,
  { isInitialSearch = false, isSeedSearch = false, calendarAccessToken = '' } = {}
) {
  if (isRunningBatch) {
    return {
      skipped: true,
      reason: 'Batch already running',
      newNotifications: [],
      newCalendarEvents: [],
    };
  }
  isRunningBatch = true;
  const startedAt = new Date().toISOString();
  const batchRunId = crypto.randomUUID();

  const activeRows = db
    .prepare('SELECT * FROM guests WHERE active = 1 ORDER BY created_at DESC')
    .all();

  db.prepare(
    `INSERT INTO search_runs (id, guest_id, slot_key, slot_label, guests_checked, started_at)
     VALUES (?, NULL, ?, ?, ?, ?)`
  ).run(batchRunId, slotKey, slotLabel, activeRows.length, startedAt);

  let totalCandidates = 0;
  let totalMatches = 0;
  let modeUsed = getSetting('gemini_api_key') ? 'gemini' : 'smart-matcher';
  const allNewNotifications = [];
  const allNewCalendarEvents = [];
  const batchCandidateGoneVins = new Set();
  const batchSeenLiveVins = new Set();

  try {
    for (const row of activeRows) {
      const guest = mapGuestRow(row);
      try {
        const evalRes = await evaluateTargetsForGuest(guest, guest.vehicleTargets || []);
        const nowIso = new Date().toISOString();
        modeUsed = evalRes.mode;
        totalCandidates += evalRes.candidatesScanned;
        totalMatches += evalRes.matches.length;
        for (const cv of evalRes.scannedCandidateVins || []) {
          batchSeenLiveVins.add(cv);
        }

        const { createdNotifications, vehiclesNeedingCallEvent, removedVins } =
          persistEvaluatedMatchesAndNotifications({
            rawGuest: row,
            guest,
            evalRes,
            slotLabel,
            nowIso,
            onlyTargetId: null,
            isInitialSearch,
            isSeedSearch,
          });
        allNewNotifications.push(...createdNotifications);
        if (evalRes.anyFetchSucceeded) {
          for (const rv of removedVins) {
            batchCandidateGoneVins.add(rv);
          }
        }

        if (!isSeedSearch && vehiclesNeedingCallEvent.length > 0) {
          try {
            const freshGuest = mapGuestRow(
              db.prepare('SELECT * FROM guests WHERE id = ?').get(guest.id)
            );
            const calRes = await scheduleSameDayGuestCallEvent({
              guest: freshGuest,
              matchedVehicles: vehiclesNeedingCallEvent,
              accessToken: calendarAccessToken,
            });
            if (calRes.event) {
              allNewCalendarEvents.push(calRes.event);
            }
          } catch (calErr) {
            console.error(
              `[Scheduler] Calendar event error for ${guest.name}:`,
              calErr.message
            );
          }
        }
      } catch (guestErr) {
        console.error(`[Scheduler] Error searching for ${guest.name}:`, guestErr.message);
      }
    }

    // Also verify any paused/inactive guests' stored matches + disappeared VINs against prestonmotor.com
    const unverifiedBatchGone = [...batchCandidateGoneVins].filter(
      (vin) => !batchSeenLiveVins.has(vin)
    );
    if (unverifiedBatchGone.length > 0) {
      await purgeConfirmedDelistedVinsAcrossAllSearches(
        unverifiedBatchGone,
        new Date().toISOString()
      );
    }
    await reconcileWebsiteMatches({ force: true });

    db.prepare(
      `UPDATE search_runs
       SET candidates_scanned = ?, matches_found = ?, agent_mode = ?, completed_at = ?
       WHERE id = ?`
    ).run(totalCandidates, totalMatches, modeUsed, new Date().toISOString(), batchRunId);

    scheduleAutoSaveToGoogleDrive();

    return {
      guestsChecked: activeRows.length,
      candidatesScanned: totalCandidates,
      matchesFound: totalMatches,
      newNotifications: allNewNotifications,
      newCalendarEvents: allNewCalendarEvents,
      mode: modeUsed,
    };
  } finally {
    isRunningBatch = false;
  }
}

export function startTwiceDailyScheduler() {
  const checkSchedule = async () => {
    try {
      const timeZone = getSetting('timezone') || 'America/New_York';
      const zoned = getZonedParts(new Date(), timeZone);

      // Slot 1: 7:30 AM (catch-up window 07:30 -> 09:00 if Chromebook wakes up slightly later)
      if (zoned.minutesOfDay >= 7 * 60 + 30 && zoned.minutesOfDay <= 9 * 60) {
        const slotKey = `${zoned.dateStr}_07:30`;
        const exists = db
          .prepare('SELECT id FROM search_runs WHERE slot_key = ? LIMIT 1')
          .get(slotKey);
        if (!exists) {
          console.log(`[Scheduler] Triggering 7:30 AM daily search (${slotKey})`);
          await runSearchForAllActiveGuests('7:30 AM Daily Search', slotKey);
        }
      }

      // Slot 2: 2:00 PM (14:00, catch-up window 14:00 -> 15:30)
      if (zoned.minutesOfDay >= 14 * 60 && zoned.minutesOfDay <= 15 * 60 + 30) {
        const slotKey = `${zoned.dateStr}_14:00`;
        const exists = db
          .prepare('SELECT id FROM search_runs WHERE slot_key = ? LIMIT 1')
          .get(slotKey);
        if (!exists) {
          console.log(`[Scheduler] Triggering 2:00 PM daily search (${slotKey})`);
          await runSearchForAllActiveGuests('2:00 PM Daily Search', slotKey);
        }
      }
    } catch (err) {
      console.error('[Scheduler] Check error:', err.message);
    }
  };

  // Run check every 20 seconds
  setInterval(checkSchedule, 20 * 1000);
  setTimeout(checkSchedule, 3000);
}
