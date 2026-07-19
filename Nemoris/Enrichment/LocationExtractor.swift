import Foundation

/// Extraction déterministe (sans LLM) du pays + de la ville depuis un libellé bancaire.
///
/// Utilisé pour pré-remplir le formulaire de création de tier **dès l'ouverture**, sans
/// attendre une réponse IA. Les patterns vietnamiens et français les plus courants y sont
/// couverts en dur.
///
/// Exemples :
///   - "ACV NOI BAI PSC VN HA NOI"        → (VN, Hanoi)   — NOI BAI = aéroport Hanoi
///   - "VNPAY NH AN HO PSC VN DA NANG"    → (VN, Da Nang)
///   - "VNPAY HUNG RES PSC VN P HA GIANG" → (VN, Ha Giang)
///   - "CB CARREFOUR MARKET 75011 PARIS"  → (FR, Paris)
///   - "CB STARBUCKS LYON 69002"          → (FR, Lyon)
enum LocationExtractor {

    struct Hit: Equatable {
        let country: String?    // ISO 2 lettres uppercased (FR, VN, US…)
        let city: String?       // Title-cased (Hanoi, Paris, Da Nang…)
    }

    static func extract(from rawLabel: String) -> Hit {
        let folded = rawLabel
            .folding(options: .diacriticInsensitive, locale: .current)
            .uppercased()

        // 1) Détecte les villes connues (multi-mots) AVANT le pays car certaines villes
        //    sont aussi des codes ISO (HUE = ville VN, pas un pays ; PARIS ≠ code pays).
        if let cityHit = matchCity(in: folded) {
            return Hit(country: cityHit.country, city: cityHit.canonical)
        }

        // 2) Détecte le pays seul (code ISO 2 lettres comme token isolé)
        if let country = detectCountryCode(in: folded) {
            return Hit(country: country, city: nil)
        }

        // 3) Code postal français (5 chiffres) ⇒ FR (sans ville déduite)
        if let _ = detectFrenchPostalCode(in: folded) {
            return Hit(country: "FR", city: nil)
        }

        return Hit(country: nil, city: nil)
    }

    // MARK: - City matching

    /// Tables des villes connues (uppercased, sans accent). Multi-mots supportés.
    /// On match avec des séparateurs de mots autour pour éviter "PARIS" qui matche "PARISIEN".
    private struct CityEntry {
        let pattern: String       // forme uppercased sans accent
        let canonical: String     // forme propre à stocker (Title Case + accents)
        let country: String       // ISO 2 lettres
    }

    private static let cities: [CityEntry] = [
        // VIETNAM
        .init(pattern: "HO CHI MINH",       canonical: "Ho Chi Minh",       country: "VN"),
        .init(pattern: "HOCHIMINH",         canonical: "Ho Chi Minh",       country: "VN"),
        .init(pattern: "SAIGON",            canonical: "Hô Chi Minh",       country: "VN"),
        .init(pattern: "HA NOI",            canonical: "Hanoi",             country: "VN"),
        .init(pattern: "HANOI",             canonical: "Hanoi",             country: "VN"),
        .init(pattern: "DA NANG",           canonical: "Da Nang",           country: "VN"),
        .init(pattern: "DANANG",            canonical: "Da Nang",           country: "VN"),
        .init(pattern: "HAI PHONG",         canonical: "Hai Phong",         country: "VN"),
        .init(pattern: "HAIPHONG",          canonical: "Hai Phong",         country: "VN"),
        .init(pattern: "HUE",               canonical: "Huê",               country: "VN"),
        .init(pattern: "NHA TRANG",         canonical: "Nha Trang",         country: "VN"),
        .init(pattern: "DA LAT",            canonical: "Da Lat",            country: "VN"),
        .init(pattern: "DALAT",             canonical: "Da Lat",            country: "VN"),
        .init(pattern: "HOI AN",            canonical: "Hôi An",            country: "VN"),
        .init(pattern: "HOIAN",             canonical: "Hôi An",            country: "VN"),
        .init(pattern: "SAPA",              canonical: "Sa Pa",             country: "VN"),
        .init(pattern: "SA PA",             canonical: "Sa Pa",             country: "VN"),
        .init(pattern: "CAN THO",           canonical: "Cân Tho",           country: "VN"),
        .init(pattern: "VUNG TAU",          canonical: "Vung Tàu",          country: "VN"),
        .init(pattern: "HA GIANG",          canonical: "Hà Giang",          country: "VN"),
        .init(pattern: "HAGIANG",           canonical: "Hà Giang",          country: "VN"),
        .init(pattern: "NGU HANH",          canonical: "Ngu Hành Son",      country: "VN"),  // district Da Nang
        .init(pattern: "NGU HANH SON",      canonical: "Ngu Hành Son",      country: "VN"),
        .init(pattern: "QUY NHON",          canonical: "Quy Nhon",          country: "VN"),
        .init(pattern: "PHU QUOC",          canonical: "Phu Quôc",          country: "VN"),
        .init(pattern: "BIEN HOA",          canonical: "Biên Hoà",          country: "VN"),

        // FRANCE (grandes villes)
        .init(pattern: "PARIS",             canonical: "Paris",             country: "FR"),
        .init(pattern: "MARSEILLE",         canonical: "Marseille",         country: "FR"),
        .init(pattern: "LYON",              canonical: "Lyon",              country: "FR"),
        .init(pattern: "TOULOUSE",          canonical: "Toulouse",          country: "FR"),
        .init(pattern: "NICE",              canonical: "Nice",              country: "FR"),
        .init(pattern: "NANTES",            canonical: "Nantes",            country: "FR"),
        .init(pattern: "STRASBOURG",        canonical: "Strasbourg",        country: "FR"),
        .init(pattern: "MONTPELLIER",       canonical: "Montpellier",       country: "FR"),
        .init(pattern: "BORDEAUX",          canonical: "Bordeaux",          country: "FR"),
        .init(pattern: "LILLE",             canonical: "Lille",             country: "FR"),
        .init(pattern: "RENNES",            canonical: "Rennes",            country: "FR"),
        .init(pattern: "REIMS",             canonical: "Reims",             country: "FR"),
        .init(pattern: "TOULON",            canonical: "Toulon",            country: "FR"),
        .init(pattern: "SAINT ETIENNE",     canonical: "Saint-Étienne",     country: "FR"),
        .init(pattern: "ST ETIENNE",        canonical: "Saint-Étienne",     country: "FR"),
        .init(pattern: "GRENOBLE",          canonical: "Grenoble",          country: "FR"),
        .init(pattern: "DIJON",             canonical: "Dijon",             country: "FR"),
        .init(pattern: "ANGERS",            canonical: "Angers",            country: "FR"),
        .init(pattern: "NIMES",             canonical: "Nîmes",             country: "FR"),
        .init(pattern: "VILLEURBANNE",      canonical: "Villeurbanne",      country: "FR"),
        .init(pattern: "OULLINS",           canonical: "Oullins",           country: "FR"),
        .init(pattern: "VENISSIEUX",        canonical: "Vénissieux",        country: "FR"),
        .init(pattern: "CAEN",              canonical: "Caen",              country: "FR"),
        .init(pattern: "BREST",             canonical: "Brest",             country: "FR"),
        .init(pattern: "LE HAVRE",          canonical: "Le Havre",          country: "FR"),
        .init(pattern: "AIX EN PROVENCE",   canonical: "Aix-en-Provence",   country: "FR"),
        .init(pattern: "CLERMONT FERRAND",  canonical: "Clermont-Ferrand",  country: "FR"),

        // AUTRES PAYS
        .init(pattern: "LONDON",            canonical: "London",            country: "GB"),
        .init(pattern: "LONDRES",           canonical: "London",            country: "GB"),
        .init(pattern: "MANCHESTER",        canonical: "Manchester",        country: "GB"),
        .init(pattern: "EDINBURGH",         canonical: "Edinburgh",         country: "GB"),
        .init(pattern: "BERLIN",            canonical: "Berlin",            country: "DE"),
        .init(pattern: "MUNCHEN",           canonical: "München",           country: "DE"),
        .init(pattern: "MUNICH",            canonical: "München",           country: "DE"),
        .init(pattern: "HAMBURG",           canonical: "Hamburg",           country: "DE"),
        .init(pattern: "FRANKFURT",         canonical: "Frankfurt",         country: "DE"),
        .init(pattern: "MADRID",            canonical: "Madrid",            country: "ES"),
        .init(pattern: "BARCELONA",         canonical: "Barcelona",         country: "ES"),
        .init(pattern: "BARCELONE",         canonical: "Barcelona",         country: "ES"),
        .init(pattern: "SEVILLA",           canonical: "Sevilla",           country: "ES"),
        .init(pattern: "VALENCIA",          canonical: "Valencia",          country: "ES"),
        .init(pattern: "ROMA",              canonical: "Roma",              country: "IT"),
        .init(pattern: "ROME",              canonical: "Roma",              country: "IT"),
        .init(pattern: "MILANO",            canonical: "Milano",            country: "IT"),
        .init(pattern: "MILAN",             canonical: "Milano",            country: "IT"),
        .init(pattern: "VENEZIA",           canonical: "Venezia",           country: "IT"),
        .init(pattern: "FIRENZE",           canonical: "Firenze",           country: "IT"),
        .init(pattern: "AMSTERDAM",         canonical: "Amsterdam",         country: "NL"),
        .init(pattern: "BRUSSELS",          canonical: "Brussels",          country: "BE"),
        .init(pattern: "BRUXELLES",         canonical: "Bruxelles",         country: "BE"),
        .init(pattern: "GENEVA",            canonical: "Genève",            country: "CH"),
        .init(pattern: "GENEVE",            canonical: "Genève",            country: "CH"),
        .init(pattern: "ZURICH",            canonical: "Zürich",            country: "CH"),
        .init(pattern: "LISBOA",            canonical: "Lisboa",            country: "PT"),
        .init(pattern: "LISBONNE",          canonical: "Lisboa",            country: "PT"),
        .init(pattern: "PORTO",             canonical: "Porto",             country: "PT"),

        // ASIE / AMÉRIQUE
        .init(pattern: "BANGKOK",           canonical: "Bangkok",           country: "TH"),
        .init(pattern: "PHUKET",            canonical: "Phuket",            country: "TH"),
        .init(pattern: "CHIANG MAI",        canonical: "Chiang Mai",        country: "TH"),
        .init(pattern: "TOKYO",             canonical: "Tokyo",             country: "JP"),
        .init(pattern: "OSAKA",             canonical: "Osaka",             country: "JP"),
        .init(pattern: "KYOTO",             canonical: "Kyoto",             country: "JP"),
        .init(pattern: "SEOUL",             canonical: "Seoul",             country: "KR"),
        .init(pattern: "SINGAPORE",         canonical: "Singapore",         country: "SG"),
        .init(pattern: "SINGAPOUR",         canonical: "Singapore",         country: "SG"),
        .init(pattern: "HONG KONG",         canonical: "Hong Kong",         country: "HK"),
        .init(pattern: "HONGKONG",          canonical: "Hong Kong",         country: "HK"),
        .init(pattern: "BEIJING",           canonical: "Beijing",           country: "CN"),
        .init(pattern: "PEKIN",             canonical: "Beijing",           country: "CN"),
        .init(pattern: "SHANGHAI",          canonical: "Shanghai",          country: "CN"),
        .init(pattern: "MUMBAI",            canonical: "Mumbai",            country: "IN"),
        .init(pattern: "DELHI",             canonical: "Delhi",             country: "IN"),
        .init(pattern: "NEW YORK",          canonical: "New York",          country: "US"),
        .init(pattern: "NEWYORK",           canonical: "New York",          country: "US"),
        .init(pattern: "LOS ANGELES",       canonical: "Los Angeles",       country: "US"),
        .init(pattern: "SAN FRANCISCO",     canonical: "San Francisco",     country: "US"),
        .init(pattern: "CHICAGO",           canonical: "Chicago",           country: "US"),
        .init(pattern: "MIAMI",             canonical: "Miami",             country: "US"),
        .init(pattern: "MONTREAL",          canonical: "Montreal",          country: "CA"),
        .init(pattern: "TORONTO",           canonical: "Toronto",           country: "CA"),
    ]

    /// Cherche la première ville matchant. Compare avec des "frontières de mots"
    /// (espace ou début/fin de chaîne) pour éviter les faux positifs (PARIS dans PARISIEN).
    private static func matchCity(in folded: String) -> CityEntry? {
        for entry in cities {
            if containsAsWord(haystack: folded, needle: entry.pattern) {
                return entry
            }
        }
        return nil
    }

    /// Vérifie que `needle` apparaît dans `haystack` entouré de séparateurs (espace, début/fin).
    /// Ex. "HA NOI" matche dans "ACV NOI BAI PSC VN HA NOI" ✓ mais pas dans "HANOIENNE".
    /// (En pratique on uppercase et on cherche les bornes — heuristique simple mais efficace.)
    private static func containsAsWord(haystack: String, needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let h = haystack as NSString
        var searchRange = NSRange(location: 0, length: h.length)
        while searchRange.length > 0 {
            let range = h.range(of: needle, options: [], range: searchRange)
            if range.location == NSNotFound { return false }
            let beforeOK = range.location == 0 || isWordBoundary(h.character(at: range.location - 1))
            let afterIdx = range.location + range.length
            let afterOK = afterIdx >= h.length || isWordBoundary(h.character(at: afterIdx))
            if beforeOK && afterOK { return true }
            // Avance la fenêtre pour chercher une occurrence suivante (pas de match propre ici)
            let next = range.location + 1
            searchRange = NSRange(location: next, length: h.length - next)
        }
        return false
    }

    private static func isWordBoundary(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return true }
        let ch = Character(scalar)
        return !ch.isLetter && !ch.isNumber
    }

    // MARK: - Country code

    private static let knownCountryCodes: Set<String> = [
        "FR", "VN", "GB", "DE", "ES", "IT", "BE", "CH", "NL", "PT",
        "US", "CA", "MX", "BR", "AR", "JP", "KR", "CN", "HK", "TW",
        "TH", "SG", "MY", "ID", "PH", "IN", "AE", "SA", "TR", "EG",
        "MA", "TN", "DZ", "SN", "CI", "ZA", "AU", "NZ", "IE", "DK",
        "SE", "NO", "FI", "PL", "CZ", "AT", "HU", "GR", "RO", "BG"
    ]

    /// Cherche un code ISO 2 lettres comme token isolé.
    /// "VN P" → VN ✓ ; "WSJ" → pas de match (3 lettres) ; "VNPAY" → pas de match (collé).
    private static func detectCountryCode(in folded: String) -> String? {
        // Cherche les tokens 2 lettres entre word-boundaries
        let pattern = "\\b([A-Z]{2})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(folded.startIndex..., in: folded)
        let matches = regex.matches(in: folded, range: range)
        for m in matches where m.numberOfRanges >= 2 {
            if let r = Range(m.range(at: 1), in: folded) {
                let code = String(folded[r])
                if knownCountryCodes.contains(code) { return code }
            }
        }
        return nil
    }

    /// Détecte un code postal français (5 chiffres) comme token isolé.
    private static func detectFrenchPostalCode(in folded: String) -> String? {
        let pattern = "\\b(\\d{5})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(folded.startIndex..., in: folded)
        if let m = regex.firstMatch(in: folded, range: range),
           m.numberOfRanges >= 2,
           let r = Range(m.range(at: 1), in: folded) {
            return String(folded[r])
        }
        return nil
    }
}
