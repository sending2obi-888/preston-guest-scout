/// Shared Natural-Language Vehicle Criteria Parser & Strict Specification Matcher
/// for Preston Motor Guest Scout (Web, Android, & Googlebook).
///
/// Understands multi-sentence and shorthand natural language vehicle queries such as:
///   "Ford F150. 6.5ft bed. XLT."
///   "Used 2022-2024 Ford F-250 Lariat Crew Cab 6.75ft bed diesel under \$65k"
///   "New Ford Bronco Badlands 4x4"
/// and enforces strict matching on every parsed structural criterion (Make, Model,
/// Trim with word boundaries, Bed Length, Cab Style, Engine/Fuel, Year, Price,
/// Mileage, Condition, Drivetrain, Exterior Color, Dealership Location, and
/// explicit Equipment/Package codes).
class NaturalLanguageVehicleParser {
  NaturalLanguageVehicleParser._();

  static const Map<String, List<String>> knownMakes = {
    'Ford': ['ford'],
    'Lincoln': ['lincoln'],
    'Hyundai': ['hyundai'],
    'Mazda': ['mazda'],
    'Nissan': ['nissan'],
    'Chevrolet': ['chevrolet', 'chevy'],
    'Jeep': ['jeep'],
    'Ram': ['ram'],
    'Dodge': ['dodge'],
    'Chrysler': ['chrysler'],
    'Toyota': ['toyota'],
    'Honda': ['honda'],
    'GMC': ['gmc'],
    'Kia': ['kia'],
    'Subaru': ['subaru'],
    'Genesis': ['genesis'],
    'Volkswagen': ['volkswagen', 'vw'],
    'BMW': ['bmw'],
    'Mercedes-Benz': ['mercedes-benz', 'mercedes'],
    'Audi': ['audi'],
    'Lexus': ['lexus'],
    'Cadillac': ['cadillac'],
    'Buick': ['buick'],
    'Acura': ['acura'],
    'INFINITI': ['infiniti'],
    'Volvo': ['volvo'],
  };

  static const List<String> locationKeywords = [
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

  static final List<({String make, String model, RegExp regex})> _modelPatterns =
      [
    // Ford
    (
      make: 'Ford',
      model: 'F-150 Lightning',
      regex: RegExp(r'\bf[\s+-]*150\s+lightning\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'F-150',
      regex: RegExp(r'\bf[\s+-]*150\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'F-250',
      regex: RegExp(
        r'\b(?:super\s+duty\s+)?f[\s+-]*250(?:\s+super\s+duty|\s+srw|\s+drw)?\b',
        caseSensitive: false,
      ),
    ),
    (
      make: 'Ford',
      model: 'F-350',
      regex: RegExp(
        r'\b(?:super\s+duty\s+)?f[\s+-]*350(?:\s+super\s+duty|\s+srw|\s+drw)?\b',
        caseSensitive: false,
      ),
    ),
    (
      make: 'Ford',
      model: 'F-450',
      regex: RegExp(
        r'\b(?:super\s+duty\s+)?f[\s+-]*450(?:\s+drw|\s+srw)?\b',
        caseSensitive: false,
      ),
    ),
    (
      make: 'Ford',
      model: 'F-550',
      regex: RegExp(
        r'\b(?:super\s+duty\s+)?f[\s+-]*550(?:\s+drw|\s+srw)?\b',
        caseSensitive: false,
      ),
    ),
    (
      make: 'Ford',
      model: 'Bronco Sport',
      regex: RegExp(r'\bbronco\s+sport\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Bronco',
      regex: RegExp(r'\bbronco\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Expedition Max',
      regex: RegExp(r'\bexpedition\s+max\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Expedition',
      regex: RegExp(r'\bexpedition\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Mustang Mach-E',
      regex: RegExp(r'\b(?:mustang\s+)?mach[\s-]*e\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Mustang',
      regex: RegExp(r'\bmustang\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Explorer',
      regex: RegExp(r'\bexplorer\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Escape',
      regex: RegExp(r'\bescape\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Edge',
      regex: RegExp(r'\bedge\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Maverick',
      regex: RegExp(r'\bmaverick\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Ranger',
      regex: RegExp(r'\branger\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Transit',
      regex: RegExp(r'\btransit\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'EcoSport',
      regex: RegExp(r'\becosport\b', caseSensitive: false),
    ),
    (
      make: 'Ford',
      model: 'Fusion',
      regex: RegExp(r'\bfusion\b', caseSensitive: false),
    ),

    // Lincoln
    (
      make: 'Lincoln',
      model: 'Navigator L',
      regex: RegExp(r'\bnavigator\s+l\b', caseSensitive: false),
    ),
    (
      make: 'Lincoln',
      model: 'Navigator',
      regex: RegExp(r'\bnavigator\b', caseSensitive: false),
    ),
    (
      make: 'Lincoln',
      model: 'Aviator',
      regex: RegExp(r'\baviator\b', caseSensitive: false),
    ),
    (
      make: 'Lincoln',
      model: 'Nautilus',
      regex: RegExp(r'\bnautilus\b', caseSensitive: false),
    ),
    (
      make: 'Lincoln',
      model: 'Corsair',
      regex: RegExp(r'\bcorsair\b', caseSensitive: false),
    ),

    // Chevrolet
    (
      make: 'Chevrolet',
      model: 'Silverado 3500HD',
      regex: RegExp(r'\bsilverado\s*3500(?:\s*hd)?\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Silverado 2500 HD',
      regex: RegExp(r'\bsilverado\s*2500(?:\s*hd)?\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Silverado 1500',
      regex: RegExp(r'\bsilverado(?:\s*1500)?\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Equinox EV',
      regex: RegExp(r'\bequinox\s+ev\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Equinox',
      regex: RegExp(r'\bequinox\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Colorado',
      regex: RegExp(r'\bcolorado\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Suburban',
      regex: RegExp(r'\bsuburban\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Tahoe',
      regex: RegExp(r'\btahoe\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Traverse',
      regex: RegExp(r'\btraverse\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Trailblazer',
      regex: RegExp(r'\btrailblazer\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Blazer',
      regex: RegExp(r'\bblazer\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Trax',
      regex: RegExp(r'\btrax\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Corvette',
      regex: RegExp(r'\bcorvette\b', caseSensitive: false),
    ),
    (
      make: 'Chevrolet',
      model: 'Malibu',
      regex: RegExp(r'\bmalibu\b', caseSensitive: false),
    ),

    // GMC
    (
      make: 'GMC',
      model: 'Sierra 3500HD',
      regex: RegExp(r'\bsierra\s*3500(?:\s*hd)?\b', caseSensitive: false),
    ),
    (
      make: 'GMC',
      model: 'Sierra 2500HD',
      regex: RegExp(r'\bsierra\s*2500(?:\s*hd)?\b', caseSensitive: false),
    ),
    (
      make: 'GMC',
      model: 'Sierra 1500',
      regex: RegExp(r'\bsierra(?:\s*1500)?\b', caseSensitive: false),
    ),
    (
      make: 'GMC',
      model: 'Yukon XL',
      regex: RegExp(r'\byukon\s+xl\b', caseSensitive: false),
    ),
    (
      make: 'GMC',
      model: 'Yukon',
      regex: RegExp(r'\byukon\b', caseSensitive: false),
    ),
    (
      make: 'GMC',
      model: 'Acadia',
      regex: RegExp(r'\bacadia\b', caseSensitive: false),
    ),
    (
      make: 'GMC',
      model: 'Terrain',
      regex: RegExp(r'\bterrain\b', caseSensitive: false),
    ),
    (
      make: 'GMC',
      model: 'Canyon',
      regex: RegExp(r'\bcanyon\b', caseSensitive: false),
    ),

    // Ram
    (
      make: 'Ram',
      model: '3500',
      regex: RegExp(r'\bram\s*3500\b', caseSensitive: false),
    ),
    (
      make: 'Ram',
      model: '2500',
      regex: RegExp(r'\bram\s*2500\b', caseSensitive: false),
    ),
    (
      make: 'Ram',
      model: '1500',
      regex: RegExp(r'\bram\s*1500\b', caseSensitive: false),
    ),
    (
      make: 'Ram',
      model: 'ProMaster',
      regex: RegExp(r'\bpromaster\b', caseSensitive: false),
    ),

    // Jeep
    (
      make: 'Jeep',
      model: 'Grand Cherokee L',
      regex: RegExp(r'\bgrand\s+cherokee\s+l\b', caseSensitive: false),
    ),
    (
      make: 'Jeep',
      model: 'Grand Cherokee',
      regex: RegExp(r'\bgrand\s+cherokee\b', caseSensitive: false),
    ),
    (
      make: 'Jeep',
      model: 'Cherokee',
      regex: RegExp(r'\bcherokee\b', caseSensitive: false),
    ),
    (
      make: 'Jeep',
      model: 'Grand Wagoneer L',
      regex: RegExp(r'\bgrand\s+wagoneer\s+l\b', caseSensitive: false),
    ),
    (
      make: 'Jeep',
      model: 'Grand Wagoneer',
      regex: RegExp(r'\bgrand\s+wagoneer\b', caseSensitive: false),
    ),
    (
      make: 'Jeep',
      model: 'Wagoneer',
      regex: RegExp(r'\bwagoneer\b', caseSensitive: false),
    ),
    (
      make: 'Jeep',
      model: 'Wrangler',
      regex: RegExp(r'\bwrangler\b', caseSensitive: false),
    ),
    (
      make: 'Jeep',
      model: 'Gladiator',
      regex: RegExp(r'\bgladiator\b', caseSensitive: false),
    ),
    (
      make: 'Jeep',
      model: 'Compass',
      regex: RegExp(r'\bcompass\b', caseSensitive: false),
    ),
    (
      make: 'Jeep',
      model: 'Renegade',
      regex: RegExp(r'\brenegade\b', caseSensitive: false),
    ),

    // Hyundai
    (
      make: 'Hyundai',
      model: 'Santa Cruz',
      regex: RegExp(r'\bsanta\s*cruz\b', caseSensitive: false),
    ),
    (
      make: 'Hyundai',
      model: 'Santa Fe',
      regex: RegExp(r'\bsanta\s+fe\b', caseSensitive: false),
    ),
    (
      make: 'Hyundai',
      model: 'Palisade',
      regex: RegExp(r'\bpalisade\b', caseSensitive: false),
    ),
    (
      make: 'Hyundai',
      model: 'Tucson',
      regex: RegExp(r'\btucson\b', caseSensitive: false),
    ),
    (
      make: 'Hyundai',
      model: 'Kona',
      regex: RegExp(r'\bkona\b', caseSensitive: false),
    ),
    (
      make: 'Hyundai',
      model: 'Elantra',
      regex: RegExp(r'\belantra\b', caseSensitive: false),
    ),
    (
      make: 'Hyundai',
      model: 'Sonata',
      regex: RegExp(r'\bsonata\b', caseSensitive: false),
    ),
    (
      make: 'Hyundai',
      model: 'Venue',
      regex: RegExp(r'\bvenue\b', caseSensitive: false),
    ),
    (
      make: 'Hyundai',
      model: 'IONIQ 5',
      regex: RegExp(r'\bioniq\s*5\b', caseSensitive: false),
    ),
    (
      make: 'Hyundai',
      model: 'IONIQ 6',
      regex: RegExp(r'\bioniq\s*6\b', caseSensitive: false),
    ),

    // Mazda
    (
      make: 'Mazda',
      model: 'CX-90',
      regex: RegExp(r'\bcx[\s-]*90\b', caseSensitive: false),
    ),
    (
      make: 'Mazda',
      model: 'CX-70',
      regex: RegExp(r'\bcx[\s-]*70\b', caseSensitive: false),
    ),
    (
      make: 'Mazda',
      model: 'CX-50',
      regex: RegExp(r'\bcx[\s-]*50\b', caseSensitive: false),
    ),
    (
      make: 'Mazda',
      model: 'CX-30',
      regex: RegExp(r'\bcx[\s-]*30\b', caseSensitive: false),
    ),
    (
      make: 'Mazda',
      model: 'CX-5',
      regex: RegExp(r'\bcx[\s-]*5\b', caseSensitive: false),
    ),
    (
      make: 'Mazda',
      model: 'MX-5 Miata',
      regex:
          RegExp(r'\b(?:mx[\s-]*5(?:\s+miata)?|miata)\b', caseSensitive: false),
    ),
    (
      make: 'Mazda',
      model: 'Mazda3',
      regex: RegExp(r'\bmazda\s*3\b', caseSensitive: false),
    ),

    // Toyota
    (
      make: 'Toyota',
      model: 'Grand Highlander',
      regex: RegExp(r'\bgrand\s+highlander\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'Highlander',
      regex: RegExp(r'\bhighlander\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'Corolla Cross',
      regex: RegExp(r'\bcorolla\s+cross\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'Corolla',
      regex: RegExp(r'\bcorolla\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'RAV4',
      regex: RegExp(r'\brav[\s-]*4\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: '4Runner',
      regex: RegExp(r'\b4[\s-]*runner\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'Land Cruiser',
      regex: RegExp(r'\bland\s+cruiser\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'Tacoma',
      regex: RegExp(r'\btacoma\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'Tundra',
      regex: RegExp(r'\btundra\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'Camry',
      regex: RegExp(r'\bcamry\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'Sienna',
      regex: RegExp(r'\bsienna\b', caseSensitive: false),
    ),
    (
      make: 'Toyota',
      model: 'Prius',
      regex: RegExp(r'\bprius\b', caseSensitive: false),
    ),

    // Honda
    (
      make: 'Honda',
      model: 'CR-V',
      regex: RegExp(r'\bcr[\s-]*v\b', caseSensitive: false),
    ),
    (
      make: 'Honda',
      model: 'HR-V',
      regex: RegExp(r'\bhr[\s-]*v\b', caseSensitive: false),
    ),
    (
      make: 'Honda',
      model: 'Pilot',
      regex: RegExp(r'\bpilot\b', caseSensitive: false),
    ),
    (
      make: 'Honda',
      model: 'Passport',
      regex: RegExp(r'\bpassport\b', caseSensitive: false),
    ),
    (
      make: 'Honda',
      model: 'Odyssey',
      regex: RegExp(r'\bodyssey\b', caseSensitive: false),
    ),
    (
      make: 'Honda',
      model: 'Ridgeline',
      regex: RegExp(r'\bridgeline\b', caseSensitive: false),
    ),
    (
      make: 'Honda',
      model: 'Accord',
      regex: RegExp(r'\baccord\b', caseSensitive: false),
    ),
    (
      make: 'Honda',
      model: 'Civic',
      regex: RegExp(r'\bcivic\b', caseSensitive: false),
    ),

    // Nissan / Kia / Subaru / Dodge / Chrysler
    (
      make: 'Nissan',
      model: 'Pathfinder',
      regex: RegExp(r'\bpathfinder\b', caseSensitive: false),
    ),
    (
      make: 'Nissan',
      model: 'Rogue',
      regex: RegExp(r'\brogue\b', caseSensitive: false),
    ),
    (
      make: 'Nissan',
      model: 'Murano',
      regex: RegExp(r'\bmurano\b', caseSensitive: false),
    ),
    (
      make: 'Nissan',
      model: 'Armada',
      regex: RegExp(r'\barmada\b', caseSensitive: false),
    ),
    (
      make: 'Nissan',
      model: 'Frontier',
      regex: RegExp(r'\bfrontier\b', caseSensitive: false),
    ),
    (
      make: 'Nissan',
      model: 'Titan',
      regex: RegExp(r'\btitan\b', caseSensitive: false),
    ),
    (
      make: 'Nissan',
      model: 'Altima',
      regex: RegExp(r'\baltima\b', caseSensitive: false),
    ),
    (
      make: 'Nissan',
      model: 'Sentra',
      regex: RegExp(r'\bsentra\b', caseSensitive: false),
    ),
    (
      make: 'Nissan',
      model: 'Kicks',
      regex: RegExp(r'\bkicks\b', caseSensitive: false),
    ),
    (
      make: 'Kia',
      model: 'Telluride',
      regex: RegExp(r'\btelluride\b', caseSensitive: false),
    ),
    (
      make: 'Kia',
      model: 'Sorento',
      regex: RegExp(r'\bsorento\b', caseSensitive: false),
    ),
    (
      make: 'Kia',
      model: 'Sportage',
      regex: RegExp(r'\bsportage\b', caseSensitive: false),
    ),
    (
      make: 'Kia',
      model: 'Carnival',
      regex: RegExp(r'\bcarnival\b', caseSensitive: false),
    ),
    (
      make: 'Kia',
      model: 'K5',
      regex: RegExp(r'\bk5\b', caseSensitive: false),
    ),
    (
      make: 'Kia',
      model: 'EV9',
      regex: RegExp(r'\bev9\b', caseSensitive: false),
    ),
    (
      make: 'Kia',
      model: 'EV6',
      regex: RegExp(r'\bev6\b', caseSensitive: false),
    ),
    (
      make: 'Subaru',
      model: 'Outback',
      regex: RegExp(r'\boutback\b', caseSensitive: false),
    ),
    (
      make: 'Subaru',
      model: 'Forester',
      regex: RegExp(r'\bforester\b', caseSensitive: false),
    ),
    (
      make: 'Subaru',
      model: 'Crosstrek',
      regex: RegExp(r'\bcrosstrek\b', caseSensitive: false),
    ),
    (
      make: 'Subaru',
      model: 'Ascent',
      regex: RegExp(r'\bascent\b', caseSensitive: false),
    ),
    (
      make: 'Subaru',
      model: 'WRX',
      regex: RegExp(r'\bwrx\b', caseSensitive: false),
    ),
    (
      make: 'Dodge',
      model: 'Durango',
      regex: RegExp(r'\bdurango\b', caseSensitive: false),
    ),
    (
      make: 'Dodge',
      model: 'Charger',
      regex: RegExp(r'\bcharger\b', caseSensitive: false),
    ),
    (
      make: 'Dodge',
      model: 'Challenger',
      regex: RegExp(r'\bchallenger\b', caseSensitive: false),
    ),
    (
      make: 'Dodge',
      model: 'Hornet',
      regex: RegExp(r'\bhornet\b', caseSensitive: false),
    ),
    (
      make: 'Chrysler',
      model: 'Pacifica',
      regex: RegExp(r'\bpacifica\b', caseSensitive: false),
    ),
  ];

  static final List<({String canonical, RegExp regex})> _trimPatterns = [
    (
      canonical: 'King Ranch',
      regex: RegExp(r'\bking\s+ranch\b', caseSensitive: false),
    ),
    (
      canonical: 'Black Label',
      regex: RegExp(r'\bblack\s+label\b', caseSensitive: false),
    ),
    (
      canonical: 'Big Bend',
      regex: RegExp(r'\bbig\s+bend\b', caseSensitive: false),
    ),
    (
      canonical: 'Outer Banks',
      regex: RegExp(r'\bouter\s+banks\b', caseSensitive: false),
    ),
    (
      canonical: 'Heritage Edition',
      regex: RegExp(r'\bheritage\s+edition\b', caseSensitive: false),
    ),
    (
      canonical: 'Raptor R',
      regex: RegExp(r'\braptor\s+r\b', caseSensitive: false),
    ),
    (
      canonical: 'Dark Horse',
      regex: RegExp(r'\bdark\s+horse\b', caseSensitive: false),
    ),
    (
      canonical: 'GT Premium',
      regex: RegExp(r'\bgt\s+premium\b', caseSensitive: false),
    ),
    (
      canonical: 'EcoBoost Premium',
      regex: RegExp(r'\becoboost\s+premium\b', caseSensitive: false),
    ),
    (
      canonical: 'ST-Line Elite',
      regex: RegExp(r'\bst[\s-]+line\s+elite\b', caseSensitive: false),
    ),
    (
      canonical: 'ST-Line Select',
      regex: RegExp(r'\bst[\s-]+line\s+select\b', caseSensitive: false),
    ),
    (
      canonical: 'ST-Line',
      regex: RegExp(r'\bst[\s-]+line\b', caseSensitive: false),
    ),
    (
      canonical: 'High Country',
      regex: RegExp(r'\bhigh\s+country\b', caseSensitive: false),
    ),
    (
      canonical: 'Custom Trail Boss',
      regex: RegExp(r'\bcustom\s+trail\s+boss\b', caseSensitive: false),
    ),
    (
      canonical: 'LT Trail Boss',
      regex: RegExp(r'\blt\s+trail\s+boss\b', caseSensitive: false),
    ),
    (
      canonical: 'Denali Ultimate',
      regex: RegExp(r'\bdenali\s+ultimate\b', caseSensitive: false),
    ),
    (
      canonical: 'Big Horn',
      regex: RegExp(r'\bbig\s+horn\b', caseSensitive: false),
    ),
    (
      canonical: 'Lone Star',
      regex: RegExp(r'\blone\s+star\b', caseSensitive: false),
    ),
    (
      canonical: 'Rubicon X',
      regex: RegExp(r'\brubicon\s+x\b', caseSensitive: false),
    ),
    (
      canonical: 'Summit Reserve',
      regex: RegExp(r'\bsummit\s+reserve\b', caseSensitive: false),
    ),
    (
      canonical: 'TRD Pro',
      regex: RegExp(r'\btrd\s+pro\b', caseSensitive: false),
    ),
    (
      canonical: 'TRD Off-Road',
      regex: RegExp(r'\btrd\s+off[\s-]*road\b', caseSensitive: false),
    ),
    (
      canonical: 'TRD Sport',
      regex: RegExp(r'\btrd\s+sport\b', caseSensitive: false),
    ),
    (
      canonical: '1794 Edition',
      regex: RegExp(r'\b1794(?:\s+edition)?\b', caseSensitive: false),
    ),
    (
      canonical: 'Carbon Edition',
      regex: RegExp(r'\bcarbon\s+edition\b', caseSensitive: false),
    ),
    (
      canonical: 'N Line',
      regex: RegExp(r'\bn[\s-]+line\b', caseSensitive: false),
    ),
    (
      canonical: 'Badlands',
      regex: RegExp(r'\bbadlands\b', caseSensitive: false),
    ),
    (
      canonical: 'Wildtrak',
      regex: RegExp(r'\bwildtrak\b', caseSensitive: false),
    ),
    (
      canonical: 'Everglades',
      regex: RegExp(r'\beverglades\b', caseSensitive: false),
    ),
    (
      canonical: 'Platinum',
      regex: RegExp(r'\bplatinum\b', caseSensitive: false),
    ),
    (
      canonical: 'Lariat',
      regex: RegExp(r'\blariat\b', caseSensitive: false),
    ),
    (
      canonical: 'Tremor',
      regex: RegExp(r'\btremor\b', caseSensitive: false),
    ),
    (
      canonical: 'Raptor',
      regex: RegExp(r'\braptor\b', caseSensitive: false),
    ),
    (canonical: 'XLT', regex: RegExp(r'\bxlt\b', caseSensitive: false)),
    (canonical: 'STX', regex: RegExp(r'\bstx\b', caseSensitive: false)),
    (canonical: 'XL', regex: RegExp(r'\bxl\b', caseSensitive: false)),
    (canonical: 'Reserve', regex: RegExp(r'\breserve\b', caseSensitive: false)),
    (
      canonical: 'Premiere',
      regex: RegExp(r'\bpremiere\b', caseSensitive: false),
    ),
    (
      canonical: 'Titanium',
      regex: RegExp(r'\btitanium\b', caseSensitive: false),
    ),
    (canonical: 'Limited', regex: RegExp(r'\blimited\b', caseSensitive: false)),
    (
      canonical: 'Calligraphy',
      regex: RegExp(r'\bcalligraphy\b', caseSensitive: false),
    ),
    (canonical: 'XRT', regex: RegExp(r'\bxrt\b', caseSensitive: false)),
    (canonical: 'SEL', regex: RegExp(r'\bsel\b', caseSensitive: false)),
    (canonical: 'SE', regex: RegExp(r'\bse\b', caseSensitive: false)),
    (canonical: 'LTZ', regex: RegExp(r'\bltz\b', caseSensitive: false)),
    (canonical: 'RST', regex: RegExp(r'\brst\b', caseSensitive: false)),
    (canonical: 'ZR2', regex: RegExp(r'\bzr2\b', caseSensitive: false)),
    (canonical: 'Z71', regex: RegExp(r'\bz71\b', caseSensitive: false)),
    (canonical: 'AT4X', regex: RegExp(r'\bat4x\b', caseSensitive: false)),
    (canonical: 'AT4', regex: RegExp(r'\bat4\b', caseSensitive: false)),
    (canonical: 'Denali', regex: RegExp(r'\bdenali\b', caseSensitive: false)),
    (canonical: 'SLT', regex: RegExp(r'\bslt\b', caseSensitive: false)),
    (canonical: 'SLE', regex: RegExp(r'\bsle\b', caseSensitive: false)),
    (
      canonical: 'Elevation',
      regex: RegExp(r'\belevation\b', caseSensitive: false),
    ),
    (canonical: 'Laramie', regex: RegExp(r'\blaramie\b', caseSensitive: false)),
    (canonical: 'Rebel', regex: RegExp(r'\brebel\b', caseSensitive: false)),
    (
      canonical: 'Tradesman',
      regex: RegExp(r'\btradesman\b', caseSensitive: false),
    ),
    (canonical: 'TRX', regex: RegExp(r'\btrx\b', caseSensitive: false)),
    (canonical: 'Rubicon', regex: RegExp(r'\brubicon\b', caseSensitive: false)),
    (canonical: 'Sahara', regex: RegExp(r'\bsahara\b', caseSensitive: false)),
    (canonical: 'Willys', regex: RegExp(r'\bwillys\b', caseSensitive: false)),
    (
      canonical: 'Overland',
      regex: RegExp(r'\boverland\b', caseSensitive: false),
    ),
    (canonical: 'Summit', regex: RegExp(r'\bsummit\b', caseSensitive: false)),
    (canonical: 'Touring', regex: RegExp(r'\btouring\b', caseSensitive: false)),
    (
      canonical: 'Preferred',
      regex: RegExp(r'\bpreferred\b', caseSensitive: false),
    ),
    (canonical: 'SR5', regex: RegExp(r'\bsr5\b', caseSensitive: false)),
    (canonical: 'XSE', regex: RegExp(r'\bxse\b', caseSensitive: false)),
    (canonical: 'XLE', regex: RegExp(r'\bxle\b', caseSensitive: false)),
    (canonical: 'EX-L', regex: RegExp(r'\bex-l\b', caseSensitive: false)),
    (
      canonical: 'PRO-4X',
      regex: RegExp(r'\bpro[\s-]*4x\b', caseSensitive: false),
    ),
    (canonical: 'SV', regex: RegExp(r'\bsv\b', caseSensitive: false)),
    (canonical: 'SL', regex: RegExp(r'\bsl\b', caseSensitive: false)),
    (canonical: 'LT', regex: RegExp(r'\blt\b', caseSensitive: false)),
    (canonical: 'WT', regex: RegExp(r'\bwt\b', caseSensitive: false)),
    (canonical: 'LS', regex: RegExp(r'\bls\b', caseSensitive: false)),
    (canonical: 'GT', regex: RegExp(r'\bgt\b', caseSensitive: false)),
    (canonical: 'ST', regex: RegExp(r'\bst\b', caseSensitive: false)),
  ];

  static const List<String> _specificColors = [
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

  static const List<String> _basicColors = [
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

  static final List<({String label, RegExp regex, RegExp matchRegex})>
      _strictPackageRules = [
    (
      label: 'FX4 Off-Road',
      regex: RegExp(r'\bfx4\b', caseSensitive: false),
      matchRegex: RegExp(r'\bfx4\b', caseSensitive: false),
    ),
    (
      label: '301A Package',
      regex: RegExp(r'\b301a\b', caseSensitive: false),
      matchRegex: RegExp(r'\b301a\b', caseSensitive: false),
    ),
    (
      label: '302A Package',
      regex: RegExp(r'\b302a\b', caseSensitive: false),
      matchRegex: RegExp(r'\b302a\b', caseSensitive: false),
    ),
    (
      label: '303A Package',
      regex: RegExp(r'\b303a\b', caseSensitive: false),
      matchRegex: RegExp(r'\b303a\b', caseSensitive: false),
    ),
    (
      label: '501A Package',
      regex: RegExp(r'\b501a\b', caseSensitive: false),
      matchRegex: RegExp(r'\b501a\b', caseSensitive: false),
    ),
    (
      label: '502A Package',
      regex: RegExp(r'\b502a\b', caseSensitive: false),
      matchRegex: RegExp(r'\b502a\b', caseSensitive: false),
    ),
    (
      label: 'Black Appearance Package',
      regex: RegExp(r'\bblack\s+appearance\b', caseSensitive: false),
      matchRegex: RegExp(r'\bblack\s+appearance\b', caseSensitive: false),
    ),
    (
      label: 'Bed Utility Package',
      regex: RegExp(r'\bbed\s+utility\b', caseSensitive: false),
      matchRegex: RegExp(r'\bbed\s+utility\b', caseSensitive: false),
    ),
    (
      label: 'Max Tow / Tow-Haul',
      regex: RegExp(
        r'\b(?:max\s+(?:trailer\s+)?tow|tow\s*\/\s*haul)\b',
        caseSensitive: false,
      ),
      matchRegex: RegExp(
        r'\b(?:max\s+(?:trailer\s+)?tow|tow\s*\/\s*haul)\b',
        caseSensitive: false,
      ),
    ),
    (
      label: 'Pro Power Onboard',
      regex: RegExp(r'\bpro\s+power\b', caseSensitive: false),
      matchRegex: RegExp(r'\bpro\s+power\b', caseSensitive: false),
    ),
    (
      label: 'BlueCruise',
      regex: RegExp(r'\bblue\s*cruise\b', caseSensitive: false),
      matchRegex: RegExp(r'\bblue\s*cruise\b', caseSensitive: false),
    ),
  ];

  static List<String> splitClauses(String text) {
    if (text.trim().isEmpty) return const [];
    final protected = text.replaceAllMapped(
      RegExp(r'(\d)\.(\d)'),
      (m) => '${m.group(1)}__DEC__${m.group(2)}',
    );
    return protected
        .split(RegExp(r'[.,;\n•|]+'))
        .map((s) => s.replaceAll('__DEC__', '.').trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static bool isPreferenceClause(String clause) {
    return RegExp(
      r'\b(?:prefer(?:s|red)?|ideally|nice\s+to\s+have|optional|if\s+possible|bonus)\b',
      caseSensitive: false,
    ).hasMatch(clause);
  }

  static String extractBedLengthFromQuery(String rawText) {
    if (rawText.trim().isEmpty) return '';
    final s = rawText.toLowerCase();

    if (RegExp(
          r"\b(?:6\.75|6\.8|6[\s-]*3\/4)\s*(?:ft\.?|foot|feet|')?(?:\s*(?:pickup\s*)?(?:bed|box))?\b",
          caseSensitive: false,
        ).hasMatch(s) &&
        (RegExp(r"\b(?:bed|box|ft\.?|foot|feet|')\b", caseSensitive: false)
                .hasMatch(s) ||
            s.contains('3/4'))) {
      return "6.75'";
    }

    if (RegExp(
          r"\b(?:6\.5|6[\s-]*1\/2)\s*(?:ft\.?|foot|feet|')(?:\s*(?:pickup\s*)?(?:bed|box))?",
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(
          r'\b(?:6\.5|6[\s-]*1\/2)\s*(?:pickup\s*)?(?:bed|box)\b',
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(
          r'\b(?:bed|box)\s*(?:length\s*(?:of|:)?\s*)?(?:6\.5|6[\s-]*1\/2)\b',
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(
          r'\b157(?:\.\d+)?\s*(?:in\.?|inch(?:es)?|")?\s*(?:wb|wheelbase)\b',
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(
          r'\b78(?:\.9)?\s*(?:in\.?|inch(?:es)?|")\s*(?:bed|box)\b',
          caseSensitive: false,
        ).hasMatch(s)) {
      return "6.5'";
    }

    if (RegExp(
          r"\b(?:5\.5|5\.6|5\.7|5[\s-]*1\/2)\s*(?:ft\.?|foot|feet|')(?:\s*(?:pickup\s*)?(?:bed|box))?",
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(r'''\b5'\s*7"?\s*(?:bed|box)?''', caseSensitive: false)
            .hasMatch(s) ||
        RegExp(
          r'\b(?:5\.5|5[\s-]*1\/2)\s*(?:pickup\s*)?(?:bed|box)\b',
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(
          r'\b(?:bed|box)\s*(?:length\s*(?:of|:)?\s*)?(?:5\.5|5[\s-]*1\/2)\b',
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(r'\bshort\s+(?:pickup\s+)?(?:bed|box)\b', caseSensitive: false)
            .hasMatch(s)) {
      return "5.5'";
    }

    if (RegExp(
          r"\b8(?:\.0)?\s*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b",
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(
          r'\b8(?:\.0)?\s*(?:pickup\s*)?(?:bed|box)\b',
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(
          r"\b(?:bed|box)\s*(?:length\s*(?:of|:)?\s*)?8(?:\.0)?\s*(?:ft\.?|foot|feet|')?\b",
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(r'\blong\s+(?:pickup\s+)?(?:bed|box)\b', caseSensitive: false)
            .hasMatch(s) ||
        RegExp(
          r'\b9[678](?:\.\d+)?\s*(?:in\.?|inch(?:es)?|")\s*(?:bed|box)\b',
          caseSensitive: false,
        ).hasMatch(s)) {
      return "8'";
    }

    if (RegExp(
          r"\b5(?:\.0)?\s*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b",
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(r'\b5(?:\.0)?[\s-]*(?:ft|foot)\s*(?:bed|box)\b',
                caseSensitive: false)
            .hasMatch(s)) {
      return "5'";
    }

    if (RegExp(
          r"\b6(?:\.0)?\s*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b",
          caseSensitive: false,
        ).hasMatch(s) ||
        RegExp(r'\b6(?:\.0)?[\s-]*(?:ft|foot)\s*(?:bed|box)\b',
                caseSensitive: false)
            .hasMatch(s)) {
      return "6'";
    }

    return '';
  }

  static List<String> bedLengthToCosmosFacetValues(String bedLength) {
    final clean = bedLength.trim().replaceAll(RegExp(r"'$"), '');
    switch (clean) {
      case '5':
        return const ['5-ft bed'];
      case '5.5':
        return const ["5-1/2' Box", '5.5-Ft.'];
      case '6':
        return const ['6-ft bed'];
      case '6.5':
        return const ["6-1/2' Box"];
      case '6.75':
        return const ["6 3/4' Box"];
      case '8':
        return const ["8' Box"];
      default:
        return const [];
    }
  }

  static String formatBedLengthLabel(String bedLength) {
    if (bedLength.trim().isEmpty) return '';
    final clean = bedLength.trim().replaceAll(RegExp(r"'$"), '');
    return '$clean ft Bed';
  }

  static String extractBedLengthFromVehicle(
    Map<String, dynamic> v, {
    String fullCommentsClean = '',
    String facetBedLength = '',
  }) {
    if (facetBedLength.isNotEmpty) return facetBedLength;

    final existing = (v['bedLength']?.toString() ?? '').trim();
    if (existing.isNotEmpty) return existing;

    final title = (v['VehicleName'] ?? v['title'] ?? '').toString();
    final body =
        '${v['VehicleBodyStyle'] ?? v['bodyStyle'] ?? ''} ${v['VehicleBodyType'] ?? ''}';
    final rawHl = (v['VehicleHighlightsModel'] is Map)
        ? ((v['VehicleHighlightsModel'] as Map)['Highlights'] as List?)
        : (v['highlights'] as List?);
    final highlights =
        rawHl?.map((e) => e.toString()).join(' | ') ?? '';
    final text = '$title | $body | $highlights | $fullCommentsClean';

    if (RegExp(
          r"\b(?:6\.75|6[\s-]*3\/4)\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b",
          caseSensitive: false,
        ).hasMatch(text) ||
        RegExp(r"\b6\s+3\/4'\s*box\b", caseSensitive: false).hasMatch(text)) {
      return "6.75'";
    }

    if (RegExp(
          r"\b(?:6\.5|6[\s-]*1\/2)\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:styleside\s+|pickup\s+)?(?:bed|box)\b",
          caseSensitive: false,
        ).hasMatch(text) ||
        RegExp(r"\b6-1\/2'\s*box\b", caseSensitive: false).hasMatch(text)) {
      return "6.5'";
    }

    if (RegExp(
          r"\b(?:5\.5|5[\s-]*1\/2)\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:styleside\s+|pickup\s+)?(?:bed|box)\b",
          caseSensitive: false,
        ).hasMatch(text) ||
        RegExp(r'''\b5'\s*7"?\s*(?:pickup\s*)?(?:bed|box)\b''',
                caseSensitive: false)
            .hasMatch(text) ||
        RegExp(r"\b5-1\/2'\s*box\b", caseSensitive: false).hasMatch(text)) {
      return "5.5'";
    }

    if (RegExp(
          r"\b8(?:\.0)?\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:styleside\s+|pickup\s+)?(?:bed|box)\b",
          caseSensitive: false,
        ).hasMatch(text) ||
        RegExp(r"\b8'\s*box\b", caseSensitive: false).hasMatch(text)) {
      return "8'";
    }

    if (RegExp(
      r"\b5(?:\.0)?\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b",
      caseSensitive: false,
    ).hasMatch(text)) {
      return "5'";
    }

    if (RegExp(
      r"\b6(?:\.0)?\s*(?:-|\s)*(?:ft\.?|foot|feet|')\s*(?:pickup\s*)?(?:bed|box)\b",
      caseSensitive: false,
    ).hasMatch(text)) {
      return "6'";
    }

    final modelStr =
        '${v['VehicleModel'] ?? v['model'] ?? ''} $title'.toLowerCase();
    final isF150 = RegExp(r'\bf[\s+-]*150\b').hasMatch(modelStr) &&
        !modelStr.contains('lightning');
    final cab = extractCabStyleFromText('$body $title $fullCommentsClean');

    if (isF150) {
      if (RegExp(
        r'\b157(?:\.\d+)?[\s-]*(?:in\.?|inch(?:es)?|")\s*(?:wb|wheelbase)\b',
        caseSensitive: false,
      ).hasMatch(text)) {
        return "6.5'";
      }
      if (cab == 'Crew Cab' &&
          RegExp(
            r'\b145(?:\.\d+)?[\s-]*(?:in\.?|inch(?:es)?|")\s*(?:wb|wheelbase)\b',
            caseSensitive: false,
          ).hasMatch(text)) {
        return "5.5'";
      }

      final rawLen = v['Length'] ?? v['vehicleLength'];
      final lenNum = rawLen is num
          ? rawLen.toDouble()
          : (double.tryParse(rawLen?.toString() ?? '') ?? 0.0);
      if (lenNum > 0) {
        if (cab == 'Regular Cab') {
          if (lenNum >= 207 && lenNum <= 212) return "6.5'";
          if (lenNum >= 225 && lenNum <= 230) return "8'";
        } else if (cab == 'SuperCab') {
          if (lenNum >= 229 && lenNum <= 235) return "6.5'";
          if (lenNum >= 248 && lenNum <= 253) return "8'";
        }
      }
    }

    return '';
  }

  static String extractCabStyleFromText(String rawText) {
    if (rawText.trim().isEmpty) return '';
    if (RegExp(
      r'\b(?:super\s*crew|crew\s*cab|crewcab|crewmax|megacab|mega\s+cab)\b',
      caseSensitive: false,
    ).hasMatch(rawText)) {
      return 'Crew Cab';
    }
    if (RegExp(
      r'\b(?:super\s*cab|extended\s*cab|ext\.?\s*cab|double\s*cab|quad\s*cab|king\s*cab|\bx[12][a-z]\b)\b',
      caseSensitive: false,
    ).hasMatch(rawText)) {
      return 'SuperCab';
    }
    if (RegExp(
      r'\b(?:regular\s*cab|reg\.?\s*cab|single\s*cab|standard\s*cab)\b',
      caseSensitive: false,
    ).hasMatch(rawText)) {
      return 'Regular Cab';
    }
    return '';
  }

  static String extractEngineSpecFromText(String rawText) {
    if (rawText.trim().isEmpty) return '';
    final dispMatch = RegExp(
      r'\b(2\.0|2\.3|2\.5|2\.7|3\.0|3\.3|3\.5|3\.6|5\.0|5\.3|5\.7|6\.2|6\.4|6\.6|6\.7|6\.8|7\.3)\s*l?\b',
      caseSensitive: false,
    ).firstMatch(rawText);
    if (dispMatch != null &&
        RegExp(
          r'\b(?:\d\.\d\s*l|v[68]|ecoboost|powerboost|power\s*stroke|diesel|engine|hemi|godzilla|duramax|cummins)\b',
          caseSensitive: false,
        ).hasMatch(rawText)) {
      return '${dispMatch.group(1)}L';
    }
    if (RegExp(r'\b(?:power\s*boost|full\s+hybrid|\bhybrid\b)\b',
            caseSensitive: false)
        .hasMatch(rawText)) {
      return 'Hybrid';
    }
    if (RegExp(r'\b(?:diesel|power\s*stroke|duramax|cummins)\b',
            caseSensitive: false)
        .hasMatch(rawText)) {
      return 'Diesel';
    }
    if (RegExp(r'\b(?:plug[\s-]*in\s+hybrid|\bphev\b)\b', caseSensitive: false)
        .hasMatch(rawText)) {
      return 'PHEV';
    }
    if (RegExp(r'\becoboost\b', caseSensitive: false).hasMatch(rawText)) {
      return 'EcoBoost';
    }
    if (RegExp(r'\bv8\b|\b8[\s-]*cyl(?:inder)?\b', caseSensitive: false)
        .hasMatch(rawText)) {
      return 'V8';
    }
    if (RegExp(r'\bv6\b|\b6[\s-]*cyl(?:inder)?\b', caseSensitive: false)
        .hasMatch(rawText)) {
      return 'V6';
    }
    return '';
  }

  static List<String> parseExteriorColors(Object? rawColors) {
    final rawItems = rawColors is List
        ? rawColors.map((c) => c?.toString() ?? '').toList()
        : <String>[rawColors?.toString() ?? ''];

    final seen = <String>{};
    final result = <String>[];

    for (final rawItem in rawItems) {
      final parts = rawItem
          .split(RegExp(r'[,;|/]+|\b(?:or|and)\b', caseSensitive: false))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);

      for (final p in parts) {
        final lower = p.toLowerCase();
        if (lower == 'any' || lower == 'any color' || lower == 'all') continue;
        final canonical = lower == 'grey'
            ? 'Gray'
            : p
                .split(RegExp(r'\s+'))
                .where((w) => w.isNotEmpty)
                .map(
                  (w) => '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}',
                )
                .join(' ');
        final key = canonical.toLowerCase();
        if (seen.add(key)) {
          result.add(canonical);
        }
      }
    }

    return result;
  }

  static String _extractColorFromStrictNotes(String strictText) {
    if (strictText.trim().isEmpty) return '';
    var cleaned = strictText.toLowerCase().replaceAll(
          RegExp(
            r'\b(?:black\s+appearance|black\s+label|black\s+widow|black\s+diamond|blue\s*cruise|blue\s+advantage|gold\s+certified|silver\s+certified|red\s+carpet|green\s+vehicle|dark\s+horse|dark\s+slate|medium\s+dark\s+slate|black\s+interior|gray\s+interior|tan\s+interior)\b',
            caseSensitive: false,
          ),
          ' ',
        );

    final found = <String>[];
    final seenLower = <String>{};

    for (final sc in _specificColors) {
      if (cleaned.contains(sc)) {
        final formatted = sc
            .split(' ')
            .map((w) => '${w[0].toUpperCase()}${w.substring(1)}')
            .join(' ');
        if (seenLower.add(formatted.toLowerCase())) {
          found.add(formatted);
        }
        cleaned = cleaned.replaceAll(sc, ' ');
      }
    }
    for (final bc in _basicColors) {
      if (RegExp('\\b$bc\\b', caseSensitive: false).hasMatch(cleaned)) {
        final normalized =
            bc == 'grey' ? 'Gray' : '${bc[0].toUpperCase()}${bc.substring(1)}';
        if (seenLower.add(normalized.toLowerCase())) {
          found.add(normalized);
        }
      }
    }
    return found.join(', ');
  }

  static String _canonicalizeKnownMake(String rawMake) {
    final s = rawMake.trim();
    if (s.isEmpty) return '';
    final lower = s.toLowerCase();
    for (final entry in knownMakes.entries) {
      if (entry.key.toLowerCase() == lower || entry.value.contains(lower)) {
        return entry.key;
      }
    }
    return '';
  }

  static double? _parseSafeDouble(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    final cleaned = raw.toString().replaceAll(RegExp(r'[^0-9.\-]'), '').trim();
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  static int? _parseSafeInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    final cleaned = raw.toString().replaceAll(RegExp(r'[^0-9\-]'), '').trim();
    if (cleaned.isEmpty) return null;
    return int.tryParse(cleaned) ?? _parseSafeDouble(raw)?.round();
  }

  static ({String make, String model}) normalizeModelInput(
    String rawMake,
    String rawModel,
  ) {
    final cleanMake = rawMake.trim();
    final cleanModel = rawModel.trim();
    final exactMake = _canonicalizeKnownMake(cleanMake);

    if (cleanModel.isEmpty) {
      if (exactMake.isNotEmpty) return (make: exactMake, model: '');
      if (cleanMake.isNotEmpty) {
        for (final entry in _modelPatterns) {
          if (entry.regex.hasMatch(cleanMake)) {
            return (make: entry.make, model: entry.model);
          }
        }
      }
      return (make: cleanMake, model: '');
    }

    for (final entry in _modelPatterns) {
      if (entry.regex.hasMatch(cleanModel)) {
        return (
          make: exactMake.isNotEmpty
              ? exactMake
              : (entry.make.isNotEmpty ? entry.make : cleanMake),
          model: entry.model,
        );
      }
    }
    return (
      make: exactMake.isNotEmpty ? exactMake : cleanMake,
      model: cleanModel,
    );
  }

  static String extractTrimFromText(String text, {String currentModel = ''}) {
    if (text.trim().isEmpty) return '';
    var working = text;
    if (currentModel.trim().isNotEmpty) {
      final escaped = RegExp.escape(currentModel)
          .replaceAll(RegExp(r'[\s\\-]+'), r'[\s+-]*');
      working = working.replaceAll(
        RegExp('\\b$escaped\\b', caseSensitive: false),
        ' ',
      );
    }
    for (final tp in _trimPatterns) {
      if (tp.regex.hasMatch(working)) {
        return tp.canonical;
      }
    }
    return '';
  }

  static ({int? minYear, int? maxYear}) _extractYearRange(String text) {
    if (text.trim().isEmpty) return (minYear: null, maxYear: null);
    final rangeMatch = RegExp(
      r'\b(20[12]\d)\s*(?:-|–|—|to|through|thru)\s*(20[12]\d)\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (rangeMatch != null) {
      final y1 = int.parse(rangeMatch.group(1)!);
      final y2 = int.parse(rangeMatch.group(2)!);
      return (
        minYear: y1 < y2 ? y1 : y2,
        maxYear: y1 > y2 ? y1 : y2,
      );
    }

    final minPlus = RegExp(
      r'\b(20[12]\d)\s*(?:\+|or\s+newer|and\s+newer|and\s+up|up)\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (minPlus != null) {
      return (minYear: int.parse(minPlus.group(1)!), maxYear: null);
    }

    final single = RegExp(r'\b(20[12]\d)\b').firstMatch(text);
    if (single != null) {
      final yr = int.parse(single.group(1)!);
      return (minYear: yr, maxYear: yr);
    }

    return (minYear: null, maxYear: null);
  }

  static int? _extractMaxMileage(String text) {
    if (text.trim().isEmpty) return null;
    final m = RegExp(
      r'(?:under|below|less\s+than|max|up\s+to|<=?)\s*(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)\s*(k)?\s*(?:miles?|mi\.?)\b|\b(\d{1,3}(?:,\d{3})+|\d+)\s*(k)\s*(?:miles?|mi\.?)\b',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return null;
    if (m.group(1) != null) {
      var v = double.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0.0;
      if (m.group(2) != null || v < 500) v *= 1000.0;
      return v > 0 ? v.round() : null;
    }
    if (m.group(3) != null) {
      final v =
          (double.tryParse(m.group(3)!.replaceAll(',', '')) ?? 0.0) * 1000.0;
      return v > 0 ? v.round() : null;
    }
    return null;
  }

  static Map<String, dynamic> parseCriteriaMap(Map<String, dynamic> raw) {
    final featuresList = (raw['features'] as List<dynamic>? ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final rawNotes = (raw['notes']?.toString() ?? '').trim();
    final combinedRaw = '$rawNotes ${featuresList.join(' ')}'.trim();

    final clauses = splitClauses(rawNotes);
    final strictClauses = clauses.where((c) => !isPreferenceClause(c)).toList();
    final preferenceClauses = clauses.where(isPreferenceClause).toList();
    final strictNotes = strictClauses.join(' ; ');
    final strictCombined = '$strictNotes ${featuresList.join(' ')}'.trim();
    final lowerAll = combinedRaw.toLowerCase();
    final lowerStrict = strictCombined.toLowerCase();

    var (:make, :model) = normalizeModelInput(
      raw['make']?.toString() ?? '',
      raw['model']?.toString() ?? '',
    );

    if (make.isEmpty && lowerAll.isNotEmpty) {
      for (final entry in knownMakes.entries) {
        final hit = entry.value.any((alias) {
          final pattern = alias.replaceAll('-', r'[-\s]?');
          return RegExp('\\b$pattern\\b', caseSensitive: false)
              .hasMatch(lowerAll);
        });
        if (hit) {
          make = entry.key;
          break;
        }
      }
    }

    if (model.isEmpty && combinedRaw.isNotEmpty) {
      for (final candidateText
          in [strictCombined, combinedRaw].where((s) => s.isNotEmpty)) {
        for (final entry in _modelPatterns) {
          if (make.isNotEmpty &&
              entry.make.toLowerCase() != make.toLowerCase()) {
            continue;
          }
          if (entry.regex.hasMatch(candidateText)) {
            model = entry.model;
            if (make.isEmpty) make = entry.make;
            break;
          }
        }
        if (model.isNotEmpty) break;
      }
      if (model.isEmpty) {
        for (final entry in _modelPatterns) {
          if (entry.regex.hasMatch(combinedRaw)) {
            model = entry.model;
            if (make.isEmpty) make = entry.make;
            break;
          }
        }
      }
    }

    String trim = (raw['trim']?.toString() ?? '').trim();
    if (trim.isNotEmpty) {
      final canonicalTrim = extractTrimFromText(trim, currentModel: model);
      if (canonicalTrim.isNotEmpty &&
          canonicalTrim.toLowerCase() == trim.toLowerCase()) {
        trim = canonicalTrim;
      }
    } else {
      final inlineMakeModel =
          '${raw['make'] ?? ''} ${raw['model'] ?? ''}'.trim();
      if (inlineMakeModel.isNotEmpty) {
        trim = extractTrimFromText(inlineMakeModel, currentModel: model);
      }
      if (trim.isEmpty && strictCombined.isNotEmpty) {
        trim = extractTrimFromText(strictCombined, currentModel: model);
      }
    }

    final explicitBed = (raw['bedLength']?.toString() ?? '').trim();
    final bedLength = explicitBed.isNotEmpty
        ? explicitBed
        : (extractBedLengthFromQuery(strictCombined).isNotEmpty
            ? extractBedLengthFromQuery(strictCombined)
            : extractBedLengthFromQuery(combinedRaw));

    final explicitCab = (raw['cabStyle']?.toString() ?? '').trim();
    final cabStyle = explicitCab.isNotEmpty
        ? explicitCab
        : extractCabStyleFromText(strictCombined);

    final explicitEngine = (raw['engineSpec']?.toString() ?? '').trim();
    final engineSpec = explicitEngine.isNotEmpty
        ? explicitEngine
        : extractEngineSpecFromText(strictNotes);

    double? maxPrice = _parseSafeDouble(raw['maxPrice']);
    if (maxPrice != null && maxPrice <= 0) maxPrice = null;
    if (maxPrice != null && maxPrice > 0 && maxPrice < 500) {
      maxPrice = maxPrice * 1000.0;
    }
    if (maxPrice == null && combinedRaw.isNotEmpty) {
      final budgetReg = RegExp(
        r'(?:under|below|max|up\s+to|less\s+than|around|budget(?:\s+of)?|<=?)\s*\$?\s*(\d+(?:,\d{3})*(?:\.\d+)?)\s*(k|thousand)?\b|\$\s*(\d+(?:,\d{3})*(?:\.\d+)?)\s*(k|thousand)\b|\$\s*(\d{1,3}(?:,\d{3})+)\b',
        caseSensitive: false,
      );
      final m = budgetReg.firstMatch(combinedRaw);
      if (m != null) {
        if (m.group(1) != null) {
          var val = double.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0.0;
          if (m.group(2) != null || (val > 0 && val < 500)) val *= 1000.0;
          if (val >= 1000) maxPrice = val;
        } else if (m.group(3) != null) {
          final val =
              (double.tryParse(m.group(3)!.replaceAll(',', '')) ?? 0.0) *
                  1000.0;
          if (val >= 1000) maxPrice = val;
        } else if (m.group(5) != null) {
          final val = double.tryParse(m.group(5)!.replaceAll(',', '')) ?? 0.0;
          if (val >= 1000) maxPrice = val;
        }
      }
    }

    int? minYear = _parseSafeInt(raw['minYear']);
    int? maxYear = _parseSafeInt(raw['maxYear']);
    if (minYear != null && minYear <= 0) minYear = null;
    if (maxYear != null && maxYear <= 0) maxYear = null;
    if (minYear == null && maxYear == null && strictNotes.isNotEmpty) {
      final yr = _extractYearRange(strictNotes);
      minYear = yr.minYear;
      maxYear = yr.maxYear;
    }

    int? maxMileage = _parseSafeInt(raw['maxMileage']);
    if (maxMileage != null && maxMileage <= 0) maxMileage = null;
    if (maxMileage == null && combinedRaw.isNotEmpty) {
      maxMileage = _extractMaxMileage(combinedRaw);
    }

    String condition = (raw['condition']?.toString() ?? 'Any').trim();
    if (condition.isEmpty) condition = 'Any';
    if (condition == 'Any' && lowerStrict.isNotEmpty) {
      final hasMixed = RegExp(
        r'\bnew\s+(?:or|and)\s+(?:used|pre-?owned)\b|\b(?:pre-?owned|used)\s+or\s+cpo\b',
        caseSensitive: false,
      ).hasMatch(lowerStrict);
      if (!hasMixed) {
        if (RegExp(r'\bcpo\b|\bcertified\s+pre-?owned\b', caseSensitive: false)
            .hasMatch(lowerStrict)) {
          condition = 'CPO';
        } else if (RegExp(r'\b(?:pre-?owned|used)\b', caseSensitive: false)
            .hasMatch(lowerStrict)) {
          condition = 'Pre-Owned';
        } else if (RegExp(r'\bnew\b', caseSensitive: false)
                .hasMatch(lowerStrict) &&
            !RegExp(r'\blike\s+new\b', caseSensitive: false)
                .hasMatch(lowerStrict)) {
          condition = 'New';
        }
      }
    }

    String drivetrain = (raw['drivetrain']?.toString() ?? 'Any').trim();
    if (drivetrain.isEmpty) drivetrain = 'Any';
    if (drivetrain == 'Any' && lowerStrict.isNotEmpty) {
      if (RegExp(
        r'\b(?:4wd|4x4|four[\s-]wheel[\s-]drive|4[\s-]wheel[\s-]drive)\b',
        caseSensitive: false,
      ).hasMatch(lowerStrict)) {
        drivetrain = '4WD';
      } else if (RegExp(
        r'\b(?:awd|all[\s-]wheel[\s-]drive)\b',
        caseSensitive: false,
      ).hasMatch(lowerStrict)) {
        drivetrain = 'AWD';
      } else if (RegExp(
        r'\b(?:rwd|2wd|4x2|rear[\s-]wheel[\s-]drive)\b',
        caseSensitive: false,
      ).hasMatch(lowerStrict)) {
        drivetrain = 'RWD';
      } else if (RegExp(
        r'\b(?:fwd|front[\s-]wheel[\s-]drive)\b',
        caseSensitive: false,
      ).hasMatch(lowerStrict)) {
        drivetrain = 'FWD';
      }
    }

    final explicitColors = parseExteriorColors(
      (raw['exteriorColors'] is List &&
              (raw['exteriorColors'] as List).isNotEmpty)
          ? raw['exteriorColors']
          : raw['exteriorColor'],
    );
    final parsedNoteColors =
        explicitColors.isEmpty && strictNotes.isNotEmpty
            ? parseExteriorColors(_extractColorFromStrictNotes(strictNotes))
            : const <String>[];
    final exteriorColors =
        explicitColors.isNotEmpty ? explicitColors : parsedNoteColors;
    final exteriorColor = exteriorColors.join(', ');

    final locationHints =
        locationKeywords.where((loc) => lowerAll.contains(loc)).toList();
    final strictPackages = _strictPackageRules
        .where((r) => r.regex.hasMatch(strictCombined))
        .map((r) => r.label)
        .toList();

    return <String, dynamic>{
      ...raw,
      'condition': condition,
      'minYear': minYear,
      'maxYear': maxYear,
      'make': make,
      'model': model,
      'trim': trim,
      'bedLength': bedLength,
      'cabStyle': cabStyle,
      'engineSpec': engineSpec,
      'maxPrice': maxPrice,
      'maxMileage': maxMileage,
      'drivetrain': drivetrain,
      'exteriorColor': exteriorColor,
      'exteriorColors': exteriorColors,
      'features': featuresList,
      'notes': rawNotes,
      'locationHints': locationHints,
      'strictPackages': strictPackages,
      'preferenceClauses': preferenceClauses,
    };
  }

  /// Builds human-readable chips describing what criteria the app understood
  /// from the natural language field + form inputs for live UI preview.
  static List<String> buildPreviewChips(Map<String, dynamic> raw) {
    final parsed = parseCriteriaMap(raw);
    final chips = <String>[];

    final cond = parsed['condition']?.toString() ?? 'Any';
    if (cond.isNotEmpty && cond != 'Any') {
      chips.add('Condition: $cond');
    }
    final minY = parsed['minYear'] as int?;
    final maxY = parsed['maxYear'] as int?;
    if (minY != null && maxY != null) {
      chips.add('Year: ${minY == maxY ? '$minY' : '$minY–$maxY'}');
    } else if (minY != null) {
      chips.add('Year: $minY+');
    } else if (maxY != null) {
      chips.add('Year: Up to $maxY');
    }

    final make = parsed['make']?.toString() ?? '';
    if (make.isNotEmpty) chips.add('Make: $make');

    final model = parsed['model']?.toString() ?? '';
    if (model.isNotEmpty) chips.add('Model: $model');

    final trim = parsed['trim']?.toString() ?? '';
    if (trim.isNotEmpty) chips.add('Trim: $trim');

    final bed = parsed['bedLength']?.toString() ?? '';
    if (bed.isNotEmpty) chips.add('Bed: ${formatBedLengthLabel(bed)}');

    final cab = parsed['cabStyle']?.toString() ?? '';
    if (cab.isNotEmpty) chips.add('Cab: $cab');

    final dt = parsed['drivetrain']?.toString() ?? 'Any';
    if (dt.isNotEmpty && dt != 'Any') chips.add('Drivetrain: $dt');

    final engine = parsed['engineSpec']?.toString() ?? '';
    if (engine.isNotEmpty) chips.add('Engine: $engine');

    final colorsList = parseExteriorColors(parsed['exteriorColors'] ?? parsed['exteriorColor']);
    if (colorsList.length == 1) {
      chips.add('Color: ${colorsList.first}');
    } else if (colorsList.length > 1) {
      chips.add('Colors: ${colorsList.join(', ')}');
    }

    final maxP = parsed['maxPrice'] as double?;
    if (maxP != null && maxP > 0) {
      chips.add('Max Price: \$${maxP.toStringAsFixed(0)}');
    }

    final maxMi = parsed['maxMileage'] as int?;
    if (maxMi != null && maxMi > 0) {
      chips.add('Max Miles: $maxMi mi');
    }

    final pkgs = (parsed['strictPackages'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
    for (final p in pkgs) {
      chips.add(p);
    }

    return chips;
  }

  static List<String> expandPrestonModelVariants(String make, String model) {
    final m = model.trim();
    if (m.isEmpty) return const [];
    final variants = <String>{m};

    final sd =
        RegExp(r'^f[\s-]*([2345]50)$', caseSensitive: false).firstMatch(m);
    if (sd != null) {
      final num = sd.group(1)!;
      variants.add('F-$num');
      variants.add('Super Duty F-$num');
      variants.add('Super Duty F-$num SRW');
      variants.add('Super Duty F-$num DRW');
      variants.add('F-$num Super Duty');
    } else if (RegExp(r'^f[\s-]*150$', caseSensitive: false).hasMatch(m)) {
      variants.add('F-150');
    } else if (RegExp(r'^(?:mustang\s+)?mach[\s-]*e$', caseSensitive: false)
        .hasMatch(m)) {
      variants.add('Mustang Mach-E');
    } else if (RegExp(r'^cx[\s-]*(\d+)$', caseSensitive: false).hasMatch(m)) {
      final num = RegExp(r'\d+').firstMatch(m)!.group(0)!;
      variants.add('CX-$num');
      variants.add('Mazda CX-$num');
    } else if (RegExp(r'^mazda\s*3$', caseSensitive: false).hasMatch(m)) {
      variants.add('Mazda3');
      variants.add('Mazda3 Sedan');
      variants.add('Mazda3 Hatchback');
    } else if (RegExp(r'^(?:mx[\s-]*5(?:\s+miata)?|miata)$',
            caseSensitive: false)
        .hasMatch(m)) {
      variants.add('Mazda MX-5 Miata');
      variants.add('Mazda MX-5 Miata RF');
    } else if (make.toLowerCase() == 'ram' &&
        RegExp(r'^(1500|2500|3500)$').hasMatch(m)) {
      variants.add(m);
      variants.add('Ram $m');
    } else if (RegExp(r'^silverado\s*2500', caseSensitive: false).hasMatch(m)) {
      variants.add('Silverado 2500 HD');
      variants.add('Silverado 2500HD');
    }

    return variants.toList();
  }

  static String _compactAlnum(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

  static bool doesVehicleMatchModel(
    String targetModel,
    Map<String, dynamic> vehicle,
  ) {
    final cleanTarget = targetModel.trim();
    if (cleanTarget.isEmpty) return true;

    final vModel = (vehicle['model']?.toString() ?? '').trim();
    final vTitle = (vehicle['title']?.toString() ?? '').trim();
    final combinedLower = '$vModel $vTitle'.toLowerCase();
    final targetLower = cleanTarget.toLowerCase();

    if (targetLower == 'bronco' &&
        RegExp(r'\bbronco\s+sport\b', caseSensitive: false)
            .hasMatch(combinedLower)) {
      return false;
    }
    if (targetLower == 'mustang' &&
        RegExp(r'\bmach[\s-]*e\b', caseSensitive: false)
            .hasMatch(combinedLower)) {
      return false;
    }
    if (targetLower == 'cherokee' &&
        RegExp(r'\bgrand\s+cherokee\b', caseSensitive: false)
            .hasMatch(combinedLower)) {
      return false;
    }
    if (targetLower == 'grand cherokee' &&
        RegExp(r'\bgrand\s+cherokee\s+l\b', caseSensitive: false)
            .hasMatch(combinedLower)) {
      return false;
    }
    if (targetLower == 'wagoneer' &&
        RegExp(r'\bgrand\s+wagoneer\b', caseSensitive: false)
            .hasMatch(combinedLower)) {
      return false;
    }
    if (targetLower == 'corolla' &&
        RegExp(r'\bcorolla\s+cross\b', caseSensitive: false)
            .hasMatch(combinedLower)) {
      return false;
    }
    if (targetLower == 'highlander' &&
        RegExp(r'\bgrand\s+highlander\b', caseSensitive: false)
            .hasMatch(combinedLower)) {
      return false;
    }
    if (RegExp(r'^f[\s-]*150$', caseSensitive: false).hasMatch(cleanTarget) &&
        RegExp(r'\blightning\b', caseSensitive: false)
            .hasMatch(combinedLower)) {
      return false;
    }

    final fMatch = RegExp(r'^f[\s-]*(\d{3})$', caseSensitive: false)
        .firstMatch(cleanTarget);
    if (fMatch != null) {
      final num = fMatch.group(1)!;
      return RegExp('\\bf[\\s+-]*$num\\b', caseSensitive: false)
          .hasMatch(combinedLower);
    }

    final cxMatch = RegExp(r'^cx[\s-]*(\d+)$', caseSensitive: false)
        .firstMatch(cleanTarget);
    if (cxMatch != null) {
      final num = cxMatch.group(1)!;
      return RegExp('\\bcx[\\s-]*$num\\b', caseSensitive: false)
          .hasMatch(combinedLower);
    }

    final normTokens = cleanTarget
        .toLowerCase()
        .replaceAll(RegExp(r'[-+]'), ' ')
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    final hayWords = combinedLower.replaceAll(RegExp(r'[-+®™]'), ' ');
    final allBounded = normTokens.every(
      (tok) => RegExp('\\b${RegExp.escape(tok)}\\b', caseSensitive: false)
          .hasMatch(hayWords),
    );
    if (allBounded) return true;

    final targetCompact = _compactAlnum(cleanTarget);
    final vModelCompact = _compactAlnum(vModel);
    if (targetCompact.length >= 3 && vModelCompact == targetCompact) {
      return true;
    }

    return false;
  }

  static bool doesVehicleMatchTrim(
    String targetTrim,
    Map<String, dynamic> vehicle,
  ) {
    final cleanTrim = targetTrim.replaceAll(RegExp(r'[®™]'), '').trim();
    if (cleanTrim.isEmpty) return true;

    final vTrimClean =
        (vehicle['trim']?.toString() ?? '').replaceAll(RegExp(r'[®™]'), '').trim();
    final vTitleClean =
        (vehicle['title']?.toString() ?? '').replaceAll(RegExp(r'[®™]'), '').trim();

    final escaped = RegExp.escape(cleanTrim)
        .replaceAll(RegExp(r'[\s\\-]+'), r'[\s-]+');
    final boundaryRegex =
        RegExp('\\b$escaped\\b(?![-\\w])', caseSensitive: false);

    if (vTrimClean.isNotEmpty) {
      return boundaryRegex.hasMatch(vTrimClean) ||
          boundaryRegex.hasMatch(vTitleClean);
    }
    return boundaryRegex.hasMatch(vTitleClean);
  }

  static bool doesVehicleMatchCabStyle(
    String targetCabStyle,
    Map<String, dynamic> vehicle,
  ) {
    if (targetCabStyle.trim().isEmpty) return true;
    final existingCab = (vehicle['cabStyle']?.toString() ?? '').trim();
    final vCab = existingCab.isNotEmpty
        ? existingCab
        : extractCabStyleFromText(
            '${vehicle['bodyStyle'] ?? ''} ${vehicle['title'] ?? ''} ${vehicle['commentsSummary'] ?? ''}',
          );
    return vCab == targetCabStyle;
  }

  static bool doesVehicleMatchEngine(
    String targetEngineSpec,
    Map<String, dynamic> vehicle,
  ) {
    if (targetEngineSpec.trim().isEmpty) return true;
    final hl = (vehicle['highlights'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .join(' ');
    final hay =
        '${vehicle['engine'] ?? ''} ${vehicle['fuelType'] ?? ''} ${vehicle['title'] ?? ''} $hl ${vehicle['fullCommentsSearchText'] ?? vehicle['commentsSummary'] ?? ''}'
            .toLowerCase();

    final spec = targetEngineSpec.trim().toLowerCase();
    if (spec == 'v8') {
      return RegExp(
        r'\bv8\b|\b8\s*cylinder\b|\b5\.0\s*l?\b|\b7\.3\s*l?\b|\b6\.8\s*l?\b|\b6\.2\s*l?\b',
        caseSensitive: false,
      ).hasMatch(hay);
    }
    if (spec == 'v6') {
      return RegExp(
        r'\bv6\b|\b6\s*cylinder\b|\b3\.5\s*l?\b|\b2\.7\s*l?\b|\becoboost\b',
        caseSensitive: false,
      ).hasMatch(hay);
    }
    if (spec == 'diesel') {
      return RegExp(
        r'\bdiesel\b|\bpower\s*stroke\b|\bduramax\b|\bcummins\b|\b6\.7\s*l?\b',
        caseSensitive: false,
      ).hasMatch(hay);
    }
    if (spec == 'hybrid') {
      return RegExp(r'\bhybrid\b|\bpower\s*boost\b', caseSensitive: false)
          .hasMatch(hay);
    }
    if (spec == 'phev') {
      return RegExp(r'\bplug[\s-]*in\s+hybrid\b|\bphev\b', caseSensitive: false)
          .hasMatch(hay);
    }
    if (spec == 'ecoboost') {
      return RegExp(r'\becoboost\b|\bturbo\b|\bv6\s+cylinder\b',
              caseSensitive: false)
          .hasMatch(hay);
    }
    if (spec.endsWith('l')) {
      final num = spec.substring(0, spec.length - 1).replaceAll('.', r'\.');
      return RegExp('\\b$num\\s*l?\\b', caseSensitive: false).hasMatch(hay);
    }
    return hay.contains(spec);
  }

  static bool _doesSingleColorMatchVehicle(
    String singleColorLower,
    String vColorLower,
  ) {
    if (singleColorLower.isEmpty) return true;
    if (singleColorLower == 'gray' || singleColorLower == 'grey') {
      return vColorLower.contains('gray') ||
          vColorLower.contains('grey') ||
          vColorLower.contains('slate') ||
          vColorLower.contains('magnetic') ||
          vColorLower.contains('carbonized') ||
          vColorLower.contains('charcoal') ||
          vColorLower.contains('graphite');
    }
    if (singleColorLower == 'white') {
      return vColorLower.contains('white') ||
          vColorLower.contains('ivory') ||
          vColorLower.contains('pearl') ||
          vColorLower.contains('oxford');
    }
    if (singleColorLower == 'black') {
      return vColorLower.contains('black') ||
          vColorLower.contains('ebony') ||
          vColorLower.contains('onyx') ||
          vColorLower.contains('obsidian') ||
          vColorLower.contains('agate');
    }
    if (singleColorLower == 'silver') {
      return vColorLower.contains('silver') ||
          vColorLower.contains('ingot') ||
          vColorLower.contains('billet') ||
          vColorLower.contains('aluminum');
    }
    if (singleColorLower == 'blue') {
      return vColorLower.contains('blue') ||
          vColorLower.contains('navy') ||
          vColorLower.contains('azure') ||
          vColorLower.contains('cobalt') ||
          vColorLower.contains('sapphire') ||
          vColorLower.contains('antimatter') ||
          vColorLower.contains('velocity');
    }
    if (singleColorLower == 'red') {
      return vColorLower.contains('red') ||
          vColorLower.contains('crimson') ||
          vColorLower.contains('ruby') ||
          vColorLower.contains('scarlet') ||
          vColorLower.contains('maroon') ||
          vColorLower.contains('burgundy');
    }
    if (singleColorLower == 'burgundy') {
      return vColorLower.contains('burgundy') ||
          vColorLower.contains('maroon') ||
          vColorLower.contains('crimson') ||
          vColorLower.contains('wine') ||
          vColorLower.contains('merlot');
    }
    if (singleColorLower == 'green') {
      return vColorLower.contains('green') ||
          vColorLower.contains('olive') ||
          vColorLower.contains('emerald') ||
          vColorLower.contains('forest') ||
          vColorLower.contains('sage') ||
          vColorLower.contains('eruption');
    }
    if (singleColorLower == 'brown') {
      return vColorLower.contains('brown') ||
          vColorLower.contains('bronze') ||
          vColorLower.contains('copper') ||
          vColorLower.contains('mocha') ||
          vColorLower.contains('espresso') ||
          vColorLower.contains('kodiak') ||
          vColorLower.contains('mahogany');
    }
    if (singleColorLower == 'tan') {
      return vColorLower.contains('tan') ||
          vColorLower.contains('beige') ||
          vColorLower.contains('sand') ||
          vColorLower.contains('dune') ||
          vColorLower.contains('cashmere') ||
          vColorLower.contains('terrain');
    }
    if (singleColorLower == 'gold') {
      return vColorLower.contains('gold') ||
          vColorLower.contains('champagne') ||
          vColorLower.contains('amber');
    }
    return vColorLower.contains(singleColorLower);
  }

  static bool doesVehicleMatchColor(
    Object? targetColor,
    Map<String, dynamic> vehicle,
  ) {
    final colors = parseExteriorColors(targetColor);
    if (colors.isEmpty) return true;
    final vColor = (vehicle['exteriorColor']?.toString() ?? '').toLowerCase();
    if (vColor.isEmpty) return false;
    return colors.any(
      (c) => _doesSingleColorMatchVehicle(c.toLowerCase(), vColor),
    );
  }

  static bool doesVehicleMatchDrivetrain(
    String targetDrivetrain,
    Map<String, dynamic> vehicle,
  ) {
    final targetDt = targetDrivetrain.trim().toUpperCase();
    if (targetDt.isEmpty || targetDt == 'ANY') return true;
    final vDt = (vehicle['drivetrain']?.toString() ?? '').toUpperCase();
    final hl = (vehicle['highlights'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .join(' ');
    final hay =
        '$vDt $hl ${vehicle['commentsSummary'] ?? ''}'.toUpperCase();

    if (targetDt == '4WD') {
      return vDt == '4WD' ||
          vDt == 'AWD / 4WD' ||
          hay.contains('4WD') ||
          hay.contains('4X4') ||
          hay.contains('FOUR WHEEL DRIVE') ||
          hay.contains('4-WHEEL DRIVE');
    }
    if (targetDt == 'AWD') {
      return vDt == 'AWD' ||
          vDt == 'AWD / 4WD' ||
          hay.contains('AWD') ||
          hay.contains('ALL WHEEL DRIVE') ||
          hay.contains('ALL-WHEEL DRIVE');
    }
    if (targetDt == 'RWD') {
      return vDt == 'RWD' ||
          hay.contains('RWD') ||
          hay.contains('REAR WHEEL DRIVE') ||
          hay.contains('2WD');
    }
    if (targetDt == 'FWD') {
      return vDt == 'FWD' ||
          hay.contains('FWD') ||
          hay.contains('FRONT WHEEL DRIVE');
    }
    return vDt == targetDt || hay.contains(targetDt);
  }

  static bool doesVehicleMatchStrictPackages(
    List<String> strictPackages,
    Map<String, dynamic> vehicle,
  ) {
    if (strictPackages.isEmpty) return true;
    final hl = (vehicle['highlights'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .join(' ');
    final hay =
        '${vehicle['title'] ?? ''} ${vehicle['trim'] ?? ''} $hl ${vehicle['fullCommentsSearchText'] ?? vehicle['commentsSummary'] ?? ''}';

    for (final label in strictPackages) {
      final rule = _strictPackageRules
          .where((r) => r.label == label)
          .firstOrNull;
      if (rule != null && !rule.matchRegex.hasMatch(hay)) {
        return false;
      }
    }
    return true;
  }
}
