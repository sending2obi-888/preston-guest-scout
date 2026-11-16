const PRESTON_HOST = 'www.prestonmotor.com';
const BASE_URL = `https://${PRESTON_HOST}`;

let cachedConfig = {
  dealerId: 19398,
  newPageId: 1446609,
  usedPageId: 1446611,
  fetchedAt: 0,
};

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

function parseVehicleCard(vc) {
  if (!vc || !vc.VehicleVin) return null;

  const prices = parsePriceLibrary(vc.VehiclePriceLibrary);
  const price =
    prices.finalPrice ||
    (vc.VehicleInternetPrice > 0 ? vc.VehicleInternetPrice : null) ||
    (vc.VehicleMsrp > 0 ? vc.VehicleMsrp : null);

  const highlights = Array.isArray(vc.VehicleHighlightsModel?.Highlights)
    ? vc.VehicleHighlightsModel.Highlights.filter(Boolean)
    : [];

  const commentsClean = stripHtml(vc.VehicleComments || '');
  const drivetrain = normalizeDrivetrain(vc, highlights, commentsClean);

  const cityState = [vc.DealerLocatedAtCity, vc.DealerLocatedAtState]
    .filter(Boolean)
    .join(', ');
  const dealerBranch =
    vc.VehicleLocationLabel ||
    vc.VehicleLocation ||
    vc.DealerName ||
    'Preston Automotive Group';
  const location =
    cityState && !dealerBranch.toLowerCase().includes((vc.DealerLocatedAtCity || '').toLowerCase())
      ? `${dealerBranch} (${cityState})`
      : dealerBranch;

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
    bodyStyle: vc.VehicleBodyStyle || vc.VehicleBodyType || '',
    price,
    msrp: prices.msrp || (vc.VehicleMsrp > 0 ? vc.VehicleMsrp : null),
    dealerFee: prices.dealerFee,
    location,
    mileage: typeof vc.VehicleMileage === 'number' ? vc.VehicleMileage : 0,
    drivetrain,
    engine: vc.VehicleEngine || '',
    transmission: vc.VehicleTransmission || '',
    exteriorColor: vc.ExteriorColorLabel || vc.VehicleGenericColor || '',
    interiorColor: vc.InteriorColorLabel || '',
    photoUrl,
    listingUrl: detailUrl.startsWith('http') ? detailUrl : `${BASE_URL}${detailUrl}`,
    highlights,
    commentsSummary: commentsClean.slice(0, 900),
  };
}

async function fetchCosmosPage(dealerId, pageId, paramsObj) {
  const qs = new URLSearchParams({
    ...paramsObj,
    pn: '96',
    host: PRESTON_HOST,
  });
  const url = `${BASE_URL}/api/vhcliaa/vehicle-pages/cosmos/srp/vehicles/${dealerId}/${pageId}?${qs.toString()}`;
  const res = await fetch(url, {
    headers: {
      'User-Agent': 'Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36',
      Accept: 'application/json',
    },
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) {
    throw new Error(`PrestonMotor API HTTP ${res.status}`);
  }
  const json = await res.json();
  const cards = Array.isArray(json.DisplayCards) ? json.DisplayCards : [];
  const vehicles = [];
  for (const item of cards) {
    if (item?.IsAdCard || !item?.VehicleCard) continue;
    const parsed = parseVehicleCard(item.VehicleCard);
    if (parsed) vehicles.push(parsed);
  }
  return vehicles;
}

export async function searchPrestonInventory(guest) {
  const cfg = await refreshDealerOnConfig();
  const cond = (guest.condition || 'Any').toLowerCase();

  const pageIds = [];
  if (cond === 'new') {
    pageIds.push(cfg.newPageId);
  } else if (cond === 'pre-owned' || cond === 'used' || cond === 'cpo' || cond === 'certified pre-owned') {
    pageIds.push(cfg.usedPageId);
  } else {
    pageIds.push(cfg.newPageId, cfg.usedPageId);
  }

  const byVin = new Map();
  const make = (guest.make || '').trim();
  const model = (guest.model || '').trim();
  const trim = (guest.trim || '').trim();

  for (const pageId of pageIds) {
    const mergedBatch = [];

    // Strategy 1: Exact Make + Model facet query (plus Ford Super Duty SRW normalization)
    if (make && model) {
      const modelVariants = [model];
      const sdMatch = model.match(/^f-?([234]50)$/i);
      if (sdMatch) {
        modelVariants.push(`Super Duty F-${sdMatch[1]} SRW`);
        modelVariants.push(`Super Duty F-${sdMatch[1]} DRW`);
      }
      for (const mv of modelVariants) {
        try {
          const res = await fetchCosmosPage(cfg.dealerId, pageId, { Make: make, Model: mv });
          mergedBatch.push(...res);
        } catch {
          // Ignore individual variant error
        }
      }
    }

    // Strategy 2: Keyword query (`q=...`) when model is partial or facet returned < 5 units
    if (mergedBatch.length < 5) {
      const keywordParts = [make, model, trim].filter(Boolean);
      const queryParams = {};
      if (make) queryParams.Make = make;
      if (keywordParts.length > 0) {
        queryParams.q = keywordParts.join(' ');
      } else if (guest.notes) {
        queryParams.q = guest.notes.split(/[.,;\n]/)[0].slice(0, 50).trim();
      }

      try {
        const kwBatch = await fetchCosmosPage(cfg.dealerId, pageId, queryParams);
        mergedBatch.push(...kwBatch);
      } catch {
        // Ignore keyword error
      }
    }

    // Strategy 3: Broaden to Make-only if still empty
    if (mergedBatch.length === 0 && make) {
      try {
        const makeBatch = await fetchCosmosPage(cfg.dealerId, pageId, { Make: make });
        mergedBatch.push(...makeBatch);
      } catch {
        // Ignore
      }
    }

    for (const v of mergedBatch) {
      if (!byVin.has(v.vin)) {
        byVin.set(v.vin, v);
      }
    }
  }

  return Array.from(byVin.values());
}
