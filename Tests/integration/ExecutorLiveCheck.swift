import Foundation

// Vérification RÉSEAU de bout en bout (AXE S) — fait tourner le VRAI `MerchantQueryExecutor`
// de l'app contre les APIs réelles.
//
// Différence avec `SireneLiveCheck` : celui-ci teste les CONTRATS d'API en reconstruisant
// les requêtes à la main ; celui-là exécute la chaîne de production complète —
// extraction → résolution de commune → cascade → classement → établissements. C'est la
// seule vérification qui prouve que ce que l'utilisateur verra à l'écran est correct,
// puisque l'UI ne fait qu'afficher `MerchantSearchResult`.
//
// Les fichiers compilés ici sont ceux de l'app, pas des copies.

nonisolated(unsafe) var failures = 0

func check(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("  ✅ \(label)") }
    else { failures += 1; print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")") }
}

func describe(_ result: MerchantSearchResult) {
    let extraction = result.plan.extraction
    print("     nom recherché  : « \(extraction.nameQuery) »")
    print("     localité       : \(extraction.primaryLocalityText.map { "« \($0) »" } ?? "aucune")")
    if let locality = result.plan.locality {
        print("     commune        : \(locality.displayName) · INSEE \(locality.inseeCode ?? "—")")
    } else {
        print("     commune        : non résolue (sert au tri sur les adresses)")
    }
    for outcome in result.outcomes {
        guard let attempt = result.plan.attempts.first(where: { $0.id == outcome.attemptId })
        else { continue }
        print("     \(outcome.attemptId). \(attempt.rationale) → \(outcome.status.label), \(outcome.resultCount) résultat(s)")
    }
    print("     \(result.costSummary)")
}

@main
enum ExecutorLiveCheck {
    static func main() async {

// MARK: - 1 · Le bug d'origine, via la chaîne de production complète

print("\n1 · « CB SROM FLANCHES » — le libellé qui échouait")
do {
    let result = await MerchantQueryExecutor.shared.search(
        input: MerchantQueryPlanner.Input(rawLabel: "CB SROM FLANCHES"),
        budget: .interactive
    )
    describe(result)

    check(result.plan.extraction.nameQuery == "srom", "le nom extrait est « srom »")
    let queries = result.plan.attempts.compactMap { attempt -> String? in
        if case .companyRegistry(let q) = attempt.kind { return q.q }
        return nil
    }
    check(queries.allSatisfy { !$0.contains("flanches") },
          "aucune requête n'envoie « flanches » au registre")
    check(!result.companies.isEmpty,
          "des entreprises sont trouvées là où l'ancienne recherche rendait 0",
          "obtenu \(result.companies.count)")
    if let top = result.companies.first {
        print("     → meilleur résultat : \(top.match.legalName)")
        if let establishment = top.bestEstablishment {
            print("       \(establishment.addressLine ?? "sans adresse")")
        }
        check(top.match.legalName.lowercased().contains("srom"),
              "le meilleur résultat porte bien le nom SROM")
    }
}

// MARK: - 2 · Gabarit à champs fixes + drill-down établissements

print("\n2 · Libellé de relevé réel avec localité tronquée en tête")
do {
    let label = "PAIEMENT PSC 1703 MASSY AUCHAN MASSY CARTE 5974 GIP010079487221556"
    let result = await MerchantQueryExecutor.shared.search(
        input: MerchantQueryPlanner.Input(rawLabel: label),
        budget: .interactive
    )
    describe(result)

    check(result.plan.extraction.nameQuery == "auchan",
          "la ville répétée est retirée du nom",
          "obtenu « \(result.plan.extraction.nameQuery) »")
    check(result.plan.locality?.inseeCode == "91377",
          "« MASSY » est résolu en Massy (Essonne), pas son homonyme de Seine-Maritime",
          "obtenu \(result.plan.locality?.inseeCode ?? "aucun")")
    check(!result.companies.isEmpty, "des entreprises sont trouvées")

    // Le cœur de la demande : trouver le commerce grâce aux ADRESSES des établissements.
    let withAddress = result.companies.flatMap { $0.match.allEstablishments }
        .filter { $0.addressLine != nil }
    check(!withAddress.isEmpty, "des établissements avec adresse sont remontés",
          "obtenu \(withAddress.count)")
    for establishment in withAddress.prefix(3) {
        print("       • \(establishment.addressLine ?? "")")
    }
}

// MARK: - 3 · Commune tronquée résolue par l'oracle

print("\n3 · Localité tronquée par la banque")
do {
    let label = "PAIEMENT PSC 1803 GIF SUR YVETT OCT TRADITION CARTE 5974"
    let result = await MerchantQueryExecutor.shared.search(
        input: MerchantQueryPlanner.Input(rawLabel: label),
        budget: .interactive
    )
    describe(result)
    check(result.plan.locality?.inseeCode == "91272",
          "« GIF SUR YVETT » tronqué est résolu en Gif-sur-Yvette (91272)",
          "obtenu \(result.plan.locality?.inseeCode ?? "aucun")")
    check(result.plan.attempts.first?.kind.shortName == "registry_commune",
          "la 1re tentative utilise le filtre commune INSEE")
}

// MARK: - 4 · Aucune requête pour un particulier

print("\n4 · Virement nominatif : aucune requête réseau")
do {
    let result = await MerchantQueryExecutor.shared.search(
        input: MerchantQueryPlanner.Input(
            rawLabel: "VIR INST WERO M ADAM FOURNIER REMBOURSEMENT 0823366242924587"),
        budget: .interactive
    )
    check(result.plan.extraction.isPersonNotBusiness, "détecté comme personne physique")
    check(result.plan.attempts.isEmpty, "aucune tentative planifiée")
    check(result.budgetUsed.requests == 0,
          "ZÉRO requête réseau — le nom d'un particulier ne part jamais vers un registre",
          "obtenu \(result.budgetUsed.requests)")
}

// MARK: - 5 · Libellé étranger

print("\n5 · Libellé hors France")
do {
    let result = await MerchantQueryExecutor.shared.search(
        input: MerchantQueryPlanner.Input(rawLabel: "Grab A 98C6OCFG VN HA NOI"),
        budget: .interactive
    )
    check(result.plan.extraction.countryHint == "VN", "pays VN détecté")
    let registryAttempts = result.plan.attempts.filter {
        if case .companyRegistry = $0.kind { return true }
        return false
    }
    check(registryAttempts.isEmpty,
          "aucune requête au registre français pour un commerce vietnamien")
    check(result.budgetUsed.requests == 0, "aucune requête réseau gaspillée")
}

// MARK: - Bilan

if failures > 0 {
    print("\n❌ \(failures) vérification(s) en échec")
    exit(1)
}
print("\n✅ Chaîne de recherche conforme de bout en bout")

    }
}
