import { getSetting } from './db.mjs';
import {
  doesVehicleMatchCabStyle,
  doesVehicleMatchColor,
  doesVehicleMatchEngine,
  doesVehicleMatchModel,
  doesVehicleMatchStrictPackages,
  doesVehicleMatchTrim,
  extractBedLengthFromVehicle,
  formatBedLengthLabel,
} from './natural_language_parser.mjs';
import { normalizeGuestSpecs } from './preston_scraper.mjs';

function doesVehicleMatchDrivetrain(targetDrivetrain, v) {
  if (!targetDrivetrain || targetDrivetrain === 'Any') return true;
  const targetDt = targetDrivetrain.toUpperCase();
  const vDt = String(v.drivetrain || '').toUpperCase();
  const hay = `${vDt} ${(v.highlights || []).join(' ')} ${v.commentsSummary || ''}`.toUpperCase();

  if (targetDt === '4WD') {
    return (
      vDt === '4WD' ||
      vDt === 'AWD / 4WD' ||
      hay.includes('4WD') ||
      hay.includes('4X4') ||
      hay.includes('FOUR WHEEL DRIVE') ||
      hay.includes('4-WHEEL DRIVE')
    );
  }
  if (targetDt === 'AWD') {
    return (
      vDt === 'AWD' ||
      vDt === 'AWD / 4WD' ||
      hay.includes('AWD') ||
      hay.includes('ALL WHEEL DRIVE') ||
      hay.includes('ALL-WHEEL DRIVE')
    );
  }
  if (targetDt === 'RWD') {
    return vDt === 'RWD' || hay.includes('RWD') || hay.includes('REAR WHEEL DRIVE') || hay.includes('2WD');
  }
  if (targetDt === 'FWD') {
    return vDt === 'FWD' || hay.includes('FWD') || hay.includes('FRONT WHEEL DRIVE');
  }
  return vDt === targetDt || hay.includes(targetDt);
}

export function preFilterCandidates(rawGuest, candidates) {
  const guest = normalizeGuestSpecs(rawGuest);

  return candidates.filter((v) => {
    // 1. Make
    if (guest.make) {
      const targetMake = guest.make.trim().toLowerCase();
      const makeHay = `${v.make || ''} ${v.title || ''}`.toLowerCase();
      if (!makeHay.includes(targetMake)) {
        return false;
      }
    }

    // 2. Model (exact model disambiguation: e.g. F150 -> F-150, Bronco != Bronco Sport, CX-5 != CX-50)
    if (guest.model && !doesVehicleMatchModel(guest.model, v)) {
      return false;
    }

    // 3. Trim (strict word-boundary trim check: e.g. XLT != XL, XL != XLT, ST != STX/ST-Line)
    if (guest.trim && !doesVehicleMatchTrim(guest.trim, v)) {
      return false;
    }

    // 4. Truck Bed Length (strict check: e.g. "6.5ft bed" -> ONLY verified 6.5' bed trucks)
    if (guest.bedLength) {
      const vBed =
        v.bedLength ||
        extractBedLengthFromVehicle(
          v,
          v.fullCommentsSearchText || v.commentsSummary || ''
        );
      if (!vBed || vBed.replace(/'$/, '') !== String(guest.bedLength).replace(/'$/, '')) {
        return false;
      }
    }

    // 5. Cab Style (Regular Cab / SuperCab / Crew Cab)
    if (guest.cabStyle && !doesVehicleMatchCabStyle(guest.cabStyle, v)) {
      return false;
    }

    // 6. Engine / Powertrain (strict only when not in a "preferred" clause)
    if (guest.engineSpec && !doesVehicleMatchEngine(guest.engineSpec, v)) {
      return false;
    }

    // 7. Drivetrain
    if (guest.drivetrain && guest.drivetrain !== 'Any') {
      if (!doesVehicleMatchDrivetrain(guest.drivetrain, v)) {
        return false;
      }
    }

    // 8. Exterior Color
    if (guest.exteriorColor && !doesVehicleMatchColor(guest.exteriorColor, v)) {
      return false;
    }

    // 9. Explicit Strict Equipment / Package Codes (e.g. FX4, 302A, Black Appearance, Tow/Haul)
    if (
      Array.isArray(guest.strictPackages) &&
      guest.strictPackages.length > 0 &&
      !doesVehicleMatchStrictPackages(guest.strictPackages, v)
    ) {
      return false;
    }

    // 10. Year range
    if (guest.minYear && v.year && v.year < Number(guest.minYear)) {
      return false;
    }
    if (guest.maxYear && v.year && v.year > Number(guest.maxYear)) {
      return false;
    }

    // 11. Strict maxPrice cap
    if (guest.maxPrice != null && Number(guest.maxPrice) > 0) {
      const cap = Number(guest.maxPrice);
      const effectivePrice =
        typeof v.price === 'number' && v.price > 0
          ? v.price
          : typeof v.msrp === 'number' && v.msrp > 0
            ? v.msrp
            : null;
      if (effectivePrice == null || effectivePrice > cap) {
        return false;
      }
    }

    // 12. Max Mileage cap
    if (guest.maxMileage && typeof v.mileage === 'number' && v.mileage > Number(guest.maxMileage)) {
      return false;
    }

    // 13. Condition
    if (guest.condition && guest.condition !== 'Any') {
      const c = guest.condition.toLowerCase();
      const vc = (v.condition || '').toLowerCase();
      if (c === 'new' && !vc.includes('new')) return false;
      if (c === 'cpo' && !vc.includes('certified')) return false;
      if (c === 'pre-owned' && vc.includes('new') && !vc.includes('pre')) return false;
    }

    // 14. Dealership / Town location hints
    if (Array.isArray(guest.locationHints) && guest.locationHints.length > 0) {
      const locHay = `${v.location || ''} ${v.dealerCity || ''} ${v.dealerState || ''}`.toLowerCase();
      const matchesLocation = guest.locationHints.some((hint) => locHay.includes(hint));
      if (!matchesLocation) return false;
    }

    return true;
  });
}

export function deterministicEvaluate(rawGuest, candidates) {
  const guest = normalizeGuestSpecs(rawGuest);
  const strictFiltered = preFilterCandidates(guest, candidates);
  const results = [];

  const desiredFeatures = [...(Array.isArray(guest.features) ? guest.features : [])];
  const preferenceClauses = Array.isArray(guest.preferenceClauses) ? guest.preferenceClauses : [];

  for (const v of strictFiltered) {
    const matchedFeatures = [];
    let score = 84;

    const vBed =
      v.bedLength ||
      extractBedLengthFromVehicle(v, v.fullCommentsSearchText || v.commentsSummary || '');

    // 1. Bed Length badge (prominently surfaced when requested or known on trucks)
    if (guest.bedLength) {
      matchedFeatures.push(`${formatBedLengthLabel(guest.bedLength)} (Verified)`);
      score += 6;
    } else if (vBed) {
      matchedFeatures.push(formatBedLengthLabel(vBed));
    }

    // 2. Trim badge
    if (guest.trim) {
      matchedFeatures.push(`${v.trim || guest.trim} Trim Package`);
      score += 5;
    } else if (v.trim) {
      matchedFeatures.push(`${v.trim} Trim`);
    }

    // 3. Cab Style & Engine badges
    if (guest.cabStyle) {
      matchedFeatures.push(v.bodyStyle || guest.cabStyle);
      score += 3;
    }
    if (guest.engineSpec) {
      matchedFeatures.push(`${guest.engineSpec} Powertrain`);
      score += 3;
    }

    // 4. Drivetrain badge
    if (guest.drivetrain && guest.drivetrain !== 'Any') {
      matchedFeatures.push(`${v.drivetrain || guest.drivetrain} Drivetrain`);
      score += 4;
    } else if (v.drivetrain) {
      matchedFeatures.push(`${v.drivetrain} Drivetrain`);
    }

    // 5. Make / Model / Condition badge
    if (guest.make && v.make) {
      matchedFeatures.push(`${v.year || ''} ${v.make} ${v.model} (${v.condition})`.trim());
    }

    // 6. Price check
    if (guest.maxPrice && v.price) {
      const savings = Math.round(Number(guest.maxPrice) - v.price);
      matchedFeatures.push(
        savings > 0
          ? `$${v.price.toLocaleString()} Preston Price ($${savings.toLocaleString()} under $${Number(guest.maxPrice).toLocaleString()} cap)`
          : `Meets $${Number(guest.maxPrice).toLocaleString()} Max Budget`
      );
      score += 4;
    }

    // 7. Year, Mileage, Color & Strict Packages
    if ((guest.minYear || guest.maxYear) && v.year) {
      matchedFeatures.push(`${v.year} ${v.condition} Model Year`);
    }
    if (guest.maxMileage && typeof v.mileage === 'number') {
      matchedFeatures.push(
        `${v.mileage.toLocaleString()} mi (Under ${Number(guest.maxMileage).toLocaleString()} mi limit)`
      );
    }
    if (guest.exteriorColor && v.exteriorColor) {
      matchedFeatures.push(`${v.exteriorColor} Exterior`);
      score += 3;
    }
    if (Array.isArray(guest.strictPackages)) {
      for (const pkg of guest.strictPackages) {
        matchedFeatures.push(pkg);
        score += 3;
      }
    }

    // 8. Soft / Preferred features against vehicle highlights + build sheet
    const vHighlights = Array.isArray(v.highlights) ? v.highlights : [];
    const fullText =
      `${vHighlights.join(' | ')} | ${v.engine || ''} | ${v.transmission || ''} | ${v.exteriorColor || ''} | ${v.interiorColor || ''} | ${v.location || ''} | ${v.fullCommentsSearchText || v.commentsSummary || ''}`.toLowerCase();

    for (const reqFeat of desiredFeatures) {
      const cleanReq = reqFeat.trim();
      if (!cleanReq) continue;
      const keywords = cleanReq
        .toLowerCase()
        .replace(/[^a-z0-9\s]/g, ' ')
        .split(/\s+/)
        .filter((w) => w.length >= 3);

      const exactHighlight = vHighlights.find(
        (h) =>
          h.toLowerCase().includes(cleanReq.toLowerCase()) ||
          keywords.some((kw) => h.toLowerCase().includes(kw))
      );

      if (exactHighlight) {
        matchedFeatures.push(exactHighlight);
        score += 2;
      } else if (keywords.length > 0 && keywords.some((kw) => fullText.includes(kw))) {
        matchedFeatures.push(cleanReq);
        score += 1;
      }
    }

    for (const pref of preferenceClauses) {
      const kws = pref
        .toLowerCase()
        .replace(/\b(?:prefer(?:s|red)?|ideally|nice\s+to\s+have|optional|if\s+possible)\b/gi, ' ')
        .split(/\s+/)
        .filter((w) => w.length >= 3);
      if (kws.length > 0 && kws.some((kw) => fullText.includes(kw))) {
        score += 2;
      }
    }

    if (matchedFeatures.length < 5) {
      for (const h of vHighlights.slice(0, 6)) {
        const hLower = h.toLowerCase();
        const alreadyCovered = matchedFeatures.some(
          (mf) =>
            mf.toLowerCase() === hLower ||
            mf.toLowerCase().includes(hLower) ||
            (hLower === '4wd/awd' && mf.toLowerCase().includes('drivetrain'))
        );
        if (!alreadyCovered) {
          matchedFeatures.push(h);
        }
        if (matchedFeatures.length >= 6) break;
      }
    }

    const dedupedFeatures = Array.from(new Set(matchedFeatures)).slice(0, 8);
    const clampedScore = Math.min(99, score);

    const specSummaryParts = [
      guest.make || null,
      guest.model || null,
      guest.trim ? `${guest.trim} trim` : null,
      guest.bedLength ? formatBedLengthLabel(guest.bedLength) : null,
      guest.cabStyle || null,
      guest.drivetrain && guest.drivetrain !== 'Any' ? guest.drivetrain : null,
      guest.maxPrice ? `under $${Number(guest.maxPrice).toLocaleString()} budget` : null,
    ].filter(Boolean);

    results.push({
      vehicle: v,
      matchScore: clampedScore,
      matchedFeatures: dedupedFeatures,
      agentSummary: `Verified match at ${v.location}: ${v.title} (${v.condition}) priced at ${
        v.price ? `$${v.price.toLocaleString()}` : 'Call for Price'
      } satisfies ${guest.name}'s ${
        specSummaryParts.length > 0 ? specSummaryParts.join(', ') : 'target vehicle'
      } criteria.`,
    });
  }

  results.sort((a, b) => {
    if (b.matchScore !== a.matchScore) return b.matchScore - a.matchScore;
    const pa = a.vehicle.price ?? Number.MAX_SAFE_INTEGER;
    const pb = b.vehicle.price ?? Number.MAX_SAFE_INTEGER;
    return pa - pb;
  });

  return results;
}

function sampleAcrossLocations(vehicles, limit = 30) {
  if (vehicles.length <= limit) return vehicles;
  const byLoc = new Map();
  for (const v of vehicles) {
    const loc = v.location || 'Preston Automotive Group';
    if (!byLoc.has(loc)) byLoc.set(loc, []);
    byLoc.get(loc).push(v);
  }
  const picked = [];
  let idx = 0;
  while (picked.length < limit) {
    let addedInRound = false;
    for (const list of byLoc.values()) {
      if (idx < list.length) {
        picked.push(list[idx]);
        addedInRound = true;
        if (picked.length >= limit) break;
      }
    }
    if (!addedInRound) break;
    idx++;
  }
  return picked;
}

export async function evaluateInventoryWithGeminiAgent(rawGuest, candidates) {
  const guest = normalizeGuestSpecs(rawGuest);
  const apiKey = getSetting('gemini_api_key');
  const model = getSetting('gemini_model') || 'gemini-2.5-flash';

  const preFiltered = preFilterCandidates(guest, candidates);
  if (preFiltered.length === 0) {
    return {
      mode: apiKey ? 'gemini' : 'smart-matcher',
      matches: [],
      summary: `Scanned ${candidates.length} live prestonmotor.com vehicles; 0 met ${guest.name}'s exact vehicle criteria.`,
    };
  }

  const fullDeterministicMatches = deterministicEvaluate(guest, preFiltered);
  const deterministicByVin = new Map(
    fullDeterministicMatches.map((dm) => [dm.vehicle.vin, dm])
  );

  if (!apiKey) {
    const locCount = new Set(fullDeterministicMatches.map((m) => m.vehicle.location)).size;
    return {
      mode: 'smart-matcher',
      matches: fullDeterministicMatches,
      summary: `Scanned ${candidates.length} live prestonmotor.com vehicles across all pages; found ${fullDeterministicMatches.length} matching vehicle(s) across ${locCount} Preston dealership location(s).`,
    };
  }

  const sampledVehicles = sampleAcrossLocations(preFiltered, 30);
  const compactCandidates = sampledVehicles.map((v) => ({
    vin: v.vin,
    title: v.title,
    year: v.year,
    make: v.make,
    model: v.model,
    trim: v.trim,
    bodyStyle: v.bodyStyle,
    bedLength: v.bedLength || '',
    condition: v.condition,
    price: v.price,
    location: v.location,
    mileage: v.mileage,
    drivetrain: v.drivetrain,
    engine: v.engine,
    exteriorColor: v.exteriorColor,
    interiorColor: v.interiorColor,
    highlights: v.highlights,
    packagesAndComments: v.commentsSummary,
  }));

  const guestCriteria = {
    guestName: guest.name,
    condition: guest.condition,
    minYear: guest.minYear,
    maxYear: guest.maxYear,
    make: guest.make,
    model: guest.model,
    trim: guest.trim,
    bedLength: guest.bedLength || '',
    cabStyle: guest.cabStyle || '',
    engineSpec: guest.engineSpec || '',
    maxPrice: guest.maxPrice,
    maxMileage: guest.maxMileage,
    drivetrain: guest.drivetrain,
    exteriorColor: guest.exteriorColor,
    exteriorColors: guest.exteriorColors || [],
    strictPackages: guest.strictPackages || [],
    mustHaveFeatures: guest.features,
    additionalNotesAndSpecs: guest.notes,
  };

  const systemPrompt = `You are the Preston Automotive Group Gemini Inventory Scout Agent.
Evaluate live vehicle listings from prestonmotor.com against the guest's exact target vehicle specifications and natural-language requirements.
Rules:
1. Only include vehicles that strictly satisfy EVERY specified requirement (make, exact model, exact trim, bedLength if specified, cabStyle if specified, drivetrain if specified, price cap if specified, exteriorColor/exteriorColors if specified — when multiple exteriorColors are listed, a vehicle matches if its exterior color matches ANY of the listed colors — and strict packages).
2. For each matching vehicle, populate "matchedFeatures" with 3 to 8 concrete, specific features of THAT vehicle that directly meet the guest's specs (e.g., "6.5 ft Bed (Verified)", "XLT Trim Package", "4WD Drivetrain", "Oxford White Exterior").
3. Provide a concise, helpful 1-2 sentence "agentSummary" explaining why this specific unit at its Preston dealership location fits the guest.`;

  const body = {
    systemInstruction: {
      parts: [{ text: systemPrompt }],
    },
    contents: [
      {
        role: 'user',
        parts: [
          {
            text: JSON.stringify({
              guestRequirements: guestCriteria,
              totalQualifyingInventoryCount: preFiltered.length,
              prestonMotorCandidatesSample: compactCandidates,
            }),
          },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
      responseSchema: {
        type: 'OBJECT',
        properties: {
          overallSummary: { type: 'STRING' },
          matches: {
            type: 'ARRAY',
            items: {
              type: 'OBJECT',
              properties: {
                vin: { type: 'STRING' },
                matchScore: { type: 'INTEGER' },
                matchedFeatures: {
                  type: 'ARRAY',
                  items: { type: 'STRING' },
                },
                agentSummary: { type: 'STRING' },
              },
              required: ['vin', 'matchScore', 'matchedFeatures', 'agentSummary'],
            },
          },
        },
        required: ['overallSummary', 'matches'],
      },
    },
  };

  try {
    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
      model
    )}:generateContent?key=${encodeURIComponent(apiKey)}`;

    const res = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30000),
    });

    if (!res.ok) {
      const errText = await res.text();
      throw new Error(`Gemini API HTTP ${res.status}: ${errText.slice(0, 160)}`);
    }

    const data = await res.json();
    const rawText = data?.candidates?.[0]?.content?.parts?.[0]?.text || '{}';
    const parsed = JSON.parse(rawText);
    const byVin = new Map(preFiltered.map((v) => [v.vin, v]));
    const sampledVinSet = new Set(sampledVehicles.map((v) => v.vin));

    const geminiByVin = new Map();
    for (const m of parsed.matches || []) {
      // Only allow VINs that already passed strict deterministic pre-filtering!
      const vehicle = byVin.get(m.vin);
      if (!vehicle || !deterministicByVin.has(m.vin)) continue;
      const detFeatures = deterministicByVin.get(m.vin)?.matchedFeatures || [];
      const combinedFeatures = Array.from(
        new Set([
          ...(guest.bedLength ? [`${formatBedLengthLabel(guest.bedLength)} (Verified)`] : []),
          ...(guest.trim ? [`${vehicle.trim || guest.trim} Trim Package`] : []),
          ...(Array.isArray(m.matchedFeatures) ? m.matchedFeatures : []),
          ...detFeatures,
        ])
      ).slice(0, 8);

      geminiByVin.set(m.vin, {
        vehicle,
        matchScore: Math.max(1, Math.min(100, Number(m.matchScore) || 90)),
        matchedFeatures: combinedFeatures,
        agentSummary: m.agentSummary || deterministicByVin.get(m.vin)?.agentSummary || '',
      });
    }

    const hasCustomNotes = String(guest.notes || '').trim().length > 0;
    let mergedMatches;
    if (geminiByVin.size === 0) {
      mergedMatches = fullDeterministicMatches;
    } else if (preFiltered.length <= 30 && hasCustomNotes) {
      mergedMatches = Array.from(geminiByVin.values());
    } else {
      // Every vehicle in fullDeterministicMatches already satisfied all strict structural criteria;
      // use Gemini's rich summary/score where available without dropping qualifying inventory!
      mergedMatches = fullDeterministicMatches.map((dm) => {
        const vin = dm.vehicle.vin;
        return geminiByVin.get(vin) || dm;
      });
    }

    mergedMatches.sort((a, b) => {
      if (b.matchScore !== a.matchScore) return b.matchScore - a.matchScore;
      const pa = a.vehicle.price ?? Number.MAX_SAFE_INTEGER;
      const pb = b.vehicle.price ?? Number.MAX_SAFE_INTEGER;
      return pa - pb;
    });

    const locCount = new Set(mergedMatches.map((m) => m.vehicle.location)).size;
    return {
      mode: 'gemini',
      matches: mergedMatches,
      summary: `Gemini Agent (${model}) scanned ${candidates.length} live prestonmotor.com vehicles and verified ${mergedMatches.length} match(es) across ${locCount} Preston dealership location(s).`,
    };
  } catch (err) {
    const locCount = new Set(fullDeterministicMatches.map((m) => m.vehicle.location)).size;
    return {
      mode: 'gemini-fallback',
      matches: fullDeterministicMatches,
      summary: `Scanned ${candidates.length} live prestonmotor.com vehicles (${fullDeterministicMatches.length} matches across ${locCount} locations). Note: Gemini fallback used (${err.message}).`,
    };
  }
}
