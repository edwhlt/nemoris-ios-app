import Foundation
import Testing
@testable import Nemoris

/// Disposition du tableau de bord : registre des cartes, préférences
/// persistées et planification de la grille.
///
/// L'enjeu tient en une phrase : une disposition mal relue est une mise en
/// page perdue. L'utilisateur qui a masqué et réordonné ses cartes ne doit
/// jamais tout retrouver par défaut à cause d'une seule valeur inattendue.
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

    // MARK: - Disposition par défaut

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
        // Disposition héritée d'une version qui ne connaissait que deux cartes.
        let stockee = [preference(.tags, true, .wide),
                       preference(.monthlyFlow, true, .wide)]

        let layout = DashboardLayoutStore.sanitize(stockee)

        // L'insérer ailleurs bousculerait un ordre choisi à la main.
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
        // Une liste d'analyses sur une demi-largeur d'iPhone serait illisible.
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

        // Écrit par une version future contenant une carte qu'on ne connaît
        // plus. Un décodage strict échouerait ici et rendrait une liste vide :
        // la mise en page entière serait perdue pour un seul identifiant.
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

    // MARK: - Planification de la grille

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

        // On ne remonte JAMAIS une carte d'en dessous pour combler un trou :
        // réordonner donnerait sinon un résultat imprévisible.
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
        // Un nombre de colonnes absurde ne doit pas faire disparaître les cartes.
        #expect(DashboardGridPlanner.rows(compactes, columns: 0).count == 4)
        #expect(DashboardGridPlanner.rows([], columns: 2).isEmpty)
    }

    @Test("Les seuils de largeur donnent 2, 3 ou 4 colonnes")
    func seuilsDeLargeur() {
        #expect(DashboardLayoutMetrics.columnCount(for: 393) == 2, "iPhone")
        #expect(DashboardLayoutMetrics.columnCount(for: 744) == 3, "iPad portrait")
        #expect(DashboardLayoutMetrics.columnCount(for: 1100) == 4, "fenêtre Mac")
    }

    // MARK: - Cohérence du registre

    @Test("Chaque carte déclare une taille tenable et ses agrégats")
    func coherenceDuRegistre() {
        for carte in DashboardCardID.allCases {
            #expect(!carte.supportedSizes.isEmpty, "\(carte.rawValue)")
            #expect(carte.supportedSizes.contains(carte.defaultSize),
                    "\(carte.rawValue) : sa taille par défaut doit être supportée")
            // Sans dépendance déclarée, masquer la carte ne ferait économiser
            // aucun calcul — c'est ce qui rend une carte masquée gratuite.
            #expect(!carte.dependencies.isEmpty, "\(carte.rawValue)")
        }

        let identifiants = DashboardCardID.allCases.map(\.rawValue)
        #expect(Set(identifiants).count == identifiants.count, "aucun identifiant en double")
    }
}
