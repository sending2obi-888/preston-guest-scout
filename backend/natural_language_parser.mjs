/**
 * Shared Natural-Language Vehicle Criteria Parser & Strict Specification Matcher.
 *
 * Understands shorthand and multi-sentence natural language vehicle queries such as:
 *   "Ford F150. 6.5ft bed. XLT."
 *   "Used 2022-2024 Ford F-250 Lariat Crew Cab 6.75ft bed diesel under $65k"
 *   "New Ford Bronco Badlands 4x4"
 * and enforces strict matching on every parsed structural criterion (Make, Model,
 * Trim with word boundaries, Bed Length, Cab Style, Engine/Fuel, Year, Price,
 * Mileage, Condition, Drivetrain, Exterior Color, Dealership Location, and
 * explicit Equipment/Package codes).
 */

export const KNOWN_MAKES = [
  { canonical: 'Ford', aliases: ['ford'] },
  { canonical: 'Lincoln', aliases: ['lincoln'] },
  { canonical: 'Hyundai', aliases: ['hyundai'] },
  { canonical: 'Mazda', aliases: ['mazda'] },
  { canonical: 'Nissan', aliases: ['nissan'] },
  { canonical: 'Chevrolet', aliases: ['chevrolet', 'chevy'] },
  { canonical: 'Jeep', aliases: ['jeep'] },
  { canonical: 'Ram', aliases: ['ram'] },
  { canonical: 'Dodge', aliases: ['dodge'] },
  { canonical: 'Chrysler', aliases: ['chrysler'] },
  { canonical: 'Toyota', aliases: ['toyota'] },
  { canonical: 'Honda', aliases: ['honda'] },
  { canonical: 'GMC', aliases: ['gmc'] },
  { canonical: 'Kia', aliases: ['kia'] },
  { canonical: 'Subaru', aliases: ['subaru'] },
  { canonical: 'Genesis', aliases: ['genesis'] },
  { canonical: 'Volkswagen', aliases: ['volkswagen', 'vw'] },
  { canonical: 'BMW', aliases: ['bmw'] },
  { canonical: 'Mercedes-Benz', aliases: ['mercedes-benz', 'mercedes'] },
  { canonical: 'Audi', aliases: ['audi'] },
  { canonical: 'Lexus', aliases: ['lexus'] },
  { canonical: 'Cadillac', aliases: ['cadillac'] },
  { canonical: 'Buick', aliases: ['buick'] },
  { canonical: 'Acura', aliases: ['acura'] },
  { canonical: 'INFINITI', aliases: ['infiniti'] },
  { canonical: 'Volvo', aliases: ['volvo'] },
];

export const LOCATION_KEYWORDS = [
  'millsboro',
  'boulevard ford',
  'boulevard lincoln',
  'lewes',
  'georgetown',
  'hurlock',
  'pittsville',
  'aberdeen',
  'denton',
  'keller',
  'dover',
  'randallstown',
  'wilmington',
  'easton',
  'snow hill',
  'salisbury',
];

/**
 * Ordered longest/most-specific first so "Bronco Sport" matches before "Bronco",
 * "F-150 Lightning" before "F-150", "Grand Cherokee L" before "Grand Cherokee"
 * before "Cherokee", "CX-50" before "CX-5", etc.
 */
const MODEL_PATTERNS = [
  // Ford
  { make: 'Ford', model: 'F-150 Lightning', regex: /\bf[\s+-]*150\s+lightning\b/i },
  { make: 'Ford', model: 'F-150', regex: /\bf[\s+-]*150\b/i },
  {
    make: 'Ford',
    model: 'F-250',
    regex: /\b(?:super\s+duty\s+)?f[\s+-]*250(?:\s+super\s+duty|\s+srw|\s+drw)?\b/i,
  },
  {
    make: 'Ford',
    model: 'F-350',
    regex: /\b(?:super\s+duty\s+)?f[\s+-]*350(?:\s+super\s+duty|\s+srw|\s+drw)?\b/i,
  },
  {
    make: 'Ford',
    model: 'F-450',
    regex: /\b(?:super\s+duty\s+)?f[\s+-]*450(?:\s+drw|\s+srw)?\b/i,
  },
  {
    make: 'Ford',
    model: 'F-550',
    regex: /\b(?:super\s+duty\s+)?f[\s+-]*550(?:\s+drw|\s+srw)?\b/i,
  },
  { make: 'Ford', model: 'Bronco Sport', regex: /\bbronco\s+sport\b/i },
  { make: 'Ford', model: 'Bronco', regex: /\bbronco\b/i },
  { make: 'Ford', model: 'Expedition Max', regex: /\bexpedition\s+max\b/i },
  { make: 'Ford', model: 'Expedition', regex: /\bexpedition\b/i },
  { make: 'Ford', model: 'Mustang Mach-E', regex: /\b(?:mustang\s+)?mach[\s-]*e\b/i },
  { make: 'Ford', model: 'Mustang', regex: /\bmustang\b/i },
  { make: 'Ford', model: 'Explorer', regex: /\bexplorer\b/i },
  { make: 'Ford', model: 'Escape', regex: /\bescape\b/i },
  { make: 'Ford', model: 'Edge', regex: /\bedge\b/i },
  { make: 'Ford', model: 'Maverick', regex: /\bmaverick\b/i },
  { make: 'Ford', model: 'Ranger', regex: /\branger\b/i },
  { make: 'Ford', model: 'Transit', regex: /\btransit\b/i },
  { make: 'Ford', model: 'EcoSport', regex: /\becosport\b/i },
  { make: 'Ford', model: 'Fusion', regex: /\bfusion\b/i },

  // Lincoln
  { make: 'Lincoln', model: 'Navigator L', regex: /\bnavigator\s+l\b/i },
  { make: 'Lincoln', model: 'Navigator', regex: /\bnavigator\b/i },
  { make: 'Lincoln', model: 'Aviator', regex: /\baviator\b/i },
  { make: 'Lincoln', model: 'Nautilus', regex: /\bnautilus\b/i },
  { make: 'Lincoln', model: 'Corsair', regex: /\bcorsair\b/i },

  // Chevrolet
  { make: 'Chevrolet', model: 'Silverado 3500HD', regex: /\bsilverado\s*3500(?:\s*hd)?\b/i },
  { make: 'Chevrolet', model: 'Silverado 2500 HD', regex: /\bsilverado\s*2500(?:\s*hd)?\b/i },
  { make: 'Chevrolet', model: 'Silverado 1500', regex: /\bsilverado(?:\s*1500)?\b/i },
  { make: 'Chevrolet', model: 'Equinox EV', regex: /\bequinox\s+ev\b/i },
  { make: 'Chevrolet', model: 'Equinox', regex: /\bequinox\b/i },
  { make: 'Chevrolet', model: 'Colorado', regex: /\bcolorado\b/i },
  { make: 'Chevrolet', model: 'Suburban', regex: /\bsuburban\b/i },
  { make: 'Chevrolet', model: 'Tahoe', regex: /\btahoe\b/i },
  { make: 'Chevrolet', model: 'Traverse', regex: /\btraverse\b/i },
  { make: 'Chevrolet', model: 'Trailblazer', regex: /\btrailblazer\b/i },
  { make: 'Chevrolet', model: 'Blazer', regex: /\bblazer\b/i },
  { make: 'Chevrolet', model: 'Trax', regex: /\btrax\b/i },
  { make: 'Chevrolet', model: 'Corvette', regex: /\bcorvette\b/i },
  { make: 'Chevrolet', model: 'Malibu', regex: /\bmalibu\b/i },

  // GMC
  { make: 'GMC', model: 'Sierra 3500HD', regex: /\bsierra\s*3500(?:\s*hd)?\b/i },
  { make: 'GMC', model: 'Sierra 2500HD', regex: /\bsierra\s*2500(?:\s*hd)?\b/i },
  { make: 'GMC', model: 'Sierra 1500', regex: /\bsierra(?:\s*1500)?\b/i },
  { make: 'GMC', model: 'Yukon XL', regex: /\byukon\s+xl\b/i },
  { make: 'GMC', model: 'Yukon', regex: /\byukon\b/i },
  { make: 'GMC', model: 'Acadia', regex: /\bacadia\b/i },
  { make: 'GMC', model: 'Terrain', regex: /\bterrain\b/i },
  { make: 'GMC', model: 'Canyon', regex: /\bcanyon\b/i },

  // Ram
  { make: 'Ram', model: '3500', regex: /\bram\s*3500\b/i },
  { make: 'Ram', model: '2500', regex: /\bram\s*2500\b/i },
  { make: 'Ram', model: '1500', regex: /\bram\s*1500\b/i },
  { make: 'Ram', model: 'ProMaster', regex: /\bpromaster\b/i },

  // Jeep
  { make: 'Jeep', model: 'Grand Cherokee L', regex: /\bgrand\s+cherokee\s+l\b/i },
  { make: 'Jeep', model: 'Grand Cherokee', regex: /\bgrand\s+cherokee\b/i },
  { make: 'Jeep', model: 'Cherokee', regex: /\bcherokee\b/i },
  { make: 'Jeep', model: 'Grand Wagoneer L', regex: /\bgrand\s+wagoneer\s+l\b/i },
  { make: 'Jeep', model: 'Grand Wagoneer', regex: /\bgrand\s+wagoneer\b/i },
  { make: 'Jeep', model: 'Wagoneer', regex: /\bwagoneer\b/i },
  { make: 'Jeep', model: 'Wrangler', regex: /\bwrangler\b/i },
  { make: 'Jeep', model: 'Gladiator', regex: /\bgladiator\b/i },
  { make: 'Jeep', model: 'Compass', regex: /\bcompass\b/i },
  { make: 'Jeep', model: 'Renegade', regex: /\brenegade\b/i },

  // Hyundai
  { make: 'Hyundai', model: 'Santa Cruz', regex: /\bsanta\s*cruz\b/i },
  { make: 'Hyundai', model: 'Santa Fe', regex: /\bsanta\s+fe\b/i },
  { make: 'Hyundai', model: 'Palisade', regex: /\bpalisade\b/i },
  { make: 'Hyundai', model: 'Tucson', regex: /\btucson\b/i },
  { make: 'Hyundai', model: 'Kona', regex: /\bkona\b/i },
  { make: 'Hyundai', model: 'Elantra', regex: /\belantra\b/i },
  { make: 'Hyundai', model: 'Sonata', regex: /\bsonata\b/i },
  { make: 'Hyundai', model: 'Venue', regex: /\bvenue\b/i },
  { make: 'Hyundai', model: 'IONIQ 5', regex: /\bioniq\s*5\b/i },
  { make: 'Hyundai', model: 'IONIQ 6', regex: /\bioniq\s*6\b/i },

  // Mazda
  { make: 'Mazda', model: 'CX-90', regex: /\bcx[\s-]*90\b/i },
  { make: 'Mazda', model: 'CX-70', regex: /\bcx[\s-]*70\b/i },
  { make: 'Mazda', model: 'CX-50', regex: /\bcx[\s-]*50\b/i },
  { make: 'Mazda', model: 'CX-30', regex: /\bcx[\s-]*30\b/i },
  { make: 'Mazda', model: 'CX-5', regex: /\bcx[\s-]*5\b/i },
  { make: 'Mazda', model: 'MX-5 Miata', regex: /\b(?:mx[\s-]*5(?:\s+miata)?|miata)\b/i },
  { make: 'Mazda', model: 'Mazda3', regex: /\bmazda\s*3\b/i },

  // Toyota
  { make: 'Toyota', model: 'Grand Highlander', regex: /\bgrand\s+highlander\b/i },
  { make: 'Toyota', model: 'Highlander', regex: /\bhighlander\b/i },
  { make: 'Toyota', model: 'Corolla Cross', regex: /\bcorolla\s+cross\b/i },
  { make: 'Toyota', model: 'Corolla', regex: /\bcorolla\b/i },
  { make: 'Toyota', model: 'RAV4', regex: /\brav[\s-]*4\b/i },
  { make: 'Toyota', model: '4Runner', regex: /\b4[\s-]*runner\b/i },
  { make: 'Toyota', model: 'Land Cruiser', regex: /\bland\s+cruiser\b/i },
  { make: 'Toyota', model: 'Tacoma', regex: /\btacoma\b/i },
  { make: 'Toyota', model: 'Tundra', regex: /\btundra\b/i },
  { make: 'Toyota', model: 'Camry', regex: /\bcamry\b/i },
  { make: 'Toyota', model: 'Sienna', regex: /\bsienna\b/i },
  { make: 'Toyota', model: 'Prius', regex: /\bprius\b/i },

  // Honda
  { make: 'Honda', model: 'CR-V', regex: /\bcr[\s-]*v\b/i },
  { make: 'Honda', model: 'HR-V', regex: /\bhr[\s-]*v\b/i },
  { make: 'Honda', model: 'Pilot', regex: /\bpilot\b/i },
  { make: 'Honda', model: 'Passport', regex: /\bpassport\b/i },
  { make: 'Honda', model: 'Odyssey', regex: /\bodyssey\b/i },
  { make: 'Honda', model: 'Ridgeline', regex: /\bridgeline\b/i },
  { make: 'Honda', model: 'Accord', regex: /\baccord\b/i },
  { make: 'Honda', model: 'Civic', regex: /\bcivic\b/i },

  // Nissan
  { make: 'Nissan', model: 'Pathfinder', regex: /\bpathfinder\b/i },
  { make: 'Nissan', model: 'Rogue', regex: /\brogue\b/i },
  { make: 'Nissan', model: 'Murano', regex: /\bmurano\b/i },
  { make: 'Nissan', model: 'Armada', regex: /\barmada\b/i },
  { make: 'Nissan', model: 'Frontier', regex: /\bfrontier\b/i },
  { make: 'Nissan', model: 'Titan', regex: /\btitan\b/i },
  { make: 'Nissan', model: 'Altima', regex: /\baltima\b/i },
  { make: 'Nissan', model: 'Sentra', regex: /\bsentra\b/i },
  { make: 'Nissan', model: 'Kicks', regex: /\bkicks\b/i },

  // Kia / Subaru / Dodge / Chrysler
  { make: 'Kia', model: 'Telluride', regex: /\btelluride\b/i },
  { make: 'Kia', model: 'Sorento', regex: /\bsorento\b/i },
  { make: 'Kia', model: 'Sportage', regex: /\bsportage\b/i },
  { make: 'Kia', model: 'Carnival', regex: /\bcarnival\b/i },
  { make: 'Kia', model: 'K5', regex: /\bk5\b/i },
  { make: 'Kia', model: 'EV9', regex: /\bev9\b/i },
  { make: 'Kia', model: 'EV6', regex: /\bev6\b/i },
  { make: 'Subaru', model: 'Outback', regex: /\boutback\b/i },
  { make: 'Subaru', model: 'Forester', regex: /\bforester\b/i },
  { make: 'Subaru', model: 'Crosstrek', regex: /\bcrosstrek\b/i },
  { make: 'Subaru', model: 'Ascent', regex: /\bascent\b/i },
  { make: 'Subaru', model: 'WRX', regex: /\bwrx\b/i },
  { make: 'Dodge', model: 'Durango', regex: /\bdurango\b/i },
  { make: 'Dodge', model: 'Charger', regex: /\bcharger\b/i },
  { make: 'Dodge', model: 'Challenger', regex: /\bchallenger\b/i },
  { make: 'Dodge', model: 'Hornet', regex: /\bhornet\b/i },
  { make: 'Chrysler', model: 'Pacifica', regex: /\bpacifica\b/i },
];

/**
 * Multi-word trims BEFORE single-word trims so e.g. "King Ranch", "Big Bend",
 * "ST-Line", "Raptor R", "Black Label" match before shorter tokens.
 */
const TRIM_PATTERNS = [
  { canonical: 'King Ranch', regex: /\bking\s+ranch\b/i },
  { canonical: 'Black Label', regex: /\bblack\s+label\b/i },
  { canonical: 'Big Bend', regex: /\bbig\s+bend\b/i },
  { canonical: 'Outer Banks', regex: /\bouter\s+banks\b/i },
  { canonical: 'Heritage Edition', regex: /\bheritage\s+edition\b/i },
  { canonical: 'Raptor R', regex: /\braptor\s+r\b/i },
  { canonical: 'Dark Horse', regex: /\bdark\s+horse\b/i },
  { canonical: 'GT Premium', regex: /\bgt\s+premium\b/i },
  { canonical: 'EcoBoost Premium', regex: /\becoboost\s+premium\b/i },
  { canonical: 'ST-Line Elite', regex: /\bst[\s-]+line\s+elite\b/i },
  { canonical: 'ST-Line Select', regex: /\bst[\s-]+line\s+select\b/i },
  { canonical: 'ST-Line', regex: /\bst[\s-]+line\b/i },
  { canonical: 'High Country', regex: /\bhigh\s+country\b/i },
  { canonical: 'Custom Trail Boss', regex: /\bcustom\s+trail\s+boss\b/i },
  { canonical: 'LT Trail Boss', regex: /\blt\s+trail\s+boss\b/i },
  { canonical: 'Denali Ultimate', regex: /\bdenali\s+ultimate\b/i },
  { canonical: 'Big Horn', regex: /\bbig\s+horn\b/i },
  { canonical: 'Lone Star', regex: /\blone\s+star\b/i },
  { canonical: 'Rubicon X', regex: /\brubicon\s+x\b/i },
  { canonical: 'Summit Reserve', regex: /\bsummit\s+reserve\b/i },
  { canonical: 'TRD Pro', regex: /\btrd\s+pro\b/i },
  { canonical: 'TRD Off-Road', regex: /\btrd\s+off[\s-]*road\b/i },
  { canonical: 'TRD Sport', regex: /\btrd\s+sport\b/i },
  { canonical: '1794 Edition', regex: /\b1794(?:\s+edition)?\b/i },
  { canonical: 'Carbon Edition', regex: /\bcarbon\s+edition\b/i },
  { canonical: 'N Line', regex: /\bn[\s-]+line\b/i },
  { canonical: 'Badlands', regex: /\bbadlands\b/i },
  { canonical: 'Wildtrak', regex: /\bwildtrak\b/i },
  { canonical: 'Everglades', regex: /\beverglades\b/i },
  { canonical: 'Platinum', regex: /\bplatinum\b/i },
  { canonical: 'Lariat', regex: /\blariat\b/i },
  { canonical: 'Tremor', regex: /\btremor\b/i },
  { canonical: 'Raptor', regex: /\braptor\b/i },
  { canonical: 'XLT', regex: /\bxlt\b/i },
  { canonical: 'STX', regex: /\bstx\b/i },
  { canonical: 'XL', regex: /\bxl\b/i },
  { canonical: 'Reserve', regex: /\breserve\b/i },
  { canonical: 'Premiere', regex: /\bpremiere\b/i },
  { canonical: 'Titanium', regex: /\btitanium\b/i },
  { canonical: 'Limited', regex: /\blimited\b/i },
  { canonical: 'Calligraphy', regex: /\bcalligraphy\b/i },
  { canonical: 'XRT', regex: /\bxrt\b/i },
  { canonical: 'SEL', regex: /\bsel\b/i },
  { canonical: 'SE', regex: /\bse\b/i },
  { canonical: 'LTZ', regex: /\bltz\b/i },
  { canonical: 'RST', regex: /\brst\b/i },
  { canonical: 'ZR2', regex: /\bzr2\b/i },
  { canonical: 'Z71', regex: /\bz71\b/i },
  { canonical: 'AT4X', regex: /\bat4x\b/i },
  { canonical: 'AT4', regex: /\bat4\b/i },
  { canonical: 'Denali', regex: /\bdenali\b/i },
  { canonical: 'SLT', regex: /\bslt\b/i },
  { canonical: 'SLE', regex: /\bsle\b/i },
  { canonical: 'Elevation', regex: /\belevation\b/i },
  { canonical: 'Laramie', regex: /\blaramie\b/i },
  { canonical: 'Rebel', regex: /\brebel\b/i },
  { canonical: 'Tradesman', regex: /\btradesman\b/i },
  { canonical: 'TRX', regex: /\btrx\b/i },
  { canonical: 'Rubicon', regex: /\brubicon\b/i },
  { canonical: 'Sahara', regex: /\bsahara\b/i },
  { canonical: 'Willys', regex: /\bwillys\b/i },
  { canonical: 'Overland', regex: /\boverland\b/i },
  { canonical: 'Summit', regex: /\bsummit\b/i },
  { canonical: 'Touring', regex: /\btouring\b/i },
  { canonical: 'Preferred', regex: /\bpreferred\b/i },
  { canonical: 'SR5', regex: /\bsr5\b/i },
  { canonical: 'XSE', regex: /\bxse\b/i },
  { canonical: 'XLE', regex: /\bxle\b/i },
  { canonical: 'EX-L', regex: /\bex-l\b/i },
  { canonical: 'PRO-4X', regex: /\bpro[\s-]*4x\b/i },
  { canonical: 'SV', regex: /\bsv\b/i },
  { canonical: 'SL', regex: /\bsl\b/i },
  { canonical: 'LT', regex: /\blt\b/i },
  { canonical: 'WT', regex: /\bwt\b/i },
  { canonical: 'LS', regex: /\bls\b/i },
  { canonical: 'GT', regex: /\bgt\b/i },
  { canonical: 'ST', regex: /\bst\b/i },
];

const SPECIFIC_COLORS = [
  'oxford white',
  'star white',
  'space white',
  'agate black',
  'shadow black',
  'iconic silver',
  'carbonized gray',
  'marsh gray',
  'lead foot',
  'avalanche',
  'antimatter blue',
  'atlas blue',
  'velocity blue',
  'vapor blue',
  'rhapsody blue',
  'rapid red',
  'race red',
  'ruby red',
  'eruption green',
  'shelter green',
  'cactus gray',
  'area 51',
  'azure gray',
  'bronze smoke',
  'dark matter',
];

const BASIC_COLORS = [
  'white',
  'black',
  'silver',
  'gray',
  'grey',
  'blue',
  'red',
  'green',
  'brown',
  'bronze',
  'gold',
  'tan',
  'orange',
  'yellow',
  'burgundy',
  'maroon',
];

const STRICT_PACKAGE_RULES = [
  { label: 'FX4 Off-Road', regex: /\bfx4\b/i, matchRegex: /\bfx4\b/i },
  { label: '301A Package', regex: /\b301a\b/i, matchRegex: /\b301a\b/i },
  { label: '302A Package', regex: /\b302a\b/i, matchRegex: /\b302a\b/i },
  { label: '303A Package', regex: /\b303a\b/i, matchRegex: /\b303a\b/i },
  { label: '501A Package', regex: /\b501a\b/i, matchRegex: /\b501a\b/i },
  { label: '502A Package', regex: /\b502a\b/i, matchRegex: /\b502a\b/i },
  { label: 'Black Appearance Package', regex: /\bblack\s+appearance\b/i, matchRegex: /\bblack\s+appearance\b/i },
  { label: 'Bed Utility Package', regex: /\bbed\s+utility\b/i, matchRegex: /\bbed\s+utility\b/i },
  { label: 'Max Tow / Tow-Haul', regex: /\b(?:max\s+(?:trailer\s+)?tow|tow\s*\/\s*haul)\b/i, matchRegex: /\b(?:max\s+(?:trailer\s+)?tow|tow\s*\/\s*haul)\b/i },
  { label: 'Pro Power Onboard', regex: /\bpro\s+power\b/i, matchRegex: /\bpro\s+power\b/i },
  { label: 'BlueCruise', regex: /\bblue\s*cruise\b/i, matchRegex: /\bblue\s*cruise\b/i },
];

export function splitNaturalLanguageClauses(text) {
  if (!text) return [];
  // Protect decimal numbers (e.g. 6.5, 5.5, 6.75, 3.5, 5.0) before splitting on sentence periods
  const protectedText = String(text).replace(/(\d)\.(\d)/g, '$1__DEC__$2');
  return protectedText
    .split(/[.,;\n•|]+/)
    .map((s) => s.replace(/__DEC__/g, '.').trim())
    .filter(Boolean);
}

function isPreferenceClause(clause) {
  return /\b(?:prefer(?:s|red)?|ideally|nice\s+to\s+have|optional|if\s+possible|bonus)\b/i.test(
    clause
  );
}

/**
 * Normalizes a user-supplied or extracted bed length to canonical values:
 *   "5'" | "5.5'" | "6'" | "6.5'" | "6.75'" | "8'" | ""
 */
export function extractBedLengthFromQuery(rawText) {
  if (!rawText) return '';
  const s = String(rawText).toLowerCase();

  // 6.75 ft / 6 3/4' box (Super Duty short bed)
  if (
    /\b(?:6\.75|6\.8|6[\s-]*3\/4)\s*(?:ft\.?|foot|feet|')?(?:\s*(?:pickup\s*)?(?:bed|box))?\b/i.test(
      s
    ) &&
    (/\b(?:bed|box|ft\.?|foot|feet|')\b/i.test(s) || /3\/4/.test(s))
  ) {
    return "6.75'";
  }

  // 6.5 ft / 6-1/2' box / 78" bed / 157" WB
  if (
    /\b(?:6\.5|6[\s-]*1\/2)\s*(?:ft\.?|foot|feet|')(?:\s*(?:pickup\s*)?(?:bed|box))?/i.test(s) ||
    /\b(?:6\.5|6[\s-]*1\/2)\s*(?:pickup\s*)?(?:bed|box)\b/i.test(s) ||
    /\b(?:bed|box)\s*(?:length\s*(?:of|:)?\s*)?(?:6\.5|6[\s-]*1\/2)\b/i.test(s) ||
    /\b157(?:\.\d+)?\s*(?:in\.?|inch(?:es)?|")?\s*(?:wb|wheelbase)\b/i.test(s) ||
    /\b78(?:\.9)?\s*(?:in\.?|inch(?:es)?|")\s*(?:bed|box)\b/i.test(s)
  ) {
    return "6.5'";
  }

  // 5.5 ft / 5-1/2' box / 5'7" box / 67" bed / 145" WB SuperCrew short bed
  if (
    /\b(?:5\.5|5\.6|5\.7|5[\s-]*1\/2)\s*(?:ft\.?|foot|feet|')(?:\s*(?:pickup\s*)?(?:bed|box))?/i.test(
      s
    ) ||
    /\b5'\s*7"?\s*(?:bed|box)?/i.test(s) ||
    /\b(?:5\.5|5[\s-]*1\/2)\s*(?:pickup\s*)?(?:bed|box)\b/i.test(s) ||
    /\b(?:bed|box)\s*(?:length\s*(?:of|:)?\s*)?(?:5\.5|5[\s-]*1\/2)\b/i.test(s) ||
    /\bshort\s+(?:pickup\s+)?(?:bed|box)\b/i.test(s)
  ) {
    return "5.5'";
  }

  // 8 ft / long bed / 96"-98" bed
  if (
    /\b8(?:\.0)?\s*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b/i.test(s) ||
    /\b8(?:\.0)?\s*(?:pickup\s*)?(?:bed|box)\b/i.test(s) ||
    /\b(?:bed|box)\s*(?:length\s*(?:of|:)?\s*)?8(?:\.0)?\s*(?:ft\.?|foot|feet|')?\b/i.test(s) ||
    /\blong\s+(?:pickup\s+)?(?:bed|box)\b/i.test(s) ||
    /\b9[678](?:\.\d+)?\s*(?:in\.?|inch(?:es)?|")\s*(?:bed|box)\b/i.test(s)
  ) {
    return "8'";
  }

  // Exact 5 ft bed (midsize e.g. Ranger / Tacoma / Maverick)
  if (
    /\b5(?:\.0)?\s*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b/i.test(s) ||
    /\b5(?:\.0)?[\s-]*(?:ft|foot)\s*(?:bed|box)\b/i.test(s)
  ) {
    return "5'";
  }

  // Exact 6 ft bed (midsize 6' box)
  if (
    /\b6(?:\.0)?\s*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b/i.test(s) ||
    /\b6(?:\.0)?[\s-]*(?:ft|foot)\s*(?:bed|box)\b/i.test(s)
  ) {
    return "6'";
  }

  return '';
}

export function bedLengthToCosmosFacetValues(bedLength) {
  switch (bedLength) {
    case "5'":
      return ['5-ft bed'];
    case "5.5'":
      return ["5-1/2' Box", '5.5-Ft.'];
    case "6'":
      return ['6-ft bed'];
    case "6.5'":
      return ["6-1/2' Box"];
    case "6.75'":
      return ["6 3/4' Box"];
    case "8'":
      return ["8' Box"];
    default:
      return [];
  }
}

export function formatBedLengthLabel(bedLength) {
  if (!bedLength) return '';
  const clean = bedLength.replace(/'$/, '');
  return `${clean} ft Bed`;
}

/**
 * Extracts verified bed length from a candidate vehicle listing using:
 *  1. DMS BedLength facet stamp (if fetched via Cosmos BedLength refinement)
 *  2. Explicit bed/box length or wheelbase mentions in VehicleName, BodyStyle, Highlights, or FULL VehicleComments
 *  3. Unambiguous cab + overall length geometry (e.g. F-150 Regular Cab 209.1"=6.5', 227.7"=8'; SuperCab 231.7"=6.5', 250.3"=8')
 */
export function extractBedLengthFromVehicle(vc, fullCommentsClean = '', facetBedLength = '') {
  if (facetBedLength) return facetBedLength;

  const title = String(vc?.VehicleName || vc?.title || '');
  const body = `${vc?.VehicleBodyStyle || vc?.bodyStyle || ''} ${vc?.VehicleBodyType || ''}`;
  const highlights = Array.isArray(vc?.VehicleHighlightsModel?.Highlights)
    ? vc.VehicleHighlightsModel.Highlights.join(' | ')
    : Array.isArray(vc?.highlights)
      ? vc.highlights.join(' | ')
      : '';
  const text = `${title} | ${body} | ${highlights} | ${fullCommentsClean}`;

  // 1. Explicit 6.75' / 6 3/4' bed or box
  if (
    /\b(?:6\.75|6[\s-]*3\/4)\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b/i.test(
      text
    ) ||
    /\b6\s+3\/4'\s*box\b/i.test(text)
  ) {
    return "6.75'";
  }

  // 2. Explicit 6.5' / 6-1/2' bed or box (never matching "6.5-inch screen")
  if (
    /\b(?:6\.5|6[\s-]*1\/2)\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:styleside\s+|pickup\s+)?(?:bed|box)\b/i.test(
      text
    ) ||
    /\b6-1\/2'\s*box\b/i.test(text)
  ) {
    return "6.5'";
  }

  // 3. Explicit 5.5' / 5-1/2' bed or box
  if (
    /\b(?:5\.5|5[\s-]*1\/2)\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:styleside\s+|pickup\s+)?(?:bed|box)\b/i.test(
      text
    ) ||
    /\b5'\s*7"?\s*(?:pickup\s*)?(?:bed|box)\b/i.test(text) ||
    /\b5-1\/2'\s*box\b/i.test(text)
  ) {
    return "5.5'";
  }

  // 4. Explicit 8' bed or box (never matching "8-inch screen" or "8-speed")
  if (
    /\b8(?:\.0)?\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:styleside\s+|pickup\s+)?(?:bed|box)\b/i.test(
      text
    ) ||
    /\b8'\s*box\b/i.test(text)
  ) {
    return "8'";
  }

  // 5. Explicit 5-ft or 6-ft midsize bed
  if (/\b5(?:\.0)?\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b/i.test(text)) {
    return "5'";
  }
  if (/\b6(?:\.0)?\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b/i.test(text)) {
    return "6'";
  }

  // 6. Explicit F-150 Wheelbase mentions in dealer build comments
  const modelStr = `${vc?.VehicleModel || vc?.model || ''} ${title}`.toLowerCase();
  const isF150 = /\bf[\s+-]*150\b/.test(modelStr) && !/lightning/.test(modelStr);
  const cab = extractCabStyleFromText(`${body} ${title} ${fullCommentsClean}`);

  if (isF150) {
    if (/\b157(?:\.\d+)?[\s-]*(?:in\.?|inch(?:es)?|")\s*(?:wb|wheelbase)\b/i.test(text)) {
      return "6.5'";
    }
    if (
      cab === 'Crew Cab' &&
      /\b145(?:\.\d+)?[\s-]*(?:in\.?|inch(?:es)?|")\s*(?:wb|wheelbase)\b/i.test(text)
    ) {
      return "5.5'";
    }

    // Unambiguous F-150 Regular Cab & SuperCab overall length geometry
    // (Note: SuperCrew Length=231.7 is intentionally NOT used because ChromeData reports 231.7 on W3L generically)
    const lenNum = Number(vc?.Length ?? vc?.vehicleLength ?? 0);
    if (lenNum > 0) {
      if (cab === 'Regular Cab') {
        if (lenNum >= 207 && lenNum <= 212) return "6.5'";
        if (lenNum >= 225 && lenNum <= 230) return "8'";
      } else if (cab === 'SuperCab') {
        if (lenNum >= 229 && lenNum <= 235) return "6.5'";
        if (lenNum >= 248 && lenNum <= 253) return "8'";
      }
    }
  }

  return '';
}

export function extractCabStyleFromText(rawText) {
  if (!rawText) return '';
  const s = String(rawText);
  if (/\b(?:super\s*crew|crew\s*cab|crewcab| crewmax|megacab|mega\s+cab)\b/i.test(s)) {
    return 'Crew Cab';
  }
  if (
    /\b(?:super\s*cab|extended\s*cab|ext\.?\s*cab|double\s*cab|quad\s*cab|king\s*cab|\bx[12][a-z]\b)\b/i.test(
      s
    )
  ) {
    return 'SuperCab';
  }
  if (/\b(?:regular\s*cab|reg\.?\s*cab|single\s*cab|standard\s*cab)\b/i.test(s)) {
    return 'Regular Cab';
  }
  return '';
}

export function extractEngineSpecFromText(rawText) {
  if (!rawText) return '';
  const s = String(rawText);

  const dispMatch = s.match(/\b(2\.0|2\.3|2\.5|2\.7|3\.0|3\.3|3\.5|3\.6|5\.0|5\.3|5\.7|6\.2|6\.4|6\.6|6\.7|6\.8|7\.3)\s*l?\b/i);
  if (dispMatch && /\b(?:\d\.\d\s*l|v[68]|ecoboost|powerboost|power\s*stroke|diesel|engine|hemi|godzilla|duramax|cummins)\b/i.test(s)) {
    return `${dispMatch[1]}L`;
  }
  if (/\b(?:power\s*boost|full\s+hybrid|\bhybrid\b)\b/i.test(s)) {
    return 'Hybrid';
  }
  if (/\b(?:diesel|power\s*stroke|duramax|cummins)\b/i.test(s)) {
    return 'Diesel';
  }
  if (/\b(?:plug[\s-]*in\s+hybrid|\bphev\b)\b/i.test(s)) {
    return 'PHEV';
  }
  if (/\b(?:ecoboost)\b/i.test(s)) {
    return 'EcoBoost';
  }
  if (/\bv8\b|\b8[\s-]*cyl(?:inder)?\b/i.test(s)) {
    return 'V8';
  }
  if (/\bv6\b|\b6[\s-]*cyl(?:inder)?\b/i.test(s)) {
    return 'V6';
  }
  return '';
}

export function parseExteriorColors(rawColors) {
  const rawItems = Array.isArray(rawColors)
    ? rawColors.map((c) => String(c || ''))
    : [String(rawColors || '')];

  const seen = new Set();
  const result = [];

  for (const rawItem of rawItems) {
    const parts = rawItem
      .split(/[,;|/]+|\b(?:or|and)\b/gi)
      .map((s) => s.trim())
      .filter(Boolean);

    for (const p of parts) {
      const lower = p.toLowerCase();
      if (lower === 'any' || lower === 'any color' || lower === 'all') continue;
      const canonical =
        lower === 'grey'
          ? 'Gray'
          : p
              .split(/\s+/)
              .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
              .join(' ');
      const dedupeKey = canonical.toLowerCase();
      if (!seen.has(dedupeKey)) {
        seen.add(dedupeKey);
        result.push(canonical);
      }
    }
  }

  return result;
}

function extractColorFromStrictNotes(strictText) {
  if (!strictText) return '';
  // Remove package/program names containing color words so "Black Appearance Package",
  // "Black Label", "BlueCruise", "Blue Advantage", "Gold Certified" never trigger exterior color filters!
  let cleaned = strictText
    .toLowerCase()
    .replace(
      /\b(?:black\s+appearance|black\s+label|black\s+widow|black\s+diamond|blue\s*cruise|blue\s+advantage|gold\s+certified|silver\s+certified|red\s+carpet|green\s+vehicle|dark\s+horse|dark\s+slate|medium\s+dark\s+slate|black\s+interior|gray\s+interior|tan\s+interior)\b/gi,
      ' '
    );

  const found = [];
  const seenLower = new Set();

  for (const sc of SPECIFIC_COLORS) {
    if (cleaned.includes(sc)) {
      const formatted = sc
        .split(' ')
        .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
        .join(' ');
      if (!seenLower.has(formatted.toLowerCase())) {
        seenLower.add(formatted.toLowerCase());
        found.push(formatted);
      }
      // Blank out matched specific color phrase so e.g. "oxford white" doesn't also add "White"
      cleaned = cleaned.split(sc).join(' ');
    }
  }

  for (const bc of BASIC_COLORS) {
    if (new RegExp(`\\b${bc}\\b`, 'i').test(cleaned)) {
      const normalized = bc === 'grey' ? 'Gray' : bc.charAt(0).toUpperCase() + bc.slice(1);
      if (!seenLower.has(normalized.toLowerCase())) {
        seenLower.add(normalized.toLowerCase());
        found.push(normalized);
      }
    }
  }

  return found.join(', ');
}

export function normalizeModelInput(rawMake, rawModel) {
  const cleanModel = String(rawModel || '').trim();
  if (!cleanModel) return { make: String(rawMake || '').trim(), model: '' };

  for (const entry of MODEL_PATTERNS) {
    if (entry.regex.test(cleanModel)) {
      return {
        make: String(rawMake || '').trim() || entry.make,
        model: entry.model,
      };
    }
  }
  return {
    make: String(rawMake || '').trim(),
    model: cleanModel,
  };
}

function extractTrimFromText(text, currentModel = '') {
  if (!text) return '';
  // Strip the matched model phrase first so e.g. "Bronco Sport" does NOT extract "Sport" as trim!
  let working = String(text);
  if (currentModel) {
    const escapedModel = currentModel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/[\s-]+/g, '[\\s+-]*');
    working = working.replace(new RegExp(`\\b${escapedModel}\\b`, 'gi'), ' ');
  }
  // Also strip bed/cab phrases so "XL" inside nothing else is confused
  for (const tp of TRIM_PATTERNS) {
    if (tp.regex.test(working)) {
      return tp.canonical;
    }
  }
  return '';
}

function extractYearRangeFromText(text) {
  if (!text) return { minYear: null, maxYear: null };
  const s = String(text);

  const rangeMatch = s.match(/\b(20[12]\d)\s*(?:-|–|—|to|through|thru)\s*(20[12]\d)\b/i);
  if (rangeMatch) {
    const y1 = Number(rangeMatch[1]);
    const y2 = Number(rangeMatch[2]);
    return { minYear: Math.min(y1, y2), maxYear: Math.max(y1, y2) };
  }

  const minPlusMatch = s.match(/\b(20[12]\d)\s*(?:\+|or\s+newer|and\s+newer|and\s+up|up)\b/i);
  if (minPlusMatch) {
    return { minYear: Number(minPlusMatch[1]), maxYear: null };
  }

  const singleYear = s.match(/\b(20[12]\d)\b/);
  if (singleYear) {
    const yr = Number(singleYear[1]);
    return { minYear: yr, maxYear: yr };
  }

  return { minYear: null, maxYear: null };
}

function extractMaxMileageFromText(text) {
  if (!text) return null;
  const m = String(text).match(
    /(?:under|below|less\s+than|max|up\s+to|<=?)\s*(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)\s*(k)?\s*(?:miles?|mi\.?)\b|\b(\d{1,3}(?:,\d{3})+|\d+)\s*(k)\s*(?:miles?|mi\.?)\b/i
  );
  if (!m) return null;
  if (m[1]) {
    let v = parseFloat(m[1].replace(/,/g, ''));
    if (m[2] || v < 500) v *= 1000;
    return v > 0 ? Math.round(v) : null;
  }
  if (m[3]) {
    const v = parseFloat(m[3].replace(/,/g, '')) * 1000;
    return v > 0 ? Math.round(v) : null;
  }
  return null;
}

/**
 * Full natural-language + structured criteria normalization.
 */
export function parseNaturalLanguageCriteria(guest = {}) {
  const featuresList = Array.isArray(guest.features)
    ? guest.features.map((f) => String(f).trim()).filter(Boolean)
    : [];
  const rawNotes = String(guest.notes || '').trim();
  const combinedRaw = `${rawNotes} ${featuresList.join(' ')}`.trim();

  const clauses = splitNaturalLanguageClauses(rawNotes);
  const strictClauses = clauses.filter((c) => !isPreferenceClause(c));
  const preferenceClauses = clauses.filter((c) => isPreferenceClause(c));
  const strictNotes = strictClauses.join(' ; ');
  const strictCombined = `${strictNotes} ${featuresList.join(' ')}`.trim();
  const lowerAll = combinedRaw.toLowerCase();
  const lowerStrict = strictCombined.toLowerCase();

  // 1. Normalize Make & Model (from explicit fields first, then natural language)
  let { make, model } = normalizeModelInput(guest.make, guest.model);

  if (!make && lowerAll) {
    for (const entry of KNOWN_MAKES) {
      const hit = entry.aliases.some((alias) =>
        new RegExp(`\\b${alias.replace('-', '[-\\s]?')}\\b`, 'i').test(lowerAll)
      );
      if (hit) {
        make = entry.canonical;
        break;
      }
    }
  }

  if (!model && combinedRaw) {
    const searchOrder = [strictCombined, combinedRaw].filter(Boolean);
    for (const candidateText of searchOrder) {
      for (const entry of MODEL_PATTERNS) {
        if (make && entry.make.toLowerCase() !== make.toLowerCase()) continue;
        if (entry.regex.test(candidateText)) {
          model = entry.model;
          if (!make) make = entry.make;
          break;
        }
      }
      if (model) break;
    }
    // Second pass without make restriction if user left make empty
    if (!model) {
      for (const entry of MODEL_PATTERNS) {
        if (entry.regex.test(combinedRaw)) {
          model = entry.model;
          if (!make) make = entry.make;
          break;
        }
      }
    }
  }

  // 2. Normalize Trim (from explicit field or strict natural language clauses)
  let trim = String(guest.trim || '').trim();
  if (trim) {
    const canonicalTrim = extractTrimFromText(trim, model);
    if (canonicalTrim && canonicalTrim.toLowerCase() === trim.toLowerCase()) {
      trim = canonicalTrim;
    }
  } else if (strictCombined) {
    trim = extractTrimFromText(strictCombined, model);
  }

  // 3. Bed Length & Cab Style
  const explicitBed = String(guest.bedLength || '').trim();
  const bedLength =
    explicitBed ||
    extractBedLengthFromQuery(strictCombined) ||
    extractBedLengthFromQuery(combinedRaw);

  const explicitCab = String(guest.cabStyle || '').trim();
  const cabStyle = explicitCab || extractCabStyleFromText(strictCombined);

  // 4. Engine / Powertrain (strict only from non-preference clauses!)
  const explicitEngine = String(guest.engineSpec || '').trim();
  const engineSpec = explicitEngine || extractEngineSpecFromText(strictNotes);

  // 5. Max Price
  let maxPrice =
    guest.maxPrice != null && Number(guest.maxPrice) > 0 ? Number(guest.maxPrice) : null;
  if (maxPrice != null && maxPrice > 0 && maxPrice < 500) {
    maxPrice = maxPrice * 1000;
  }
  if (maxPrice == null && combinedRaw) {
    const budgetRegex =
      /(?:under|below|max|up\s+to|less\s+than|around|budget(?:\s+of)?|<=?)\s*\$?\s*(\d+(?:,\d{3})*(?:\.\d+)?)\s*(k|thousand)?\b|\$\s*(\d+(?:,\d{3})*(?:\.\d+)?)\s*(k|thousand)\b|\$\s*(\d{1,3}(?:,\d{3})+)\b/i;
    const m = combinedRaw.match(budgetRegex);
    if (m) {
      if (m[1]) {
        let val = parseFloat(m[1].replace(/,/g, ''));
        if (m[2] || (val > 0 && val < 500)) val *= 1000;
        if (val >= 1000) maxPrice = val;
      } else if (m[3]) {
        const val = parseFloat(m[3].replace(/,/g, '')) * 1000;
        if (val >= 1000) maxPrice = val;
      } else if (m[5]) {
        const val = parseFloat(m[5].replace(/,/g, ''));
        if (val >= 1000) maxPrice = val;
      }
    }
  }

  // 6. Min/Max Year & Max Mileage
  let minYear = guest.minYear != null && Number(guest.minYear) > 0 ? Number(guest.minYear) : null;
  let maxYear = guest.maxYear != null && Number(guest.maxYear) > 0 ? Number(guest.maxYear) : null;
  if (minYear == null && maxYear == null && strictNotes) {
    const yr = extractYearRangeFromText(strictNotes);
    minYear = yr.minYear;
    maxYear = yr.maxYear;
  }

  let maxMileage =
    guest.maxMileage != null && Number(guest.maxMileage) > 0 ? Number(guest.maxMileage) : null;
  if (maxMileage == null && combinedRaw) {
    maxMileage = extractMaxMileageFromText(combinedRaw);
  }

  // 7. Condition
  let condition = String(guest.condition || 'Any').trim() || 'Any';
  if (condition === 'Any' && lowerStrict) {
    const hasNewAndUsed =
      /\bnew\s+(?:or|and)\s+(?:used|pre-?owned)\b|\b(?:pre-?owned|used)\s+or\s+cpo\b/i.test(
        lowerStrict
      );
    if (!hasNewAndUsed) {
      if (/\bcpo\b|\bcertified\s+pre-?owned\b/i.test(lowerStrict)) {
        condition = 'CPO';
      } else if (/\b(?:pre-?owned|used)\b/i.test(lowerStrict)) {
        condition = 'Pre-Owned';
      } else if (/\bnew\b/i.test(lowerStrict) && !/\blike\s+new\b/i.test(lowerStrict)) {
        condition = 'New';
      }
    }
  }

  // 8. Drivetrain
  let drivetrain = String(guest.drivetrain || 'Any').trim() || 'Any';
  if (drivetrain === 'Any' && lowerStrict) {
    if (/\b(?:4wd|4x4|four[\s-]wheel[\s-]drive|4[\s-]wheel[\s-]drive)\b/i.test(lowerStrict)) {
      drivetrain = '4WD';
    } else if (/\b(?:awd|all[\s-]wheel[\s-]drive)\b/i.test(lowerStrict)) {
      drivetrain = 'AWD';
    } else if (/\b(?:rwd|2wd|4x2|rear[\s-]wheel[\s-]drive)\b/i.test(lowerStrict)) {
      drivetrain = 'RWD';
    } else if (/\b(?:fwd|front[\s-]wheel[\s-]drive)\b/i.test(lowerStrict)) {
      drivetrain = 'FWD';
    }
  }

  // 9. Exterior Color(s) — supports single or multiple chosen colors
  const explicitColors = parseExteriorColors(
    Array.isArray(guest.exteriorColors) && guest.exteriorColors.length > 0
      ? guest.exteriorColors
      : guest.exteriorColor
  );
  const parsedNoteColors =
    explicitColors.length === 0 && strictNotes
      ? parseExteriorColors(extractColorFromStrictNotes(strictNotes))
      : [];
  const exteriorColors = explicitColors.length > 0 ? explicitColors : parsedNoteColors;
  const exteriorColor = exteriorColors.join(', ');

  // 10. Dealership Location Hints
  const locationHints = LOCATION_KEYWORDS.filter((loc) => lowerAll.includes(loc));

  // 11. Explicit Strict Packages (only from non-preference clauses)
  const strictPackages = STRICT_PACKAGE_RULES.filter((rule) => rule.regex.test(strictCombined)).map(
    (r) => r.label
  );

  return {
    ...guest,
    make,
    model,
    trim,
    bedLength,
    cabStyle,
    engineSpec,
    condition,
    drivetrain,
    minYear,
    maxYear,
    maxPrice,
    maxMileage,
    exteriorColor,
    exteriorColors,
    features: featuresList,
    notes: rawNotes,
    locationHints,
    strictPackages,
    preferenceClauses,
  };
}

export function expandPrestonModelVariants(make, model) {
  const m = String(model || '').trim();
  if (!m) return [];
  const variants = new Set([m]);

  const sdMatch = m.match(/^f[\s-]*([2345]50)$/i);
  if (sdMatch) {
    const num = sdMatch[1];
    variants.add(`F-${num}`);
    variants.add(`Super Duty F-${num}`);
    variants.add(`Super Duty F-${num} SRW`);
    variants.add(`Super Duty F-${num} DRW`);
    variants.add(`F-${num} Super Duty`);
  } else if (/^f[\s-]*150$/i.test(m)) {
    variants.add('F-150');
  } else if (/^(?:mustang\s+)?mach[\s-]*e$/i.test(m)) {
    variants.add('Mustang Mach-E');
  } else if (/^cx[\s-]*(\d+)$/i.test(m)) {
    const num = m.match(/\d+/)[0];
    variants.add(`CX-${num}`);
    variants.add(`Mazda CX-${num}`);
  } else if (/^mazda\s*3$/i.test(m)) {
    variants.add('Mazda3');
    variants.add('Mazda3 Sedan');
    variants.add('Mazda3 Hatchback');
  } else if (/^(?:mx[\s-]*5(?:\s+miata)?|miata)$/i.test(m)) {
    variants.add('Mazda MX-5 Miata');
    variants.add('Mazda MX-5 Miata RF');
  } else if (String(make || '').toLowerCase() === 'ram' && /^(1500|2500|3500)$/.test(m)) {
    variants.add(m);
    variants.add(`Ram ${m}`);
  } else if (/^silverado\s*2500/i.test(m)) {
    variants.add('Silverado 2500 HD');
    variants.add('Silverado 2500HD');
  }

  return Array.from(variants);
}

function compactAlnum(s) {
  return String(s || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

export function doesVehicleMatchModel(targetModel, vehicle) {
  const cleanTarget = String(targetModel || '').trim();
  if (!cleanTarget) return true;

  const vModel = String(vehicle?.model || '').trim();
  const vTitle = String(vehicle?.title || '').trim();
  const combinedLower = `${vModel} ${vTitle}`.toLowerCase();

  // Prevent well-known prefix collisions between distinct vehicle lines!
  const targetLower = cleanTarget.toLowerCase();
  if (targetLower === 'bronco' && /\bbronco\s+sport\b/i.test(combinedLower)) {
    return false;
  }
  if (targetLower === 'mustang' && /\bmach[\s-]*e\b/i.test(combinedLower)) {
    return false;
  }
  if (targetLower === 'cherokee' && /\bgrand\s+cherokee\b/i.test(combinedLower)) {
    return false;
  }
  if (targetLower === 'grand cherokee' && /\bgrand\s+cherokee\s+l\b/i.test(combinedLower)) {
    return false;
  }
  if (targetLower === 'wagoneer' && /\bgrand\s+wagoneer\b/i.test(combinedLower)) {
    return false;
  }
  if (targetLower === 'corolla' && /\bcorolla\s+cross\b/i.test(combinedLower)) {
    return false;
  }
  if (targetLower === 'highlander' && /\bgrand\s+highlander\b/i.test(combinedLower)) {
    return false;
  }
  if (
    /^f[\s-]*150$/i.test(cleanTarget) &&
    /\blightning\b/i.test(combinedLower)
  ) {
    return false;
  }

  // F-Series check (e.g. F-150 vs F-250 vs F-350)
  const fMatch = cleanTarget.match(/^f[\s-]*(\d{3})$/i);
  if (fMatch) {
    const num = fMatch[1];
    return new RegExp(`\\bf[\\s+-]*${num}\\b`, 'i').test(combinedLower);
  }

  // CX-5 vs CX-50 / CX-30 / CX-90 exact token check
  const cxMatch = cleanTarget.match(/^cx[\s-]*(\d+)$/i);
  if (cxMatch) {
    const num = cxMatch[1];
    return new RegExp(`\\bcx[\\s-]*${num}\\b`, 'i').test(combinedLower);
  }

  // General word-boundary token check + compact fallback (for CRV -> CR-V, RAV-4 -> RAV4)
  const normTokens = cleanTarget
    .toLowerCase()
    .replace(/[-+]/g, ' ')
    .split(/\s+/)
    .filter(Boolean);
  const hayWords = combinedLower.replace(/[-+®™]/g, ' ');
  const allWordBoundary = normTokens.every((tok) =>
    new RegExp(`\\b${tok.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i').test(hayWords)
  );
  if (allWordBoundary) return true;

  const targetCompact = compactAlnum(cleanTarget);
  const vModelCompact = compactAlnum(vModel);
  if (targetCompact.length >= 3 && vModelCompact === targetCompact) {
    return true;
  }

  return false;
}

/**
 * Strict word-boundary trim check:
 *   "XLT" matches "XLT" or "XLT 302A", NEVER "XL"
 *   "XL" matches "XL", NEVER "XLT" or "XLE"
 *   "ST" matches "ST", NEVER "STX", "ST-Line", or "Mustang"
 */
export function doesVehicleMatchTrim(targetTrim, vehicle) {
  const cleanTrim = String(targetTrim || '')
    .replace(/[®™]/g, '')
    .trim();
  if (!cleanTrim) return true;

  const vTrimClean = String(vehicle?.trim || '')
    .replace(/[®™]/g, '')
    .trim();
  const vTitleClean = String(vehicle?.title || '')
    .replace(/[®™]/g, '')
    .trim();

  const escaped = cleanTrim
    .replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    .replace(/[\s-]+/g, '[\\s-]+');

  // Guard against hyphenated suffix collisions like "ST" matching "ST-Line" or "EX" matching "EX-L"
  const boundaryRegex = new RegExp(`\\b${escaped}\\b(?![-\\w])`, 'i');

  if (vTrimClean) {
    // When vehicle has an explicit trim (e.g. "XL", "XLT", "STX", "Lariat"), require v.trim (or v.title) to match word-bounded!
    return boundaryRegex.test(vTrimClean) || boundaryRegex.test(vTitleClean);
  }

  return boundaryRegex.test(vTitleClean);
}

export function doesVehicleMatchCabStyle(targetCabStyle, vehicle) {
  if (!targetCabStyle) return true;
  const vCab =
    vehicle?.cabStyle ||
    extractCabStyleFromText(
      `${vehicle?.bodyStyle || ''} ${vehicle?.title || ''} ${vehicle?.commentsSummary || ''}`
    );
  return vCab === targetCabStyle;
}

export function doesVehicleMatchEngine(targetEngineSpec, vehicle) {
  if (!targetEngineSpec) return true;
  const hay = `${vehicle?.engine || ''} ${vehicle?.fuelType || ''} ${vehicle?.title || ''} ${(
    vehicle?.highlights || []
  ).join(' ')} ${vehicle?.fullCommentsSearchText || vehicle?.commentsSummary || ''}`.toLowerCase();

  const spec = targetEngineSpec.toLowerCase();
  if (spec === 'v8') {
    return /\bv8\b|\b8\s*cylinder\b|\b5\.0\s*l?\b|\b7\.3\s*l?\b|\b6\.8\s*l?\b|\b6\.2\s*l?\b/i.test(
      hay
    );
  }
  if (spec === 'v6') {
    return /\bv6\b|\b6\s*cylinder\b|\b3\.5\s*l?\b|\b2\.7\s*l?\b|\becoboost\b/i.test(hay);
  }
  if (spec === 'diesel') {
    return /\bdiesel\b|\bpower\s*stroke\b|\bduramax\b|\bcummins\b|\b6\.7\s*l?\b/i.test(hay);
  }
  if (spec === 'hybrid') {
    return /\bhybrid\b|\bpower\s*boost\b/i.test(hay);
  }
  if (spec === 'phev') {
    return /\bplug[\s-]*in\s+hybrid\b|\bphev\b/i.test(hay);
  }
  if (spec === 'ecoboost') {
    return /\becoboost\b|\bturbo\b|\bv6\s+cylinder\b/i.test(hay);
  }
  if (spec.endsWith('l')) {
    const num = spec.slice(0, -1).replace('.', '\\.');
    return new RegExp(`\\b${num}\\s*l?\\b`, 'i').test(hay);
  }
  return hay.includes(spec);
}

function doesSingleColorMatchVehicle(singleColorLower, vColorLower) {
  if (!singleColorLower) return true;
  if (singleColorLower === 'gray' || singleColorLower === 'grey') {
    return (
      vColorLower.includes('gray') ||
      vColorLower.includes('grey') ||
      vColorLower.includes('slate') ||
      vColorLower.includes('magnetic') ||
      vColorLower.includes('carbonized') ||
      vColorLower.includes('charcoal') ||
      vColorLower.includes('graphite')
    );
  }
  if (singleColorLower === 'white') {
    return (
      vColorLower.includes('white') ||
      vColorLower.includes('ivory') ||
      vColorLower.includes('pearl') ||
      vColorLower.includes('oxford')
    );
  }
  if (singleColorLower === 'black') {
    return (
      vColorLower.includes('black') ||
      vColorLower.includes('ebony') ||
      vColorLower.includes('onyx') ||
      vColorLower.includes('obsidian') ||
      vColorLower.includes('agate')
    );
  }
  if (singleColorLower === 'silver') {
    return (
      vColorLower.includes('silver') ||
      vColorLower.includes('ingot') ||
      vColorLower.includes('billet') ||
      vColorLower.includes('aluminum')
    );
  }
  if (singleColorLower === 'blue') {
    return (
      vColorLower.includes('blue') ||
      vColorLower.includes('navy') ||
      vColorLower.includes('azure') ||
      vColorLower.includes('cobalt') ||
      vColorLower.includes('sapphire') ||
      vColorLower.includes('antimatter') ||
      vColorLower.includes('velocity')
    );
  }
  if (singleColorLower === 'red') {
    return (
      vColorLower.includes('red') ||
      vColorLower.includes('crimson') ||
      vColorLower.includes('ruby') ||
      vColorLower.includes('scarlet') ||
      vColorLower.includes('maroon') ||
      vColorLower.includes('burgundy')
    );
  }
  if (singleColorLower === 'burgundy') {
    return (
      vColorLower.includes('burgundy') ||
      vColorLower.includes('maroon') ||
      vColorLower.includes('crimson') ||
      vColorLower.includes('wine') ||
      vColorLower.includes('merlot')
    );
  }
  if (singleColorLower === 'green') {
    return (
      vColorLower.includes('green') ||
      vColorLower.includes('olive') ||
      vColorLower.includes('emerald') ||
      vColorLower.includes('forest') ||
      vColorLower.includes('sage') ||
      vColorLower.includes('eruption')
    );
  }
  if (singleColorLower === 'brown') {
    return (
      vColorLower.includes('brown') ||
      vColorLower.includes('bronze') ||
      vColorLower.includes('copper') ||
      vColorLower.includes('mocha') ||
      vColorLower.includes('espresso') ||
      vColorLower.includes('kodiak') ||
      vColorLower.includes('mahogany')
    );
  }
  if (singleColorLower === 'tan') {
    return (
      vColorLower.includes('tan') ||
      vColorLower.includes('beige') ||
      vColorLower.includes('sand') ||
      vColorLower.includes('dune') ||
      vColorLower.includes('cashmere') ||
      vColorLower.includes('terrain')
    );
  }
  if (singleColorLower === 'gold') {
    return (
      vColorLower.includes('gold') ||
      vColorLower.includes('champagne') ||
      vColorLower.includes('amber')
    );
  }
  return vColorLower.includes(singleColorLower);
}

export function doesVehicleMatchColor(targetColor, vehicle) {
  const colors = parseExteriorColors(targetColor);
  if (colors.length === 0) return true;
  const vColor = String(vehicle?.exteriorColor || '').toLowerCase();
  if (!vColor) return false;
  return colors.some((c) => doesSingleColorMatchVehicle(c.toLowerCase(), vColor));
}

export function doesVehicleMatchStrictPackages(strictPackages, vehicle) {
  if (!Array.isArray(strictPackages) || strictPackages.length === 0) return true;
  const hay = `${vehicle?.title || ''} ${vehicle?.trim || ''} ${(vehicle?.highlights || []).join(
    ' '
  )} ${vehicle?.fullCommentsSearchText || vehicle?.commentsSummary || ''}`;

  for (const label of strictPackages) {
    const rule = STRICT_PACKAGE_RULES.find((r) => r.label === label);
    if (rule && !rule.matchRegex.test(hay)) {
      return false;
    }
  }
  return true;
}
