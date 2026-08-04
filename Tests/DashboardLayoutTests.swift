import Foundation

// Tests unitaires du registre de cartes, de sa persistance et du planificateur de
// grille — compile les fichiers RÉELS avec des stubs minimaux.
//
// Deux garanties sont verrouillées ici, parce que ce sont celles qui abîmeraient
// silencieusement le travail de l'utilisateur :
//   • une carte ajoutée dans une future version atterrit EN FIN de grille et ne
//     s'insère jamais au milieu d'une disposition déjà personnalisée (t3) ;
//   • un identifiant de carte inconnu dans le JSON ne fait pas échouer le décodage
//     de toute la disposition (t5) — sans le décodage tolérant, retirer une carte
//     ferait perdre à l'utilisateur l'intégralité de sa mise en page.

// MARK: - Stubs des types de l'app

enum MainTabItem: String {
    case dashboard, transactions, investments, patrimoine, tricount, budget, referenceData, sqlConsole
}

struct MonthlyTotals {}
struct DashboardStats {}
struct CategoryTotal {}
struct TagTotal {}
struct EnvelopeProgress {}
struct BudgetRecap {}
struct InvestmentsRecap {}
struct PatrimoineSnapshot {}
struct Alert {}
struct Insight {}

// MARK: - Harness

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func expect(_ condition: Bool, _ label: String, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ✅ \(label)")
    } else {
        failures += 1
        print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func preference(_ card: DashboardCardID, _ visible: Bool, _ size: DashboardCardSize) -> DashboardCardPreference {
    DashboardCardPreference(card: card, isVisible: visible, size: size)
}

@main
enum DashboardLayoutTests {
    static func main() {

// MARK: - t1 · Disposition par défaut

print("\nt1 · Sans préférence enregistrée, la disposition suit le registre")
do {
    let layout = DashboardLayoutStore.sanitize([])
    expect(layout.count == DashboardCardID.allCases.count, "toutes les cartes sont présentes")
    expect(layout.map(\.card) == DashboardCardID.allCases,
           "l'ordre par défaut est l'ordre de déclaration de l'enum")
    for entry in layout {
        expect(entry.isVisible == entry.card.isVisibleByDefault && entry.size == entry.card.defaultSize,
               "\(entry.card.rawValue) prend ses réglages par défaut")
    }
}

// MARK: - t2 · Déduplication

print("\nt2 · Les doublons sont écartés, la première occurrence gagne")
do {
    let layout = DashboardLayoutStore.sanitize([
        preference(.tags, false, .compact),
        preference(.tags, true, .wide)
    ])
    let tags = layout.filter { $0.card == .tags }
    expect(tags.count == 1, "une seule entrée pour .tags")
    expect(tags.first?.isVisible == false, "c'est la première occurrence qui est conservée")
}

// MARK: - t3 · Ajout d'une carte dans une future version

print("\nt3 · Une carte absente est ajoutée EN FIN, sans déranger l'ordre existant")
do {
    // Disposition « héritée » d'une version qui ne connaissait que deux cartes.
    let stored = [preference(.tags, true, .wide), preference(.monthlyFlow, true, .wide)]
    let layout = DashboardLayoutStore.sanitize(stored)

    expect(layout.prefix(2).map(\.card) == [.tags, .monthlyFlow],
           "l'ordre choisi par l'utilisateur est intact en tête")
    let appended = layout.dropFirst(2).map(\.card)
    expect(!appended.isEmpty, "les cartes inconnues de l'ancienne version ont été ajoutées")
    expect(!appended.contains(.tags) && !appended.contains(.monthlyFlow),
           "aucune carte connue n'est dupliquée en fin de liste")
    expect(Set(layout.map(\.card)) == Set(DashboardCardID.allCases), "la liste est complète")
}

// MARK: - t4 · Taille invalide

print("\nt4 · Une taille non supportée retombe sur la taille par défaut")
do {
    // `insightsCoach` n'existe qu'en large : une liste d'insights sur une
    // demi-largeur d'iPhone serait illisible.
    expect(DashboardCardID.insightsCoach.supportedSizes == [.wide], "prérequis : insightsCoach est large uniquement")

    let layout = DashboardLayoutStore.sanitize([preference(.insightsCoach, true, .compact)])
    let coach = layout.first { $0.card == .insightsCoach }
    expect(coach?.size == .wide, "la taille compacte a été corrigée")

    // Une taille légitime n'est évidemment pas touchée.
    let tags = DashboardLayoutStore.sanitize([preference(.tags, true, .compact)]).first { $0.card == .tags }
    expect(tags?.size == .compact, "une taille supportée est conservée")
}

// MARK: - t5 · Décodage tolérant + aller-retour disque

print("\nt5 · Un identifiant inconnu n'emporte pas toute la disposition")
do {
    let suite = "dashboard.layout.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        expect(false, "suite UserDefaults créée"); return
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    // JSON tel qu'écrit par une version future contenant une carte qu'on ne
    // connaît plus. Un décodage direct en [DashboardCardPreference] échouerait ici
    // et renverrait une liste vide → mise en page entièrement perdue.
    let json = """
    [{"card":"tags","isVisible":false,"size":"compact"},
     {"card":"carteQuiNExistePlus","isVisible":true,"size":"wide"},
     {"card":"monthlyFlow","isVisible":true,"size":"zzz"}]
    """
    defaults.set(Data(json.utf8), forKey: DashboardLayoutStore.storageKey)

    let layout = DashboardLayoutStore.load(from: defaults)
    let tags = layout.first { $0.card == .tags }
    expect(tags?.isVisible == false, "la carte connue garde son réglage")
    expect(tags?.size == .compact, "et sa taille")
    expect(layout.first { $0.card == .monthlyFlow }?.size == DashboardCardID.monthlyFlow.defaultSize,
           "une taille illisible retombe sur la valeur par défaut")
    expect(Set(layout.map(\.card)) == Set(DashboardCardID.allCases), "la liste reste complète")

    // Aller-retour complet.
    var roundtrip = layout
    roundtrip.reverse()
    DashboardLayoutStore.save(roundtrip, to: defaults)
    expect(DashboardLayoutStore.load(from: defaults).map(\.card) == roundtrip.map(\.card),
           "l'ordre survit à un aller-retour disque")
}

print("\nt5b · Une clé absente donne la disposition par défaut")
do {
    let suite = "dashboard.layout.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        expect(false, "suite UserDefaults créée"); return
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    expect(DashboardLayoutStore.load(from: defaults).map(\.card) == DashboardCardID.allCases,
           "aucune préférence → disposition par défaut")
}

// MARK: - t6 · Planificateur de grille

print("\nt6 · Une carte large occupe sa ligne, les compactes se groupent")
do {
    let cards = [
        preference(.insightsCoach, true, .wide),
        preference(.budgetEnvelopes, true, .compact),
        preference(.netWorth, true, .compact),
        preference(.investments, true, .compact),
        preference(.monthlyFlow, true, .wide)
    ]
    let rows = DashboardGridPlanner.rows(cards, columns: 2)
    expect(rows.count == 4, "5 cartes → 4 lignes en 2 colonnes", "obtenu \(rows.count)")
    expect(rows[0].map(\.card) == [.insightsCoach], "la large est seule sur sa ligne")
    expect(rows[1].map(\.card) == [.budgetEnvelopes, .netWorth], "deux compactes se groupent")
    expect(rows[2].map(\.card) == [.investments], "la compacte restante ferme sa ligne avant la large")
    expect(rows[3].map(\.card) == [.monthlyFlow], "la large suivante est seule")

    // L'ordre est TOUJOURS respecté : on ne remonte jamais une carte d'en dessous
    // pour combler un trou, sinon réordonner donnerait un résultat imprévisible.
    expect(rows.flatMap { $0 }.map(\.card) == cards.map(\.card), "l'ordre utilisateur est préservé")
}

print("\nt6b · Largeurs : 2, 3 ou 4 colonnes")
do {
    let compacts = (0..<4).map { _ in preference(.netWorth, true, .compact) }
    expect(DashboardGridPlanner.rows(compacts, columns: 4).count == 1, "4 compactes tiennent sur une ligne en 4 colonnes")
    expect(DashboardGridPlanner.rows(compacts, columns: 3).count == 2, "3 + 1 en 3 colonnes")
    expect(DashboardGridPlanner.rows(compacts, columns: 2).count == 2, "2 + 2 en 2 colonnes")

    // Une seule colonne : une compacte occupe la largeur pleine, donc une par ligne.
    expect(DashboardGridPlanner.rows(compacts, columns: 1).count == 4, "1 colonne → une carte par ligne")
    expect(DashboardGridPlanner.rows(compacts, columns: 0).count == 4, "un nombre de colonnes absurde est borné à 1")
    expect(DashboardGridPlanner.rows([], columns: 2).isEmpty, "aucune carte → aucune ligne")
}

print("\nt6c · Seuils de colonnes")
do {
    expect(DashboardLayoutMetrics.columnCount(for: 393) == 2, "iPhone → 2 colonnes")
    expect(DashboardLayoutMetrics.columnCount(for: 744) == 3, "iPad portrait → 3 colonnes")
    expect(DashboardLayoutMetrics.columnCount(for: 1100) == 4, "fenêtre Mac par défaut → 4 colonnes")
}

// MARK: - t7 · Cohérence du registre

print("\nt7 · Le registre est cohérent")
do {
    for card in DashboardCardID.allCases {
        expect(!card.supportedSizes.isEmpty, "\(card.rawValue) supporte au moins une taille")
        expect(card.supportedSizes.contains(card.defaultSize),
               "\(card.rawValue) : la taille par défaut est supportée")
        expect(!card.dependencies.isEmpty, "\(card.rawValue) déclare au moins un agrégat")
    }
    let ids = DashboardCardID.allCases.map(\.rawValue)
    expect(Set(ids).count == ids.count, "aucun identifiant en double")
}

// MARK: - Bilan

print("\n\(checks - failures)/\(checks) assertions OK")
if failures > 0 {
    print("❌ \(failures) test(s) en échec")
    exit(1)
}
print("✅ Tous les tests passent")

    }
}
