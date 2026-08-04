import Foundation

// Vérification RÉSEAU de la chaîne de recherche (AXE S) — opt-in, à lancer à la main.
//
// Elle sert deux buts distincts :
//   1. DÉTECTER LA DÉRIVE DE CONTRAT des APIs publiques (les paramètres et les clés de
//      réponse sur lesquels tout le module repose ne sont garantis par personne).
//   2. PROUVER DE BOUT EN BOUT que le bug d'origine est corrigé, en rejouant la cascade
//      réelle sur les libellés qui échouaient.
//
// Elle n'est PAS dans le chemin de test par défaut : elle sort sur le réseau, dépend de la
// disponibilité de services tiers, et un échec y signifie souvent « gouv.fr est en panse »
// et non « le code est cassé ».

let registryBase = "https://recherche-entreprises.api.gouv.fr"
let geoBase = "https://geo.api.gouv.fr/communes"

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var warnings = 0
nonisolated(unsafe) var requests = 0

func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("  ✅ \(label)") }
    else { failures += 1; print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
}

func warn(_ label: String) {
    warnings += 1
    print("  ⚠️  \(label)")
}

/// Cadencé à 200 ms : la doc gouv annonce ~7 req/s, on reste très en dessous.
func fetch(_ urlString: String) -> Data? {
    guard requests < 30 else { print("  (plafond de requêtes atteint)"); return nil }
    requests += 1
    Thread.sleep(forTimeInterval: 0.2)
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url)
    request.setValue("Nemoris/1.0 (integration check)", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 15

    let semaphore = DispatchSemaphore(value: 0)
    var out: Data?
    URLSession.shared.dataTask(with: request) { data, _, _ in
        out = data
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 20)
    return out
}

func encode(_ s: String) -> String {
    s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
}

/// Requête registre construite comme le fait `CompanyRegistryClient` — `minimal` AVANT
/// `include`, sans quoi l'API refuse.
func registrySearch(q: String, extra: String = "", limit: Int = 10) -> [String: Any]? {
    let url = "\(registryBase)/search?q=\(encode(q))&per_page=5&minimal=true"
        + "&include=siege,matching_etablissements&limite_matching_etablissements=\(limit)"
        + "&etat_administratif=A\(extra)"
    guard let data = fetch(url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@main
enum SireneLiveCheck {
    static func main() {

// MARK: - 1 · Contrat : minimal obligatoire avant include

print("\n1 · Contrat de l'API entreprises")
do {
    let url = "\(registryBase)/search?q=pralus&include=matching_etablissements"
    if let data = fetch(url),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check(json["erreur"] != nil,
              "`include` sans `minimal=true` est toujours refusé",
              "l'API l'accepte désormais — le commentaire de CompanyRegistryClient est à revoir")
    } else {
        warn("réponse illisible sur le test `include` seul")
    }
}

// MARK: - 2 · matching_etablissements

print("\n2 · Établissements rattachés (le drill-down)")
do {
    guard let json = registrySearch(q: "boulangerie pralus", limit: 20),
          let results = json["results"] as? [[String: Any]], let first = results.first else {
        warn("aucun résultat pour « boulangerie pralus » — service indisponible ?")
        finish()
        return
    }
    let etabs = first["matching_etablissements"] as? [[String: Any]] ?? []
    check(etabs.count >= 3, "au moins 3 établissements renvoyés", "obtenu \(etabs.count)")
    check(etabs.allSatisfy { $0["siret"] is String },
          "chaque établissement porte un SIRET")
    check(etabs.allSatisfy { $0["adresse"] is String },
          "chaque établissement porte une adresse")
    check(etabs.contains { ($0["est_siege"] as? Bool) == true },
          "le siège est identifiable parmi les établissements")

    // Le cas d'usage réel : trouver la bonne boutique par son adresse.
    let cities = etabs.compactMap { $0["libelle_commune"] as? String }
    check(Set(cities).count >= 2,
          "les établissements couvrent plusieurs communes (\(Set(cities).sorted().joined(separator: ", ")))")

    // Dérive de contrat : on ALERTE sur une clé nouvelle, on ÉCHOUE sur une clé attendue
    // disparue. L'inverse produirait du bruit à chaque évolution de l'API.
    let expectedKeys: Set<String> = [
        "siret", "adresse", "code_postal", "libelle_commune", "latitude", "longitude",
        "liste_enseignes", "est_siege", "etat_administratif", "activite_principale"
    ]
    if let sample = etabs.first {
        let actual = Set(sample.keys)
        let missing = expectedKeys.subtracting(actual)
        check(missing.isEmpty, "toutes les clés attendues sont présentes",
              "manquantes : \(missing.sorted().joined(separator: ", "))")
        let novel = actual.subtracting(expectedKeys)
        if !novel.isEmpty { warn("clés nouvelles (informatif) : \(novel.sorted().prefix(6).joined(separator: ", "))") }
    }
}

// MARK: - 3 · La régression, en conditions réelles

print("\n3 · Le bug d'origine, rejoué sur l'API réelle")
do {
    let withCity = registrySearch(q: "carrefour market flanches")
    let withoutCity = registrySearch(q: "carrefour market")
    let n1 = withCity?["total_results"] as? Int ?? -1
    let n2 = withoutCity?["total_results"] as? Int ?? -1

    print("     q=carrefour market flanches → \(n1) résultat(s)")
    print("     q=carrefour market          → \(n2) résultat(s)")
    check(n2 > 0, "le nom seul trouve des entreprises")
    if n1 > 0 {
        // Amélioration de l'API : c'est une bonne nouvelle, pas un échec.
        warn("l'API trouve désormais aussi avec la ville dans q= — le planificateur reste correct")
    } else {
        check(true, "la ville dans q= donne toujours 0 (règle cardinale justifiée)")
    }

    let srom = registrySearch(q: "srom")
    let sromCount = srom?["total_results"] as? Int ?? 0
    check(sromCount > 0, "q=srom trouve l'entreprise que « SROM FLANCHES » ratait",
          "obtenu \(sromCount)")
}

// MARK: - 4 · Filtres géographiques

print("\n4 · Filtres géographiques")
do {
    let byCommune = registrySearch(q: "pralus", extra: "&code_commune=69382")
    check((byCommune?["total_results"] as? Int ?? 0) > 0, "filtre code_commune opérationnel")
    let byDep = registrySearch(q: "pralus", extra: "&departement=42")
    check((byDep?["total_results"] as? Int ?? 0) > 0, "filtre departement opérationnel")

    if let data = fetch("\(registryBase)/near_point?lat=45.7578&long=4.8320&radius=0.5&per_page=3&minimal=true&include=siege"),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        check(json["results"] != nil, "endpoint near_point opérationnel")
    } else {
        warn("near_point injoignable")
    }
}

// MARK: - 5 · L'oracle des communes, sur des noms TRONQUÉS

print("\n5 · Résolution des communes tronquées par la banque")
do {
    // Ces graphies viennent telles quelles de relevés réels : le champ fait ~13 caractères.
    let cases: [(fragment: String, expectedInsee: String)] = [
        ("GIF SUR YVETT", "91272"),
        ("ISSY LES", "92040"),
        ("CORMEILLES EN", "95176"),
        ("PERROGNEY LES", "52384"),
        ("ROSIERES PRES", "10325"),
    ]
    for (fragment, expected) in cases {
        let url = "\(geoBase)?nom=\(encode(fragment))&fields=nom,code&limit=1&boost=population"
        guard let data = fetch(url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            warn("« \(fragment) » : réponse illisible")
            continue
        }
        let insee = arr.first?["code"] as? String
        let nom = arr.first?["nom"] as? String ?? "—"
        check(insee == expected, "« \(fragment) » → \(nom) (\(expected))",
              "obtenu \(insee ?? "aucun")")
    }

    // L'oracle NÉGATIF compte autant : il justifie de garder le fragment comme
    // signal de tri au lieu d'inventer un filtre géographique.
    if let data = fetch("\(geoBase)?nom=\(encode("Flanches"))&fields=nom,code&limit=1"),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        check(arr.isEmpty, "« Flanches » n'est pas une commune (oracle négatif)")
    }

    // Désambiguïsation par population : deux « Massy » existent.
    if let data = fetch("\(geoBase)?nom=Massy&fields=nom,code,population&limit=2&boost=population"),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        check((arr.first?["code"] as? String) == "91377",
              "« Massy » est désambiguïsé par population (Essonne)")
    }
}

finish()

    }

    static func finish() {
        print("\n\(requests) requête(s) réseau · \(warnings) avertissement(s)")
        if failures > 0 {
            print("❌ \(failures) vérification(s) en échec — contrat d'API probablement modifié")
            exit(1)
        }
        print("✅ Contrats d'API conformes")
    }
}
