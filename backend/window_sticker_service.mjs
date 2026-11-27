import { getSetting, setSetting } from './db.mjs';

const DEFAULT_STICKERPULL_PORTAL_URL = 'https://dpapp.autoipacket.com/stickerpull';
const AUTH_LOGIN_URL = 'https://auth-api.autoipacket.com/api/authn/login';
const AUTH_REFRESH_URL = 'https://auth-api.autoipacket.com/api/authn/token/refresh';
const DJAPI_BASE_URL = 'https://djapi.autoipacket.com';
const AIP_CLIENT_ID = 5100206;
const AIP_APP_VERSION = '1.46.1';

const DEFAULT_AIP_USERNAME =
  process.env.AUTOIPACKET_USERNAME || 'oonyeador@prestonmotor.com';
const DEFAULT_AIP_PASSWORD =
  process.env.AUTOIPACKET_PASSWORD || 'Destiny703!1*';

const VPIC_DECODE_URL = 'https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValuesExtended';
const GEMINI_API_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';

let cachedAuthSession = {
  username: '',
  accessToken: '',
  refreshToken: '',
  obtainedAtMs: 0,
};

// Keep recent pulled results & PDF buffers in memory for fast inline serving
const recentStickerPulls = []; // newest first, max 25
const pdfBufferCache = new Map(); // vin -> { buffer, fileName, fetchedAtMs, pdfUrl }
const MAX_PDF_CACHE_ENTRIES = 12;

export function getStickerPullCredentials() {
  const savedUser = (getSetting('stickerpull_username') || '').trim();
  const savedPass = getSetting('stickerpull_password') || '';
  const username = savedUser || DEFAULT_AIP_USERNAME;
  const password = savedPass || DEFAULT_AIP_PASSWORD;
  return {
    portalUrl: DEFAULT_STICKERPULL_PORTAL_URL,
    username,
    password,
    hasCustomCredentials: Boolean(savedUser && savedPass),
  };
}

export function updateStickerPullCredentials({ username, password }) {
  const cleanUser = String(username || '').trim();
  const cleanPass = String(password || '');
  if (!cleanUser || !cleanPass) {
    const err = new Error('Both username and password are required.');
    err.statusCode = 400;
    throw err;
  }
  setSetting('stickerpull_username', cleanUser);
  setSetting('stickerpull_password', cleanPass);
  cachedAuthSession = {
    username: '',
    accessToken: '',
    refreshToken: '',
    obtainedAtMs: 0,
  };
  return {
    portalUrl: DEFAULT_STICKERPULL_PORTAL_URL,
    username: cleanUser,
    configured: true,
  };
}

export function validateAndExtractVin(rawInput) {
  const upper = String(rawInput || '').toUpperCase().trim();
  if (!upper) {
    return {
      valid: false,
      vin: '',
      error: 'Please enter a 17-character VIN.',
    };
  }
  // Extract embedded 17-char VIN if pasted inside a URL or sentence
  const directCleaned = upper.replace(/[\s\-]+/g, '');
  if (directCleaned.length === 17) {
    if (/[IOQ]/.test(directCleaned)) {
      return {
        valid: false,
        vin: directCleaned,
        error: 'Standard 17-character VINs never contain the letters I, O, or Q.',
      };
    }
    if (!/^[A-HJ-NPR-Z0-9]{17}$/.test(directCleaned)) {
      return {
        valid: false,
        vin: directCleaned,
        error: 'VIN must contain only letters A–Z (excluding I, O, Q) and digits 0–9.',
      };
    }
    return { valid: true, vin: directCleaned, error: '' };
  }

  const embeddedMatch = upper.match(/\b([A-HJ-NPR-Z0-9]{17})\b/);
  if (embeddedMatch) {
    return { valid: true, vin: embeddedMatch[1], error: '' };
  }

  return {
    valid: false,
    vin: directCleaned.slice(0, 17),
    error: `VIN must be exactly 17 characters (currently ${directCleaned.length}).`,
  };
}

function buildAipHeaders(accessToken) {
  return {
    Authorization: `bearer ${accessToken}`,
    'AIP-Application-Type': '3',
    'AIP-Application-Version': AIP_APP_VERSION,
    'AIP-Time-Zone': 'America/New_York',
    Accept: 'application/json',
  };
}

async function authenticateAutoIPacket({ forceFresh = false } = {}) {
  const { username, password } = getStickerPullCredentials();
  const now = Date.now();

  if (
    !forceFresh &&
    cachedAuthSession.accessToken &&
    cachedAuthSession.username === username &&
    now - cachedAuthSession.obtainedAtMs < 25 * 60 * 1000
  ) {
    return cachedAuthSession.accessToken;
  }

  if (
    !forceFresh &&
    cachedAuthSession.refreshToken &&
    cachedAuthSession.username === username
  ) {
    try {
      const refRes = await fetch(AUTH_REFRESH_URL, {
        method: 'POST',
        headers: {
          Authorization: `bearer ${cachedAuthSession.refreshToken}`,
          Accept: 'application/json',
        },
        signal: AbortSignal.timeout(12000),
      });
      if (refRes.ok) {
        const refData = await refRes.json();
        if (refData?.access_token) {
          cachedAuthSession = {
            username,
            accessToken: refData.access_token,
            refreshToken: refData.refresh_token || cachedAuthSession.refreshToken,
            obtainedAtMs: Date.now(),
          };
          return cachedAuthSession.accessToken;
        }
      }
    } catch {
      // Fall through to full login
    }
  }

  const res = await fetch(AUTH_LOGIN_URL, {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      username,
      password,
      client_id: AIP_CLIENT_ID,
    }),
    signal: AbortSignal.timeout(15000),
  });

  let data = {};
  try {
    data = await res.json();
  } catch {
    data = {};
  }

  if (!res.ok || !data.access_token) {
    const detail =
      data.detail ||
      data.error_code ||
      `Auto iPacket login failed (HTTP ${res.status}).`;
    const err = new Error(
      `Unable to sign in to Auto iPacket StickerPull (${DEFAULT_STICKERPULL_PORTAL_URL}): ${detail}`
    );
    err.statusCode = res.status === 401 ? 401 : 502;
    throw err;
  }

  cachedAuthSession = {
    username,
    accessToken: data.access_token,
    refreshToken: data.refresh_token || '',
    obtainedAtMs: Date.now(),
  };
  return cachedAuthSession.accessToken;
}

async function fetchAipWithAutoRefresh(url, options = {}) {
  let token = await authenticateAutoIPacket({ forceFresh: false });
  let res = await fetch(url, {
    ...options,
    headers: {
      ...buildAipHeaders(token),
      ...(options.headers || {}),
    },
  });

  if (res.status === 401 || res.status === 403) {
    token = await authenticateAutoIPacket({ forceFresh: true });
    res = await fetch(url, {
      ...options,
      headers: {
        ...buildAipHeaders(token),
        ...(options.headers || {}),
      },
    });
  }
  return { res, token };
}

async function decodeVinNhtsaVpic(vin) {
  try {
    const res = await fetch(`${VPIC_DECODE_URL}/${encodeURIComponent(vin)}?format=json`, {
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) return null;
    const json = await res.json();
    const row = json?.Results?.[0];
    if (!row) return null;
    const yearNum = parseInt(String(row.ModelYear || '').trim(), 10);
    const dispL = String(row.DisplacementL || '').trim();
    const cyl = String(row.EngineCylinders || '').trim();
    const fuel = String(row.FuelTypePrimary || '').trim();
    const engineParts = [
      dispL ? `${dispL}L` : '',
      cyl ? `${cyl}-Cyl` : '',
      fuel,
    ].filter(Boolean);
    return {
      year: Number.isFinite(yearNum) ? yearNum : null,
      make: String(row.Make || '').trim(),
      model: String(row.Model || '').trim(),
      trim: String(row.Trim || row.Series || '').trim(),
      bodyStyle: String(row.BodyClass || '').trim(),
      drivetrain: String(row.DriveType || '').trim(),
      engine: engineParts.join(' '),
      transmission: String(row.TransmissionStyle || '').trim(),
    };
  } catch {
    return null;
  }
}

async function executeStickerPullOnAutoIPacket(vin) {
  const pullUrl = `${DJAPI_BASE_URL}/v2/sticker-puller/pull/${encodeURIComponent(vin)}`;
  const { res: pullRes, token } = await fetchAipWithAutoRefresh(pullUrl, {
    method: 'PUT',
    signal: AbortSignal.timeout(20000),
  });

  let pullJson = {};
  try {
    pullJson = await pullRes.json();
  } catch {
    pullJson = {};
  }

  if (!pullRes.ok || !pullJson.id) {
    const detail =
      pullJson.detail ||
      pullJson.message ||
      `Auto iPacket StickerPull could not start lookup for VIN ${vin} (HTTP ${pullRes.status}).`;
    const err = new Error(detail);
    err.statusCode = pullRes.status >= 400 && pullRes.status < 500 ? pullRes.status : 502;
    throw err;
  }

  const pollUrl = `${DJAPI_BASE_URL}/v2/sticker-puller/poll/${encodeURIComponent(pullJson.id)}`;
  let finalPayload = null;

  for (let attempt = 0; attempt < 35; attempt++) {
    await new Promise((r) => setTimeout(r, attempt === 0 ? 900 : 1100));
    const pollRes = await fetch(pollUrl, {
      method: 'GET',
      headers: buildAipHeaders(token),
      signal: AbortSignal.timeout(15000),
    });
    let pollJson = {};
    try {
      pollJson = await pollRes.json();
    } catch {
      pollJson = {};
    }

    const state = String(pollJson.state || '').toUpperCase();
    if (state === 'SUCCESS') {
      finalPayload = pollJson;
      break;
    }
    if (state === 'FAILED' || state === 'ERROR') {
      const reason =
        pollJson.detail ||
        pollJson.error_code ||
        `OEM Window Sticker is not available for VIN ${vin} on Auto iPacket StickerPull.`;
      const err = new Error(reason);
      err.statusCode = 404;
      throw err;
    }
  }

  if (!finalPayload) {
    const err = new Error(
      `Timed out waiting for Auto iPacket StickerPull to generate the window sticker for ${vin}. Please try again.`
    );
    err.statusCode = 504;
    throw err;
  }

  let pdfBuffer = null;
  if (finalPayload.pdf) {
    try {
      const pdfRes = await fetch(finalPayload.pdf, {
        headers: buildAipHeaders(token),
        signal: AbortSignal.timeout(25000),
      });
      if (pdfRes.ok) {
        pdfBuffer = Buffer.from(await pdfRes.arrayBuffer());
      }
    } catch {
      pdfBuffer = null;
    }
  }

  let buildData = null;
  if (finalPayload.build_data) {
    try {
      const bdRes = await fetch(finalPayload.build_data, {
        signal: AbortSignal.timeout(12000),
      });
      if (bdRes.ok) {
        buildData = await bdRes.json();
      }
    } catch {
      buildData = null;
    }
  }

  return {
    pollPayload: finalPayload,
    pdfBuffer,
    buildData,
  };
}

function getConfiguredGeminiKeyAndModel() {
  const key = (
    getSetting('gemini_api_key') ||
    process.env.GEMINI_API_KEY ||
    ''
  ).trim();
  const model = (
    getSetting('gemini_model') ||
    process.env.GEMINI_MODEL ||
    'gemini-2.5-flash'
  ).trim();
  return { key, model };
}

/**
 * Uses Gemini (gemini-2.5-flash) with tool declaration `pull_autoipacket_window_sticker`
 * targeting https://dpapp.autoipacket.com/stickerpull AND multimodal PDF/build_data extraction.
 * Gracefully falls back to direct Auto iPacket pull if GEMINI_API_KEY is not configured or rate-limited.
 */
async function orchestrateAndAnalyzeWithGemini({
  vin,
  prePulledBundle = null,
  vpic = null,
}) {
  const { key, model } = getConfiguredGeminiKeyAndModel();
  let bundle = prePulledBundle;
  let geminiToolInvoked = false;

  // Step 1: If Gemini key is configured and bundle isn't pulled yet, let Gemini invoke the StickerPull tool!
  if (key && !bundle) {
    try {
      const toolEndpoint = `${GEMINI_API_BASE}/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(key)}`;
      const toolResp = await fetch(toolEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          systemInstruction: {
            parts: [
              {
                text: 'You are the Preston Automotive Group Window Sticker Agent. When given a 17-character VIN, always call `pull_autoipacket_window_sticker` to retrieve the official OEM window sticker from https://dpapp.autoipacket.com/stickerpull.',
              },
            ],
          },
          contents: [
            {
              role: 'user',
              parts: [
                {
                  text: `Pull the official vehicle window sticker from https://dpapp.autoipacket.com/stickerpull for VIN ${vin}.`,
                },
              ],
            },
          ],
          tools: [
            {
              functionDeclarations: [
                {
                  name: 'pull_autoipacket_window_sticker',
                  description:
                    'Authenticates with https://dpapp.autoipacket.com/stickerpull and pulls the official OEM Window Sticker / Buildsheet PDF and build data for a 17-character VIN.',
                  parameters: {
                    type: 'OBJECT',
                    properties: {
                      vin: {
                        type: 'STRING',
                        description: '17-character Vehicle Identification Number (VIN)',
                      },
                    },
                    required: ['vin'],
                  },
                },
              ],
            },
          ],
          toolConfig: {
            functionCallingConfig: {
              mode: 'ANY',
              allowedFunctionNames: ['pull_autoipacket_window_sticker'],
            },
          },
        }),
        signal: AbortSignal.timeout(15000),
      });

      if (toolResp.ok) {
        const toolJson = await toolResp.json();
        const parts = toolJson?.candidates?.[0]?.content?.parts || [];
        const fnCall = parts.find(
          (p) => p.functionCall?.name === 'pull_autoipacket_window_sticker'
        );
        if (fnCall) {
          const targetVin =
            validateAndExtractVin(fnCall.functionCall.args?.vin || vin).vin || vin;
          bundle = await executeStickerPullOnAutoIPacket(targetVin);
          geminiToolInvoked = true;
        }
      }
    } catch {
      // Fallback to direct Auto iPacket execution below
    }
  }

  if (!bundle) {
    bundle = await executeStickerPullOnAutoIPacket(vin);
  }

  // Step 2: Have Gemini read the pulled Window Sticker PDF and/or build_data JSON to extract full Monroney specs
  let geminiExtracted = null;
  if (key) {
    try {
      const extractEndpoint = `${GEMINI_API_BASE}/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(key)}`;
      const userParts = [];

      if (bundle.pdfBuffer && bundle.pdfBuffer.length > 0 && bundle.pdfBuffer.length <= 16 * 1024 * 1024) {
        userParts.push({
          inlineData: {
            mimeType: 'application/pdf',
            data: bundle.pdfBuffer.toString('base64'),
          },
        });
      }

      const contextSummary = {
        vin,
        portalSource: DEFAULT_STICKERPULL_PORTAL_URL,
        autoIPacketVehicleDetails: bundle.pollPayload?.vehicle_details || null,
        autoIPacketBuildData: bundle.buildData || null,
        nhtsaVpicFactoryDecode: vpic || null,
      };

      userParts.push({
        text: `Extract complete window sticker specifications, MSRP pricing breakdown, factory installed packages/options with prices, standard equipment highlights, warranty info, and a concise 2-sentence salesperson summary for VIN ${vin} pulled from https://dpapp.autoipacket.com/stickerpull.\n\nReference metadata:\n${JSON.stringify(contextSummary)}`,
      });

      const extractRes = await fetch(extractEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{ role: 'user', parts: userParts }],
          generationConfig: {
            temperature: 0.1,
            responseMimeType: 'application/json',
            responseSchema: {
              type: 'OBJECT',
              properties: {
                year: { type: 'INTEGER', nullable: true },
                make: { type: 'STRING' },
                model: { type: 'STRING' },
                trim: { type: 'STRING' },
                bodyStyle: { type: 'STRING' },
                exteriorColor: { type: 'STRING' },
                interiorColor: { type: 'STRING' },
                engine: { type: 'STRING' },
                transmission: { type: 'STRING' },
                drivetrain: { type: 'STRING' },
                cityMpg: { type: 'INTEGER', nullable: true },
                highwayMpg: { type: 'INTEGER', nullable: true },
                combinedMpg: { type: 'INTEGER', nullable: true },
                baseMsrp: { type: 'NUMBER', nullable: true },
                optionsTotal: { type: 'NUMBER', nullable: true },
                destinationCharge: { type: 'NUMBER', nullable: true },
                totalMsrp: { type: 'NUMBER', nullable: true },
                packagesAndOptions: {
                  type: 'ARRAY',
                  items: {
                    type: 'OBJECT',
                    properties: {
                      code: { type: 'STRING' },
                      description: { type: 'STRING' },
                      price: { type: 'NUMBER', nullable: true },
                    },
                    required: ['description'],
                  },
                },
                standardHighlights: {
                  type: 'ARRAY',
                  items: { type: 'STRING' },
                },
                warrantySummary: { type: 'STRING' },
                salesSummary: { type: 'STRING' },
              },
              required: [
                'make',
                'model',
                'packagesAndOptions',
                'standardHighlights',
                'salesSummary',
              ],
            },
          },
        }),
        signal: AbortSignal.timeout(35000),
      });

      if (extractRes.ok) {
        const extractJson = await extractRes.json();
        const rawText =
          extractJson?.candidates?.[0]?.content?.parts?.[0]?.text || '';
        if (rawText) {
          geminiExtracted = JSON.parse(rawText);
        }
      }
    } catch {
      geminiExtracted = null;
    }
  }

  return {
    bundle,
    geminiExtracted,
    geminiToolInvoked,
  };
}

function normalizeStickerResult({
  vin,
  bundle,
  vpic,
  geminiExtracted,
  geminiToolInvoked,
  includeBase64Pdf = true,
}) {
  const { pollPayload, pdfBuffer, buildData } = bundle;
  const vd = pollPayload?.vehicle_details || {};
  const gd = buildData?.generic_details || {};
  const pd = buildData?.pricing_details || {};
  const fe = gd?.fuel_economy || {};
  const gx = geminiExtracted || {};

  const year =
    gx.year ||
    vd.year ||
    gd.year ||
    vpic?.year ||
    null;
  const make = String(gx.make || vd.make || gd.make || vpic?.make || '').trim();
  const model = String(gx.model || vd.model || gd.model || vpic?.model || '').trim();
  const trim = String(gx.trim || gd.trim || vpic?.trim || '').trim();

  const titleParts = [
    year ? String(year) : '',
    make,
    model,
    trim && !model.toLowerCase().includes(trim.toLowerCase()) ? trim : '',
  ].filter(Boolean);
  const vehicleTitle = titleParts.join(' ') || `VIN ${vin}`;

  // Merge options from Gemini or Auto iPacket build_data
  let packagesAndOptions = [];
  if (Array.isArray(gx.packagesAndOptions) && gx.packagesAndOptions.length > 0) {
    packagesAndOptions = gx.packagesAndOptions
      .filter((o) => o && String(o.description || '').trim())
      .map((o) => ({
        code: String(o.code || '').trim(),
        description: String(o.description || '').trim(),
        price: typeof o.price === 'number' && Number.isFinite(o.price) ? o.price : null,
      }));
  } else if (Array.isArray(buildData?.options)) {
    packagesAndOptions = buildData.options
      .filter((o) => o && String(o.description || o.name || '').trim())
      .map((o) => ({
        code: String(o.code || '').trim(),
        description: String(o.description || o.name || '').trim(),
        price:
          typeof o.price === 'number' && Number.isFinite(o.price)
            ? o.price
            : typeof o.msrp === 'number' && Number.isFinite(o.msrp)
              ? o.msrp
              : null,
      }));
  }

  let standardHighlights = [];
  if (Array.isArray(gx.standardHighlights) && gx.standardHighlights.length > 0) {
    standardHighlights = gx.standardHighlights
      .map((s) => String(s || '').trim())
      .filter(Boolean);
  } else if (Array.isArray(buildData?.standard_equipment)) {
    standardHighlights = buildData.standard_equipment
      .slice(0, 18)
      .map((s) => String(s?.description || s?.name || s || '').trim())
      .filter(Boolean);
  }

  const baseMsrp =
    typeof gx.baseMsrp === 'number'
      ? gx.baseMsrp
      : typeof pd.base === 'number'
        ? pd.base
        : null;
  const totalMsrp =
    typeof gx.totalMsrp === 'number'
      ? gx.totalMsrp
      : typeof pd.total === 'number'
        ? pd.total
        : null;
  const destinationCharge =
    typeof gx.destinationCharge === 'number'
      ? gx.destinationCharge
      : typeof pd.freight === 'number'
        ? pd.freight
        : null;
  const optionsTotal =
    typeof gx.optionsTotal === 'number'
      ? gx.optionsTotal
      : baseMsrp != null && totalMsrp != null && totalMsrp >= baseMsrp
        ? Math.max(0, totalMsrp - baseMsrp - (destinationCharge || 0))
        : null;

  const exteriorColor = String(gx.exteriorColor || gd.exterior_color || '').trim();
  const interiorColor = String(gx.interiorColor || gd.interior_color || '').trim();
  const engine = String(gx.engine || gd.engine || vpic?.engine || '').trim();
  const transmission = String(
    gx.transmission || gd.transmission || vpic?.transmission || ''
  ).trim();
  const drivetrain = String(
    gx.drivetrain || gd.drivetrain || vpic?.drivetrain || ''
  ).trim();
  const bodyStyle = String(
    gx.bodyStyle || gd.body_style || vpic?.bodyStyle || ''
  ).trim();

  const cityMpg =
    typeof gx.cityMpg === 'number'
      ? Math.round(gx.cityMpg)
      : typeof fe.city === 'number'
        ? Math.round(fe.city)
        : null;
  const highwayMpg =
    typeof gx.highwayMpg === 'number'
      ? Math.round(gx.highwayMpg)
      : typeof fe.highway === 'number'
        ? Math.round(fe.highway)
        : null;
  const combinedMpg =
    typeof gx.combinedMpg === 'number'
      ? Math.round(gx.combinedMpg)
      : typeof fe.combined === 'number'
        ? Math.round(fe.combined)
        : null;

  const defaultSummaryParts = [
    `Official OEM Window Sticker pulled from Auto iPacket StickerPull for ${vehicleTitle} (VIN ${vin}).`,
    totalMsrp != null ? `Total MSRP: $${Math.round(totalMsrp).toLocaleString()}.` : '',
    exteriorColor ? `Exterior: ${exteriorColor}.` : '',
    engine ? `Powertrain: ${engine}.` : '',
  ].filter(Boolean);

  const salesSummary =
    String(gx.salesSummary || '').trim() || defaultSummaryParts.join(' ');
  const warrantySummary = String(gx.warrantySummary || '').trim();
  const fileName = `WindowSticker-${vin}.pdf`;
  const pulledAt = new Date().toISOString();
  const { username } = getStickerPullCredentials();

  return {
    vin,
    portalUrl: DEFAULT_STICKERPULL_PORTAL_URL,
    accountEmail: username,
    pulledAt,
    year,
    make,
    model,
    trim,
    vehicleTitle,
    bodyStyle,
    exteriorColor,
    interiorColor,
    engine,
    transmission,
    drivetrain,
    cityMpg,
    highwayMpg,
    combinedMpg,
    baseMsrp,
    optionsTotal,
    destinationCharge,
    totalMsrp,
    packagesAndOptions,
    standardHighlights,
    warrantySummary,
    salesSummary,
    pdfUrl: pollPayload?.pdf || '',
    ipacketViewerUrl: pollPayload?.ipacket_viewer || '',
    buildDataUrl: pollPayload?.build_data || '',
    inlineServerPdfUrl: pdfBuffer ? `/api/window-sticker/pdf/${vin}` : '',
    fileName,
    pdfSizeBytes: pdfBuffer ? pdfBuffer.length : 0,
    pdfBase64:
      includeBase64Pdf && pdfBuffer && pdfBuffer.length <= 12 * 1024 * 1024
        ? pdfBuffer.toString('base64')
        : '',
    geminiAnalyzed: Boolean(geminiExtracted),
    geminiToolInvoked: Boolean(geminiToolInvoked),
  };
}

function recordRecentPull(result, pdfBuffer) {
  if (pdfBuffer && pdfBuffer.length > 0) {
    pdfBufferCache.set(result.vin, {
      buffer: pdfBuffer,
      fileName: result.fileName,
      fetchedAtMs: Date.now(),
      pdfUrl: result.pdfUrl,
    });
    while (pdfBufferCache.size > MAX_PDF_CACHE_ENTRIES) {
      const oldestKey = pdfBufferCache.keys().next().value;
      pdfBufferCache.delete(oldestKey);
    }
  }

  const entry = {
    vin: result.vin,
    year: result.year,
    make: result.make,
    model: result.model,
    trim: result.trim,
    vehicleTitle: result.vehicleTitle,
    pulledAt: result.pulledAt,
    pdfUrl: result.pdfUrl,
    ipacketViewerUrl: result.ipacketViewerUrl,
    totalMsrp: result.totalMsrp,
  };

  const existingIdx = recentStickerPulls.findIndex((x) => x.vin === result.vin);
  if (existingIdx !== -1) {
    recentStickerPulls.splice(existingIdx, 1);
  }
  recentStickerPulls.unshift(entry);
  if (recentStickerPulls.length > 25) {
    recentStickerPulls.length = 25;
  }
}

export async function pullWindowStickerByVin(rawVin, { includeBase64Pdf = true } = {}) {
  const check = validateAndExtractVin(rawVin);
  if (!check.valid) {
    const err = new Error(check.error);
    err.statusCode = 400;
    throw err;
  }
  const vin = check.vin;

  const [vpic, orchestrated] = await Promise.all([
    decodeVinNhtsaVpic(vin),
    orchestrateAndAnalyzeWithGemini({ vin }),
  ]);

  const result = normalizeStickerResult({
    vin,
    bundle: orchestrated.bundle,
    vpic,
    geminiExtracted: orchestrated.geminiExtracted,
    geminiToolInvoked: orchestrated.geminiToolInvoked,
    includeBase64Pdf,
  });

  recordRecentPull(result, orchestrated.bundle.pdfBuffer);
  return result;
}

export async function getWindowStickerPdfForVin(rawVin) {
  const check = validateAndExtractVin(rawVin);
  if (!check.valid) return null;
  const vin = check.vin;

  const cached = pdfBufferCache.get(vin);
  if (cached && Date.now() - cached.fetchedAtMs < 45 * 60 * 1000) {
    return cached;
  }

  const bundle = await executeStickerPullOnAutoIPacket(vin);
  if (!bundle.pdfBuffer) return null;
  const entry = {
    buffer: bundle.pdfBuffer,
    fileName: `WindowSticker-${vin}.pdf`,
    fetchedAtMs: Date.now(),
    pdfUrl: bundle.pollPayload?.pdf || '',
  };
  pdfBufferCache.set(vin, entry);
  return entry;
}

export async function listRecentWindowStickers() {
  const combined = [...recentStickerPulls];
  const seen = new Set(combined.map((x) => x.vin));

  try {
    const historyUrl = `${DJAPI_BASE_URL}/v1/sticker-puller/history/?success=true&items_per_page=10&page=1`;
    const { res } = await fetchAipWithAutoRefresh(historyUrl, {
      method: 'GET',
      signal: AbortSignal.timeout(10000),
    });
    if (res.ok) {
      const data = await res.json();
      for (const item of data?.results || []) {
        const v = String(item?.vin || '').trim().toUpperCase();
        if (v.length !== 17 || seen.has(v)) continue;
        seen.add(v);
        const yr = item.year || null;
        const mk = String(item.make || '').trim();
        const md = String(item.model || '').trim();
        combined.push({
          vin: v,
          year: yr,
          make: mk,
          model: md,
          trim: '',
          vehicleTitle: [yr, mk, md].filter(Boolean).join(' ') || v,
          pulledAt: item.request_ts ? `${item.request_ts}Z` : '',
          pdfUrl: '',
          ipacketViewerUrl: '',
          totalMsrp: null,
        });
      }
    }
  } catch {
    // Return local recent pulls if remote history call fails
  }

  return combined.slice(0, 15);
}
