import Foundation

// Villes et pays HORS FRANCE.
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
//
// Périmètre volontairement restreint au non-français. Les communes FRANÇAISES ne sont
// PAS listées ici : elles sont résolues par `geo.api.gouv.fr` (via `GeoCommuneResolver`),
// qui connaît les 35 000 communes, gère la troncature en largeur fixe des relevés
// (« GIF-SUR-YVETT » → Gif-sur-Yvette, « ISSY LES » → Issy-les-Moulineaux) et désambiguïse
// par population. Aucune liste en dur ne peut faire ça — c'est pour cette raison précise
// que la liste FR de l'ancien `LocationExtractor` n'est pas reprise ici.
//
// Ce qui reste en dur, c'est ce que l'oracle FR ne couvre pas : l'étranger.

enum ForeignLocalityTable {

    /// Ville étrangère (normalisée : minuscules, sans diacritiques) → code pays ISO-2.
    /// Multi-mots acceptés — la recherche essaie les n-grams les plus longs d'abord.
    static let cities: [String: String] = [
        // Vietnam — les libellés VNPAY sont fréquents dans les relevés de voyage
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
        // Amériques
        "new york": "US", "los angeles": "US", "san francisco": "US",
        "chicago": "US", "miami": "US", "boston": "US", "seattle": "US",
        "las vegas": "US", "washington": "US", "austin": "US", "denver": "US",
        "montreal": "CA", "toronto": "CA", "vancouver": "CA", "quebec": "CA",
        "ottawa": "CA", "calgary": "CA",
        "mexico": "MX", "cancun": "MX", "guadalajara": "MX",
        "sao paulo": "BR", "rio de janeiro": "BR", "brasilia": "BR",
        "buenos aires": "AR", "santiago": "CL", "lima": "PE", "bogota": "CO",
        // Afrique / Océanie
        "marrakech": "MA", "casablanca": "MA", "rabat": "MA", "tanger": "MA",
        "tunis": "TN", "djerba": "TN", "alger": "DZ", "le caire": "EG", "cairo": "EG",
        "dakar": "SN", "abidjan": "CI", "nairobi": "KE",
        "johannesburg": "ZA", "cape town": "ZA", "le cap": "ZA",
        "sydney": "AU", "melbourne": "AU", "brisbane": "AU", "perth": "AU",
        "auckland": "NZ", "wellington": "NZ"
    ]

    /// Codes pays ISO-2 acceptés comme jeton isolé dans un libellé.
    /// ⚠️ `FR` en fait partie mais un token de 2 lettres n'est PROMU en code pays que
    /// s'il est en position finale — sans quoi « CB CARREFOUR » verrait « cb » comme
    /// un code pays, et surtout « SC-X2M » ou « JD » deviendraient des pays.
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

    /// Cherche une ville étrangère parmi les tokens : n-grams de 3 mots, puis 2, puis 1.
    /// Renvoie l'intervalle consommé + le code pays.
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
