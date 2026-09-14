import Foundation
import Testing
@testable import Nemoris

/// Dashboard layout: the card registry, persisted
/// preferences, and grid planning.
///
/// The stakes fit in one sentence: a poorly restored layout is a lost
/// page setup. A user who hid and reordered their cards must
/// never get everything back to default because of a single unexpected value.
@Suite("Disposition du tableau de bord")
struct DashboardLayoutTests {

    private func preference(_ card: DashboardCardID, _ visible: Bool,
                            _ size: DashboardCardSize) -> DashboardCardPreference {
        DashboardCardPreference(card: card, isVisible: visible, size: size)
    }

    private func defaultsTemporaires() throws -> (UserDefaults, String) {
        let nom = "dashboard.layout.tests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: nom)), nom)
    }

    // MARK: - Default layout

    @Test("Sans préférence enregistrée, la disposition suit le registre")
    func dispositionParDefaut() {
        let layout = DashboardLayoutStore.sanitize([])

        #expect(layout.map(\.card) == DashboardCardID.allCases,
                "l'ordre par défaut est celui de la déclaration")
        for entree in layout {
            #expect(entree.isVisible == entree.card.isVisibleByDefault,
                    "\(entree.card.rawValue) : visibilité par défaut")
            #expect(entree.size == entree.card.defaultSize,
                    "\(entree.card.rawValue) : taille par défaut")
        }
    }

    // MARK: - Assainissement

    @Test("Un doublon est écarté, la première occurrence gagne")
    func deduplication() {
        let layout = DashboardLayoutStore.sanitize([
            preference(.tags, false, .compact),
            preference(.tags, true, .wide)
        ])

        let tags = layout.filter { $0.card == .tags }
        #expect(tags.count == 1)
        #expect(tags.first?.isVisible == false, "la première occurrence fait foi")
    }

    @Test("Une carte inconnue d'une ancienne disposition est ajoutée en fin")
    func ajoutEnFin() {
        // A layout inherited from a version that only knew about two cards.
        let stockee = [preference(.tags, true, .wide),
                       preference(.monthlyFlow, true, .wide)]

        let layout = DashboardLayoutStore.sanitize(stockee)

        // Inserting it elsewhere would disturb an order chosen by hand.
        #expect(layout.prefix(2).map(\.card) == [.tags, .monthlyFlow],
                "l'ordre de l'utilisateur reste intact en tête")
        let ajoutees = layout.dropFirst(2).map(\.card)
        #expect(!ajoutees.isEmpty)
        #expect(!ajoutees.contains(.tags) && !ajoutees.contains(.monthlyFlow),
                "aucune carte connue n'est dupliquée en fin")
        #expect(Set(layout.map(\.card)) == Set(DashboardCardID.allCases))
    }

    @Test("Une taille non supportée retombe sur la taille par défaut")
    func tailleInvalide() {
        // A list of analyses on half an iPhone's width would be unreadable.
        #expect(DashboardCardID.insightsCoach.supportedSizes == [.wide],
                "prérequis du scénario")

        let layout = DashboardLayoutStore.sanitize([preference(.insightsCoach, true, .compact)])
        #expect(layout.first { $0.card == .insightsCoach }?.size == .wide)

        let tags = DashboardLayoutStore.sanitize([preference(.tags, true, .compact)])
            .first { $0.card == .tags }
        #expect(tags?.size == .compact, "une taille légitime n'est pas touchée")
    }

    // MARK: - Persistance

    @Test("Un identifiant inconnu n'emporte pas toute la disposition")
    func decodageTolerant() throws {
        let (defaults, nom) = try defaultsTemporaires()
        defer { defaults.removePersistentDomain(forName: nom) }

        // Written by a future version containing a card we no longer
        // recognize. Strict decoding would fail here and yield an empty list:
        // the entire layout would be lost over a single unknown id.
        let json = """
        [{"card":"tags","isVisible":false,"size":"compact"},
         {"card":"carteQuiNExistePlus","isVisible":true,"size":"wide"},
         {"card":"monthlyFlow","isVisible":true,"size":"zzz"}]
        """
        defaults.set(Data(json.utf8), forKey: DashboardLayoutStore.storageKey)

        let layout = DashboardLayoutStore.load(from: defaults)
        let tags = layout.first { $0.card == .tags }
        #expect(tags?.isVisible == false, "la carte connue garde son réglage")
        #expect(tags?.size == .compact)
        #expect(layout.first { $0.card == .monthlyFlow }?.size == DashboardCardID.monthlyFlow.defaultSize,
                "une taille illisible retombe sur sa valeur par défaut")
        #expect(Set(layout.map(\.card)) == Set(DashboardCardID.allCases),
                "la liste reste complète")
    }

    @Test("L'ordre survit à un aller-retour sur disque")
    func allerRetourDisque() throws {
        let (defaults, nom) = try defaultsTemporaires()
        defer { defaults.removePersistentDomain(forName: nom) }

        var dispositions = DashboardLayoutStore.sanitize([])
        dispositions.reverse()
        DashboardLayoutStore.save(dispositions, to: defaults)

        #expect(DashboardLayoutStore.load(from: defaults).map(\.card) == dispositions.map(\.card))
    }

    @Test("Une clé absente donne la disposition par défaut")
    func cleAbsente() throws {
        let (defaults, nom) = try defaultsTemporaires()
        defer { defaults.removePersistentDomain(forName: nom) }

        #expect(DashboardLayoutStore.load(from: defaults).map(\.card) == DashboardCardID.allCases)
    }

    // MARK: - Grid planning

    @Test("Une carte large occupe sa ligne, les compactes se groupent")
    func planificationDesLignes() {
        let cartes = [
            preference(.insightsCoach, true, .wide),
            preference(.budgetEnvelopes, true, .compact),
            preference(.netWorth, true, .compact),
            preference(.investments, true, .compact),
            preference(.monthlyFlow, true, .wide)
        ]

        let lignes = DashboardGridPlanner.rows(cartes, columns: 2)

        #expect(lignes.count == 4, "obtenu : \(lignes.count)")
        #expect(lignes[0].map(\.card) == [.insightsCoach], "la large est seule")
        #expect(lignes[1].map(\.card) == [.budgetEnvelopes, .netWorth])
        #expect(lignes[2].map(\.card) == [.investments],
                "la compacte restante ferme sa ligne avant la large")
        #expect(lignes[3].map(\.card) == [.monthlyFlow])

        // A card from below is NEVER pulled up to fill a gap:
        // reordering would otherwise give an unpredictable result.
        #expect(lignes.flatMap { $0 }.map(\.card) == cartes.map(\.card),
                "l'ordre de l'utilisateur est préservé")
    }

    @Test("Le nombre de colonnes répartit les cartes compactes")
    func repartitionParColonnes() {
        let compactes = (0..<4).map { _ in preference(.netWorth, true, .compact) }

        #expect(DashboardGridPlanner.rows(compactes, columns: 4).count == 1)
        #expect(DashboardGridPlanner.rows(compactes, columns: 3).count == 2)
        #expect(DashboardGridPlanner.rows(compactes, columns: 2).count == 2)
        #expect(DashboardGridPlanner.rows(compactes, columns: 1).count == 4)
        // An absurd column count must not make the cards disappear.
        #expect(DashboardGridPlanner.rows(compactes, columns: 0).count == 4)
        #expect(DashboardGridPlanner.rows([], columns: 2).isEmpty)
    }

    @Test("Les seuils de largeur donnent 2, 3 ou 4 colonnes")
    func seuilsDeLargeur() {
        #expect(DashboardLayoutMetrics.columnCount(for: 393) == 2, "iPhone")
        #expect(DashboardLayoutMetrics.columnCount(for: 744) == 3, "iPad portrait")
        #expect(DashboardLayoutMetrics.columnCount(for: 1100) == 4, "fenêtre Mac")
    }

    // MARK: - Registry consistency

    @Test("Chaque carte déclare une taille tenable et ses agrégats")
    func coherenceDuRegistre() {
        for carte in DashboardCardID.allCases {
            #expect(!carte.supportedSizes.isEmpty, "\(carte.rawValue)")
            #expect(carte.supportedSizes.contains(carte.defaultSize),
                    "\(carte.rawValue) : sa taille par défaut doit être supportée")
            // Without a declared dependency, hiding the card wouldn't save
            // any computation — that's what makes a hidden card free.
            #expect(!carte.dependencies.isEmpty, "\(carte.rawValue)")
        }

        let identifiants = DashboardCardID.allCases.map(\.rawValue)
        #expect(Set(identifiants).count == identifiants.count, "aucun identifiant en double")
    }
}
