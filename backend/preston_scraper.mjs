import {
  bedLengthToCosmosFacetValues,
  expandPrestonModelVariants,
  extractBedLengthFromVehicle,
  extractCabStyleFromText,
  formatBedLengthLabel,
  parseNaturalLanguageCriteria,
} from './natural_language_parser.mjs';

const PRESTON_HOST = 'www.prestonmotor.com';
const BASE_URL = `https://${PRESTON_HOST}`;

let cachedConfig = {
  dealerId: 19398,
  newPageId: 1446609,
  usedPageId: 1446611,
  fetchedAt: 0,
};

/**
 * Normalizes structured guest fields AND extracts structured vehicle criteria
 * (Make, Model like "F150" -> "F-150", Trim like "XLT", Bed Length like "6.5ft bed",
 * Cab Style, Engine, Year Range, Max Price, Max Mileage, Condition, Drivetrain,
 * Color, and Dealership Location hints) from natural-language input.
 */
export function normalizeGuestSpecs(guest) {
  return parseNaturalLanguageCriteria(guest);
}

async function refreshDealerOnConfig(force = false) {
  const now = Date.now();
  if (!force && now - cachedConfig.fetchedAt < 6 * 3600 * 1000 && cachedConfig.fetchedAt > 0) {
    return cachedConfig;
  }
  try {
    const [newHtml, usedHtml] = await Promise.all([
      fetch(`${BASE_URL}/searchnew.aspx`, {
        headers: { 'User-Agent': 'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36' },
        signal: AbortSignal.timeout(10000),
      }).then((r) => r.text()),
      fetch(`${BASE_URL}/searchused.aspx`, {
        headers: { 'User-Agent': 'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36' },
        signal: AbortSignal.timeout(10000),
      }).then((r) => r.text()),
    ]);

    const extractModel = (html) => {
      const m = html.match(/id=["']dlron-srp-model["'][^>]*>([\s\S]*?)<\/script>/i);
      if (!m) return null;
      return JSON.parse(m[1].trim());
    };

    const newModel = extractModel(newHtml);
    const usedModel = extractModel(usedHtml);

    cachedConfig = {
      dealerId: newModel?.DealerId || usedModel?.DealerId || 19398,
      newPageId: newModel?.PageId || 1446609,
      usedPageId: usedModel?.PageId || 1446611,
      fetchedAt: now,
    };
  } catch {
    // Retain safe known Preston Motor IDs on transient timeout
    cachedConfig.fetchedAt = now;
  }
  return cachedConfig;
}

function parsePriceLibrary(b64String) {
  const prices = {
    finalPrice: null,
    internetPrice: null,
    sellingPrice: null,
    msrp: null,
    dealerFee: null,
  };
  if (!b64String) return prices;

  try {
    const decoded = Buffer.from(b64String, 'base64').toString('utf8');
    const entries = decoded.split(';');
    const kv = {};
    for (const entry of entries) {
      const idx = entry.indexOf(':');
      if (idx === -1) continue;
      const k = entry.slice(0, idx).trim();
      const v = parseFloat(entry.slice(idx + 1).trim());
      if (!Number.isNaN(v) && v > 0) {
        kv[k] = v;
      }
    }

    prices.msrp = kv['MSRP'] || kv['calc_MSRP'] || null;
    prices.internetPrice =
      kv['Internet Price'] || kv['calc_INTERNET PRICE'] || kv['Selling Price'] || null;
    prices.sellingPrice = kv['Selling Price'] || null;
    prices.finalPrice =
      kv['calc_FINAL PRICE'] ||
      kv['Internet Price'] ||
      kv['Selling Price'] ||
      kv['calc_INTERNET PRICE'] ||
      kv['MSRP'] ||
      null;
    prices.dealerFee =
      kv['Dealer Processing Fee'] || kv['calc_Dealer Doc Fee'] || null;
  } catch {
    // Ignore malformed base64
  }
  return prices;
}

function stripHtml(html) {
  if (!html) return '';
  return html
    .replace(/<br\s*\/?>/gi, ' | ')
    .replace(/<\/h4>/gi, ': ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, ' ')
    .trim();
}

function normalizeDrivetrain(vc, highlights, commentsText) {
  const explicitDt = (vc.VehicleDriveTrain || '').toUpperCase();
  const raw = `${explicitDt} ${highlights.join(' ')} ${commentsText}`.toUpperCase();
  if (explicitDt.includes('4WD') || explicitDt.includes('4X4') || raw.includes('4X4') || raw.includes('FOUR WHEEL DRIVE')) {
    return '4WD';
  }
  if (explicitDt.includes('AWD') || raw.includes('ALL WHEEL DRIVE') || raw.includes('ALL-WHEEL')) {
    return 'AWD';
  }
  if (raw.includes('4WD/AWD')) {
    return 'AWD / 4WD';
  }
  if (raw.includes('4WD')) {
    return '4WD';
  }
  if (raw.includes('RWD') || raw.includes('REAR WHEEL DRIVE')) {
    return 'RWD';
  }
  if (raw.includes('FWD') || raw.includes('FRONT WHEEL DRIVE')) {
    return 'FWD';
  }
  return vc.VehicleDriveTrain || '';
}

function formatDealershipLocation(vc) {
  const city = (vc.DealerLocatedAtCity || '').trim();
  const state = (vc.DealerLocatedAtState || '').trim();
  const cityState = [city, state].filter(Boolean).join(', ');
  const dealerBranch = (
    vc.VehicleLocationLabel ||
    vc.VehicleLocation ||
    vc.DealerName ||
    'Preston Automotive Group'
  ).trim();

  if (!cityState) return dealerBranch;
  if (city && dealerBranch.toLowerCase().includes(city.toLowerCase())) {
    if (state && !dealerBranch.toLowerCase().includes(`, ${state.toLowerCase()}`)) {
      return `${dealerBranch}, ${state}`;
    }
    return dealerBranch;
  }
  return `${dealerBranch} (${cityState})`;
}

function parseVehicleCard(vc, { facetBedLength = '' } = {}) {
  if (!vc || !vc.VehicleVin) return null;

  const prices = parsePriceLibrary(vc.VehiclePriceLibrary);
  const price =
    prices.finalPrice ||
    (vc.VehicleInternetPrice > 0 ? vc.VehicleInternetPrice : null) ||
    (vc.VehicleMsrp > 0 ? vc.VehicleMsrp : null);

  const rawHighlights = Array.isArray(vc.VehicleHighlightsModel?.Highlights)
    ? vc.VehicleHighlightsModel.Highlights.filter(Boolean)
    : [];

  const commentsClean = stripHtml(vc.VehicleComments || '');
  const drivetrain = normalizeDrivetrain(vc, rawHighlights, commentsClean);
  const location = formatDealershipLocation(vc);
  const bodyStyle = vc.VehicleBodyStyle || vc.VehicleBodyType || '';
  const bedLength = extractBedLengthFromVehicle(vc, commentsClean, facetBedLength);
  const cabStyle = extractCabStyleFromText(
    `${bodyStyle} ${vc.VehicleName || ''} ${commentsClean}`
  );

  const highlights = [...rawHighlights];
  if (bedLength) {
    const bedLabel = formatBedLengthLabel(bedLength);
    if (bedLabel && !highlights.some((h) => h.toLowerCase().includes(bedLabel.toLowerCase()))) {
      highlights.unshift(bedLabel);
    }
  }

  const rawPhoto =
    vc.VehicleImageModel?.VehicleImageCarouselModel?.PhotoList?.[0] ||
    vc.VehicleImageModel?.VehiclePhotoSrc ||
    '';
  const photoUrl = rawPhoto
    ? rawPhoto.startsWith('http')
      ? rawPhoto
      : `${BASE_URL}${rawPhoto}`
    : '';

  const detailUrl =
    vc.VehicleImageModel?.VehicleDetailUrl ||
    vc.VehicleImageModel?.VehicleImageCarouselModel?.RedirectLocation ||
    BASE_URL;

  const conditionRaw = vc.VehicleCondition || (vc.VehicleType === 'new' ? 'New' : 'Pre-Owned');
  const condition = vc.VehicleCpo ? 'Certified Pre-Owned' : conditionRaw;

  return {
    vin: vc.VehicleVin,
    stockNumber: vc.VehicleStockNumber || '',
    title: vc.VehicleName || `${vc.VehicleYear} ${vc.VehicleMake} ${vc.VehicleModel}`.trim(),
    year: Number(vc.VehicleYear) || null,
    make: (vc.VehicleMake || '').trim(),
    model: (vc.VehicleModel || '').trim(),
    trim: (vc.VehicleTrim || vc.VehicleRuleAdjustedTrim || '').trim(),
    condition,
    bodyStyle,
    bedLength,
    cabStyle,
    vehicleLength: Number(vc.Length) || null,
    price,
    msrp: prices.msrp || (vc.VehicleMsrp > 0 ? vc.VehicleMsrp : null),
    dealerFee: prices.dealerFee,
    location,
    dealerCity: (vc.DealerLocatedAtCity || '').trim(),
    dealerState: (vc.DealerLocatedAtState || '').trim(),
    mileage: typeof vc.VehicleMileage === 'number' ? vc.VehicleMileage : 0,
    drivetrain,
    engine: vc.VehicleEngine || '',
    fuelType: vc.VehicleFuelType || '',
    transmission: vc.VehicleTransmission || '',
    exteriorColor: vc.ExteriorColorLabel || vc.VehicleGenericColor || '',
    interiorColor: vc.InteriorColorLabel || '',
    photoUrl,
    listingUrl: detailUrl.startsWith('http') ? detailUrl : `${BASE_URL}${detailUrl}`,
    highlights,
    commentsSummary: commentsClean.slice(0, 900),
    fullCommentsSearchText: commentsClean.slice(0, 3500),
  };
}

async function fetchSingleCosmosPage(
  dealerId,
  pageId,
  paramsObj,
  pageNumber = 1,
  retries = 1,
  { facetBedLength = '' } = {}
) {
  const queryObj = {
    ...paramsObj,
    pn: '96',
    host: PRESTON_HOST,
  };
  if (pageNumber > 1) {
    queryObj.pt = String(pageNumber);
  }
  const qs = new URLSearchParams(queryObj);
  const url = `${BASE_URL}/api/vhcliaa/vehicle-pages/cosmos/srp/vehicles/${dealerId}/${pageId}?${qs.toString()}`;

  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const res = await fetch(url, {
        headers: {
          'User-Agent': 'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36',
          Accept: 'application/json',
        },
        signal: AbortSignal.timeout(20000),
      });
      if (!res.ok) {
        throw new Error(`PrestonMotor API HTTP ${res.status}`);
      }
      const json = await res.json();
      const cards = Array.isArray(json.DisplayCards) ? json.DisplayCards : [];
      const vehicles = [];
      for (const item of cards) {
        if (item?.IsAdCard || !item?.VehicleCard) continue;
        const parsed = parseVehicleCard(item.VehicleCard, { facetBedLength });
        if (parsed) vehicles.push(parsed);
      }

      const paging = json?.Paging?.PaginationDataModel || {};
      const totalCount = Number(paging.TotalCount) || vehicles.length;
      const pageSize = Number(paging.PageSize) || 96;
      const computedPages =
        pageSize > 0 ? Math.ceil(totalCount / pageSize) : Number(paging.TotalPages) || 1;
      const totalPages = Math.min(25, Math.max(1, Number(paging.TotalPages) || computedPages));

      return { vehicles, totalPages, totalCount };
    } catch (err) {
      if (attempt === retries) throw err;
      await new Promise((r) => setTimeout(r, 350));
    }
  }
  return { vehicles: [], totalPages: 1, totalCount: 0 };
}

/**
 * Fetches ALL result pages (pt = 1 .. totalPages, 96 vehicles/page) from prestonmotor.com
 * in gentle concurrent batches of 3 so broad searches (such as "Ford under $60K") capture
 * every matching vehicle across every Preston Automotive Group store (including Boulevard Ford
 * in Millsboro, DE).
 */
async function fetchAllCosmosPages(
  dealerId,
  pageId,
  paramsObj,
  { maxPrice = null, facetBedLength = '' } = {}
) {
  const firstPage = await fetchSingleCosmosPage(dealerId, pageId, paramsObj, 1, 1, {
    facetBedLength,
  });
  const allVehicles = [...firstPage.vehicles];

  if (firstPage.totalPages <= 1) {
    return allVehicles;
  }

  const concurrency = 3;
  for (let startPt = 2; startPt <= firstPage.totalPages; startPt += concurrency) {
    const pageNums = [];
    for (let pt = startPt; pt < startPt + concurrency && pt <= firstPage.totalPages; pt++) {
      pageNums.push(pt);
    }

    const batchResults = await Promise.all(
      pageNums.map((pt) =>
        fetchSingleCosmosPage(dealerId, pageId, paramsObj, pt, 1, { facetBedLength }).catch(() => ({
          vehicles: [],
        }))
      )
    );

    let batchAllOverCap = false;
    for (const pageRes of batchResults) {
      allVehicles.push(...pageRes.vehicles);

      // DealerOn sorts SRP results by price ascending; if an entire full page has every
      // priced vehicle well above maxPrice * 1.25 (allowing generous margin for rebates),
      // remaining higher-priced pages cannot match.
      if (maxPrice != null && maxPrice > 0 && pageRes.vehicles.length >= 40) {
        const priced = pageRes.vehicles.filter((v) => typeof v.price === 'number' && v.price > 0);
        if (
          priced.length >= 40 &&
          priced.every((v) => v.price > maxPrice * 1.25 && (!v.msrp || v.msrp > maxPrice * 1.25))
        ) {
          batchAllOverCap = true;
        }
      }
    }

    if (batchAllOverCap) break;
  }

  return allVehicles;
}

function cleanKeywordFromNotes(notes) {
  if (!notes) return '';
  return notes
    .split(/[.,;\n]/)[0]
    .replace(
      /\b(?:under|below|max|up\s+to|less\s+than|around|budget(?:\s+of)?)\s*\$?\s*\d+(?:,\d{3})*(?:\.\d+)?\s*(?:k|thousand)?\b/gi,
      ' '
    )
    .replace(/\$\s*\d+(?:,\d{3})*(?:\.\d+)?\s*(?:k|thousand)?\b/gi, ' ')
    .replace(/\b(?:looking\s+for|wants?|needs?|targeting|a|an|the|at|in|with)\b/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 50);
}

export async function searchPrestonInventory(rawGuest) {
  const guest = normalizeGuestSpecs(rawGuest);
  const cfg = await refreshDealerOnConfig();
  const cond = (guest.condition || 'Any').toLowerCase();

  const pageIds = [];
  if (cond === 'new') {
    pageIds.push(cfg.newPageId);
  } else if (
    cond === 'pre-owned' ||
    cond === 'used' ||
    cond === 'cpo' ||
    cond === 'certified pre-owned'
  ) {
    pageIds.push(cfg.usedPageId);
  } else {
    pageIds.push(cfg.newPageId, cfg.usedPageId);
  }

  const byVin = new Map();
  const make = guest.make;
  const model = guest.model;
  const trim = guest.trim;
  const bedLength = guest.bedLength || '';
  const maxPrice = guest.maxPrice;
  const modelVariants = expandPrestonModelVariants(make, model);
  const bedFacetValues = bedLengthToCosmosFacetValues(bedLength);

  for (const pageId of pageIds) {
    const mergedBatch = [];

    // Strategy 0: Exact DMS BedLength facet query when user specified a truck bed length (e.g. "6.5ft bed")!
    // DealerOn stores factory bed length as a server-side facet ("6-1/2' Box", "5-1/2' Box", "8' Box", etc.)
    // even when VehicleCard comments omit bed dimensions on New factory-invoice trucks.
    if (bedFacetValues.length > 0) {
      const targetModels = modelVariants.length > 0 ? modelVariants : [''];
      for (const mv of targetModels) {
        for (const bedFacet of bedFacetValues) {
          const facetParams = { BedLength: bedFacet };
          if (make) facetParams.Make = make;
          if (mv) facetParams.Model = mv;
          try {
            const facetRes = await fetchAllCosmosPages(cfg.dealerId, pageId, facetParams, {
              maxPrice,
              facetBedLength: bedLength,
            });
            mergedBatch.push(...facetRes);
          } catch {
            // Ignore individual facet query error
          }
        }
      }
    }

    // Strategy 1: Exact Make + Model facet query across all pages (also captures Pre-Owned units
    // whose dealer build sheet comments specify "6.5' bed" even when DMS BedLength facet is blank)
    if (make && modelVariants.length > 0) {
      for (const mv of modelVariants) {
        try {
          const res = await fetchAllCosmosPages(
            cfg.dealerId,
            pageId,
            { Make: make, Model: mv },
            { maxPrice }
          );
          mergedBatch.push(...res);
        } catch {
          // Ignore individual variant error
        }
      }
    }

    // Strategy 2: Make-only (or Make + Trim) full multi-page scan — e.g. "Ford under $60K"
    if (make && modelVariants.length === 0) {
      try {
        const params = { Make: make };
        if (trim) params.q = `${make} ${trim}`;
        const makeBatch = await fetchAllCosmosPages(cfg.dealerId, pageId, params, { maxPrice });
        mergedBatch.push(...makeBatch);
      } catch {
        // Ignore
      }

      if (mergedBatch.length === 0 && trim) {
        try {
          const fallbackMakeBatch = await fetchAllCosmosPages(
            cfg.dealerId,
            pageId,
            { Make: make },
            { maxPrice }
          );
          mergedBatch.push(...fallbackMakeBatch);
        } catch {
          // Ignore
        }
      }
    }

    // Strategy 3: Keyword fallback when Make+Model returned < 5 units or Make was not specified
    if (mergedBatch.length < 5 && (!make || model)) {
      const keywordParts = [make, model, trim].filter(Boolean);
      const queryParams = {};
      if (make) queryParams.Make = make;
      if (keywordParts.length > 0) {
        queryParams.q = keywordParts.join(' ');
      } else {
        const cleanedNotes = cleanKeywordFromNotes(guest.notes);
        if (cleanedNotes) queryParams.q = cleanedNotes;
      }

      if (Object.keys(queryParams).length > 0) {
        try {
          const kwBatch = await fetchAllCosmosPages(cfg.dealerId, pageId, queryParams, {
            maxPrice,
          });
          mergedBatch.push(...kwBatch);
        } catch {
          // Ignore keyword error
        }
      }
    }

    // Strategy 4: Broad full-catalog fallback if neither make nor keyword matched (e.g. "SUV under $25K")
    if (mergedBatch.length === 0) {
      try {
        const fallbackParams = make ? { Make: make } : {};
        const broadBatch = await fetchAllCosmosPages(cfg.dealerId, pageId, fallbackParams, {
          maxPrice,
        });
        mergedBatch.push(...broadBatch);
      } catch {
        // Ignore
      }
    }

    for (const v of mergedBatch) {
      const existing = byVin.get(v.vin);
      if (!existing) {
        byVin.set(v.vin, v);
      } else if (!existing.bedLength && v.bedLength) {
        byVin.set(v.vin, {
          ...existing,
          bedLength: v.bedLength,
          highlights: v.highlights,
        });
      }
    }
  }

  return Array.from(byVin.values());
}
