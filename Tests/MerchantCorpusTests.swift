import Foundation

// Mesure du « SPECTRE DE RECHERCHE » (AXE S) — fait tourner le planificateur RÉEL sur un
// corpus de libellés bancaires authentiques et en tire un score suivi dans le temps.
//
// Ce que ce harness mesure : la QUALITÉ DE PLANIFICATION (a-t-on extrait le bon nom, le bon
// lieu, le bon pays, et évité d'interroger un registre pour un particulier ?).
// Ce qu'il NE mesure PAS : le taux de réussite bout en bout, qui suppose la cascade réseau
// réelle plus une relecture humaine. Ne jamais présenter ce pourcentage comme un taux de
// succès de la recherche — cf. `Fixtures/merchant_labels_live_results.md`.
//
// Le corpus embarque sa propre carte `communes` : c'est l'oracle HORS LIGNE. Une valeur
// nulle y signifie « geo.api.gouv.fr ne connaît pas cette commune » (le cas Flanches), ce
// qui permet d'exercer la gestion d'un échec de résolution sans réseau.

// MARK: - Modèles du corpus

struct Corpus: Decodable {
    let version: Int
    let communes: [String: CorpusCommune?]
    let labels: [CorpusLabel]
}

struct CorpusCommune: Decodable {
    let display: String
    let insee: String?
    let cp: [String]?
    let dep: String?
    let pop: Int?
}

struct CorpusLabel: Decodable {
    let id: String
    let label: String
    let expect: CorpusExpectation
    let tags: [String]
}

struct CorpusExpectation: Decodable {
    var person: Bool?
    var nameQuery: String?
    var locality: String?
    var localityResolvable: Bool?
    var postalCode: String?
    var country: String?
    var processor: String?
    var merchantNameHint: String?
    var firstAttempt: String?
    var mustNotAppearInQ: [String]?
    var attemptCountMax: Int?

    enum CodingKeys: String, CodingKey {
        case person
        case nameQuery = "name_query"
        case locality
        case localityResolvable = "locality_resolvable"
        case postalCode = "postal_code"
        case country
        case processor
        case merchantNameHint = "merchant_name_hint"
        case firstAttempt = "first_attempt"
        case mustNotAppearInQ = "must_not_appear_in_q"
        case attemptCountMax = "attempt_count_max"
    }
}

// MARK: - Résolveur hors ligne

/// Alimenté par la carte `communes` du corpus. Reproduit le contrat de `GeoCommuneResolver`
/// sans réseau : essaie les fragments du plus long au plus court, renvoie nil sur un miss
/// explicite (valeur nulle dans la carte).
struct CorpusLocalityResolver {
    let communes: [String: CorpusCommune?]

    func resolve(_ tokens: [LocalityToken]) -> ResolvedLocality? {
        for token in tokens where token.kind == .cityName {
            let key = token.raw.lowercased()
            guard let entry = communes[key], let commune = entry else { continue }
            return ResolvedLocality(
                displayName: commune.display,
                inseeCode: commune.insee,
                postalCodes: commune.cp ?? [],
                departmentCode: commune.dep,
                countryCode: "FR",
                latitude: nil, longitude: nil,
                population: commune.pop,
                source: .geoAPI
            )
        }
        return nil
    }
}

// MARK: - Résultat par libellé

struct LabelOutcome {
    let id: String
    let tags: [String]
    var problems: [String] = []
    var ok: Bool { problems.isEmpty }
}

// MARK: - Aides

/// Mots que le nom d'affichage saisi à la main ajoute et que le libellé ne contient pas.
let hintDecorations: Set<String> = [
    "le", "la", "les", "de", "du", "des", "et", "aux", "au", "chez", "a", "l", "d",
    "sarl", "sas", "sa", "eurl", "sasu", "inc", "ltd", "gmbh"
]

func significantTokens(_ s: String) -> [String] {
    MerchantTokenSimilarity.tokenize(s).filter { $0.count >= 3 && !hintDecorations.contains($0) }
}

/// Le nom d'affichage du corpus est saisi à la main (« LECLERS - Rosière »,
/// « Station Avia - Perrogney Les Fontaines ») : il mélange l'enseigne et le lieu, et
/// contient parfois une connaissance sémantique absente du libellé (« Cantine Em Lyon »
/// pour « SAS SISENS »). On ne peut donc pas exiger l'égalité — on exige un RECOUVREMENT :
/// au moins un token significatif partagé, exact ou par préfixe (les relevés tronquent).
func hintOverlaps(_ hint: String, nameQuery: String) -> Bool {
    let hintTokens = significantTokens(hint)
    let nameTokens = significantTokens(nameQuery)
    guard !hintTokens.isEmpty, !nameTokens.isEmpty else { return false }
    for h in hintTokens {
        for n in nameTokens {
            if h == n { return true }
            if h.count >= 4 && n.hasPrefix(h) { return true }
            if n.count >= 4 && h.hasPrefix(n) { return true }
            // Le nom d'affichage est saisi à la main : il contient des coquilles et des
            // raccourcis personnels (« LECLERS » pour Leclerc). Une lettre d'écart sur un
            // mot long reste le même marchand — refuser ces cas mesurerait la qualité de
            // la saisie, pas celle de l'extraction.
            if h.count >= 6 && n.count >= 6 && editDistanceAtMostOne(h, n) { return true }
        }
    }
    return false
}

/// Vrai si les deux chaînes sont à une substitution, insertion ou suppression près.
func editDistanceAtMostOne(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let x = Array(a), y = Array(b)
    if abs(x.count - y.count) > 1 { return false }
    var i = 0, j = 0, edits = 0
    while i < x.count && j < y.count {
        if x[i] == y[j] { i += 1; j += 1; continue }
        edits += 1
        if edits > 1 { return false }
        if x.count == y.count { i += 1; j += 1 }
        else if x.count > y.count { i += 1 }
        else { j += 1 }
    }
    return edits + (x.count - i) + (y.count - j) <= 1
}

@main
enum MerchantCorpusTests {
    static func main() {
        let args = CommandLine.arguments
        let path = args.count > 1 ? args[1] : "Fixtures/merchant_labels_corpus.json"
        let minScore = args.count > 2 ? (Double(args[2]) ?? 0.90) : 0.90
        let minLabels = args.count > 3 ? (Int(args[3]) ?? 900) : 900

        guard let data = FileManager.default.contents(atPath: path) else {
            print("❌ Corpus introuvable : \(path)")
            exit(1)
        }
        guard let corpus = try? JSONDecoder().decode(Corpus.self, from: data) else {
            print("❌ Corpus illisible : \(path)")
            exit(1)
        }

        // Garde-fou : personne ne doit « améliorer » le score en supprimant les cas durs.
        if corpus.labels.count < minLabels {
            print("❌ Corpus rétréci : \(corpus.labels.count) libellés < \(minLabels) attendus")
            exit(1)
        }

        let resolver = CorpusLocalityResolver(communes: corpus.communes)
        var outcomes: [LabelOutcome] = []

        for entry in corpus.labels {
            var outcome = LabelOutcome(id: entry.id, tags: entry.tags)
            let extraction = MerchantQueryPlanner.extract(
                MerchantQueryPlanner.Input(rawLabel: entry.label)
            )
            let locality = resolver.resolve(extraction.localityTokens)
            let plan = MerchantQueryPlanner.plan(extraction: extraction, locality: locality,
                                                 options: .interactive)
            let queries: [String] = plan.attempts.compactMap {
                if case .companyRegistry(let q) = $0.kind { return q.q }
                return nil
            }

            // --- Invariants universels, vérifiés sur TOUS les libellés.

            // 1. La localité ne finit jamais dans q= — la règle cardinale de l'axe.
            // Comparaison par TOKENS, pas par sous-chaîne : « on » est une sous-chaîne de
            // « lyon » ou « bourgogne » et déclencherait des alertes fantômes.
            for token in extraction.localityTokens where token.kind == .cityName {
                let localityWords = Set(MerchantTokenSimilarity.tokenize(token.raw))
                let leaked = queries.contains { query in
                    !Set(MerchantTokenSimilarity.tokenize(query)).isDisjoint(with: localityWords)
                }
                if leaked {
                    outcome.problems.append("localité « \(token.raw) » présente dans q=")
                }
            }
            // 2. Un particulier ne déclenche aucune requête au registre d'entreprises.
            if extraction.isPersonNotBusiness && !plan.attempts.isEmpty {
                outcome.problems.append("personne physique mais \(plan.attempts.count) tentative(s)")
            }
            // 3. Le budget est respecté.
            if plan.attempts.count > MerchantQueryPlanner.Options.interactive.maxAttempts {
                outcome.problems.append("budget dépassé : \(plan.attempts.count) tentatives")
            }
            // 4. Jamais de q= vide envoyé au registre.
            if queries.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                outcome.problems.append("q= vide")
            }

            // --- Attentes déclarées dans le corpus.
            let e = entry.expect

            if let expected = e.person, expected != extraction.isPersonNotBusiness {
                outcome.problems.append(
                    "personne : attendu \(expected) · obtenu \(extraction.isPersonNotBusiness)")
            }
            if let expected = e.nameQuery, expected != extraction.nameQuery {
                outcome.problems.append(
                    "name_query : attendu « \(expected) » · obtenu « \(extraction.nameQuery) »")
            }
            if let expected = e.locality {
                let got = extraction.primaryLocalityText ?? ""
                if !got.contains(expected) && !expected.contains(got) {
                    outcome.problems.append("locality : attendu « \(expected) » · obtenu « \(got) »")
                }
            }
            if let expected = e.postalCode, extraction.postalCodeToken != expected {
                outcome.problems.append(
                    "postal_code : attendu « \(expected) » · obtenu « \(extraction.postalCodeToken ?? "")»")
            }
            if let expected = e.country, extraction.countryHint != expected {
                outcome.problems.append(
                    "country : attendu « \(expected) » · obtenu « \(extraction.countryHint ?? "")»")
            }
            if let expected = e.processor, extraction.processorId != expected {
                outcome.problems.append(
                    "processor : attendu « \(expected) » · obtenu « \(extraction.processorId ?? "")»")
            }
            if let expected = e.firstAttempt {
                let got = plan.attempts.first?.kind.shortName ?? ""
                if got != expected {
                    outcome.problems.append("first_attempt : attendu « \(expected) » · obtenu « \(got) »")
                }
            }
            if let forbidden = e.mustNotAppearInQ {
                for needle in forbidden where queries.contains(where: { $0.contains(needle) }) {
                    outcome.problems.append("« \(needle) » interdit dans q=")
                }
            }
            if let maxCount = e.attemptCountMax, plan.attempts.count > maxCount {
                outcome.problems.append("attempt_count : \(plan.attempts.count) > \(maxCount)")
            }
            // Recouvrement avec le nom d'affichage saisi à la main : la mesure de fond,
            // appliquée aux ~800 libellés commerçants du corpus.
            if let hint = e.merchantNameHint, !extraction.isPersonNotBusiness,
               !extraction.degenerate {
                // On mesure si l'information a été CONSERVÉE, pas si elle se trouve dans
                // un champ précis. Un fragment classé « localité » mais non résolu reste
                // interrogé par la tentative « nom complet » : « FOURNIL PLIQUE » donne
                // q=fournil ET q=fournil plique. L'enseigne est donc bien trouvable.
                let searchable = ([extraction.nameQuery] + extraction.localityTokens
                    .filter { $0.kind == .cityName }
                    .map(\.raw)).joined(separator: " ")
                if !hintOverlaps(hint, nameQuery: searchable) {
                    outcome.problems.append(
                        "nom : attendu ≈ « \(hint) » · obtenu « \(extraction.nameQuery) »")
                }
            }

            outcomes.append(outcome)
        }

        // MARK: - Rapport

        let failed = outcomes.filter { !$0.ok }
        print("\n── Échecs (\(failed.count)) ──")
        // Les régressions d'abord : ce sont elles qu'on veut voir même quand la liste
        // est longue, puisqu'un seul de ces échecs invalide toute la suite.
        let ordered = failed.sorted { lhs, rhs in
            lhs.tags.contains("regression") && !rhs.tags.contains("regression")
        }
        for outcome in ordered.prefix(40) {
            print("❌ \(outcome.id)")
            for problem in outcome.problems { print("     \(problem)") }
        }
        if failed.count > 40 { print("   … et \(failed.count - 40) autre(s)") }

        let passed = outcomes.count - failed.count
        let score = Double(passed) / Double(outcomes.count)
        print("\nSpectre de recherche : \(passed)/\(outcomes.count) libellés correctement planifiés "
              + "(\(String(format: "%.1f", score * 100)) %)")

        // Détail par tag — un score global masque les régressions localisées.
        var byTag: [String: (ok: Int, total: Int)] = [:]
        for outcome in outcomes {
            for tag in outcome.tags {
                var entry = byTag[tag] ?? (0, 0)
                entry.total += 1
                if outcome.ok { entry.ok += 1 }
                byTag[tag] = entry
            }
        }
        let detail = byTag.keys.sorted().map { tag -> String in
            let entry = byTag[tag]!
            return "\(tag) \(entry.ok)/\(entry.total)"
        }
        print("  par tag : " + detail.joined(separator: " · "))
        print("  plancher : \(String(format: "%.2f", minScore))")

        // Garde-fou : tout libellé tagué `regression` en échec est un échec ABSOLU,
        // quel que soit le pourcentage global. Les régressions n'ont pas de franchise.
        let regressionFailures = failed.filter { $0.tags.contains("regression") }
        if !regressionFailures.isEmpty {
            print("\n❌ RÉGRESSION : \(regressionFailures.map(\.id).joined(separator: ", "))")
            exit(1)
        }
        if score < minScore {
            print("\n❌ Score sous le plancher")
            exit(1)
        }
        print("\n✅ Spectre de recherche conforme")
    }
}
