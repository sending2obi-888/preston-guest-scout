import { getSetting } from './db.mjs';

function preFilterCandidates(guest, candidates) {
  return candidates.filter((v) => {
    if (guest.make) {
      const targetMake = guest.make.trim().toLowerCase();
      if (v.make && !v.make.toLowerCase().includes(targetMake) && !v.title.toLowerCase().includes(targetMake)) {
        return false;
      }
    }
    if (guest.model) {
      const tokens = guest.model
        .toLowerCase()
        .split(/[\s-]+/)
        .filter((t) => t.length >= 2);
      const hay = `${v.model} ${v.title} ${v.trim}`.toLowerCase().replace(/-/g, ' ');
      const normalizedTokens = guest.model.toLowerCase().replace(/-/g, ' ').split(/\s+/).filter(Boolean);
      const matchesAll = normalizedTokens.every((t) => hay.includes(t));
      const matchesRaw = `${v.model} ${v.title}`.toLowerCase().includes(guest.model.trim().toLowerCase());
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
    if (guest.maxPrice && v.price && v.price > Number(guest.maxPrice)) {
      return false;
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
    return true;
  });
}

function deterministicEvaluate(guest, candidates) {
  const strictFiltered = preFilterCandidates(guest, candidates);
  const results = [];

  const desiredFeatures = [
    ...(Array.isArray(guest.features) ? guest.features : []),
  ];
  const noteTokens = (guest.notes || '')
    .split(/[,;\n•]+/)
    .map((s) => s.trim())
    .filter((s) => s.length >= 3 && s.length <= 55);

  for (const v of strictFiltered) {
    const matchedFeatures = [];
    let score = 78;

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
        // Hard requirement mismatch if explicit drivetrain requested and vehicle clearly differs
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

    // 3. Price check
    if (guest.maxPrice && v.price) {
      const savings = Math.round(Number(guest.maxPrice) - v.price);
      matchedFeatures.push(
        savings > 0
          ? `$${v.price.toLocaleString()} Preston Price ($${savings.toLocaleString()} under $${Number(guest.maxPrice).toLocaleString()} cap)`
          : `Meets $${Number(guest.maxPrice).toLocaleString()} Max Budget`
      );
      score += 4;
    }

    // 4. Year & Condition check
    if ((guest.minYear || guest.maxYear) && v.year) {
      matchedFeatures.push(`${v.year} ${v.condition} Model Year`);
    }
    if (guest.maxMileage && typeof v.mileage === 'number') {
      matchedFeatures.push(`${v.mileage.toLocaleString()} mi (Under ${Number(guest.maxMileage).toLocaleString()} mi limit)`);
    }

    // 5. Color check
    if (guest.exteriorColor) {
      const targetColor = guest.exteriorColor.trim().toLowerCase();
      if ((v.exteriorColor || '').toLowerCase().includes(targetColor)) {
        matchedFeatures.push(`${v.exteriorColor} Exterior`);
        score += 3;
      }
    }

    // 6. Specific requested features & notes against vehicle highlights + build sheet
    const fullText = `${v.highlights.join(' | ')} | ${v.engine} | ${v.transmission} | ${v.exteriorColor} | ${v.interiorColor} | ${v.commentsSummary}`.toLowerCase();

    for (const reqFeat of desiredFeatures) {
      const cleanReq = reqFeat.trim();
      if (!cleanReq) continue;
      const keywords = cleanReq
        .toLowerCase()
        .replace(/[^a-z0-9\s]/g, ' ')
        .split(/\s+/)
        .filter((w) => w.length >= 3);

      const exactHighlight = v.highlights.find((h) =>
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
        .split(/\s+/)
        .filter((w) => w.length >= 4 && !['must', 'have', 'with', 'prefer', 'wants', 'needs', 'under'].includes(w));
      if (kws.length > 0 && kws.every((kw) => fullText.includes(kw))) {
        matchedFeatures.push(phrase);
        score += 2;
      }
    }

    // Fill in standout vehicle highlights if user kept feature requirements broad
    if (matchedFeatures.length < 4) {
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
      } satisfies ${guest.name}'s ${[
        guest.minYear || guest.maxYear ? 'model year' : null,
        guest.maxPrice ? 'budget' : null,
        guest.drivetrain && guest.drivetrain !== 'Any' ? guest.drivetrain : null,
        desiredFeatures.length > 0 ? 'feature' : 'inventory',
      ]
        .filter(Boolean)
        .join(', ')} criteria.`,
    });
  }

  results.sort((a, b) => b.matchScore - a.matchScore);
  return results.slice(0, 25);
}

export async function evaluateInventoryWithGeminiAgent(guest, candidates) {
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

  if (!apiKey) {
    const matches = deterministicEvaluate(guest, preFiltered);
    return {
      mode: 'smart-matcher',
      matches,
      summary: `Scanned ${candidates.length} live prestonmotor.com vehicles (${preFiltered.length} candidates); found ${matches.length} match(es). Add a Gemini API key in Settings to enable full Gemini LLM semantic reasoning.`,
    };
  }

  // Prepare compact candidate payload for Gemini Agent (up to 35 top candidates)
  const compactCandidates = preFiltered.slice(0, 35).map((v) => ({
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
1. Only include vehicles that genuinely satisfy the guest's core requirements (make, model, trim if specified, drivetrain if specified, price cap if specified, and critical must-have features).
2. For each matching vehicle, populate "matchedFeatures" with 3 to 8 concrete, specific features of THAT vehicle that directly meet the guest's previously input specs & requirements (e.g., "4WD Drivetrain", "Reserve Trim", "Apple CarPlay & Navigation", "Leather Heated Seats", "$28,900 ($1,100 under $30,000 budget)", "Rhapsody Blue Exterior").
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
              prestonMotorCandidates: compactCandidates,
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

    const hydrated = [];
    for (const m of parsed.matches || []) {
      const vehicle = byVin.get(m.vin);
      if (!vehicle) continue;
      hydrated.push({
        vehicle,
        matchScore: Math.max(1, Math.min(100, Number(m.matchScore) || 88)),
        matchedFeatures: Array.isArray(m.matchedFeatures) ? m.matchedFeatures : [],
        agentSummary: m.agentSummary || '',
      });
    }

    hydrated.sort((a, b) => b.matchScore - a.matchScore);
    return {
      mode: 'gemini',
      matches: hydrated,
      summary:
        parsed.overallSummary ||
        `Gemini Agent (${model}) evaluated ${compactCandidates.length} prestonmotor.com candidates and verified ${hydrated.length} match(es).`,
    };
  } catch (err) {
    // Graceful fallback so twice-daily searches never drop matches on transient API issues
    const fallbackMatches = deterministicEvaluate(guest, preFiltered);
    return {
      mode: 'gemini-fallback',
      matches: fallbackMatches,
      summary: `Scanned ${candidates.length} live prestonmotor.com vehicles (${fallbackMatches.length} matches). Note: Gemini fallback used (${err.message}).`,
    };
  }
}
