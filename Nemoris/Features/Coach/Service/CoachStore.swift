import Foundation
import Observation

// MARK: - CoachStore
//
// État observable du coach : ce que les vues lisent, et le seul endroit qui
// déclenche une analyse.
//
// ⚠️ À injecter UNE SEULE FOIS dans l'environnement (`NemorisApp`), jamais en
// `@State` d'une vue — même raison que `DashboardSnapshotStore` : le Dashboard
// est instancié deux fois (TabView iOS et volet détail macOS), et deux `@State`
// signifieraient deux analyses lancées en parallèle sur le même domaine.
//
// ─── Le contrat de non-blocage ─────────────────────────────────────────────
//
// Une analyse dure de quelques secondes à une minute (lecture de 10 000
// transactions + aller-retour modèle). Elle ne doit JAMAIS être attendue par
// une vue :
//   • `refreshIfStale` et `refresh` ne sont PAS `async` — elles lancent une
//     tâche et rendent la main immédiatement ;
//   • l'état `running` est publié tout de suite, pour que l'UI montre que
//     quelque chose se passe ;
//   • les recommandations déjà persistées restent affichées PENDANT le
//     recalcul, jamais remplacées par un écran vide.

@MainActor
@Observable
final class CoachStore {

    /// Recommandations persistées, tous domaines confondus.
    private(set) var recommendations: [CoachRecommendation] = []
    /// Dernière analyse connue par domaine.
    private(set) var analyses: [CoachDomain: CoachAnalysis] = [:]
    /// Domaines dont une analyse est en cours — c'est ce que l'UI observe pour
    /// afficher son indicateur.
    private(set) var running: Set<CoachDomain> = []
    /// Objectifs de l'utilisateur, PAR DOMAINE (miroir de `coach_profile`).
    ///
    /// ⚠️ Un seul texte partagé faisait porter à chaque analyse un objectif
    /// qu'elle ne pouvait pas servir : « mieux diversifier » n'a aucune prise
    /// sur un dossier de dépenses, « moins dépenser » aucune sur un
    /// portefeuille (migration v50).
    private(set) var profiles: [CoachDomain: CoachProfile] = [:]

    private var hasLoaded = false

    // MARK: - Lecture

    func analysis(for domain: CoachDomain) -> CoachAnalysis {
        analyses[domain] ?? .empty(domain)
    }

    func profile(for domain: CoachDomain) -> CoachProfile {
        profiles[domain] ?? .empty
    }

    func isRunning(_ domain: CoachDomain) -> Bool { running.contains(domain) }

    /// Recommandations visibles d'un domaine, classées par priorité.
    func visibleRecommendations(for domain: CoachDomain) -> [CoachRecommendation] {
        CoachRanker.visible(recommendations, domain: domain)
    }

    /// Les 3 recommandations les plus importantes TOUS DOMAINES CONFONDUS —
    /// ce qu'affiche le Dashboard. L'arbitrage vit dans `CoachRanker` (moteur
    /// pur), pas ici.
    func topRecommendations(limit: Int = 3) -> [CoachRecommendation] {
        CoachRanker.topAcrossDomains(recommendations, limit: limit)
    }

    // MARK: - Chargement

    /// Recharge depuis la base. Rapide (pas d'IA), appelable à chaque `.task`.
    func load() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            (recos: CoachRepository.shared.fetchRecommendations(),
             transactions: CoachRepository.shared.fetchAnalysis(domain: .transactions),
             investments: CoachRepository.shared.fetchAnalysis(domain: .investments),
             profiles: CoachRepository.shared.fetchProfiles())
        }.value
        recommendations = loaded.recos
        analyses = [.transactions: loaded.transactions, .investments: loaded.investments]
        profiles = loaded.profiles
        hasLoaded = true
    }

    // MARK: - Analyse

    /// Relance SI l'analyse est périmée (> 7 jours) et qu'une IA est
    /// disponible. Non bloquant, silencieux si rien à faire.
    ///
    /// ⚠️ Ne relance jamais après une ERREUR : sinon un backend mal configuré
    /// ferait retenter une analyse à chaque ouverture de l'écran, en boucle et
    /// sans que l'utilisateur l'ait demandé. Après un échec, c'est à lui de
    /// relancer explicitement.
    func refreshIfStale(_ domain: CoachDomain, now: Date = Date()) {
        guard hasLoaded, !running.contains(domain) else { return }
        let current = analysis(for: domain)
        guard !current.isError, current.isStale(now: now) else { return }
        guard AIEnrichmentBackend.isAvailable(for: domain.aiFeature) else { return }
        start(domain, now: now)
    }

    /// Relance à la demande, quel que soit l'état. Non bloquant.
    func refresh(_ domain: CoachDomain, now: Date = Date()) {
        guard !running.contains(domain) else { return }
        start(domain, now: now)
    }

    private func start(_ domain: CoachDomain, now: Date) {
        running.insert(domain)
        Task {
            let analysis = await CoachService.analyze(domain: domain, now: now)
            // Les recommandations ont été réécrites en base par le service :
            // on relit plutôt que de deviner l'état résultant (les statuts
            // conservés d'une analyse à l'autre ne sont connus que de la base).
            let fresh = await Task.detached(priority: .userInitiated) {
                CoachRepository.shared.fetchRecommendations()
            }.value
            recommendations = fresh
            analyses[domain] = analysis
            running.remove(domain)
        }
    }

    // MARK: - Actions sur une recommandation

    func setStatus(_ status: CoachRecommendationStatus, for reco: CoachRecommendation) {
        // Mise à jour optimiste : l'utilisateur voit la carte disparaître tout
        // de suite, l'écriture suit.
        if let index = recommendations.firstIndex(where: { $0.id == reco.id }) {
            recommendations[index].status = status
        }
        let id = reco.id
        Task.detached(priority: .utility) {
            CoachRepository.shared.updateStatus(id: id, status: status)
        }
    }

    // MARK: - Objectifs

    func saveObjectives(_ text: String, for domain: CoachDomain) {
        profiles[domain] = CoachProfile(objectives: text, updatedAt: Date())
        Task.detached(priority: .utility) {
            CoachRepository.shared.saveObjectives(text, domain: domain)
        }
    }
}
