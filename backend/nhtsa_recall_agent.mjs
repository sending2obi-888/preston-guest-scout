import crypto from 'node:crypto';
import { db, getSetting } from './db.mjs';

const VPIC_BASE = 'https://vpic.nhtsa.dot.gov/api/vehicles';
const NHTSA_API_BASE = 'https://api.nhtsa.gov';
const NHTSA_RECALLS_WEB_URL = 'https://www.nhtsa.gov/recalls';
const PRESTON_AUTOCHECK_URL = 'https://www.prestonmotor.com/autocheck.aspx';
const PRESTON_AUTOCHECK_ACCOUNT = 'NQAyADAAOAA2ADYAOAA%3d';

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

/**
 * Encodes a 17-character VIN as UTF-16LE Base64 for Preston Automotive Group's
 * VIN-specific Open Recall lookup (`prestonmotor.com/autocheck.aspx`).
 */
export function encodeVinUtf16LeBase64(vin) {
  return Buffer.from(String(vin || '').trim().toUpperCase(), 'utf16le').toString('base64');
}

/**
 * Normalizes an NHTSA campaign identifier to its 6-char core prefix (e.g. "25V347000" or "25V-347" -> "25V347").
 */
export function normalizeNhtsaPrefix(rawCampaign) {
  const cleaned = String(rawCampaign || '')
    .toUpperCase()
    .replace(/[\s-]+/g, '')
    .trim();
  if (!cleaned || cleaned === 'NA' || cleaned === 'N/A') return '';
  if (/^\d{2}[A-Z]\d{3}000$/.test(cleaned)) {
    return cleaned.slice(0, 6);
  }
  return cleaned;
}

/**
 * Extracts manufacturer / OEM recall code from NHTSA Remedy / Summary / Notes text
 * (e.g. "Ford's number for this recall is 25S53." -> "25S53").
 */
export function extractOemRecallNumber(...texts) {
  const combined = texts
    .map((t) => String(t || '').trim())
    .filter(Boolean)
    .join(' ');
  if (!combined) return '';

  const patterns = [
    /(?:number\s+for\s+this\s+recall\s+is|recall\s+number\s+(?:for\s+this\s+recall\s+)?is|campaign\s+number\s+is)\s+([A-Z0-9][A-Z0-9-]{1,14})/i,
    /manufacturer(?:'s)?\s+recall\s+(?:number|code|id)\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{1,14})/i,
  ];

  for (const re of patterns) {
    const m = combined.match(re);
    if (m?.[1]) {
      const candidate = m[1].replace(/[.,;:]+$/, '').toUpperCase().trim();
      if (/\d/.test(candidate) && candidate.length >= 2) {
        return candidate;
      }
    }
  }
  return '';
}

export function isRemedyUnavailableText(...texts) {
  const combined = texts
    .map((t) => String(t || '').trim())
    .filter(Boolean)
    .join(' ');
  return /remedy\s+(?:is\s+)?not\s+(?:yet\s+)?available|remedy\s+(?:is\s+)?currently\s+under\s+development|remedy\s+under\s+development|parts\s+are\s+not\s+(?:yet\s+)?available/i.test(
    combined
  );
}

function stripHtmlAndDecodeEntities(rawHtml) {
  return String(rawHtml || '')
    .replace(/<br\s*\/?>/gi, ' | ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/\s+/g, ' ')
    .trim();
}

function parseUsMonthDayYearDate(rawDate) {
  const s = String(rawDate || '').trim();
  const mdy = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (mdy) {
    const month = Number(mdy[1]);
    const day = Number(mdy[2]);
    const year = Number(mdy[3]);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      const dt = new Date(Date.UTC(year, month - 1, day));
      return {
        displayDate: dt.toLocaleDateString('en-US', {
          timeZone: 'UTC',
          month: 'short',
          day: 'numeric',
          year: 'numeric',
        }),
        isoDate: `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`,
      };
    }
  }
  return parseNhtsaReportDate(s);
}

/**
 * Parses live VIN-specific Open Recall HTML from Preston's AutoCheck report
 * so we know with per-VIN accuracy which campaigns are still Incomplete (Open) vs Complete (Closed).
 */
export function parseVinOpenRecallHtml(html) {
  const text = String(html || '');
  if (!text || (!/Open\s+Recall\s+Check/i.test(text) && !/id="recallSection"/i.test(text))) {
    return { verified: false, openRecallCount: null, openRecalls: [] };
  }

  let declaredCount = null;
  if (
    /\bNo\s+Open\s+Recalls\b/i.test(text) ||
    /AutoCheck\s+found\s+no\s+open\s+recalls/i.test(text)
  ) {
    declaredCount = 0;
  } else {
    const countMatch =
      text.match(/AutoCheck\s+found\s*<span[^>]*>\s*(\d+)\s*<\/span>\s*open\s+recall/i) ||
      text.match(/<p[^>]*>\s*Open\s+Recall\s+Check\s*<\/p>[\s\S]{0,1400}?(\d+)\s+Open\s+Recall/i) ||
      text.match(/Open\s+Recall\s+Check[\s\S]{0,1600}?(\d+)\s+Open\s+Recall/i);
    if (countMatch?.[1]) {
      declaredCount = Number(countMatch[1]);
    }
  }

  const openRecalls = [];
  const secIdx = text.indexOf('id="recallSection"');
  if (secIdx >= 0) {
    const afterSec = text.slice(secIdx);
    const bodyStart = afterSec.indexOf('<div class="rTableBody">');
    const mobileMarker = afterSec.indexOf('<!-- Mobile -->');
    const serviceMarker = afterSec.indexOf('id="serviceHistorySummary"');
    const endBound =
      mobileMarker > bodyStart && mobileMarker !== -1
        ? mobileMarker
        : serviceMarker > bodyStart && serviceMarker !== -1
          ? serviceMarker
          : Math.min(afterSec.length, 16000);

    if (bodyStart >= 0) {
      const tableBodyHtml = afterSec.slice(bodyStart, endBound);
      const rowChunks = tableBodyHtml.split(/<div\s+class="rTableRow">/i).slice(1);

      for (const chunk of rowChunks) {
        const cells = [...chunk.matchAll(/<div\s+class="rTableCell[^"]*">([\s\S]*?)<\/div>/gi)].map(
          (m) => stripHtmlAndDecodeEntities(m[1])
        );
        if (cells.length < 3) continue;

        const recallDateRaw = cells[0].replace(/\s*\|\s*/g, ' ').trim();
        const recallType = cells[1].replace(/\s*\|\s*/g, ' ').trim();
        const idsRaw = cells[2].replace(/\s*\|\s*/g, ' ').trim();
        const descRaw = cells[3] || '';

        const idParts = idsRaw.split('/').map((p) => p.trim());
        const rawNhtsa = idParts[0] || '';
        const rawOem = idParts[1] || '';
        const nhtsaPrefix = normalizeNhtsaPrefix(rawNhtsa);
        const oemRecallNumber =
          rawOem && rawOem.toUpperCase() !== 'N/A' && rawOem.toUpperCase() !== 'NA'
            ? rawOem.toUpperCase().replace(/\s+/g, '')
            : '';

        const descParts = descRaw
          .split('|')
          .map((p) => p.trim())
          .filter(Boolean);
        let statusText = '';
        const descriptionSegments = [];
        for (const seg of descParts) {
          const stMatch = seg.match(/^Status:\s*(.+)$/i);
          if (stMatch) {
            statusText = stMatch[1].trim();
          } else {
            descriptionSegments.push(seg);
          }
        }

        openRecalls.push({
          recallDate: recallDateRaw,
          recallType,
          nhtsaPrefix,
          oemRecallNumber,
          description: descriptionSegments.join(' — ') || descRaw,
          statusText,
        });
      }
    }
  }

  if (declaredCount === null && openRecalls.length > 0) {
    declaredCount = openRecalls.length;
  }

  return {
    verified: declaredCount !== null || openRecalls.length > 0,
    openRecallCount: declaredCount ?? openRecalls.length,
    openRecalls,
  };
}

async function fetchVinSpecificOpenRecalls(vin) {
  try {
    const sv = encodeURIComponent(encodeVinUtf16LeBase64(vin));
    const url = `${PRESTON_AUTOCHECK_URL}?sv=${sv}&ac=${PRESTON_AUTOCHECK_ACCOUNT}`;
    const res = await fetch(url, {
      headers: {
        'User-Agent':
          'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
        Accept: 'text/html,application/xhtml+xml',
      },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) {
      return { verified: false, openRecallCount: null, openRecalls: [] };
    }
    const html = await res.text();
    return parseVinOpenRecallHtml(html);
  } catch {
    return { verified: false, openRecallCount: null, openRecalls: [] };
  }
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
      'User-Agent': 'PrestonGuestScout/1.11 (NHTSA VIN Recall Checker)',
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

  const dispL = row.DisplacementL ? `${Number(row.DisplacementL).toFixed(1)}L` : '';
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
 * Matches a decoded vPIC model against NHTSA's recall-specific model taxonomy.
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

    if (lowerBase === 'bronco' && /\bbronco\s+sport\b/i.test(lowerCand)) continue;
    if (lowerBase === 'mustang' && /\bmach[\s-]*e\b/i.test(lowerCand)) continue;
    if (lowerBase === 'cherokee' && /\bgrand\s+cherokee\b/i.test(lowerCand)) continue;
    if (lowerBase === 'wagoneer' && /\bgrand\s+wagoneer\b/i.test(lowerCand)) continue;
    if (lowerBase === 'expedition' && /\bexpedition\s+max\b/i.test(lowerCand)) continue;
    if (lowerBase === 'navigator' && /\bnavigator\s+l\b/i.test(lowerCand)) continue;
    if (lowerBase === 'corolla' && /\bcorolla\s+cross\b/i.test(lowerCand)) continue;
    if (lowerBase === 'highlander' && /\bgrand\s+highlander\b/i.test(lowerCand)) continue;
    if (/^f[\s-]*150$/i.test(baseModel) && /\blightning\b/i.test(lowerCand)) continue;

    if (doors === '2' && /\b4\s*dr\b/i.test(lowerCand)) continue;
    if (doors === '4' && /\b2\s*dr\b/i.test(lowerCand)) continue;

    const isPlugIn = /plug[\s-]*in|phev/i.test(fuelLower);
    const isHybrid = !isPlugIn && /hybrid|hev/i.test(fuelLower);
    const isElectric = /electric|bev/i.test(fuelLower) && !/hybrid|hev/i.test(fuelLower);
    if (!isPlugIn && /\bphev\b|plug[\s-]*in/i.test(lowerCand)) continue;
    if (!isHybrid && /\bhev\b/i.test(lowerCand) && !/\bphev\b/i.test(lowerCand)) continue;
    if (!isElectric && /\bbev\b|\belectric\b|\blightning\b|\bev\b/i.test(lowerCand)) continue;
    if ((isPlugIn || isHybrid || isElectric) && /\bgas\b/i.test(lowerCand)) continue;

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
        headers: { Accept: 'application/json', 'User-Agent': 'PrestonGuestScout/1.11' },
        signal: AbortSignal.timeout(12000),
      }
    ),
  ]);

  const nhtsaSiteReachable =
    siteCheckRes.status === 'fulfilled' &&
    siteCheckRes.value.status >= 200 &&
    siteCheckRes.value.status < 400;

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
          headers: { Accept: 'application/json', 'User-Agent': 'PrestonGuestScout/1.11' },
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
          const summary = String(item.Summary || '').replace(/\s+/g, ' ').trim();
          const consequence = String(item.Consequence || '').replace(/\s+/g, ' ').trim();
          const remedy = String(item.Remedy || '').replace(/\s+/g, ' ').trim();
          const notes = String(item.Notes || '').replace(/\s+/g, ' ').trim();
          const oemRecallNumber = extractOemRecallNumber(remedy, summary, notes);

          byCampaign.set(campaign, {
            campaignNumber: campaign,
            oemRecallNumber,
            manufacturer: String(item.Manufacturer || decoded.manufacturer || '').trim(),
            component: String(item.Component || 'Vehicle Safety System').trim(),
            reportDate: displayDate,
            reportIsoDate: isoDate,
            summary,
            consequence,
            remedy,
            notes,
            parkIt: Boolean(item.parkIt),
            parkOutSide: Boolean(item.parkOutSide),
            overTheAirUpdate: Boolean(item.overTheAirUpdate),
            nhtsaModelMatched: String(item.Model || modelName).trim(),
            applicability: 'Matches Decoded Vehicle',
            geminiNote: '',
            completionStatus: 'unverified',
            completionSource: 'model_lookup_only',
            remedyAvailable: !isRemedyUnavailableText(remedy),
            vinStatusNote: '',
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
      applicability: rec.applicability || 'Matches Decoded Vehicle',
      geminiNote:
        rec.geminiNote ||
        "Matches this VIN's decoded model year, make, model, and powertrain.",
    };
  });
}

function getCompletionSortRank(status) {
  switch (status) {
    case 'incomplete':
      return 0;
    case 'incomplete_no_remedy':
      return 1;
    case 'unverified':
      return 2;
    case 'complete':
      return 3;
    case 'not_applicable':
      return 4;
    default:
      return 5;
  }
}

export function buildVerdictHeadline({
  vehicleTitle,
  incompleteCount,
  completeCount,
  vinCompletionVerified,
}) {
  if (incompleteCount === 0 && completeCount === 0) {
    return `No Open or Historical Recalls Found for ${vehicleTitle}`;
  }
  if (incompleteCount === 0 && completeCount > 0) {
    return `0 Incomplete Recalls • ${completeCount} Complete Recall${
      completeCount === 1 ? '' : 's'
    } for ${vehicleTitle}`;
  }
  if (incompleteCount > 0 && completeCount > 0) {
    return `${incompleteCount} Incomplete Recall${
      incompleteCount === 1 ? '' : 's'
    } • ${completeCount} Complete Recall${completeCount === 1 ? '' : 's'} for ${vehicleTitle}`;
  }
  if (vinCompletionVerified) {
    return `${incompleteCount} Incomplete Recall${
      incompleteCount === 1 ? '' : 's'
    } • 0 Complete for ${vehicleTitle}`;
  }
  return `${incompleteCount} Unverified / Incomplete Recall${
    incompleteCount === 1 ? '' : 's'
  } for ${vehicleTitle}`;
}

/**
 * Reconciles NHTSA model-level recall campaigns with live per-VIN open-recall records
 * plus any dealership service overrides (`vin_recall_overrides`).
 */
export function reconcileVinRecallCompletion({
  decoded = {},
  recalls = [],
  vinOpenCheck = { verified: false, openRecallCount: null, openRecalls: [] },
  overridesMap = new Map(),
}) {
  const openList = Array.isArray(vinOpenCheck?.openRecalls) ? vinOpenCheck.openRecalls : [];
  const matchedOpenIndices = new Set();

  const reconciled = recalls.map((rec) => {
    const recPrefix = normalizeNhtsaPrefix(rec.campaignNumber);
    const recOem = String(rec.oemRecallNumber || extractOemRecallNumber(rec.remedy, rec.summary, rec.notes))
      .toUpperCase()
      .trim();

    let matchedOpen = null;
    for (let i = 0; i < openList.length; i++) {
      const openItem = openList[i];
      const prefixMatches =
        recPrefix && openItem.nhtsaPrefix && recPrefix === openItem.nhtsaPrefix;
      const oemMatches =
        recOem && openItem.oemRecallNumber && recOem === openItem.oemRecallNumber;
      if (prefixMatches || oemMatches) {
        matchedOpen = openItem;
        matchedOpenIndices.add(i);
        break;
      }
    }

    const finalOem = recOem || matchedOpen?.oemRecallNumber || '';
    const isOtherVariant = /other\s+(?:engine|powertrain)/i.test(rec.applicability || '');
    const manualStatus = overridesMap.get(rec.campaignNumber);

    const noRemedy =
      isRemedyUnavailableText(rec.remedy, matchedOpen?.statusText) ||
      rec.remedyAvailable === false;

    if (manualStatus === 'complete') {
      return {
        ...rec,
        oemRecallNumber: finalOem,
        remedyAvailable: !noRemedy,
        completionStatus: 'complete',
        completionSource: 'dealer_override',
        vinStatusNote: 'Marked Complete by Dealership Service (remedy verified repaired on VIN).',
      };
    }

    if (manualStatus === 'incomplete') {
      return {
        ...rec,
        oemRecallNumber: finalOem,
        remedyAvailable: !noRemedy,
        completionStatus: noRemedy ? 'incomplete_no_remedy' : 'incomplete',
        completionSource: 'dealer_override',
        vinStatusNote: noRemedy
          ? 'Marked Incomplete by Dealership Service • Manufacturer remedy not yet available.'
          : 'Marked Incomplete (Open) by Dealership Service — requires recall repair.',
      };
    }

    if (matchedOpen) {
      const openNoRemedy = isRemedyUnavailableText(rec.remedy, matchedOpen.statusText);
      const statusDetail = matchedOpen.statusText ? ` (${matchedOpen.statusText})` : '';
      return {
        ...rec,
        oemRecallNumber: finalOem,
        applicability: 'Confirmed Open on This VIN',
        remedyAvailable: !openNoRemedy,
        completionStatus: openNoRemedy ? 'incomplete_no_remedy' : 'incomplete',
        completionSource: 'vin_live_lookup',
        vinStatusNote: openNoRemedy
          ? `Confirmed INCOMPLETE on this VIN${statusDetail} — manufacturer remedy/parts not yet available.`
          : `Confirmed INCOMPLETE (Open) on this VIN${statusDetail} — schedule free dealer recall repair.`,
      };
    }

    if (isOtherVariant) {
      return {
        ...rec,
        oemRecallNumber: finalOem,
        remedyAvailable: !noRemedy,
        completionStatus: 'not_applicable',
        completionSource: 'powertrain_mismatch',
        vinStatusNote: 'Applies to a different engine/powertrain configuration than this VIN.',
      };
    }

    if (vinOpenCheck?.verified) {
      return {
        ...rec,
        oemRecallNumber: finalOem,
        remedyAvailable: true,
        completionStatus: 'complete',
        completionSource: 'vin_live_lookup',
        vinStatusNote: 'Confirmed COMPLETE / CLOSED on this VIN (0 open recall status on VIN record).',
      };
    }

    return {
      ...rec,
      oemRecallNumber: finalOem,
      remedyAvailable: !noRemedy,
      completionStatus: 'unverified',
      completionSource: 'model_lookup_only',
      vinStatusNote:
        'VIN-specific completion status could not be verified automatically — confirm repair history in OEM warranty/OASIS or on www.nhtsa.gov/recalls.',
    };
  });

  // Append any VIN-specific open recall (such as an OEM-only campaign like "N/A / P33")
  // that was not already present in NHTSA's model-level campaign feed!
  for (let i = 0; i < openList.length; i++) {
    if (matchedOpenIndices.has(i)) continue;
    const openItem = openList[i];
    const campaignNumber = openItem.nhtsaPrefix
      ? `${openItem.nhtsaPrefix}000`
      : openItem.oemRecallNumber
        ? `OEM-${openItem.oemRecallNumber}`
        : `OPEN-${i + 1}`;
    const manualStatus = overridesMap.get(campaignNumber);
    const { displayDate, isoDate } = parseUsMonthDayYearDate(openItem.recallDate);
    const openNoRemedy = isRemedyUnavailableText(openItem.statusText, openItem.description);

    const completionStatus =
      manualStatus === 'complete'
        ? 'complete'
        : openNoRemedy
          ? 'incomplete_no_remedy'
          : 'incomplete';

    reconciled.push({
      campaignNumber,
      oemRecallNumber: openItem.oemRecallNumber || '',
      manufacturer: decoded.manufacturer || decoded.make || 'Manufacturer',
      component: openItem.description || `${openItem.recallType || 'Safety'} Recall Campaign`,
      reportDate: displayDate,
      reportIsoDate: isoDate,
      summary: openItem.description || 'Open manufacturer recall reported for this specific VIN.',
      consequence: '',
      remedy: openItem.statusText
        ? `Manufacturer Recall Status: ${openItem.statusText}. Contact an authorized ${
            decoded.make || 'OEM'
          } service department for free recall remedy.`
        : `Contact an authorized ${decoded.make || 'OEM'} service department for free recall remedy.`,
      notes: '',
      parkIt: false,
      parkOutSide: false,
      overTheAirUpdate: false,
      nhtsaModelMatched: decoded.model || '',
      applicability: 'Confirmed Open on This VIN',
      geminiNote: `Directly reported as an active open recall on VIN ${decoded.vin || ''}.`,
      completionStatus,
      completionSource: manualStatus ? 'dealer_override' : 'vin_live_lookup',
      remedyAvailable: !openNoRemedy,
      vinStatusNote:
        completionStatus === 'complete'
          ? 'Marked Complete by Dealership Service (remedy verified repaired on VIN).'
          : openNoRemedy
            ? `Confirmed INCOMPLETE on this VIN (${openItem.statusText || 'Remedy Not Available'}).`
            : `Confirmed INCOMPLETE (Open) on this VIN${
                openItem.statusText ? ` (${openItem.statusText})` : ''
              }.`,
    });
  }

  reconciled.sort((a, b) => {
    const rankDiff =
      getCompletionSortRank(a.completionStatus) - getCompletionSortRank(b.completionStatus);
    if (rankDiff !== 0) return rankDiff;
    return (b.reportIsoDate || '').localeCompare(a.reportIsoDate || '');
  });

  const incompleteCount = reconciled.filter(
    (r) =>
      r.completionStatus === 'incomplete' ||
      r.completionStatus === 'incomplete_no_remedy' ||
      r.completionStatus === 'unverified'
  ).length;

  const completeCount = reconciled.filter((r) => r.completionStatus === 'complete').length;

  return {
    recalls: reconciled,
    incompleteCount,
    completeCount,
    vinCompletionVerified: Boolean(vinOpenCheck?.verified),
  };
}

function getOverridesMapForVin(vin) {
  const map = new Map();
  try {
    const rows = db
      .prepare('SELECT campaign_number, status FROM vin_recall_overrides WHERE vin = ?')
      .all(vin);
    for (const r of rows) {
      if (r.campaign_number && r.status) {
        map.set(String(r.campaign_number), String(r.status));
      }
    }
  } catch {}
  return map;
}

async function analyzeRecallsWithGemini({
  vin,
  decoded,
  recalls,
  vinOpenCheck,
  overridesMap,
  nhtsaUrl,
}) {
  const annotated = annotateRecallApplicabilityDeterministically(decoded, recalls);
  const initialReconciled = reconcileVinRecallCompletion({
    decoded,
    recalls: annotated,
    vinOpenCheck,
    overridesMap,
  });

  const apiKey = getSetting('gemini_api_key');
  const model = getSetting('gemini_model') || 'gemini-2.5-flash';
  const vehicleTitle = [decoded.year, decoded.make, decoded.model, decoded.trim]
    .filter(Boolean)
    .join(' ');

  const buildFallbackTexts = (recList, incCount, compCount, verified) => {
    const openUrgentParkIt = recList.some(
      (r) =>
        r.parkIt &&
        (r.completionStatus === 'incomplete' ||
          r.completionStatus === 'incomplete_no_remedy' ||
          r.completionStatus === 'unverified')
    );
    const openUrgentParkOutside = recList.some(
      (r) =>
        r.parkOutSide &&
        (r.completionStatus === 'incomplete' ||
          r.completionStatus === 'incomplete_no_remedy' ||
          r.completionStatus === 'unverified')
    );
    const noRemedyOpenCount = recList.filter(
      (r) => r.completionStatus === 'incomplete_no_remedy'
    ).length;

    let summary;
    if (incCount === 0 && compCount === 0) {
      summary = `Checked NHTSA (${NHTSA_RECALLS_WEB_URL}) and VIN-specific recall status for VIN ${vin} (${vehicleTitle}): 0 incomplete (open) recalls and 0 completed recall campaigns are on file.`;
    } else if (incCount === 0 && compCount > 0) {
      summary = `Good news for VIN ${vin} (${vehicleTitle}): 0 incomplete (open) recalls remain on this vehicle, and ${compCount} historical NHTSA recall campaign${
        compCount === 1 ? ' is' : 's are'
      } confirmed COMPLETE / closed on this VIN.`;
    } else if (verified) {
      summary = `VIN ${vin} (${vehicleTitle}) has ${incCount} INCOMPLETE (open) recall${
        incCount === 1 ? '' : 's'
      }${
        noRemedyOpenCount > 0
          ? ` (${noRemedyOpenCount} awaiting manufacturer remedy availability)`
          : ''
      } and ${compCount} COMPLETE (closed) recall${
        compCount === 1 ? '' : 's'
      } verified against NHTSA (${NHTSA_RECALLS_WEB_URL}) and live VIN recall records.`;
    } else {
      summary = `Found ${incCount} matching NHTSA safety recall campaign${
        incCount === 1 ? '' : 's'
      } on file for VIN ${vin} (${vehicleTitle}) via ${NHTSA_RECALLS_WEB_URL}. Verify per-VIN repair completion in ${
        decoded.make
      } warranty history or mark completed campaigns below.`;
    }

    let action;
    if (incCount === 0) {
      action =
        compCount > 0
          ? `All ${compCount} applicable NHTSA recall campaign${
              compCount === 1 ? ' has' : 's have'
            } been completed/closed for VIN ${vin}. Ready for guest delivery.`
          : 'No open safety recalls require service action on this VIN.';
    } else if (openUrgentParkIt) {
      action =
        'URGENT — DO NOT DRIVE warning on an INCOMPLETE recall! Hold vehicle immediately and schedule authorized dealer recall repair before driving or delivery.';
    } else if (openUrgentParkOutside) {
      action =
        'IMPORTANT — Park Outside advisory on an INCOMPLETE recall. Park away from structures and schedule authorized dealer recall repair immediately.';
    } else if (noRemedyOpenCount === incCount) {
      action = `Open recall remedy is not yet available from ${decoded.make}. Advise the guest of the open recall notice and monitor www.nhtsa.gov/recalls for parts release.`;
    } else {
      action = `Schedule free recall repair with ${decoded.make} Service for the ${incCount} INCOMPLETE recall${
        incCount === 1 ? '' : 's'
      } before delivery, then tap "Mark Complete" once repaired.`;
    }

    return { summary, action, openUrgentParkIt, openUrgentParkOutside };
  };

  if (!apiKey) {
    const fb = buildFallbackTexts(
      initialReconciled.recalls,
      initialReconciled.incompleteCount,
      initialReconciled.completeCount,
      initialReconciled.vinCompletionVerified
    );
    return {
      agentMode: initialReconciled.vinCompletionVerified
        ? 'nhtsa+vin-live-status'
        : 'nhtsa-smart-analyzer',
      incompleteCount: initialReconciled.incompleteCount,
      completeCount: initialReconciled.completeCount,
      vinCompletionVerified: initialReconciled.vinCompletionVerified,
      hasRecalls: initialReconciled.incompleteCount > 0,
      verdictHeadline: buildVerdictHeadline({
        vehicleTitle,
        incompleteCount: initialReconciled.incompleteCount,
        completeCount: initialReconciled.completeCount,
        vinCompletionVerified: initialReconciled.vinCompletionVerified,
      }),
      geminiSummary: fb.summary,
      recommendedAction: fb.action,
      recalls: initialReconciled.recalls,
    };
  }

  const promptPayload = {
    referenceWebsite: nhtsaUrl,
    vin,
    decodedVehicleFromNhtsaVpic: decoded,
    vinCompletionVerified: initialReconciled.vinCompletionVerified,
    incompleteRecallCount: initialReconciled.incompleteCount,
    completeRecallCount: initialReconciled.completeCount,
    recallCampaignsOnFile: initialReconciled.recalls.map((r) => ({
      campaignNumber: r.campaignNumber,
      oemRecallNumber: r.oemRecallNumber,
      completionStatus: r.completionStatus,
      remedyAvailable: r.remedyAvailable,
      reportDate: r.reportDate,
      component: r.component,
      parkItDoNotDrive: r.parkIt,
      parkOutsideWarning: r.parkOutSide,
      summary: r.summary,
      remedy: r.remedy,
      initialSpecCheck: r.applicability,
    })),
  };

  const systemPrompt = `You are the Preston Automotive Group Gemini NHTSA Recall Inspector.
Your job is to inspect a specific 17-character VIN against www.nhtsa.gov/recalls, official NHTSA vPIC + Recalls records, and live per-VIN recall completion data, clearly differentiating INCOMPLETE (open/unrepaired) recalls from COMPLETE (closed/repaired) recalls.
Rules:
1. Never lump completed recalls together with incomplete recalls. Explicitly state both the INCOMPLETE (open) recall count and the COMPLETE (closed) recall count in "geminiSummary".
2. If an incomplete recall has completionStatus "incomplete_no_remedy" (remedyAvailable: false), note that the manufacturer remedy/parts are not yet available.
3. Cross-reference each campaign's summary and component against the VIN's decoded engine/fuel/body specifications. Classify "applicability" as:
   - "Confirmed Open on This VIN" (if completionStatus is incomplete or incomplete_no_remedy)
   - "Matches Decoded Vehicle" (applies to this model/powertrain and is complete/closed on this VIN)
   - "Other Engine / Equipment Variant" (clearly for a different engine/fuel/body than this decoded VIN)
   and provide a concise 1-sentence "geminiNote" mentioning whether it is Incomplete (Open) or Complete (Closed) on this VIN.
4. Provide a concise 2-3 sentence "geminiSummary" referencing www.nhtsa.gov/recalls and a practical dealership "recommendedAction".`;

  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
    model
  )}:generateContent?key=${encodeURIComponent(apiKey)}`;

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
              text: `Check ${nhtsaUrl} and analyze Complete vs. Incomplete recall status for VIN ${vin}. Return ONLY valid JSON with keys: geminiSummary (string), recommendedAction (string), campaignAssessments (array of {campaignNumber, applicability, geminiNote}).\n\nData:\n${JSON.stringify(
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
            required: ['geminiSummary', 'recommendedAction', 'campaignAssessments'],
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

  let workingRecalls = annotated;
  if (parsed?.campaignAssessments) {
    const assessmentMap = new Map();
    for (const item of parsed.campaignAssessments) {
      if (item?.campaignNumber) {
        assessmentMap.set(String(item.campaignNumber).trim(), item);
      }
    }
    workingRecalls = annotated.map((r) => {
      const a = assessmentMap.get(r.campaignNumber);
      if (!a) return r;
      return {
        ...r,
        applicability: String(a.applicability || r.applicability).trim(),
        geminiNote: String(a.geminiNote || r.geminiNote).trim(),
      };
    });
  }

  const finalReconciled = reconcileVinRecallCompletion({
    decoded,
    recalls: workingRecalls,
    vinOpenCheck,
    overridesMap,
  });

  // Also apply any Gemini note for OEM-only open recalls if returned
  if (parsed?.campaignAssessments) {
    const assessmentMap = new Map(
      parsed.campaignAssessments
        .filter((x) => x?.campaignNumber)
        .map((x) => [String(x.campaignNumber).trim(), x])
    );
    finalReconciled.recalls = finalReconciled.recalls.map((r) => {
      const a = assessmentMap.get(r.campaignNumber);
      if (!a?.geminiNote) return r;
      return { ...r, geminiNote: String(a.geminiNote).trim() };
    });
  }

  const fb = buildFallbackTexts(
    finalReconciled.recalls,
    finalReconciled.incompleteCount,
    finalReconciled.completeCount,
    finalReconciled.vinCompletionVerified
  );

  return {
    agentMode: parsed
      ? usedGroundedUrlContext
        ? `gemini-url-context (${model})`
        : `gemini (${model})`
      : 'gemini-fallback',
    incompleteCount: finalReconciled.incompleteCount,
    completeCount: finalReconciled.completeCount,
    vinCompletionVerified: finalReconciled.vinCompletionVerified,
    hasRecalls: finalReconciled.incompleteCount > 0,
    verdictHeadline: buildVerdictHeadline({
      vehicleTitle,
      incompleteCount: finalReconciled.incompleteCount,
      completeCount: finalReconciled.completeCount,
      vinCompletionVerified: finalReconciled.vinCompletionVerified,
    }),
    geminiSummary: String(parsed?.geminiSummary || fb.summary).trim(),
    recommendedAction: String(parsed?.recommendedAction || fb.action).trim(),
    recalls: finalReconciled.recalls,
  };
}

function persistVinRecallCheckResult(resultPayload) {
  db.prepare(
    `INSERT INTO vin_recall_checks (
      vin, vehicle_title, has_recalls, recall_count, incomplete_count, complete_count, verdict_headline, result_json, checked_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(vin) DO UPDATE SET
      vehicle_title = excluded.vehicle_title,
      has_recalls = excluded.has_recalls,
      recall_count = excluded.recall_count,
      incomplete_count = excluded.incomplete_count,
      complete_count = excluded.complete_count,
      verdict_headline = excluded.verdict_headline,
      result_json = excluded.result_json,
      checked_at = excluded.checked_at`
  ).run(
    resultPayload.vin,
    resultPayload.vehicleTitle,
    resultPayload.hasRecalls ? 1 : 0,
    resultPayload.recallCount,
    resultPayload.incompleteCount,
    resultPayload.completeCount,
    resultPayload.verdictHeadline,
    JSON.stringify(resultPayload),
    resultPayload.checkedAt
  );
}

export function listRecentVinRecallChecks(limit = 15) {
  const rows = db
    .prepare('SELECT * FROM vin_recall_checks ORDER BY checked_at DESC LIMIT ?')
    .all(limit);
  return rows.map((r) => {
    let parsedResult = null;
    if (r.incomplete_count == null && r.result_json) {
      try {
        parsedResult = JSON.parse(r.result_json);
      } catch {}
    }
    const incompleteCount = Number(
      r.incomplete_count ?? parsedResult?.incompleteCount ?? r.recall_count ?? 0
    );
    const completeCount = Number(
      r.complete_count ?? parsedResult?.completeCount ?? 0
    );
    return {
      vin: r.vin,
      vehicleTitle: r.vehicle_title || r.vin,
      hasRecalls: Boolean(r.has_recalls),
      recallCount: Number(r.recall_count || 0),
      incompleteCount,
      completeCount,
      verdictHeadline: r.verdict_headline || '',
      checkedAt: r.checked_at,
    };
  });
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

  // Decode VIN via NHTSA vPIC and query live per-VIN open recall completion status concurrently!
  const [decoded, vinOpenCheck] = await Promise.all([
    decodeVinViaVpic(vin),
    fetchVinSpecificOpenRecalls(vin),
  ]);

  if (!decoded.make || !decoded.year) {
    const err = new Error(
      `Unable to decode a valid vehicle from VIN "${vin}" via NHTSA vPIC (${
        decoded.errorText || 'unrecognized WMI/model year'
      }). Double-check all 17 characters.`
    );
    err.statusCode = 422;
    throw err;
  }

  const { recalls, queriedModels, nhtsaSiteReachable } =
    await fetchNhtsaRecallsForDecodedVehicle(decoded);

  const overridesMap = getOverridesMapForVin(vin);

  const analysis = await analyzeRecallsWithGemini({
    vin,
    decoded,
    recalls,
    vinOpenCheck,
    overridesMap,
    nhtsaUrl,
  });

  const checkedAt = new Date().toISOString();
  const vehicleTitle = [decoded.year, decoded.make, decoded.model, decoded.trim]
    .filter(Boolean)
    .join(' ');

  const openRecallsOnly = analysis.recalls.filter(
    (r) =>
      r.completionStatus === 'incomplete' ||
      r.completionStatus === 'incomplete_no_remedy' ||
      r.completionStatus === 'unverified'
  );

  const resultPayload = {
    id: crypto.randomUUID(),
    vin,
    nhtsaUrl,
    nhtsaSiteReachable,
    vinCompletionVerified: analysis.vinCompletionVerified,
    checkedAt,
    agentMode: analysis.agentMode,
    vehicleTitle,
    vehicle: decoded,
    queriedModels,
    hasRecalls: analysis.incompleteCount > 0,
    recallCount: analysis.incompleteCount,
    incompleteCount: analysis.incompleteCount,
    completeCount: analysis.completeCount,
    totalModelRecalls: analysis.recalls.length,
    parkItUrgent: openRecallsOnly.some((r) => r.parkIt),
    parkOutsideWarning: openRecallsOnly.some((r) => r.parkOutSide),
    verdictHeadline: analysis.verdictHeadline,
    geminiSummary: analysis.geminiSummary,
    recommendedAction: analysis.recommendedAction,
    recalls: analysis.recalls,
  };

  try {
    persistVinRecallCheckResult(resultPayload);
  } catch {
    // Non-fatal history persistence error
  }

  return resultPayload;
}

/**
 * Allows dealership staff to mark an individual recall campaign on a VIN as
 * `'complete'`, `'incomplete'`, or `'auto'` (reset to live VIN lookup status).
 */
export async function updateVinRecallCampaignStatus({
  vin: rawVin,
  campaignNumber: rawCampaign,
  status: rawStatus,
}) {
  const validation = validateAndNormalizeVin(rawVin);
  if (!validation.valid) {
    const err = new Error(validation.error);
    err.statusCode = 400;
    throw err;
  }
  const campaignNumber = String(rawCampaign || '').trim();
  if (!campaignNumber) {
    const err = new Error('campaignNumber is required.');
    err.statusCode = 400;
    throw err;
  }
  const normalizedStatus = String(rawStatus || '').trim().toLowerCase();
  if (!['complete', 'incomplete', 'auto', 'reset'].includes(normalizedStatus)) {
    const err = new Error('status must be "complete", "incomplete", or "auto".');
    err.statusCode = 400;
    throw err;
  }

  const vin = validation.vin;
  const nowIso = new Date().toISOString();

  if (normalizedStatus === 'auto' || normalizedStatus === 'reset') {
    db.prepare('DELETE FROM vin_recall_overrides WHERE vin = ? AND campaign_number = ?').run(
      vin,
      campaignNumber
    );
  } else {
    db.prepare(
      `INSERT INTO vin_recall_overrides (vin, campaign_number, status, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(vin, campaign_number) DO UPDATE SET
         status = excluded.status,
         updated_at = excluded.updated_at`
    ).run(vin, campaignNumber, normalizedStatus, nowIso);
  }

  const existingRow = db
    .prepare('SELECT result_json FROM vin_recall_checks WHERE vin = ?')
    .get(vin);

  if (!existingRow?.result_json) {
    return checkVinRecallsWithGemini(vin);
  }

  let cached;
  try {
    cached = JSON.parse(existingRow.result_json);
  } catch {
    return checkVinRecallsWithGemini(vin);
  }

  if (normalizedStatus === 'auto' || normalizedStatus === 'reset') {
    return checkVinRecallsWithGemini(vin);
  }

  const updatedRecalls = (cached.recalls || []).map((rec) => {
    if (rec.campaignNumber !== campaignNumber) return rec;
    const noRemedy = isRemedyUnavailableText(rec.remedy) && rec.remedyAvailable === false;
    if (normalizedStatus === 'complete') {
      return {
        ...rec,
        completionStatus: 'complete',
        completionSource: 'dealer_override',
        vinStatusNote: 'Marked Complete by Dealership Service (remedy verified repaired on VIN).',
      };
    }
    return {
      ...rec,
      completionStatus: noRemedy ? 'incomplete_no_remedy' : 'incomplete',
      completionSource: 'dealer_override',
      vinStatusNote: noRemedy
        ? 'Marked Incomplete by Dealership Service • Manufacturer remedy not yet available.'
        : 'Marked Incomplete (Open) by Dealership Service — requires recall repair.',
    };
  });

  updatedRecalls.sort((a, b) => {
    const rankDiff =
      getCompletionSortRank(a.completionStatus) - getCompletionSortRank(b.completionStatus);
    if (rankDiff !== 0) return rankDiff;
    return (b.reportIsoDate || '').localeCompare(a.reportIsoDate || '');
  });

  const incompleteCount = updatedRecalls.filter(
    (r) =>
      r.completionStatus === 'incomplete' ||
      r.completionStatus === 'incomplete_no_remedy' ||
      r.completionStatus === 'unverified'
  ).length;
  const completeCount = updatedRecalls.filter((r) => r.completionStatus === 'complete').length;
  const openRecallsOnly = updatedRecalls.filter(
    (r) =>
      r.completionStatus === 'incomplete' ||
      r.completionStatus === 'incomplete_no_remedy' ||
      r.completionStatus === 'unverified'
  );

  const updatedPayload = {
    ...cached,
    checkedAt: nowIso,
    hasRecalls: incompleteCount > 0,
    recallCount: incompleteCount,
    incompleteCount,
    completeCount,
    parkItUrgent: openRecallsOnly.some((r) => r.parkIt),
    parkOutsideWarning: openRecallsOnly.some((r) => r.parkOutSide),
    verdictHeadline: buildVerdictHeadline({
      vehicleTitle: cached.vehicleTitle || vin,
      incompleteCount,
      completeCount,
      vinCompletionVerified: Boolean(cached.vinCompletionVerified),
    }),
    recalls: updatedRecalls,
  };

  try {
    persistVinRecallCheckResult(updatedPayload);
  } catch {}

  return updatedPayload;
}
