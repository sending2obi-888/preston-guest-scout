import crypto from 'node:crypto';
import { db, getSetting, mapGuestRow, formatVehicleTargetLabel } from './db.mjs';
import { searchPrestonInventory } from './preston_scraper.mjs';
import { evaluateInventoryWithGeminiAgent } from './gemini_agent.mjs';
import { scheduleAutoSaveToGoogleDrive } from './drive_sync.mjs';

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
    last_seen_at = excluded.last_seen_at,
    target_id = excluded.target_id,
    target_label = excluded.target_label
`);

async function evaluateTargetsForGuest(guest, targetsToRun) {
  let totalCandidatesScanned = 0;
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
      maxPrice: target.maxPrice,
      maxMileage: target.maxMileage,
      drivetrain: target.drivetrain || 'Any',
      exteriorColor: target.exteriorColor || '',
      features: Array.isArray(target.features) ? target.features : [],
      notes: target.notes || '',
    };

    const candidates = await searchPrestonInventory(virtualGuestSpec);
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
    matches: combinedMatches,
    mode: modeUsed,
    summary,
  };
}

export async function runSearchForGuest(
  guestId,
  slotLabel = 'Manual Gemini Search',
  { onlyTargetId = null } = {}
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
    const validTargetIds = new Set(allTargets.map((t) => t.id));

    db.exec('BEGIN IMMEDIATE');
    try {
      if (!onlyTargetId && evalRes.candidatesScanned > 0) {
        // Clean up matches belonging to removed targets or sold VINs on full scan
        const foundVins = new Set(evalRes.matches.map((m) => m.vehicle.vin));
        const existingRows = db
          .prepare('SELECT id, vin, target_id FROM matches WHERE guest_id = ?')
          .all(guest.id);
        const delStmt = db.prepare('DELETE FROM matches WHERE id = ?');
        for (const r of existingRows) {
          if (
            (r.target_id && !validTargetIds.has(r.target_id)) ||
            !foundVins.has(r.vin)
          ) {
            delStmt.run(r.id);
          }
        }
      } else if (onlyTargetId && evalRes.candidatesScanned > 0) {
        db.prepare('DELETE FROM matches WHERE guest_id = ? AND target_id = ?').run(
          guest.id,
          onlyTargetId
        );
      }

      for (const m of evalRes.matches) {
        const v = m.vehicle;
        upsertMatchStmt.run({
          id: crypto.randomUUID(),
          guest_id: guest.id,
          vin: v.vin,
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
          exterior_color: v.exteriorColor || '',
          interior_color: v.interiorColor || '',
          photo_url: v.photoUrl || '',
          listing_url: v.listingUrl || 'https://www.prestonmotor.com',
          matched_features_json: JSON.stringify(m.matchedFeatures || []),
          all_highlights_json: JSON.stringify(v.highlights || []),
          agent_summary: m.agentSummary || '',
          match_score: m.matchScore || 85,
          found_at: nowIso,
          search_slot: slotLabel,
          last_seen_at: nowIso,
          target_id: m.targetId || '',
          target_label: m.targetLabel || '',
        });
      }
      db.exec('COMMIT');
    } catch (txErr) {
      try {
        db.exec('ROLLBACK');
      } catch {}
      throw txErr;
    }

    db.prepare(
      'UPDATE guests SET last_searched_at = ?, last_search_summary = ?, updated_at = ? WHERE id = ?'
    ).run(nowIso, evalRes.summary, nowIso, guest.id);

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

export async function runSearchForAllActiveGuests(slotLabel = 'Scheduled Search', slotKey = null) {
  if (isRunningBatch) {
    return { skipped: true, reason: 'Batch already running' };
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

  try {
    for (const row of activeRows) {
      const guest = mapGuestRow(row);
      try {
        const evalRes = await evaluateTargetsForGuest(guest, guest.vehicleTargets || []);
        const nowIso = new Date().toISOString();
        modeUsed = evalRes.mode;
        totalCandidates += evalRes.candidatesScanned;
        totalMatches += evalRes.matches.length;

        const validTargetIds = new Set((guest.vehicleTargets || []).map((t) => t.id));

        db.exec('BEGIN IMMEDIATE');
        try {
          if (evalRes.candidatesScanned > 0) {
            const foundVins = new Set(evalRes.matches.map((m) => m.vehicle.vin));
            const existingRows = db
              .prepare('SELECT id, vin, target_id FROM matches WHERE guest_id = ?')
              .all(guest.id);
            const delStmt = db.prepare('DELETE FROM matches WHERE id = ?');
            for (const r of existingRows) {
              if (
                (r.target_id && !validTargetIds.has(r.target_id)) ||
                !foundVins.has(r.vin)
              ) {
                delStmt.run(r.id);
              }
            }
          }

          for (const m of evalRes.matches) {
            const v = m.vehicle;
            upsertMatchStmt.run({
              id: crypto.randomUUID(),
              guest_id: guest.id,
              vin: v.vin,
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
              exterior_color: v.exteriorColor || '',
              interior_color: v.interiorColor || '',
              photo_url: v.photoUrl || '',
              listing_url: v.listingUrl || 'https://www.prestonmotor.com',
              matched_features_json: JSON.stringify(m.matchedFeatures || []),
              all_highlights_json: JSON.stringify(v.highlights || []),
              agent_summary: m.agentSummary || '',
              match_score: m.matchScore || 85,
              found_at: nowIso,
              search_slot: slotLabel,
              last_seen_at: nowIso,
              target_id: m.targetId || '',
              target_label: m.targetLabel || '',
            });
          }
          db.exec('COMMIT');
        } catch (txErr) {
          try {
            db.exec('ROLLBACK');
          } catch {}
          throw txErr;
        }

        db.prepare(
          'UPDATE guests SET last_searched_at = ?, last_search_summary = ?, updated_at = ? WHERE id = ?'
        ).run(nowIso, evalRes.summary, nowIso, guest.id);
      } catch (guestErr) {
        console.error(`[Scheduler] Error searching for ${guest.name}:`, guestErr.message);
      }
    }

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
