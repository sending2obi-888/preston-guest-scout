import crypto from 'node:crypto';
import { db, getSetting } from './db.mjs';

const VPIC_BASE = 'https://vpic.nhtsa.dot.gov/api/vehicles';
const NHTSA_API_BASE = 'https://api.nhtsa.gov';
const NHTSA_RECALLS_WEB_URL = 'https://www.nhtsa.gov/recalls';

/**
 * Validates and normalizes a standard 17-character Vehicle Identification Number (VIN).
 */
export function validateAndNormalizeVin(rawVin) {
  const cleaned = String(rawVin || '')
    .toUpperCase()
    .replace(/[\s-]+/g, '')
    .trim();

  if (!cleaned) {
    return { valid: false, vin: '', error: 'Please enter a 17-character VIN.' };
  }
  if (cleaned.length !== 17) {
    return {
      valid: false,
      vin: cleaned,
      error: `VIN must be exactly 17 characters (currently ${cleaned.length}).`,
    };
  }
  const invalidChars = cleaned.match(/[IOQ]/g);
  if (invalidChars) {
    return {
      valid: false,
      vin: cleaned,
      error: `Invalid character(s) ${[...new Set(invalidChars)].join(', ')} — standard 17-character VINs never contain I, O, or Q (use 1 or 0 instead).`,
    };
  }
  if (!/^[A-HJ-NPR-Z0-9]{17}$/.test(cleaned)) {
    return {
      valid: false,
      vin: cleaned,
      error: 'VIN must contain only letters A–Z (excluding I, O, Q) and digits 0–9.',
    };
  }
  return { valid: true, vin: cleaned, error: '' };
}

function titleCaseMake(rawMake) {
  const s = String(rawMake || '').trim();
  if (!s) return '';
  const upper = s.toUpperCase();
  if (['BMW', 'GMC', 'RAM', 'MINI', 'KIA', 'FIAT'].includes(upper)) {
    return upper === 'RAM' ? 'Ram' : upper === 'KIA' ? 'Kia' : upper;
  }
  if (upper === 'MERCEDES-BENZ') return 'Mercedes-Benz';
  return s
    .toLowerCase()
    .split(/(\s+|-)/)
    .map((part) =>
      /^[a-z]/.test(part) ? part.charAt(0).toUpperCase() + part.slice(1) : part
    )
    .join('');
}

/**
 * Parses NHTSA's DD/MM/YYYY date format (e.g. "10/05/2024" -> May 10, 2024 & "2024-05-10").
 */
export function parseNhtsaReportDate(rawDate) {
  const s = String(rawDate || '').trim();
  if (!s) return { displayDate: '', isoDate: '' };

  const dmy = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (dmy) {
    const day = Number(dmy[1]);
    const month = Number(dmy[2]);
    const year = Number(dmy[3]);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      const dt = new Date(Date.UTC(year, month - 1, day));
      const isoDate = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
      const displayDate = dt.toLocaleDateString('en-US', {
        timeZone: 'UTC',
        month: 'short',
        day: 'numeric',
        year: 'numeric',
      });
      return { displayDate, isoDate };
    }
  }

  const parsed = new Date(s);
  if (!Number.isNaN(parsed.getTime())) {
    return {
      displayDate: parsed.toLocaleDateString('en-US', {
        month: 'short',
        day: 'numeric',
        year: 'numeric',
      }),
      isoDate: parsed.toISOString().slice(0, 10),
    };
  }

  return { displayDate: s, isoDate: '' };
}

async function decodeVinViaVpic(vin) {
  const url = `${VPIC_BASE}/DecodeVinValues/${encodeURIComponent(vin)}?format=json`;
  const res = await fetch(url, {
    headers: {
      Accept: 'application/json',
      'User-Agent': 'PrestonGuestScout/1.9 (NHTSA VIN Recall Checker)',
    },
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) {
    throw new Error(`NHTSA vPIC VIN decoder returned HTTP ${res.status}`);
  }
  const data = await res.json();
  const row = data?.Results?.[0] || {};

  const yearNum = Number(row.ModelYear) || null;
  const make = titleCaseMake(row.Make || '');
  const model = String(row.Model || '').trim();
  const trim = String(row.Trim || row.Series || '').trim();
  const series = [row.Series, row.Series2]
    .map((x) => String(x || '').trim())
    .filter(Boolean)
    .join(' • ');
  const bodyClass = [row.BodyClass, row.BodyCabType]
    .map((x) => String(x || '').trim())
    .filter((x) => x && !x.toLowerCase().includes('not applicable'))
    .join(' • ');

  const dispL = row.DisplacementL ? `${ Number(row.DisplacementL).toFixed(1) }L` : '';
  const cyl = row.EngineCylinders ? `${row.EngineCylinders}-Cyl` : '';
  const fuel = String(row.FuelTypePrimary || '').trim();
  const elec = String(row.ElectrificationLevel || '').trim();
  const turbo = String(row.Turbo || '').toLowerCase() === 'yes' ? 'Turbo' : '';
  const engine = [dispL, cyl, turbo, fuel]
    .filter(Boolean)
    .join(' ')
    .trim();

  const plant = [row.PlantCity, row.PlantState, row.PlantCountry]
    .map((x) => String(x || '').trim())
    .filter(Boolean)
    .join(', ');

  return {
    vin,
    year: yearNum,
    make,
    model,
    trim,
    series,
    bodyClass,
    driveType: String(row.DriveType || '').trim(),
    engine,
    displacementL: row.DisplacementL ? String(row.DisplacementL).trim() : '',
    cylinders: row.EngineCylinders ? String(row.EngineCylinders).trim() : '',
    fuelType: [fuel, elec].filter(Boolean).join(' • '),
    doors: String(row.Doors || '').trim(),
    plant,
    manufacturer: String(row.Manufacturer || '').trim(),
    errorCode: String(row.ErrorCode || '').trim(),
    errorText: String(row.ErrorText || '').trim(),
  };
}

/**
 * Matches a decoded vPIC model against NHTSA's recall-specific model taxonomy
 * (e.g., "Bronco" -> ["BRONCO 2DR", "BRONCO 4DR"] while excluding "BRONCO SPORT",
 * "Escape" -> ["ESCAPE GAS", "ESCAPE HEV", ...] filtered by fuel type, "F-250" -> ["F-250 SD"]).
 */
export function selectMatchingNhtsaRecallModels(decodedVehicle, nhtsaModels = []) {
  const baseModel = String(decodedVehicle?.model || '').trim();
  if (!baseModel) return [];

  const candidates = new Set();
  const lowerBase = baseModel.toLowerCase();
  const compactBase = lowerBase.replace(/[^a-z0-9]+/g, '');
  const fuelLower = String(decodedVehicle?.fuelType || '').toLowerCase();
  const doors = String(decodedVehicle?.doors || '').trim();

  for (const rawCandidate of nhtsaModels) {
    const cand = String(rawCandidate || '').trim();
    if (!cand) continue;
    const lowerCand = cand.toLowerCase();
    const compactCand = lowerCand.replace(/[^a-z0-9]+/g, '');

    // Guard against distinct vehicle line prefix collisions!
    if (lowerBase === 'bronco' && /\bbronco\s+sport\b/i.test(lowerCand)) continue;
    if (lowerBase === 'mustang' && /\bmach[\s-]*e\b/i.test(lowerCand)) continue;
    if (lowerBase === 'cherokee' && /\bgrand\s+cherokee\b/i.test(lowerCand)) continue;
    if (lowerBase === 'wagoneer' && /\bgrand\s+wagoneer\b/i.test(lowerCand)) continue;
    if (lowerBase === 'expedition' && /\bexpedition\s+max\b/i.test(lowerCand)) continue;
    if (lowerBase === 'navigator' && /\bnavigator\s+l\b/i.test(lowerCand)) continue;
    if (lowerBase === 'corolla' && /\bcorolla\s+cross\b/i.test(lowerCand)) continue;
    if (lowerBase === 'highlander' && /\bgrand\s+highlander\b/i.test(lowerCand)) continue;
    if (/^f[\s-]*150$/i.test(baseModel) && /\blightning\b/i.test(lowerCand)) continue;

    // Filter 2DR vs 4DR if doors is explicitly decoded
    if (doors === '2' && /\b4\s*dr\b/i.test(lowerCand)) continue;
    if (doors === '4' && /\b2\s*dr\b/i.test(lowerCand)) continue;

    // Filter PHEV / HEV / BEV vs GAS if fuel/electrification is explicitly decoded
    const isPlugIn = /plug[\s-]*in|phev/i.test(fuelLower);
    const isHybrid = !isPlugIn && /hybrid|hev/i.test(fuelLower);
    const isElectric = /electric|bev/i.test(fuelLower) && !/hybrid|hev/i.test(fuelLower);
    if (!isPlugIn && /\bphev\b|plug[\s-]*in/i.test(lowerCand)) continue;
    if (!isHybrid && /\bhev\b/i.test(lowerCand) && !/\bphev\b/i.test(lowerCand)) continue;
    if (!isElectric && /\bbev\b|\belectric\b|\blightning\b|\bev\b/i.test(lowerCand)) continue;
    if ((isPlugIn || isHybrid || isElectric) && /\bgas\b/i.test(lowerCand)) continue;

    // Check F-series match (e.g. F-250 matches F-250, F-250 SD, SUPER DUTY F-250)
    const fMatch = baseModel.match(/^f[\s-]*(\d{3})$/i);
    if (fMatch) {
      if (new RegExp(`\\bf[\\s-]*${fMatch[1]}\\b`, 'i').test(lowerCand)) {
        candidates.add(cand);
      }
      continue;
    }

    const baseWords = lowerBase.replace(/[-+]/g, ' ').split(/\s+/).filter(Boolean);
    const candWords = lowerCand.replace(/[-+]/g, ' ');
    const allTokensMatch = baseWords.every((w) =>
      new RegExp(`\\b${w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i').test(candWords)
    );

    if (allTokensMatch || compactCand === compactBase) {
      candidates.add(cand);
    }
  }

  candidates.add(baseModel);
  return Array.from(candidates);
}

async function fetchNhtsaRecallsForDecodedVehicle(decoded) {
  if (!decoded.year || !decoded.make || !decoded.model) {
    return { recalls: [], queriedModels: [], nhtsaSiteReachable: false };
  }

  const nhtsaVinPageUrl = `${NHTSA_RECALLS_WEB_URL}?vin=${encodeURIComponent(decoded.vin)}`;

  // Check www.nhtsa.gov/recalls reachability + fetch NHTSA recall model taxonomy in parallel
  const [siteCheckRes, modelsRes] = await Promise.allSettled([
    fetch(nhtsaVinPageUrl, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36',
        Accept: 'text/html,application/xhtml+xml',
      },
      signal: AbortSignal.timeout(10000),
    }),
    fetch(
      `${NHTSA_API_BASE}/products/vehicle/models?modelYear=${encodeURIComponent(
        decoded.year
      )}&make=${encodeURIComponent(decoded.make)}&issueType=r`,
      {
        headers: { Accept: 'application/json', 'User-Agent': 'PrestonGuestScout/1.9' },
        signal: AbortSignal.timeout(12000),
      }
    ),
  ]);

  const nhtsaSiteReachable =
    siteCheckRes.status === 'fulfilled' && siteCheckRes.value.status >= 200 && siteCheckRes.value.status < 400;

  let taxonomyModels = [];
  if (modelsRes.status === 'fulfilled' && modelsRes.value.ok) {
    try {
      const mj = await modelsRes.value.json();
      taxonomyModels = (mj?.results || []).map((r) => r.model).filter(Boolean);
    } catch {}
  }

  const modelsToQuery = selectMatchingNhtsaRecallModels(decoded, taxonomyModels);
  const byCampaign = new Map();

  await Promise.all(
    modelsToQuery.map(async (modelName) => {
      try {
        const qs = new URLSearchParams({
          make: decoded.make,
          model: modelName,
          modelYear: String(decoded.year),
        });
        const r = await fetch(`${NHTSA_API_BASE}/recalls/recallsByVehicle?${qs.toString()}`, {
          headers: { Accept: 'application/json', 'User-Agent': 'PrestonGuestScout/1.9' },
          signal: AbortSignal.timeout(15000),
        });
        if (!r.ok) return;
        const j = await r.json();
        const items = Array.isArray(j?.results)
          ? j.results
          : Array.isArray(j?.Results)
            ? j.Results
            : [];
        for (const item of items) {
          const campaign = String(item.NHTSACampaignNumber || '').trim();
          if (!campaign || byCampaign.has(campaign)) continue;
          const { displayDate, isoDate } = parseNhtsaReportDate(item.ReportReceivedDate);
          byCampaign.set(campaign, {
            campaignNumber: campaign,
            manufacturer: String(item.Manufacturer || decoded.manufacturer || '').trim(),
            component: String(item.Component || 'Vehicle Safety System').trim(),
            reportDate: displayDate,
            reportIsoDate: isoDate,
            summary: String(item.Summary || '').replace(/\s+/g, ' ').trim(),
            consequence: String(item.Consequence || '').replace(/\s+/g, ' ').trim(),
            remedy: String(item.Remedy || '').replace(/\s+/g, ' ').trim(),
            notes: String(item.Notes || '').replace(/\s+/g, ' ').trim(),
            parkIt: Boolean(item.parkIt),
            parkOutSide: Boolean(item.parkOutSide),
            overTheAirUpdate: Boolean(item.overTheAirUpdate),
            nhtsaModelMatched: String(item.Model || modelName).trim(),
            applicability: 'Applies to Vehicle Line',
            geminiNote: '',
          });
        }
      } catch {
        // Ignore transient model variant error
      }
    })
  );

  const recalls = Array.from(byCampaign.values()).sort((a, b) =>
    (b.reportIsoDate || '').localeCompare(a.reportIsoDate || '')
  );

  return {
    recalls,
    queriedModels: modelsToQuery,
    nhtsaSiteReachable,
  };
}

/**
 * Deterministic powertrain/spec cross-check when filtering or annotating NHTSA campaigns
 * against the VIN's exact decoded engine displacement / fuel type.
 */
function annotateRecallApplicabilityDeterministically(decoded, recalls) {
  const vDisp = decoded.displacementL ? Number(decoded.displacementL).toFixed(1) : '';
  const vFuel = (decoded.fuelType || '').toLowerCase();

  return recalls.map((rec) => {
    const text = `${rec.summary} ${rec.component}`.toLowerCase();

    // Check if recall explicitly names a specific displacement (e.g. "equipped with 2.7L engines")
    const mentionedDisps = [...text.matchAll(/\b(\d\.\d)\s*-?\s*l(?:iter)?\b/gi)].map((m) =>
      Number(m[1]).toFixed(1)
    );
    if (vDisp && mentionedDisps.length > 0 && !mentionedDisps.includes(vDisp)) {
      return {
        ...rec,
        applicability: 'Other Engine / Equipment Variant',
        geminiNote: `Campaign specifically references ${[...new Set(mentionedDisps)].join('/')}L engine; this VIN decoded with ${vDisp}L.`,
      };
    }

    if (/\bhybrid\b/i.test(text) && vFuel && !vFuel.includes('hybrid') && !vFuel.includes('electric')) {
      return {
        ...rec,
        applicability: 'Other Powertrain Variant',
        geminiNote: `Campaign targets Hybrid powertrain; this VIN decoded as ${decoded.fuelType}.`,
      };
    }

    return {
      ...rec,
      applicability: 'Matches Decoded Vehicle',
      geminiNote: 'Matches this VIN\'s decoded model year, make, model, and powertrain.',
    };
  });
}

async function analyzeRecallsWithGemini({ vin, decoded, recalls, nhtsaUrl }) {
  const annotated = annotateRecallApplicabilityDeterministically(decoded, recalls);
  const matchingRecalls = annotated.filter(
    (r) => r.applicability !== 'Other Engine / Equipment Variant' && r.applicability !== 'Other Powertrain Variant'
  );

  const apiKey = getSetting('gemini_api_key');
  const model = getSetting('gemini_model') || 'gemini-2.5-flash';
  const vehicleTitle = [decoded.year, decoded.make, decoded.model, decoded.trim]
    .filter(Boolean)
    .join(' ');

  const urgentParkIt = annotated.some((r) => r.parkIt);
  const urgentParkOutside = annotated.some((r) => r.parkOutSide);

  const fallbackSummary =
    annotated.length === 0
      ? `Checked NHTSA (${NHTSA_RECALLS_WEB_URL}) for VIN ${vin} (${vehicleTitle}): 0 safety recall campaigns are on file for this vehicle.`
      : matchingRecalls.length > 0
        ? `Checked NHTSA (${NHTSA_RECALLS_WEB_URL}) for VIN ${vin} (${vehicleTitle}): found ${matchingRecalls.length} matching NHTSA safety recall campaign(s)${
            annotated.length > matchingRecalls.length
              ? ` (${annotated.length} total on the ${decoded.year} ${decoded.make} ${decoded.model} line)`
              : ''
          }. Confirm VIN-specific repair completion status on NHTSA.gov/recalls or with an authorized ${decoded.make} service department.`
        : `Found ${annotated.length} recall campaign(s) on the ${decoded.year} ${decoded.make} ${decoded.model} model line, though they appear specific to different engine/equipment variants than this VIN (${decoded.engine || 'decoded build'}). Verify exact VIN status on NHTSA.gov/recalls.`;

  const fallbackAction =
    annotated.length === 0
      ? 'No open NHTSA model-level safety recalls found. You can still click "Verify on NHTSA.gov/recalls" anytime before delivery.'
      : urgentParkIt
        ? 'URGENT — DO NOT DRIVE warning present on at least one campaign. Verify immediately on www.nhtsa.gov/recalls and schedule authorized dealer repair before driving.'
        : urgentParkOutside
          ? 'IMPORTANT — Park Outside advisory present. Verify VIN repair history on www.nhtsa.gov/recalls and schedule free recall remedy with service.'
          : `Verify whether each campaign remedy has already been completed for VIN ${vin} on www.nhtsa.gov/recalls or in ${decoded.make} warranty/OASIS history.`;

  if (!apiKey) {
    return {
      agentMode: 'nhtsa-smart-analyzer',
      hasRecalls: matchingRecalls.length > 0,
      applicableCount: matchingRecalls.length,
      verdictHeadline:
        matchingRecalls.length === 0
          ? `No Matching NHTSA Recalls Found for ${vehicleTitle}`
          : `${matchingRecalls.length} NHTSA Recall Campaign(s) Found for ${vehicleTitle}`,
      geminiSummary: fallbackSummary,
      recommendedAction: fallbackAction,
      recalls: annotated,
    };
  }

  const promptPayload = {
    referenceWebsite: nhtsaUrl,
    vin,
    decodedVehicleFromNhtsaVpic: decoded,
    nhtsaRecallCampaignsOnFile: annotated.map((r) => ({
      campaignNumber: r.campaignNumber,
      reportDate: r.reportDate,
      component: r.component,
      parkItDoNotDrive: r.parkIt,
      parkOutsideWarning: r.parkOutSide,
      overTheAirUpdate: r.overTheAirUpdate,
      summary: r.summary,
      consequence: r.consequence,
      remedy: r.remedy,
      initialSpecCheck: r.applicability,
    })),
  };

  const systemPrompt = `You are the Preston Automotive Group Gemini NHTSA Recall Inspector.
Your job is to check NHTSA recall data from www.nhtsa.gov/recalls and NHTSA's official vPIC + Recalls database for a specific 17-character VIN and determine whether the vehicle has any recalls.
Rules:
1. Cross-reference each NHTSA recall campaign's summary and component against the VIN's decoded factory specifications (Model Year, Make, Model, Trim/Series, Body Class, Engine displacement/cylinders/fuel, Drivetrain, Assembly Plant).
2. Set "hasRecalls" to true if 1 or more NHTSA recall campaigns apply (or potentially apply) to this vehicle's configuration; false if 0 apply.
3. For each campaign, classify "applicability" as one of:
   - "Matches Decoded Vehicle" (applies to this model/powertrain or all builds unless already repaired)
   - "Verify Build Date / Equipment" (depends on production date window or optional package)
   - "Other Engine / Equipment Variant" (clearly for a different engine/fuel/body than this decoded VIN)
   and provide a concise 1-sentence "geminiNote" explaining why.
4. Provide a clear, accurate "verdictHeadline", a 2-3 sentence "geminiSummary" referencing www.nhtsa.gov/recalls, and a practical "recommendedAction" reminding the user to confirm whether the specific VIN's recall repair has already been performed.`;

  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
    model
  )}:generateContent?key=${encodeURIComponent(apiKey)}`;

  // Attempt 1: Grounded Gemini check with url_context on https://www.nhtsa.gov/recalls?vin=<VIN>
  let parsed = null;
  let usedGroundedUrlContext = false;

  try {
    const groundedBody = {
      systemInstruction: { parts: [{ text: systemPrompt }] },
      tools: [{ urlContext: {} }],
      contents: [
        {
          role: 'user',
          parts: [
            {
              text: `Check ${nhtsaUrl} and analyze these official NHTSA recall records for VIN ${vin}. Return ONLY valid JSON with keys: hasRecalls (boolean), applicableCount (integer), verdictHeadline (string), geminiSummary (string), recommendedAction (string), campaignAssessments (array of {campaignNumber, applicability, geminiNote}).\n\nData:\n${JSON.stringify(
                promptPayload
              )}`,
            },
          ],
        },
      ],
      generationConfig: {
        temperature: 0.1,
      },
    };

    const res1 = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(groundedBody),
      signal: AbortSignal.timeout(25000),
    });

    if (res1.ok) {
      const d1 = await res1.json();
      const raw1 =
        (d1?.candidates?.[0]?.content?.parts || [])
          .map((p) => p?.text || '')
          .join('\n')
          .trim() || '';
      const jsonMatch = raw1.match(/\{[\s\S]*\}/);
      if (jsonMatch) {
        parsed = JSON.parse(jsonMatch[0]);
        usedGroundedUrlContext = true;
      }
    }
  } catch {
    // Fall through to structured responseSchema JSON call
  }

  // Attempt 2: Guaranteed structured JSON schema call with Gemini
  if (!parsed) {
    try {
      const schemaBody = {
        systemInstruction: { parts: [{ text: systemPrompt }] },
        contents: [
          {
            role: 'user',
            parts: [{ text: JSON.stringify(promptPayload) }],
          },
        ],
        generationConfig: {
          temperature: 0.1,
          responseMimeType: 'application/json',
          responseSchema: {
            type: 'OBJECT',
            properties: {
              hasRecalls: { type: 'BOOLEAN' },
              applicableCount: { type: 'INTEGER' },
              verdictHeadline: { type: 'STRING' },
              geminiSummary: { type: 'STRING' },
              recommendedAction: { type: 'STRING' },
              campaignAssessments: {
                type: 'ARRAY',
                items: {
                  type: 'OBJECT',
                  properties: {
                    campaignNumber: { type: 'STRING' },
                    applicability: { type: 'STRING' },
                    geminiNote: { type: 'STRING' },
                  },
                  required: ['campaignNumber', 'applicability', 'geminiNote'],
                },
              },
            },
            required: [
              'hasRecalls',
              'applicableCount',
              'verdictHeadline',
              'geminiSummary',
              'recommendedAction',
              'campaignAssessments',
            ],
          },
        },
      };

      const res2 = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(schemaBody),
        signal: AbortSignal.timeout(25000),
      });

      if (res2.ok) {
        const d2 = await res2.json();
        const raw2 = d2?.candidates?.[0]?.content?.parts?.[0]?.text || '{}';
        parsed = JSON.parse(raw2);
      }
    } catch {
      parsed = null;
    }
  }

  if (!parsed) {
    return {
      agentMode: 'gemini-fallback',
      hasRecalls: matchingRecalls.length > 0,
      applicableCount: matchingRecalls.length,
      verdictHeadline:
        matchingRecalls.length === 0
          ? `No Matching NHTSA Recalls Found for ${vehicleTitle}`
          : `${matchingRecalls.length} NHTSA Recall Campaign(s) Found for ${vehicleTitle}`,
      geminiSummary: fallbackSummary,
      recommendedAction: fallbackAction,
      recalls: annotated,
    };
  }

  const assessmentMap = new Map();
  for (const item of parsed.campaignAssessments || []) {
    if (item?.campaignNumber) {
      assessmentMap.set(String(item.campaignNumber).trim(), item);
    }
  }

  const enrichedRecalls = annotated.map((r) => {
    const a = assessmentMap.get(r.campaignNumber);
    if (!a) return r;
    return {
      ...r,
      applicability: String(a.applicability || r.applicability).trim(),
      geminiNote: String(a.geminiNote || r.geminiNote).trim(),
    };
  });

  const computedApplicable = enrichedRecalls.filter(
    (r) => !/other\s+(?:engine|powertrain)/i.test(r.applicability)
  ).length;
  const finalHasRecalls =
    enrichedRecalls.length === 0
      ? false
      : typeof parsed.hasRecalls === 'boolean'
        ? parsed.hasRecalls || computedApplicable > 0
        : computedApplicable > 0;

  return {
    agentMode: usedGroundedUrlContext ? `gemini-url-context (${model})` : `gemini (${model})`,
    hasRecalls: finalHasRecalls,
    applicableCount: computedApplicable,
    verdictHeadline:
      String(parsed.verdictHeadline || '').trim() ||
      (finalHasRecalls
        ? `${computedApplicable} NHTSA Recall Campaign(s) Found for ${vehicleTitle}`
        : `No Matching NHTSA Recalls Found for ${vehicleTitle}`),
    geminiSummary: String(parsed.geminiSummary || fallbackSummary).trim(),
    recommendedAction: String(parsed.recommendedAction || fallbackAction).trim(),
    recalls: enrichedRecalls,
  };
}

export function listRecentVinRecallChecks(limit = 15) {
  const rows = db
    .prepare('SELECT * FROM vin_recall_checks ORDER BY checked_at DESC LIMIT ?')
    .all(limit);
  return rows.map((r) => ({
    vin: r.vin,
    vehicleTitle: r.vehicle_title || r.vin,
    hasRecalls: Boolean(r.has_recalls),
    recallCount: Number(r.recall_count || 0),
    verdictHeadline: r.verdict_headline || '',
    checkedAt: r.checked_at,
  }));
}

export async function checkVinRecallsWithGemini(rawVin) {
  const validation = validateAndNormalizeVin(rawVin);
  if (!validation.valid) {
    const err = new Error(validation.error);
    err.statusCode = 400;
    throw err;
  }

  const vin = validation.vin;
  const nhtsaUrl = `${NHTSA_RECALLS_WEB_URL}?vin=${encodeURIComponent(vin)}`;
  const decoded = await decodeVinViaVpic(vin);

  if (!decoded.make || !decoded.year) {
    const err = new Error(
      `Unable to decode a valid vehicle from VIN "${vin}" via NHTSA vPIC (${decoded.errorText || 'unrecognized WMI/model year'}). Double-check all 17 characters.`
    );
    err.statusCode = 422;
    throw err;
  }

  const { recalls, queriedModels, nhtsaSiteReachable } =
    await fetchNhtsaRecallsForDecodedVehicle(decoded);

  const analysis = await analyzeRecallsWithGemini({
    vin,
    decoded,
    recalls,
    nhtsaUrl,
  });

  const checkedAt = new Date().toISOString();
  const vehicleTitle = [decoded.year, decoded.make, decoded.model, decoded.trim]
    .filter(Boolean)
    .join(' ');

  const resultPayload = {
    id: crypto.randomUUID(),
    vin,
    nhtsaUrl,
    nhtsaSiteReachable,
    checkedAt,
    agentMode: analysis.agentMode,
    vehicleTitle,
    vehicle: decoded,
    queriedModels,
    hasRecalls: analysis.hasRecalls,
    recallCount: analysis.applicableCount,
    totalModelRecalls: analysis.recalls.length,
    parkItUrgent: analysis.recalls.some((r) => r.parkIt),
    parkOutsideWarning: analysis.recalls.some((r) => r.parkOutSide),
    verdictHeadline: analysis.verdictHeadline,
    geminiSummary: analysis.geminiSummary,
    recommendedAction: analysis.recommendedAction,
    recalls: analysis.recalls,
  };

  try {
    db.prepare(
      `INSERT INTO vin_recall_checks (
        vin, vehicle_title, has_recalls, recall_count, verdict_headline, result_json, checked_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(vin) DO UPDATE SET
        vehicle_title = excluded.vehicle_title,
        has_recalls = excluded.has_recalls,
        recall_count = excluded.recall_count,
        verdict_headline = excluded.verdict_headline,
        result_json = excluded.result_json,
        checked_at = excluded.checked_at`
    ).run(
      vin,
      vehicleTitle,
      resultPayload.hasRecalls ? 1 : 0,
      resultPayload.recallCount,
      resultPayload.verdictHeadline,
      JSON.stringify(resultPayload),
      checkedAt
    );
  } catch {
    // Non-fatal history persistence error
  }

  return resultPayload;
}
