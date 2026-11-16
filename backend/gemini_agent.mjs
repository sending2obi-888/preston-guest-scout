import { getSetting } from './db.mjs';
import { normalizeGuestSpecs } from './preston_scraper.mjs';

function preFilterCandidates(rawGuest, candidates) {
  const guest = normalizeGuestSpecs(rawGuest);

  return candidates.filter((v) => {
    if (guest.make) {
      const targetMake = guest.make.trim().toLowerCase();
      if (
        v.make &&
        !v.make.toLowerCase().includes(targetMake) &&
        !v.title.toLowerCase().includes(targetMake)
      ) {
        return false;
      }
    }

    if (guest.model) {
      const tokens = guest.model
        .toLowerCase()
        .split(/[\s-]+/)
        .filter((t) => t.length >= 2);
      const hay = `${v.model} ${v.title} ${v.trim}`.toLowerCase().replace(/-/g, ' ');
      const normalizedTokens = guest.model
        .toLowerCase()
        .replace(/-/g, ' ')
        .split(/\s+/)
        .filter(Boolean);
      const matchesAll = normalizedTokens.every((t) => hay.includes(t));
      const matchesRaw = `${v.model} ${v.title}`
        .toLowerCase()
        .includes(guest.model.trim().toLowerCase());
      if (!matchesAll && !matchesRaw && tokens.length > 0) {
        return false;
      }
    }

    if (guest.minYear && v.year && v.year < Number(guest.minYear)) {
      return false;
    }
    if (guest.maxYear && v.year && v.year > Number(guest.maxYear)) {
      return false;
    }

    // Strict maxPrice check: when a budget cap (e.g. "under $60K") is specified,
    // require either a verified selling/final price <= maxPrice, or (if unpriced) an MSRP <= maxPrice.
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

    if (guest.maxMileage && typeof v.mileage === 'number' && v.mileage > Number(guest.maxMileage)) {
      return false;
    }

    if (guest.condition && guest.condition !== 'Any') {
      const c = guest.condition.toLowerCase();
      const vc = (v.condition || '').toLowerCase();
      if (c === 'new' && !vc.includes('new')) return false;
      if (c === 'cpo' && !vc.includes('certified')) return false;
      if (c === 'pre-owned' && vc.includes('new') && !vc.includes('pre')) return false;
    }

    // If the guest explicitly specified a dealership/town in notes (e.g., "Boulevard Ford" or "Millsboro"),
    // enforce that location requirement; otherwise include all Preston Automotive Group locations.
    if (Array.isArray(guest.locationHints) && guest.locationHints.length > 0) {
      const locHay = `${v.location || ''} ${v.dealerCity || ''} ${v.dealerState || ''}`.toLowerCase();
      const matchesLocation = guest.locationHints.some((hint) => locHay.includes(hint));
      if (!matchesLocation) return false;
    }

    return true;
  });
}

function deterministicEvaluate(rawGuest, candidates) {
  const guest = normalizeGuestSpecs(rawGuest);
  const strictFiltered = preFilterCandidates(guest, candidates);
  const results = [];

  const desiredFeatures = [...(Array.isArray(guest.features) ? guest.features : [])];
  const noteTokens = (guest.notes || '')
    .split(/[,;\n•]+/)
    .map((s) => s.trim())
    .filter((s) => s.length >= 3 && s.length <= 55);

  for (const v of strictFiltered) {
    const matchedFeatures = [];
    let score = 80;

    // 1. Drivetrain check
    if (guest.drivetrain && guest.drivetrain !== 'Any') {
      const targetDt = guest.drivetrain.toUpperCase();
      const vDt = (v.drivetrain || '').toUpperCase();
      const hay = `${vDt} ${v.highlights.join(' ')} ${v.commentsSummary}`.toUpperCase();
      if (
        vDt === targetDt ||
        hay.includes(targetDt) ||
        (targetDt === '4WD' && (hay.includes('4X4') || hay.includes('4WD/AWD'))) ||
        (targetDt === 'AWD' && hay.includes('4WD/AWD'))
      ) {
        matchedFeatures.push(`${v.drivetrain || targetDt} Drivetrain`);
        score += 5;
      } else {
        if (vDt && vDt !== targetDt) continue;
      }
    } else if (v.drivetrain) {
      matchedFeatures.push(`${v.drivetrain} Drivetrain`);
    }

    // 2. Trim check
    if (guest.trim) {
      const targetTrim = guest.trim.trim().toLowerCase();
      if (`${v.trim} ${v.title} ${v.commentsSummary}`.toLowerCase().includes(targetTrim)) {
        matchedFeatures.push(`${v.trim || guest.trim} Trim Package`);
        score += 5;
      } else {
        continue;
      }
    } else if (v.trim) {
      matchedFeatures.push(`${v.trim} Trim`);
    }

    // 3. Make / Condition badge
    if (guest.make && v.make) {
      matchedFeatures.push(`${v.year || ''} ${v.make} ${v.model} (${v.condition})`.trim());
    }

    // 4. Price check
    if (guest.maxPrice && v.price) {
      const savings = Math.round(Number(guest.maxPrice) - v.price);
      matchedFeatures.push(
        savings > 0
          ? `$${v.price.toLocaleString()} Preston Price ($${savings.toLocaleString()} under $${Number(guest.maxPrice).toLocaleString()} cap)`
          : `Meets $${Number(guest.maxPrice).toLocaleString()} Max Budget`
      );
      score += 4;
    }

    // 5. Year & Mileage check
    if ((guest.minYear || guest.maxYear) && v.year) {
      matchedFeatures.push(`${v.year} ${v.condition} Model Year`);
    }
    if (guest.maxMileage && typeof v.mileage === 'number') {
      matchedFeatures.push(
        `${v.mileage.toLocaleString()} mi (Under ${Number(guest.maxMileage).toLocaleString()} mi limit)`
      );
    }

    // 6. Color check
    if (guest.exteriorColor) {
      const targetColor = guest.exteriorColor.trim().toLowerCase();
      if ((v.exteriorColor || '').toLowerCase().includes(targetColor)) {
        matchedFeatures.push(`${v.exteriorColor} Exterior`);
        score += 3;
      }
    }

    // 7. Specific requested features & notes against vehicle highlights + build sheet
    const fullText =
      `${v.highlights.join(' | ')} | ${v.engine} | ${v.transmission} | ${v.exteriorColor} | ${v.interiorColor} | ${v.location} | ${v.commentsSummary}`.toLowerCase();

    for (const reqFeat of desiredFeatures) {
      const cleanReq = reqFeat.trim();
      if (!cleanReq) continue;
      const keywords = cleanReq
        .toLowerCase()
        .replace(/[^a-z0-9\s]/g, ' ')
        .split(/\s+/)
        .filter((w) => w.length >= 3);

      const exactHighlight = v.highlights.find(
        (h) =>
          h.toLowerCase().includes(cleanReq.toLowerCase()) ||
          keywords.some((kw) => h.toLowerCase().includes(kw))
      );

      if (exactHighlight) {
        matchedFeatures.push(exactHighlight);
        score += 3;
      } else if (keywords.length > 0 && keywords.some((kw) => fullText.includes(kw))) {
        matchedFeatures.push(cleanReq);
        score += 2;
      }
    }

    for (const phrase of noteTokens) {
      const kws = phrase
        .toLowerCase()
        .replace(/\$?\d+(?:,\d{3})*(?:\.\d+)?\s*(?:k|thousand)?/gi, ' ')
        .split(/\s+/)
        .filter(
          (w) =>
            w.length >= 4 &&
            !['must', 'have', 'with', 'prefer', 'wants', 'needs', 'under', 'below', 'ford', 'lincoln'].includes(
              w
            )
        );
      if (kws.length > 0 && kws.every((kw) => fullText.includes(kw))) {
        matchedFeatures.push(phrase);
        score += 2;
      }
    }

    // Fill in standout vehicle highlights if user kept feature requirements broad (e.g. "Ford under $60K")
    if (matchedFeatures.length < 5) {
      for (const h of v.highlights.slice(0, 5)) {
        if (!matchedFeatures.includes(h)) {
          matchedFeatures.push(h);
        }
        if (matchedFeatures.length >= 6) break;
      }
    }

    const dedupedFeatures = Array.from(new Set(matchedFeatures)).slice(0, 8);
    const clampedScore = Math.min(99, score);

    results.push({
      vehicle: v,
      matchScore: clampedScore,
      matchedFeatures: dedupedFeatures,
      agentSummary: `Verified match at ${v.location}: ${v.title} (${v.condition}) priced at ${
        v.price ? `$${v.price.toLocaleString()}` : 'Call for Price'
      } satisfies ${guest.name}'s ${
        [
          guest.make || null,
          guest.minYear || guest.maxYear ? 'model year' : null,
          guest.maxPrice ? `under $${Number(guest.maxPrice).toLocaleString()} budget` : null,
          guest.drivetrain && guest.drivetrain !== 'Any' ? guest.drivetrain : null,
          desiredFeatures.length > 0 ? 'feature' : 'inventory',
        ]
          .filter(Boolean)
          .join(', ')
      } criteria.`,
    });
  }

  // Sort highest match score first, then lowest price so best-value deals surface cleanly,
  // WITHOUT truncating results so ALL qualifying vehicles across all Preston locations are returned.
  results.sort((a, b) => {
    if (b.matchScore !== a.matchScore) return b.matchScore - a.matchScore;
    const pa = a.vehicle.price ?? Number.MAX_SAFE_INTEGER;
    const pb = b.vehicle.price ?? Number.MAX_SAFE_INTEGER;
    return pa - pb;
  });

  return results;
}

/**
 * Selects a diverse sample across dealerships when sending a batch to Gemini so
 * multi-location inventories (Hurlock, Millsboro, Pittsville, Aberdeen, etc.) are
 * all represented in Gemini's semantic pass, while ALL remaining qualifying vehicles
 * are preserved via hybrid merge (zero match truncation).
 */
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
      summary: `Scanned ${candidates.length} live prestonmotor.com vehicles; 0 met ${guest.name}'s core year/make/model/budget filters.`,
    };
  }

  // Always compute full-inventory deterministic matches across ALL qualifying vehicles (no cap)
  const fullDeterministicMatches = deterministicEvaluate(guest, preFiltered);

  if (!apiKey) {
    const locCount = new Set(fullDeterministicMatches.map((m) => m.vehicle.location)).size;
    return {
      mode: 'smart-matcher',
      matches: fullDeterministicMatches,
      summary: `Scanned ${candidates.length} live prestonmotor.com vehicles across all pages; found ${fullDeterministicMatches.length} matching vehicle(s) across ${locCount} Preston dealership location(s).`,
    };
  }

  // Sample up to 30 vehicles distributed across all Preston dealerships for Gemini LLM enrichment
  const sampledVehicles = sampleAcrossLocations(preFiltered, 30);
  const compactCandidates = sampledVehicles.map((v) => ({
    vin: v.vin,
    title: v.title,
    year: v.year,
    make: v.make,
    model: v.model,
    trim: v.trim,
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
    maxPrice: guest.maxPrice,
    maxMileage: guest.maxMileage,
    drivetrain: guest.drivetrain,
    exteriorColor: guest.exteriorColor,
    mustHaveFeatures: guest.features,
    additionalNotesAndSpecs: guest.notes,
  };

  const systemPrompt = `You are the Preston Automotive Group Gemini Inventory Scout Agent.
Evaluate live vehicle listings from prestonmotor.com against the guest's target vehicle specifications and requirements.
Rules:
1. Only include vehicles that genuinely satisfy the guest's core requirements (make, model if specified, trim if specified, drivetrain if specified, price cap if specified, and critical must-have features).
2. For each matching vehicle, populate "matchedFeatures" with 3 to 8 concrete, specific features of THAT vehicle that directly meet the guest's previously input specs & requirements (e.g., "4WD Drivetrain", "Reserve Trim", "Apple CarPlay & Navigation", "$42,900 ($17,100 under $60,000 cap)", "Oxford White Exterior").
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
      temperature: 0.15,
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
      const vehicle = byVin.get(m.vin);
      if (!vehicle) continue;
      geminiByVin.set(m.vin, {
        vehicle,
        matchScore: Math.max(1, Math.min(100, Number(m.matchScore) || 88)),
        matchedFeatures: Array.isArray(m.matchedFeatures) ? m.matchedFeatures : [],
        agentSummary: m.agentSummary || '',
      });
    }

    // If all candidates fit inside Gemini's single-call window (<= 30), use Gemini's exact verified list.
    // If there are more than 30 qualifying vehicles (e.g., "Ford under $60K" -> 1,000+ matches across
    // all Preston dealerships including Boulevard Ford in Millsboro), merge Gemini's enriched cards
    // with the full verified inventory so NO qualifying vehicle is ever dropped!
    let mergedMatches;
    if (preFiltered.length <= 30) {
      mergedMatches = Array.from(geminiByVin.values());
    } else {
      mergedMatches = [];
      for (const dm of fullDeterministicMatches) {
        const vin = dm.vehicle.vin;
        if (geminiByVin.has(vin)) {
          mergedMatches.push(geminiByVin.get(vin));
        } else if (!sampledVinSet.has(vin)) {
          mergedMatches.push(dm);
        }
      }
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
