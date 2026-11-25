import zlib from 'node:zlib';
import { getSetting } from './db.mjs';
import { fetchEntirePrestonInventory } from './preston_scraper.mjs';
import {
  doesVehicleMatchColor,
  doesVehicleMatchModel,
  doesVehicleMatchTrim,
  extractBedLengthFromVehicle,
  formatBedLengthLabel,
  parseNaturalLanguageCriteria,
} from './natural_language_parser.mjs';

const VPIC_BASE = 'https://vpic.nhtsa.dot.gov/api/vehicles';

const GEMINI_INLINE_MIME_TYPES = new Set([
  'application/pdf',
  'image/png',
  'image/jpeg',
  'image/jpg',
  'image/webp',
  'image/heic',
  'image/heif',
  'image/gif',
  'text/plain',
  'text/csv',
  'text/html',
]);

function inferMimeType(fileName = '', rawMimeType = '') {
  const cleanMime = String(rawMimeType || '').trim().toLowerCase();
  if (cleanMime && cleanMime !== 'application/octet-stream') {
    return cleanMime === 'image/jpg' ? 'image/jpeg' : cleanMime;
  }
  const ext = String(fileName || '')
    .toLowerCase()
    .split('.')
    .pop();
  switch (ext) {
    case 'pdf':
      return 'application/pdf';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    case 'heic':
      return 'image/heic';
    case 'gif':
      return 'image/gif';
    case 'csv':
      return 'text/csv';
    case 'html':
    case 'htm':
      return 'text/html';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'txt':
    case 'md':
    case 'tsv':
    case 'json':
    case 'xml':
      return 'text/plain';
    default:
      return cleanMime || 'application/octet-stream';
  }
}

/**
 * Extracts plain text from a .docx ZIP buffer (`word/document.xml`) without external dependencies.
 */
function extractDocxText(buffer) {
  try {
    let offset = 0;
    const chunks = [];
    while (offset + 30 <= buffer.length) {
      const sig = buffer.readUInt32LE(offset);
      if (sig !== 0x04034b50) break;
      const compression = buffer.readUInt16LE(offset + 8);
      const compSize = buffer.readUInt32LE(offset + 18);
      const nameLen = buffer.readUInt16LE(offset + 26);
      const extraLen = buffer.readUInt16LE(offset + 28);
      const nameStart = offset + 30;
      const dataStart = nameStart + nameLen + extraLen;
      if (dataStart > buffer.length) break;
      const entryName = buffer.slice(nameStart, nameStart + nameLen).toString('utf8');
      const compEnd = Math.min(buffer.length, dataStart + compSize);
      if (entryName === 'word/document.xml' && compEnd > dataStart) {
        const rawSlice = buffer.slice(dataStart, compEnd);
        const xmlBuf =
          compression === 8
            ? zlib.inflateRawSync(rawSlice)
            : compression === 0
              ? rawSlice
              : null;
        if (xmlBuf) {
          const xmlText = xmlBuf
            .toString('utf8')
            .replace(/<\/w:p>/gi, '\n')
            .replace(/<[^>]+>/g, ' ')
            .replace(/&amp;/g, '&')
            .replace(/&lt;/g, '<')
            .replace(/&gt;/g, '>')
            .replace(/&quot;/g, '"')
            .replace(/\s+/g, ' ')
            .trim();
          chunks.push(xmlText);
        }
      }
      if (compSize === 0) break;
      offset = compEnd;
    }
    return chunks.join('\n').trim();
  } catch {
    return '';
  }
}

function extractReadableTextFromBuffer(buffer, fileName, mimeType) {
  if (!buffer || buffer.length === 0) return '';
  const ext = String(fileName || '')
    .toLowerCase()
    .split('.')
    .pop();

  if (
    ext === 'docx' ||
    mimeType === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ) {
    return extractDocxText(buffer).slice(0, 14000);
  }

  if (
    mimeType.startsWith('text/') ||
    ['txt', 'csv', 'tsv', 'md', 'json', 'html', 'htm', 'xml'].includes(ext)
  ) {
    const raw = buffer.toString('utf8');
    return raw
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, 14000);
  }

  if (mimeType === 'application/pdf' || ext === 'pdf') {
    // Lightweight fallback text extraction for uncompressed PDF text runs `( ... )`
    const latin = buffer.toString('latin1');
    const matches = [...latin.matchAll(/\(([^\x00-\x1f\\()]{3,120})\)/g)]
      .map((m) => m[1].trim())
      .filter((s) => /[A-Za-z0-9]/.test(s));
    return matches.slice(0, 400).join(' ').slice(0, 10000);
  }

  return '';
}

function extractFirstValidVinFromText(text = '') {
  const matches = String(text || '')
    .toUpperCase()
    .match(/\b[A-HJ-NPR-Z0-9]{17}\b/g);
  if (!matches) return '';
  // Prefer VINs containing at least 4 digits so English 17-letter words never match
  return matches.find((cand) => (cand.match(/\d/g) || []).length >= 4) || '';
}

async function decodeVinHint(vin) {
  if (!vin) return null;
  try {
    const res = await fetch(
      `${VPIC_BASE}/DecodeVinValues/${encodeURIComponent(vin)}?format=json`,
      {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(8000),
      }
    );
    if (!res.ok) return null;
    const data = await res.json();
    const row = data?.Results?.[0];
    if (!row || !row.Make || !row.ModelYear) return null;
    return {
      vin,
      year: Number(row.ModelYear) || null,
      make: String(row.Make || '').trim(),
      model: String(row.Model || '').trim(),
      trim: String(row.Trim || row.Series || '').trim(),
      bodyClass: String(row.BodyClass || '').trim(),
      driveType: String(row.DriveType || '').trim(),
      doors: String(row.Doors || '').trim(),
      fuelType: [row.FuelTypePrimary, row.ElectrificationLevel]
        .map((x) => String(x || '').trim())
        .filter(Boolean)
        .join(' • '),
      displacementL: row.DisplacementL ? `${Number(row.DisplacementL).toFixed(1)}L` : '',
    };
  } catch {
    return null;
  }
}

export function classifyBodyCategory(text = '') {
  const s = String(text || '').toLowerCase();
  if (
    /\b(?:f-?150|f-?250|f-?350|f-?450|super\s*duty|ranger|maverick|silverado|sierra|colorado|canyon|ram\s*1500|ram\s*2500|ram\s*3500|tundra|tacoma|frontier|titan|santa\s*cruz|gladiator|ridgeline|pickup|truck|crew\s*cab|supercab|regular\s*cab)\b/i.test(
      s
    )
  ) {
    return 'Pickup Truck';
  }
  if (/\b(?:transit|savana|express|sprinter|promaster|cargo\s*van|passenger\s*van|minivan|odyssey|sienna|pacifica|carnival)\b/i.test(s)) {
    return 'Van / Minivan';
  }
  if (
    /\b(?:expedition|navigator|tahoe|suburban|yukon|escalade|wagoneer|sequoia|armada|infiniti\s*qx80)\b/i.test(
      s
    )
  ) {
    return 'Full-Size 3-Row SUV';
  }
  if (
    /\b(?:explorer|aviator|palisade|telluride|cx-?90|cx-?9|highlander|grand\s*highlander|pilot|pathfinder|traverse|enclave|acadia|atlas|ascent|mdx|3rd[\s-]*row|three[\s-]*row|7[\s-]*passenger|8[\s-]*passenger)\b/i.test(
      s
    )
  ) {
    return '3-Row SUV';
  }
  if (
    /\b(?:nautilus|corsair|gv70|gv80|rx\s*350|nx\s*350|x3|x5|q5|q7|glc|gle|xt5|xt6|xc60|xc90|rdx|luxury\s*suv)\b/i.test(
      s
    )
  ) {
    return 'Luxury SUV';
  }
  if (
    /\b(?:bronco(?!\s*sport)|wrangler|4runner|land\s*cruiser|defender)\b/i.test(s)
  ) {
    return 'Off-Road SUV';
  }
  if (
    /\b(?:SANTA\s*FE|cx-?70|murano|edge|blazer|passport|outback|grand\s*cherokee|crown\s*signia|venza|midsize\s*suv)\b/i.test(
      s
    )
  ) {
    return 'Midsize SUV';
  }
  if (
    /\b(?:escape|bronco\s*sport|tucson|kona|venue|cx-?50|cx-?5|cx-?30|rogue|kicks|equinox|trailblazer|trax|rav4|cr-?v|hr-?v|forester|crosstrek|sportage|seltos|compass|cherokee|terrain|encore|compact\s*suv|suv|crossover|sport\s*utility)\b/i.test(
      s
    )
  ) {
    return 'Compact / Midsize SUV';
  }
  if (/\b(?:mustang(?!\s*mach)|corvette|camaro|challenger|miata|mx-?5|supra|z\s*coupe|brz|gr86|coupe|convertible)\b/i.test(s)) {
    return 'Sports Car / Coupe';
  }
  if (
    /\b(?:elantra|sonata|mazda3|altima|sentra|versa|malibu|camry|corolla|accord|civic|prius|jetta|k4|k5|sedan|hatchback)\b/i.test(
      s
    )
  ) {
    return 'Sedan / Hatchback';
  }
  return 'SUV / Crossover';
}

function classifyTrimTier(trim = '') {
  const s = String(trim || '').toLowerCase();
  if (!s) return '';
  if (
    /\b(?:black\s*label|platinum|king\s*ranch|limited|calligraphy|signature|turbo\s*s|turbo\s*premium\s*plus|high\s*country|premier|denali|reserve|summit|overland|autobiography|touring|prestige)\b/i.test(
      s
    )
  ) {
    return 'luxury';
  }
  if (
    /\b(?:lariat|st-?line|st|xlt|sel|preferred|lt|rst|z71|tremor|badlands|outer\s*banks|big\s*bend|rock\s*creek|carbon\s*edition|n\s*line|sv|ex-?l|ex|sport)\b/i.test(
      s
    )
  ) {
    return 'mid';
  }
  if (/\b(?:xl|se|s|base|wt|work\s*truck|ls|lx|le|select)\b/i.test(s)) {
    return 'entry';
  }
  return 'mid';
}

function defaultCrossBrandEquivalents(make, model, bodyCategory, powertrain) {
  const key = `${make || ''} ${model || ''}`.toLowerCase();
  const isHyb = /hybrid|hev|phev/i.test(powertrain || '');
  if (/highlander|pilot|telluride|atlas|ascent|traverse|mdx/i.test(key) || bodyCategory === '3-Row SUV') {
    return [
      { make: 'Ford', model: 'Explorer' },
      { make: 'Hyundai', model: isHyb ? 'Santa Fe' : 'Palisade' },
      { make: 'Mazda', model: 'CX-90' },
      { make: 'Lincoln', model: 'Aviator' },
      { make: 'Chevrolet', model: 'Traverse' },
      { make: 'Nissan', model: 'Pathfinder' },
    ];
  }
  if (/nautilus|rx|x5|gle|q7|gv80|xc90|mdx|xt5|xt6/i.test(key) || bodyCategory === 'Luxury SUV') {
    return [
      { make: 'Lincoln', model: 'Nautilus' },
      { make: 'Lincoln', model: 'Aviator' },
      { make: 'Lincoln', model: 'Corsair' },
      { make: 'Mazda', model: 'CX-70' },
      { make: 'Mazda', model: 'CX-90' },
      { make: 'Hyundai', model: 'Palisade' },
    ];
  }
  if (/rav4|cr-?v|forester|sportage|rogue|tucson|cx-?5|equinox|escape/i.test(key)) {
    return [
      { make: 'Mazda', model: 'CX-50' },
      { make: 'Mazda', model: 'CX-5' },
      { make: 'Hyundai', model: 'Tucson' },
      { make: 'Ford', model: 'Escape' },
      { make: 'Ford', model: 'Bronco Sport' },
      { make: 'Chevrolet', model: 'Equinox' },
      { make: 'Nissan', model: 'Rogue' },
    ];
  }
  if (bodyCategory === 'Pickup Truck') {
    if (/2500|3500|f-?250|f-?350|hd/i.test(key)) {
      return [
        { make: 'Ford', model: 'F-250' },
        { make: 'Ford', model: 'F-350' },
        { make: 'Chevrolet', model: 'Silverado 2500HD' },
      ];
    }
    if (/tacoma|colorado|canyon|frontier|ranger|maverick/i.test(key)) {
      return [
        { make: 'Ford', model: 'Ranger' },
        { make: 'Ford', model: 'Maverick' },
        { make: 'Chevrolet', model: 'Colorado' },
        { make: 'Nissan', model: 'Frontier' },
      ];
    }
    return [
      { make: 'Ford', model: 'F-150' },
      { make: 'Chevrolet', model: 'Silverado 1500' },
      { make: 'Ram', model: '1500' },
      { make: 'GMC', model: 'Sierra 1500' },
    ];
  }
  if (bodyCategory === 'Full-Size 3-Row SUV') {
    return [
      { make: 'Ford', model: 'Expedition' },
      { make: 'Lincoln', model: 'Navigator' },
      { make: 'Chevrolet', model: 'Tahoe' },
      { make: 'Chevrolet', model: 'Suburban' },
    ];
  }
  if (bodyCategory === 'Sedan / Hatchback') {
    return [
      { make: 'Hyundai', model: 'Sonata' },
      { make: 'Hyundai', model: 'Elantra' },
      { make: 'Mazda', model: 'Mazda3' },
      { make: 'Nissan', model: 'Altima' },
      { make: 'Nissan', model: 'Sentra' },
    ];
  }
  return [];
}

function buildFallbackExtractedProfile({ fileName, readableText, vinDecoded, extraNotes }) {
  const combinedText = [readableText, extraNotes].filter(Boolean).join('\n').trim();
  const nlParsed = parseNaturalLanguageCriteria({
    make: vinDecoded?.make || '',
    model: vinDecoded?.model || '',
    trim: vinDecoded?.trim || '',
    doors: vinDecoded?.doors || '',
    minYear: vinDecoded?.year || null,
    maxYear: vinDecoded?.year || null,
    notes: combinedText,
  });

  const make = nlParsed.make || vinDecoded?.make || '';
  const model = nlParsed.model || vinDecoded?.model || '';
  const trim = nlParsed.trim || vinDecoded?.trim || '';
  const year = vinDecoded?.year || nlParsed.minYear || nlParsed.maxYear || null;

  const powertrainText = `${combinedText} ${vinDecoded?.fuelType || ''} ${nlParsed.engineSpec || ''}`;
  let powertrain = 'Any';
  if (/plug[\s-]*in|\bphev\b/i.test(powertrainText)) powertrain = 'Plug-In Hybrid';
  else if (/\bhybrid\b|\bfhev\b|\bhev\b/i.test(powertrainText)) powertrain = 'Hybrid';
  else if (/\belectric\b|\bbev\b|\blightning\b|\bmach-?e\b|\bioniq\b/i.test(powertrainText))
    powertrain = 'Electric';
  else if (/\bdiesel\b|\bpower\s*stroke\b|\bduramax\b/i.test(powertrainText))
    powertrain = 'Diesel';
  else if (/\bv8\b|5\.0l|7\.3l|6\.2l/i.test(powertrainText)) powertrain = 'V8';
  else if (/ecoboost|turbo/i.test(powertrainText)) powertrain = 'Turbo / EcoBoost';

  const bodyCategory = classifyBodyCategory(
    `${make} ${model} ${trim} ${vinDecoded?.bodyClass || ''} ${combinedText}`
  );

  // Also detect standalone dollar price in document if "under $X" wasn't written (e.g. MSRP $54,820)
  let targetPrice = nlParsed.maxPrice || null;
  if (!targetPrice && combinedText) {
    const dollarMatches = [
      ...combinedText.matchAll(/\$\s*(\d{2,3},\d{3}(?:\.\d{2})?|\d{5,6})\b/g),
    ]
      .map((m) => Number(m[1].replace(/,/g, '')))
      .filter((n) => n >= 8000 && n <= 250000);
    if (dollarMatches.length > 0) {
      targetPrice = Math.max(...dollarMatches);
    }
  }

  let drivetrain = nlParsed.drivetrain || 'Any';
  if (drivetrain === 'Any' && vinDecoded?.driveType) {
    if (/4wd|4x4|four/i.test(vinDecoded.driveType)) drivetrain = '4WD';
    else if (/awd|all/i.test(vinDecoded.driveType)) drivetrain = 'AWD';
    else if (/fwd|front/i.test(vinDecoded.driveType)) drivetrain = 'FWD';
    else if (/rwd|rear/i.test(vinDecoded.driveType)) drivetrain = 'RWD';
  }

  const featurePatterns = [
    ['Leather Seats', /\bleather\b/i],
    ['Sunroof/Moonroof', /\b(?:sunroof|moonroof|panoramic|vista\s*roof)\b/i],
    ['Navigation System', /\b(?:navigation|nav\b)\b/i],
    ['Apple CarPlay', /\bcarplay\b/i],
    ['Android Auto', /\bandroid\s*auto\b/i],
    ['Blind Spot Monitor', /\b(?:blind\s*spot|blis)\b/i],
    ['Heated Seats', /\bheated\s*(?:front\s*)?seats\b/i],
    ['3rd Row Seating', /\b(?:3rd[\s-]*row|third[\s-]*row|7[\s-]*passenger|8[\s-]*passenger)\b/i],
    ['Tow Hitch', /\b(?:tow\s*(?:package|hitch|haul)|max\s*trailer)\b/i],
    ['360 Camera', /\b(?:360[\s°-]*camera|surround\s*view)\b/i],
    ['Remote Start', /\bremote\s*start\b/i],
    ['BlueCruise / Hands-Free', /\b(?:bluecruise|super\s*cruise)\b/i],
  ];
  const keyFeatures = [...(nlParsed.features || []), ...(nlParsed.strictPackages || [])];
  for (const [label, re] of featurePatterns) {
    if (re.test(combinedText) && !keyFeatures.includes(label)) {
      keyFeatures.push(label);
    }
  }

  const summaryVehicleLabel = [
    nlParsed.condition && nlParsed.condition !== 'Any' ? nlParsed.condition : '',
    year || '',
    make,
    model,
    trim,
    powertrain !== 'Any' && !/hybrid/i.test(`${model} ${trim}`) ? powertrain : '',
  ]
    .filter(Boolean)
    .join(' ');

  return {
    documentSummary: summaryVehicleLabel
      ? `Extracted target specifications from "${fileName}": ${summaryVehicleLabel}${
          targetPrice ? ` (~$${Math.round(targetPrice).toLocaleString()})` : ''
        }.`
      : `Analyzed "${fileName}" for vehicle class (${bodyCategory}), budget, and equipment preferences.`,
    extractedGuestName: '',
    referenceVehicle: {
      condition: nlParsed.condition || 'Any',
      year,
      minYear: nlParsed.minYear || (year ? year - 2 : null),
      maxYear: nlParsed.maxYear || (year ? year + 1 : null),
      make,
      model,
      trim,
      bodyCategory,
      doors: nlParsed.doors || (vinDecoded?.doors ? String(vinDecoded.doors) : ''),
      cabStyle: nlParsed.cabStyle || '',
      bedLength: nlParsed.bedLength ? String(nlParsed.bedLength).replace(/'$/, '') : '',
      drivetrain,
      powertrain,
      engineSpec: nlParsed.engineSpec || vinDecoded?.displacementL || '',
      targetPrice,
      maxMileage: nlParsed.maxMileage || null,
      exteriorColor: nlParsed.exteriorColor || '',
      interiorColor: '',
      keyFeatures: keyFeatures.slice(0, 10),
      equivalentPrestonModels: defaultCrossBrandEquivalents(
        make,
        model,
        bodyCategory,
        powertrain
      ),
    },
  };
}

async function extractDocumentProfileWithGemini({
  apiKey,
  model,
  fileName,
  mimeType,
  base64Data,
  readableText,
  vinDecoded,
  extraNotes,
}) {
  const fallback = buildFallbackExtractedProfile({
    fileName,
    readableText,
    vinDecoded,
    extraNotes,
  });
  if (!apiKey) return fallback;

  const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
    model
  )}:generateContent?key=${encodeURIComponent(apiKey)}`;

  const userParts = [];
  if (base64Data && GEMINI_INLINE_MIME_TYPES.has(mimeType)) {
    userParts.push({
      inlineData: {
        mimeType,
        data: base64Data,
      },
    });
  }

  const contextHints = {
    uploadedFileName: fileName,
    decodedVinFromDocumentIfFound: vinDecoded,
    extractedReadableTextPreview: readableText ? readableText.slice(0, 10000) : undefined,
    salespersonExtraNotes: extraNotes || undefined,
  };

  userParts.push({
    text: `Inspect this uploaded guest/vehicle document (e.g. window sticker, competitor quote, build sheet, buyer's order, trade-in registration, spec list, or photo) and extract a complete structured vehicle profile so we can find the closest equivalent vehicles across all Preston Automotive Group dealerships (Ford, Lincoln, Hyundai, Mazda, Nissan, Chevrolet, plus Pre-Owned of all makes).\n\nContext:\n${JSON.stringify(
      contextHints
    )}`,
  });

  const systemPrompt = `You are the Preston Automotive Group Gemini Document & Window-Sticker Analyst.
Extract the target vehicle specifications from the uploaded document and also suggest 3 to 6 closest equivalent models stocked at Preston Automotive Group (Ford, Lincoln, Hyundai, Mazda, Nissan, Chevrolet, GMC, Jeep, Ram, Toyota, Honda) in case an identical vehicle is not in stock.
For bodyCategory, choose one of: "Pickup Truck", "Full-Size 3-Row SUV", "3-Row SUV", "Luxury SUV", "Off-Road SUV", "Midsize SUV", "Compact / Midsize SUV", "Sedan / Hatchback", "Sports Car / Coupe", "Van / Minivan".
For drivetrain, choose one of: "4WD", "AWD", "FWD", "RWD", "Any".
For condition, choose one of: "New", "Pre-Owned", "CPO", "Any".
For powertrain, choose one of: "Hybrid", "Plug-In Hybrid", "Electric", "Diesel", "V8", "Turbo / EcoBoost", "Gasoline", "Any".`;

  try {
    const res = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: systemPrompt }] },
        contents: [{ role: 'user', parts: userParts }],
        generationConfig: {
          temperature: 0.1,
          responseMimeType: 'application/json',
          responseSchema: {
            type: 'OBJECT',
            properties: {
              documentSummary: { type: 'STRING' },
              extractedGuestName: { type: 'STRING' },
              condition: { type: 'STRING' },
              year: { type: 'INTEGER', nullable: true },
              make: { type: 'STRING' },
              model: { type: 'STRING' },
              trim: { type: 'STRING' },
              bodyCategory: { type: 'STRING' },
              doors: { type: 'STRING' },
              cabStyle: { type: 'STRING' },
              bedLength: { type: 'STRING' },
              drivetrain: { type: 'STRING' },
              powertrain: { type: 'STRING' },
              engineSpec: { type: 'STRING' },
              targetPrice: { type: 'NUMBER', nullable: true },
              maxMileage: { type: 'INTEGER', nullable: true },
              exteriorColor: { type: 'STRING' },
              interiorColor: { type: 'STRING' },
              keyFeatures: { type: 'ARRAY', items: { type: 'STRING' } },
              equivalentPrestonModels: {
                type: 'ARRAY',
                items: {
                  type: 'OBJECT',
                  properties: {
                    make: { type: 'STRING' },
                    model: { type: 'STRING' },
                  },
                  required: ['make', 'model'],
                },
              },
            },
            required: [
              'documentSummary',
              'condition',
              'make',
              'model',
              'trim',
              'bodyCategory',
              'drivetrain',
              'powertrain',
              'keyFeatures',
              'equivalentPrestonModels',
            ],
          },
        },
      }),
      signal: AbortSignal.timeout(30000),
    });

    if (!res.ok) return fallback;
    const data = await res.json();
    const raw = data?.candidates?.[0]?.content?.parts?.[0]?.text || '{}';
    const parsed = JSON.parse(raw);

    const ref = fallback.referenceVehicle;
    const yr = Number(parsed.year) || ref.year || null;
    const mergedEquiv = [
      ...(Array.isArray(parsed.equivalentPrestonModels) ? parsed.equivalentPrestonModels : []),
      ...(ref.equivalentPrestonModels || []),
    ];

    return {
      documentSummary: String(parsed.documentSummary || fallback.documentSummary).trim(),
      extractedGuestName: String(parsed.extractedGuestName || '').trim(),
      referenceVehicle: {
        condition: ['New', 'Pre-Owned', 'CPO', 'Any'].includes(parsed.condition)
          ? parsed.condition
          : ref.condition,
        year: yr,
        minYear: yr ? yr - 2 : ref.minYear,
        maxYear: yr ? yr + 1 : ref.maxYear,
        make: String(parsed.make || ref.make || '').trim(),
        model: String(parsed.model || ref.model || '').trim(),
        trim: String(parsed.trim || ref.trim || '').trim(),
        bodyCategory:
          String(parsed.bodyCategory || '').trim() ||
          classifyBodyCategory(`${parsed.make || ''} ${parsed.model || ''} ${parsed.trim || ''}`),
        doors: String(parsed.doors || ref.doors || '')
          .replace(/[^0-9]/g, '')
          .slice(0, 1),
        cabStyle: String(parsed.cabStyle || ref.cabStyle || '').trim(),
        bedLength: String(parsed.bedLength || ref.bedLength || '')
          .replace(/[^0-9.]/g, '')
          .trim(),
        drivetrain: ['4WD', 'AWD', 'FWD', 'RWD', 'Any'].includes(
          String(parsed.drivetrain || '').toUpperCase()
        )
          ? String(parsed.drivetrain).toUpperCase()
          : ref.drivetrain,
        powertrain: String(parsed.powertrain || ref.powertrain || 'Any').trim(),
        engineSpec: String(parsed.engineSpec || ref.engineSpec || '').trim(),
        targetPrice:
          typeof parsed.targetPrice === 'number' && parsed.targetPrice > 0
            ? parsed.targetPrice
            : ref.targetPrice,
        maxMileage:
          typeof parsed.maxMileage === 'number' && parsed.maxMileage > 0
            ? parsed.maxMileage
            : ref.maxMileage,
        exteriorColor: String(parsed.exteriorColor || ref.exteriorColor || '').trim(),
        interiorColor: String(parsed.interiorColor || '').trim(),
        keyFeatures: Array.from(
          new Set([
            ...(Array.isArray(parsed.keyFeatures)
              ? parsed.keyFeatures.map((f) => String(f).trim()).filter(Boolean)
              : []),
            ...(ref.keyFeatures || []),
          ])
        ).slice(0, 10),
        equivalentPrestonModels: mergedEquiv.slice(0, 8),
      },
    };
  } catch {
    return fallback;
  }
}

/**
 * Scores EVERY vehicle in the entire prestonmotor.com inventory by closeness/equivalence
 * to the extracted document profile — NEVER rejecting close alternatives when an exact twin is absent.
 */
export function scoreInventoryEquivalence(referenceVehicle, catalogVehicles) {
  const ref = referenceVehicle || {};
  const refMake = String(ref.make || '').trim().toLowerCase();
  const refModel = String(ref.model || '').trim();
  const refTrim = String(ref.trim || '').trim();
  const refTrimTier = classifyTrimTier(refTrim);
  const refBody =
    ref.bodyCategory || classifyBodyCategory(`${ref.make || ''} ${ref.model || ''} ${ref.trim || ''}`);
  const refPowertrain = String(ref.powertrain || 'Any').toLowerCase();
  const refDt = String(ref.drivetrain || 'Any').toUpperCase();
  const refPrice = typeof ref.targetPrice === 'number' && ref.targetPrice > 0 ? ref.targetPrice : null;
  const refYear = Number(ref.year) || null;
  const refCond = String(ref.condition || 'Any').toLowerCase();
  const refColor = String(ref.exteriorColor || '').trim();
  const refBed = String(ref.bedLength || '').replace(/'$/, '').trim();
  const refCab = String(ref.cabStyle || '').toLowerCase();
  const refDoors = String(ref.doors || '').trim();
  const refFeatures = Array.isArray(ref.keyFeatures) ? ref.keyFeatures : [];
  const equivModels = Array.isArray(ref.equivalentPrestonModels)
    ? ref.equivalentPrestonModels
    : [];

  const scored = [];

  for (const v of catalogVehicles) {
    let points = 32;
    const matchingHighlights = [];
    const keyDifferences = [];

    const vMakeLower = String(v.make || '').trim().toLowerCase();
    const sameMake = Boolean(refMake && vMakeLower === refMake);
    const sameModel = Boolean(refModel && doesVehicleMatchModel(refModel, v));

    const isSuggestedEquivModel =
      !sameModel &&
      equivModels.some((em) => {
        const emMake = String(em.make || '').trim().toLowerCase();
        const emModel = String(em.model || '').trim();
        return (!emMake || emMake === vMakeLower) && emModel && doesVehicleMatchModel(emModel, v);
      });

    const vBody = classifyBodyCategory(
      `${v.make || ''} ${v.model || ''} ${v.trim || ''} ${v.bodyStyle || ''} ${v.bodyType || ''} ${
        v.commentsSummary || ''
      }`
    );

    let matchTier = 'Closest Segment Alternative';

    if (sameMake && sameModel) {
      points += 30;
      matchingHighlights.push(`Same ${v.make} ${v.model} Model`);
      matchTier = 'Same Model • Closest Spec';
    } else if (isSuggestedEquivModel) {
      points += 21;
      matchingHighlights.push(`Direct ${refBody} Equivalent (${v.make} ${v.model})`);
      if (refMake && refModel) {
        keyDifferences.push(`${v.make} ${v.model} equivalent to ${ref.make} ${ref.model}`);
      }
      matchTier = 'Closest Cross-Brand Equivalent';
    } else if (vBody === refBody) {
      points += 15;
      matchingHighlights.push(`Matching ${vBody} Segment`);
      if (refMake && refModel) {
        keyDifferences.push(`${v.make} ${v.model} in same ${vBody} class`);
      }
      matchTier = sameMake ? 'Same Brand • Closest Segment' : 'Closest Cross-Brand Equivalent';
    } else if (
      refBody.includes('SUV') &&
      vBody.includes('SUV')
    ) {
      points += 7;
      keyDifferences.push(`${vBody} vs. ${refBody}`);
    } else {
      points -= 28;
      keyDifferences.push(`${vBody} body style`);
    }

    // Trim & Equipment Tier Closeness
    if (refTrim && doesVehicleMatchTrim(refTrim, v)) {
      points += 11;
      matchingHighlights.push(`${v.trim || refTrim} Trim`);
      if (sameMake && sameModel) {
        matchTier = 'Exact / Near-Identical Match';
      }
    } else if (refTrimTier && classifyTrimTier(v.trim) === refTrimTier && v.trim) {
      points += 6;
      matchingHighlights.push(`Comparable ${v.trim} Equipment Tier`);
      if (refTrim && sameModel) {
        keyDifferences.push(`${v.trim} trim vs. ${refTrim}`);
      }
    } else if (refTrim && v.trim && sameModel) {
      keyDifferences.push(`${v.trim} trim vs. ${refTrim}`);
    }

    // Powertrain / Fuel Closeness
    const vPowerText = `${v.fuelType || ''} ${v.engine || ''} ${v.title || ''} ${
      v.commentsSummary || ''
    }`.toLowerCase();
    const vIsHybrid = /hybrid|\bfhev\b|\bhev\b|gas\/electric/i.test(vPowerText);
    const vIsPhev = /plug[\s-]*in|\bphev\b/i.test(vPowerText);
    const vIsElectric = /\belectric\b|\bbev\b|\blightning\b|\bmach-?e\b|\bioniq\b/i.test(vPowerText) && !vIsHybrid;
    const vIsDiesel = /\bdiesel\b|power\s*stroke|duramax/i.test(vPowerText);

    if (refPowertrain && refPowertrain !== 'any') {
      if (refPowertrain.includes('plug') && vIsPhev) {
        points += 10;
        matchingHighlights.push('Plug-In Hybrid Powertrain');
      } else if (refPowertrain.includes('hybrid') && (vIsHybrid || vIsPhev)) {
        points += 10;
        matchingHighlights.push('Hybrid Powertrain');
      } else if (refPowertrain.includes('electric') && vIsElectric) {
        points += 10;
        matchingHighlights.push('All-Electric Powertrain');
      } else if (refPowertrain.includes('diesel') && vIsDiesel) {
        points += 10;
        matchingHighlights.push('Diesel Powertrain');
      } else if (refPowertrain.includes('v8') && /\bv8\b|5\.0l|7\.3l|6\.2l/i.test(vPowerText)) {
        points += 8;
        matchingHighlights.push(`${v.engine || 'V8'} Engine`);
      } else if (refPowertrain.includes('turbo') && /ecoboost|turbo/i.test(vPowerText)) {
        points += 7;
        matchingHighlights.push('Turbocharged Engine');
      } else if (refPowertrain.includes('gas') && !vIsElectric && !vIsDiesel) {
        points += 5;
      } else if (refPowertrain.includes('hybrid') && !vIsHybrid) {
        points -= 4;
        keyDifferences.push(`${v.fuelType || 'Gasoline'} vs. Hybrid`);
      }
    }

    // Drivetrain Closeness
    const vDt = String(v.drivetrain || '').toUpperCase();
    if (refDt && refDt !== 'ANY') {
      if (vDt.includes(refDt) || (refDt === '4WD' && vDt.includes('4WD')) || (refDt === 'AWD' && vDt.includes('AWD'))) {
        points += 9;
        matchingHighlights.push(`${v.drivetrain || refDt} Drivetrain`);
      } else if ((refDt === '4WD' && vDt.includes('AWD')) || (refDt === 'AWD' && vDt.includes('4WD'))) {
        points += 7;
        matchingHighlights.push(`${v.drivetrain} All-Weather Traction`);
      } else if (vDt) {
        points -= 4;
        keyDifferences.push(`${v.drivetrain} vs. ${refDt}`);
      }
    } else if (v.drivetrain) {
      matchingHighlights.push(`${v.drivetrain} Drivetrain`);
    }

    // Price Closeness
    const effectivePrice =
      typeof v.price === 'number' && v.price > 0
        ? v.price
        : typeof v.msrp === 'number' && v.msrp > 0
          ? v.msrp
          : null;
    if (refPrice && effectivePrice) {
      const diff = effectivePrice - refPrice;
      const pctDiff = Math.abs(diff) / refPrice;
      if (pctDiff <= 0.08) {
        points += 12;
        matchingHighlights.push(
          diff <= 0
            ? `$${Math.round(effectivePrice).toLocaleString()} ($${Math.round(Math.abs(diff)).toLocaleString()} under target)`
            : `$${Math.round(effectivePrice).toLocaleString()} (Within 8% of target)`
        );
      } else if (pctDiff <= 0.18) {
        points += 8;
        if (diff < 0) {
          matchingHighlights.push(
            `$${Math.round(Math.abs(diff)).toLocaleString()} below target price`
          );
        } else {
          keyDifferences.push(`$${Math.round(diff).toLocaleString()} above document price`);
        }
      } else if (pctDiff <= 0.3) {
        points += 3;
        keyDifferences.push(
          diff > 0
            ? `$${Math.round(diff).toLocaleString()} higher price tier`
            : `$${Math.round(Math.abs(diff)).toLocaleString()} lower price tier`
        );
      } else {
        points -= Math.min(14, Math.round((pctDiff - 0.3) * 24));
      }
    }

    // Condition & Year Closeness
    const vcLower = String(v.condition || '').toLowerCase();
    if (refCond && refCond !== 'any') {
      if (
        (refCond === 'new' && vcLower.includes('new')) ||
        (refCond === 'cpo' && vcLower.includes('certified')) ||
        (refCond === 'pre-owned' && !vcLower.includes('new'))
      ) {
        points += 5;
      } else {
        keyDifferences.push(`${v.condition} condition`);
      }
    }
    if (refYear && v.year) {
      const yrDiff = Math.abs(Number(v.year) - refYear);
      if (yrDiff === 0) points += 5;
      else if (yrDiff <= 1) points += 3;
      else if (yrDiff <= 3) points += 1;
      else points -= Math.min(8, yrDiff * 2);
    }

    // Truck Cab / Bed / Doors Closeness
    if (refBed) {
      const vBed = (
        v.bedLength ||
        extractBedLengthFromVehicle(v, v.fullCommentsSearchText || v.commentsSummary || '')
      )
        .replace(/'$/, '')
        .trim();
      if (vBed && vBed === refBed) {
        points += 7;
        matchingHighlights.push(formatBedLengthLabel(vBed));
      } else if (vBed) {
        keyDifferences.push(`${formatBedLengthLabel(vBed)} vs. ${formatBedLengthLabel(refBed)}`);
      }
    }
    if (refCab && v.cabStyle) {
      if (v.cabStyle.toLowerCase() === refCab) {
        points += 5;
        matchingHighlights.push(v.cabStyle);
      } else {
        keyDifferences.push(`${v.cabStyle} vs. ${ref.cabStyle}`);
      }
    }
    if (refDoors && v.doors && String(v.doors) === refDoors) {
      points += 3;
    }

    // Exterior Color & Key Features Overlap
    if (refColor && v.exteriorColor) {
      if (doesVehicleMatchColor(refColor, v)) {
        points += 5;
        matchingHighlights.push(`${v.exteriorColor} Exterior`);
      } else {
        keyDifferences.push(`${v.exteriorColor} exterior`);
      }
    }

    const fullHay = `${(v.highlights || []).join(' | ')} | ${v.engine || ''} | ${
      v.exteriorColor || ''
    } | ${v.interiorColor || ''} | ${v.fullCommentsSearchText || v.commentsSummary || ''}`.toLowerCase();

    let featureHits = 0;
    for (const feat of refFeatures) {
      const words = String(feat || '')
        .toLowerCase()
        .replace(/[^a-z0-9\s]/g, ' ')
        .split(/\s+/)
        .filter((w) => w.length >= 3);
      if (words.length > 0 && words.some((w) => fullHay.includes(w))) {
        featureHits++;
        if (matchingHighlights.length < 6) {
          matchingHighlights.push(feat);
        }
      }
    }
    points += Math.min(10, featureHits * 2);

    if (matchingHighlights.length < 4 && Array.isArray(v.highlights)) {
      for (const h of v.highlights.slice(0, 4)) {
        if (!matchingHighlights.some((mh) => mh.toLowerCase().includes(h.toLowerCase()))) {
          matchingHighlights.push(h);
        }
        if (matchingHighlights.length >= 5) break;
      }
    }

    const maxAllowedScore = sameMake && sameModel ? 99 : 94;
    const similarityScore = Math.max(35, Math.min(maxAllowedScore, Math.round(points)));
    const priceLabel = effectivePrice
      ? `$${Math.round(effectivePrice).toLocaleString()}`
      : 'Call for Price';

    const whyEquivalent =
      sameMake && sameModel
        ? `In-stock ${v.condition} ${v.title} at ${v.location} (${priceLabel}) closely matches the uploaded ${
            ref.make
          } ${ref.model} spec${
            keyDifferences.length > 0 ? ` (${keyDifferences.slice(0, 2).join('; ')})` : ''
          }.`
        : `Closest ${vBody.toLowerCase()} equivalent at ${v.location}: ${v.condition} ${
            v.title
          } (${priceLabel}) aligns on ${matchingHighlights.slice(0, 3).join(', ')}.`;

    scored.push({
      vehicle: v,
      rawPoints: points,
      similarityScore,
      matchTier,
      whyEquivalent,
      matchingHighlights: Array.from(new Set(matchingHighlights)).slice(0, 6),
      keyDifferences: Array.from(new Set(keyDifferences)).slice(0, 3),
    });
  }

  scored.sort((a, b) => {
    if (b.similarityScore !== a.similarityScore) {
      return b.similarityScore - a.similarityScore;
    }
    if (b.rawPoints !== a.rawPoints) {
      return b.rawPoints - a.rawPoints;
    }
    const pa = a.vehicle.price ?? Number.MAX_SAFE_INTEGER;
    const pb = b.vehicle.price ?? Number.MAX_SAFE_INTEGER;
    if (refPrice && pa !== Number.MAX_SAFE_INTEGER && pb !== Number.MAX_SAFE_INTEGER) {
      return Math.abs(pa - refPrice) - Math.abs(pb - refPrice);
    }
    return pa - pb;
  });

  return scored;
}

/**
 * Full pipeline: reads uploaded document -> extracts target specs with Gemini ->
 * scans ENTIRE prestonmotor.com inventory -> ranks closest equivalent vehicles with Gemini.
 */
export async function findClosestEquivalentsFromDocument({
  fileName = 'uploaded-document',
  mimeType = '',
  base64Data = '',
  extraNotes = '',
}) {
  const cleanB64 = String(base64Data || '')
    .replace(/^data:[^;]+;base64,/, '')
    .replace(/\s+/g, '');

  if (!cleanB64 && !String(extraNotes || '').trim()) {
    const err = new Error('Please choose a document file to upload.');
    err.statusCode = 400;
    throw err;
  }

  const resolvedMime = inferMimeType(fileName, mimeType);
  const buffer = cleanB64 ? Buffer.from(cleanB64, 'base64') : Buffer.alloc(0);
  const readableText = extractReadableTextFromBuffer(buffer, fileName, resolvedMime);
  const detectedVin = extractFirstValidVinFromText(`${readableText} ${extraNotes}`);

  const apiKey = getSetting('gemini_api_key');
  const model = getSetting('gemini_model') || 'gemini-2.5-flash';

  // Run NHTSA vPIC VIN hint decode (if a VIN appears in the doc) and full prestonmotor.com catalog fetch in parallel!
  const [vinDecoded, entireCatalog] = await Promise.all([
    decodeVinHint(detectedVin),
    fetchEntirePrestonInventory(),
  ]);

  const extracted = await extractDocumentProfileWithGemini({
    apiKey,
    model,
    fileName,
    mimeType: resolvedMime,
    base64Data: cleanB64,
    readableText,
    vinDecoded,
    extraNotes,
  });

  const referenceVehicle = extracted.referenceVehicle;
  const deterministicRanked = scoreInventoryEquivalence(referenceVehicle, entireCatalog);
  const topShortlist = deterministicRanked.slice(0, 32);

  let finalEquivalents = deterministicRanked.slice(0, 15);
  let overallSummary = extracted.documentSummary;
  let agentMode = apiKey ? `gemini (${model})` : 'smart-equivalence-engine';

  if (apiKey && topShortlist.length > 0) {
    const endpoint = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
      model
    )}:generateContent?key=${encodeURIComponent(apiKey)}`;

    const shortlistCompact = topShortlist.map((item) => ({
      vin: item.vehicle.vin,
      title: item.vehicle.title,
      year: item.vehicle.year,
      make: item.vehicle.make,
      model: item.vehicle.model,
      trim: item.vehicle.trim,
      condition: item.vehicle.condition,
      price: item.vehicle.price,
      location: item.vehicle.location,
      mileage: item.vehicle.mileage,
      drivetrain: item.vehicle.drivetrain,
      engine: item.vehicle.engine,
      fuelType: item.vehicle.fuelType,
      exteriorColor: item.vehicle.exteriorColor,
      bedLength: item.vehicle.bedLength || '',
      cabStyle: item.vehicle.cabStyle || '',
      highlights: (item.vehicle.highlights || []).slice(0, 6),
      baselineScore: item.similarityScore,
    }));

    const rankPrompt = `You are the Preston Automotive Group Gemini Equivalent-Vehicle Matchmaker.
Given the vehicle specifications extracted from the guest's uploaded document ("${fileName}") and the top candidate vehicles across the entire prestonmotor.com inventory (${entireCatalog.length} total vehicles scanned), select and rank the 10 to 15 CLOSEST EQUIVALENT vehicles.
Important Rules:
1. Matching vehicles do NOT have to be identical to the document — rank the closest equivalents available in stock on prestonmotor.com!
2. Prioritize exact/same-model matches first when available, followed by closest trim/year/price variants and closest cross-brand segment equivalents (same body style, seating capacity, drivetrain, powertrain, and budget tier).
3. Never return an empty list when candidates are provided — always surface the closest available vehicles and clearly note both matchingHighlights and any keyDifferences.`;

    try {
      const rankRes = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: rankPrompt }] },
          contents: [
            {
              role: 'user',
              parts: [
                {
                  text: JSON.stringify({
                    documentSummary: extracted.documentSummary,
                    targetReferenceVehicle: referenceVehicle,
                    totalPrestonInventoryScanned: entireCatalog.length,
                    shortlistedCandidates: shortlistCompact,
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
                equivalents: {
                  type: 'ARRAY',
                  items: {
                    type: 'OBJECT',
                    properties: {
                      vin: { type: 'STRING' },
                      similarityScore: { type: 'INTEGER' },
                      matchTier: { type: 'STRING' },
                      whyEquivalent: { type: 'STRING' },
                      matchingHighlights: {
                        type: 'ARRAY',
                        items: { type: 'STRING' },
                      },
                      keyDifferences: {
                        type: 'ARRAY',
                        items: { type: 'STRING' },
                      },
                    },
                    required: [
                      'vin',
                      'similarityScore',
                      'matchTier',
                      'whyEquivalent',
                      'matchingHighlights',
                      'keyDifferences',
                    ],
                  },
                },
              },
              required: ['overallSummary', 'equivalents'],
            },
          },
        }),
        signal: AbortSignal.timeout(30000),
      });

      if (rankRes.ok) {
        const d = await rankRes.json();
        const raw = d?.candidates?.[0]?.content?.parts?.[0]?.text || '{}';
        const parsed = JSON.parse(raw);
        const detByVin = new Map(topShortlist.map((s) => [s.vehicle.vin, s]));
        const geminiPicked = [];

        for (const eq of parsed.equivalents || []) {
          const base = detByVin.get(eq.vin);
          if (!base) continue;
          geminiPicked.push({
            vehicle: base.vehicle,
            similarityScore: Math.max(
              35,
              Math.min(99, Number(eq.similarityScore) || base.similarityScore)
            ),
            matchTier: String(eq.matchTier || base.matchTier).trim(),
            whyEquivalent: String(eq.whyEquivalent || base.whyEquivalent).trim(),
            matchingHighlights: Array.from(
              new Set([
                ...(Array.isArray(eq.matchingHighlights) ? eq.matchingHighlights : []),
                ...base.matchingHighlights,
              ])
            ).slice(0, 6),
            keyDifferences: Array.from(
              new Set([
                ...(Array.isArray(eq.keyDifferences) ? eq.keyDifferences : []),
                ...base.keyDifferences,
              ])
            ).slice(0, 3),
          });
        }

        if (geminiPicked.length > 0) {
          geminiPicked.sort((a, b) => b.similarityScore - a.similarityScore);
          finalEquivalents = geminiPicked.slice(0, 15);
          if (parsed.overallSummary) {
            overallSummary = String(parsed.overallSummary).trim();
          }
        }
      }
    } catch {
      agentMode = `gemini-fallback (${model})`;
    }
  } else {
    const locCount = new Set(finalEquivalents.map((m) => m.vehicle.location)).size;
    overallSummary = `${extracted.documentSummary} Scanned all ${entireCatalog.length.toLocaleString()} live prestonmotor.com vehicles and ranked the ${
      finalEquivalents.length
    } closest equivalent vehicle(s) across ${locCount} Preston dealership location(s).`;
  }

  return {
    fileName,
    mimeType: resolvedMime,
    analyzedAt: new Date().toISOString(),
    agentMode,
    totalInventoryScanned: entireCatalog.length,
    documentSummary: extracted.documentSummary,
    overallSummary,
    extractedGuestName: extracted.extractedGuestName || '',
    referenceVehicle,
    equivalents: finalEquivalents.map((item) => ({
      vin: item.vehicle.vin,
      stockNumber: item.vehicle.stockNumber || '',
      title: item.vehicle.title || '',
      year: item.vehicle.year || null,
      make: item.vehicle.make || '',
      model: item.vehicle.model || '',
      trim: item.vehicle.trim || '',
      condition: item.vehicle.condition || '',
      price: item.vehicle.price ?? null,
      msrp: item.vehicle.msrp ?? null,
      location: item.vehicle.location || 'Preston Automotive Group',
      mileage: typeof item.vehicle.mileage === 'number' ? item.vehicle.mileage : 0,
      drivetrain: item.vehicle.drivetrain || '',
      engine: item.vehicle.engine || '',
      fuelType: item.vehicle.fuelType || '',
      exteriorColor: item.vehicle.exteriorColor || '',
      interiorColor: item.vehicle.interiorColor || '',
      photoUrl: item.vehicle.photoUrl || '',
      listingUrl: item.vehicle.listingUrl || 'https://www.prestonmotor.com',
      similarityScore: item.similarityScore,
      matchTier: item.matchTier,
      whyEquivalent: item.whyEquivalent,
      matchingHighlights: item.matchingHighlights,
      keyDifferences: item.keyDifferences,
    })),
  };
}
