import Foundation

// Cities and countries OUTSIDE FRANCE.
// ⚠️ PURE FILE: `import Foundation` ONLY.
//
// Scope deliberately restricted to non-French places. FRENCH communes are
// NOT listed here: they're resolved by `geo.api.gouv.fr` (via `GeoCommuneResolver`),
// which knows all 35,000 communes, handles statements' fixed-width truncation
// ("GIF-SUR-YVETT" → Gif-sur-Yvette, "ISSY LES" → Issy-les-Moulineaux) and disambiguates
// by population. No hardcoded list can do that — that's the exact reason
// the old `LocationExtractor`'s FR list isn't reused here.
//
// What remains hardcoded is what the FR oracle doesn't cover: everywhere else.

enum ForeignLocalityTable {

    /// Foreign city (normalized: lowercase, no diacritics) → ISO-2 country code.
    /// Multi-word entries accepted — the lookup tries the longest n-grams first.
    static let cities: [String: String] = [
        // Vietnam — VNPAY labels are common on travel statements
        "ha noi": "VN", "hanoi": "VN", "ho chi minh": "VN", "saigon": "VN",
        "da nang": "VN", "danang": "VN", "hue": "VN", "hai phong": "VN",
        "nha trang": "VN", "da lat": "VN", "dalat": "VN", "hoi an": "VN",
        "can tho": "VN", "vung tau": "VN", "ha giang": "VN", "phu quoc": "VN",
        "sa pa": "VN", "sapa": "VN", "ninh binh": "VN", "ha long": "VN",
        "ngu hanh son": "VN", "noi bai": "VN", "tan son nhat": "VN",
        // Asie
        "bangkok": "TH", "chiang mai": "TH", "phuket": "TH", "krabi": "TH",
        "singapore": "SG", "singapour": "SG",
        "kuala lumpur": "MY", "penang": "MY",
        "phnom penh": "KH", "siem reap": "KH",
        "vientiane": "LA", "luang prabang": "LA",
        "tokyo": "JP", "osaka": "JP", "kyoto": "JP",
        "seoul": "KR", "hong kong": "HK", "hongkong": "HK",
        "shanghai": "CN", "beijing": "CN", "pekin": "CN", "shenzhen": "CN",
        "taipei": "TW", "bali": "ID", "jakarta": "ID", "denpasar": "ID",
        "manila": "PH", "delhi": "IN", "mumbai": "IN", "goa": "IN",
        "dubai": "AE", "abu dhabi": "AE", "doha": "QA", "istanbul": "TR",
        // Europe
        "london": "GB", "londres": "GB", "manchester": "GB", "edinburgh": "GB",
        "berlin": "DE", "munich": "DE", "munchen": "DE", "hamburg": "DE",
        "frankfurt": "DE", "koln": "DE", "cologne": "DE", "dusseldorf": "DE",
        "madrid": "ES", "barcelona": "ES", "barcelone": "ES", "valencia": "ES",
        "sevilla": "ES", "seville": "ES", "malaga": "ES", "bilbao": "ES",
        "roma": "IT", "rome": "IT", "milano": "IT", "milan": "IT",
        "venezia": "IT", "venise": "IT", "firenze": "IT", "florence": "IT",
        "napoli": "IT", "naples": "IT", "torino": "IT", "turin": "IT",
        "amsterdam": "NL", "rotterdam": "NL", "utrecht": "NL", "eindhoven": "NL",
        "bruxelles": "BE", "brussels": "BE", "anvers": "BE", "antwerpen": "BE",
        "gent": "BE", "liege": "BE", "bruges": "BE", "brugge": "BE",
        "geneve": "CH", "geneva": "CH", "zurich": "CH", "lausanne": "CH",
        "basel": "CH", "bale": "CH", "bern": "CH", "lugano": "CH",
        "wien": "AT", "vienne": "AT", "salzburg": "AT", "innsbruck": "AT",
        "lisboa": "PT", "lisbonne": "PT", "porto": "PT", "faro": "PT",
        "dublin": "IE", "cork": "IE", "galway": "IE",
        "praha": "CZ", "prague": "CZ", "brno": "CZ",
        "warszawa": "PL", "varsovie": "PL", "krakow": "PL", "cracovie": "PL",
        "budapest": "HU", "bucuresti": "RO", "bucarest": "RO",
        "athina": "GR", "athenes": "GR", "athens": "GR", "thessaloniki": "GR",
        "stockholm": "SE", "goteborg": "SE", "malmo": "SE",
        "oslo": "NO", "bergen": "NO", "copenhagen": "DK", "copenhague": "DK",
        "helsinki": "FI", "reykjavik": "IS", "tallinn": "EE", "riga": "LV",
        "vilnius": "LT", "zagreb": "HR", "split": "HR", "dubrovnik": "HR",
        "ljubljana": "SI", "sofia": "BG", "beograd": "RS", "belgrade": "RS",
        "luxembourg": "LU", "monaco": "MC", "andorra": "AD", "andorre": "AD",
        "valletta": "MT", "malte": "MT",
        // Americas
        "new york": "US", "los angeles": "US", "san francisco": "US",
        "chicago": "US", "miami": "US", "boston": "US", "seattle": "US",
        "las vegas": "US", "washington": "US", "austin": "US", "denver": "US",
        "montreal": "CA", "toronto": "CA", "vancouver": "CA", "quebec": "CA",
        "ottawa": "CA", "calgary": "CA",
        "mexico": "MX", "cancun": "MX", "guadalajara": "MX",
        "sao paulo": "BR", "rio de janeiro": "BR", "brasilia": "BR",
        "buenos aires": "AR", "santiago": "CL", "lima": "PE", "bogota": "CO",
        // Africa / Oceania
        "marrakech": "MA", "casablanca": "MA", "rabat": "MA", "tanger": "MA",
        "tunis": "TN", "djerba": "TN", "alger": "DZ", "le caire": "EG", "cairo": "EG",
        "dakar": "SN", "abidjan": "CI", "nairobi": "KE",
        "johannesburg": "ZA", "cape town": "ZA", "le cap": "ZA",
        "sydney": "AU", "melbourne": "AU", "brisbane": "AU", "perth": "AU",
        "auckland": "NZ", "wellington": "NZ"
    ]

    /// ISO-2 country codes accepted as an isolated token in a label.
    /// ⚠️ "FR" is among them, but a 2-letter token is only PROMOTED to a country code if
    /// it's in the final position — otherwise "CB CARREFOUR" would see "cb" as
    /// a country code, and especially "SC-X2M" or "JD" would turn into countries.
    static let countryCodes: Set<String> = [
        "fr", "gb", "uk", "de", "es", "it", "nl", "be", "ch", "at", "pt", "ie",
        "lu", "mc", "ad", "mt", "cz", "pl", "hu", "ro", "gr", "se", "no", "dk",
        "fi", "is", "ee", "lv", "lt", "hr", "si", "bg", "rs", "sk", "ua", "tr",
        "us", "ca", "mx", "br", "ar", "cl", "pe", "co",
        "vn", "th", "sg", "my", "kh", "la", "jp", "kr", "hk", "cn", "tw", "id",
        "ph", "in", "ae", "qa", "il", "np",
        "ma", "tn", "dz", "eg", "sn", "ci", "ke", "za",
        "au", "nz"
    ]

    /// Looks for a foreign city among the tokens: 3-word n-grams, then 2, then 1.
    /// Returns the consumed range + the country code.
    static func findCity(in tokens: [String]) -> (range: Range<Int>, countryCode: String, name: String)? {
        guard !tokens.isEmpty else { return nil }
        for span in stride(from: min(3, tokens.count), through: 1, by: -1) {
            var start = 0
            while start + span <= tokens.count {
                let phrase = tokens[start..<(start + span)].joined(separator: " ")
                if let code = cities[phrase] {
                    return (start..<(start + span), code, phrase)
                }
                start += 1
            }
        }
        return nil
    }

    /// Normalise `uk` en `GB` (ISO 3166-1 alpha-2 officiel).
    static func normalizeCountryCode(_ raw: String) -> String {
        let up = raw.uppercased()
        return up == "UK" ? "GB" : up
    }
}
