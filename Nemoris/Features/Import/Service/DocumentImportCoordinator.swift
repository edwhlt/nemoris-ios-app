import Foundation
import Observation

/// Porte l'analyse d'un import de documents EN DEHORS de l'écran qui l'a
/// lancée, pour que l'utilisateur puisse continuer à se servir de l'app pendant
/// que ça travaille.
///
/// **Pourquoi ce coordinateur existe :** l'analyse vivait dans la vue poussée.
/// Fermer l'écran perdait le travail, et tant qu'elle tournait l'utilisateur
/// était captif d'un écran de progression — sur un PDF de plusieurs pages avec
/// une génération IA par page, ça se compte en dizaines de secondes.
///
/// Le travail est démarré ici, la progression est publiée, et le bandeau
/// d'import (`MainTabView`) sert de point de retour : il affiche l'avancement
/// puis « Continuer » quand le résultat est prêt à être relu.
///
/// ⚠️ Ce coordinateur ne fait AUCUN travail lourd sur le main actor : il
/// orchestre des parseurs qui déportent eux-mêmes l'OCR, la lecture PDF et
/// l'extraction déterministe dans des tâches détachées.
@MainActor
@Observable
final class DocumentImportCoordinator {

    static let shared = DocumentImportCoordinator()

    enum Phase: Equatable {
        case idle
        /// `total == 0` tant que le nombre d'unités n'est pas connu (il ne
        /// l'est qu'après ouverture des PDF et OCR des images).
        case analyzing(done: Int, total: Int)
        /// Analyse terminée : `count` éléments reconnus, en attente de relecture.
        case ready(count: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var destination: ImportDestination = .transactions
    private(set) var accountId: Int = 0
    /// Libellé de la source, repris comme `source_file` de la session.
    private(set) var sourceLabel: String?
    /// Session persistée pour une analyse d'investissements — c'est elle qui
    /// permet de retrouver le résultat après un redémarrage de l'app.
    private(set) var persistedSessionId: UUID?

    /// Sortie du pipeline — un seul modèle, quelle que soit la destination.
    private(set) var batch = ImportBatchResult()
    /// Lignes déjà produites par les tables mappées du même import (CSV,
    /// feuilles de classeur), à fusionner avec celles extraites des documents.
    private(set) var seedRows: [ImportSessionRow] = []

    private var job: Task<Void, Never>?

    var isRunning: Bool { if case .analyzing = phase { return true }; return false }
    var isReady: Bool { if case .ready = phase { return true }; return false }
    var isActive: Bool { phase != .idle }

    /// Toutes les lignes de transactions prêtes à devenir une session.
    var transactionRows: [ImportSessionRow] {
        seedRows + batch.sessionRows(startingAt: seedRows.count + 1)
    }

    /// Détail par source, pour le bandeau de fin d'analyse. Les tables déjà
    /// mappées y figurent aussi : c'est tout l'intérêt du bloc, vérifier
    /// qu'AUCUNE source n'a été perdue sur un import mêlant plusieurs formats.
    var sourceBreakdown: [ImportSourceSummary] {
        var summaries = batch.perSource()
        let mappedSources = Dictionary(grouping: seedRows.compactMap(\.sourceFile), by: { $0 })
        // Décalage des index pour que les tables mappées et les documents
        // analysés ne se recouvrent pas dans la liste.
        let offset = (summaries.map(\.sourceIndex).max() ?? -1) + 1
        for (index, entry) in mappedSources.sorted(by: { $0.key < $1.key }).enumerated() {
            summaries.append(ImportSourceSummary(
                sourceIndex: offset + index, sourceName: entry.key, kind: .text,
                unitCount: 1, failedUnitCount: 0, elementCount: entry.value.count))
        }
        return summaries
    }

    // MARK: - Accumulation des sources

    /// Ouvre un job d'import et remet le compteur de lignes à zéro.
    ///
    /// ⚠️ C'est le coordinateur — et non l'écran d'import — qui détient les
    /// lignes accumulées. L'entonnoir traverse plusieurs étapes (un mapping par
    /// CSV, puis l'analyse des documents) et se ferme avant la fin : faire
    /// vivre l'accumulation dans son `@State` la rendait dépendante de la survie
    /// d'une vue, et les sources ne se retrouvaient pas toutes dans l'import
    /// final. Un seul propriétaire, du début à la fin du job.
    func beginJob(destination: ImportDestination, accountId: Int, sourceLabel: String?) {
        job?.cancel()
        job = nil
        self.destination = destination
        self.accountId = accountId
        self.sourceLabel = sourceLabel
        seedRows = []
        batch = ImportBatchResult()
        persistedSessionId = nil
        phase = .idle
    }

    /// Ajoute les lignes d'une source déterministe (un CSV mappé). Cumulatif :
    /// appelé une fois par fichier, dans l'ordre de traitement.
    func addRows(_ rows: [ImportSessionRow]) {
        seedRows.append(contentsOf: rows)
    }

    // MARK: - Cycle de vie

    /// Démarre l'analyse des documents du job courant.
    ///
    /// ⚠️ Ne touche PAS à `seedRows` : les lignes des sources déterministes
    /// (CSV déjà mappés) ont été accumulées par `addRows` et doivent survivre à
    /// l'analyse — c'est ce qui garantit que TOUTES les sources se retrouvent
    /// dans l'import final, quel que soit leur type et leur nombre.
    func startAnalysis(readout: ImportPipeline.Readout) {
        job?.cancel()
        batch = ImportBatchResult()
        phase = .analyzing(done: 0, total: 0)
        let destination = self.destination

        job = Task { [weak self] in
            guard let self else { return }
            let result = await ImportPipeline.analyze(readout, destination: destination) { done, total in
                self.phase = .analyzing(done: done, total: total)
            }
            guard !Task.isCancelled else { return }
            self.batch = result
            self.persistIfInvestments(result)
            // Les lignes des tables déjà mappées comptent dans le total : c'est
            // le nombre d'éléments de TOUT l'import qui est annoncé, pas celui
            // de la seule passe d'analyse.
            self.phase = .ready(count: result.elements.count + self.seedRows.count)
        }
    }

    /// Persiste le résultat d'une analyse d'INVESTISSEMENTS en session.
    ///
    /// ⚠️ Sans ça, ce résultat ne vivait qu'en mémoire : quitter l'app le
    /// perdait, alors qu'une analyse de relevé se compte en dizaines de
    /// secondes. Les transactions, elles, ont toujours eu ce filet — la session
    /// y est créée par l'écran de relecture, après confirmation, parce qu'elle
    /// porte en plus l'état de résolution de chaque ligne.
    private func persistIfInvestments(_ result: ImportBatchResult) {
        guard destination == .investments, !result.elements.isEmpty,
              accountId > 0, persistedSessionId == nil else { return }
        persistedSessionId = ImportSessionRepository()
            .createSession(batch: result, accountId: accountId, sourceFile: sourceLabel)?.id
    }

    /// Recharge une analyse d'investissements depuis sa session persistée.
    ///
    /// C'est le pendant lecture de `persistIfInvestments` : l'app a redémarré,
    /// le coordinateur est vide, mais la session existe toujours en base. Sans
    /// ce chemin, la persistance ne servirait à rien — le bandeau afficherait
    /// une session que rien ne saurait rouvrir.
    @discardableResult
    func restore(sessionId: UUID) -> Bool {
        guard let session = ImportSessionRepository().fetchSession(id: sessionId),
              session.destination == .investments,
              let restored = session.batch, !restored.elements.isEmpty else { return false }
        job?.cancel()
        job = nil
        destination = .investments
        accountId = session.accountId ?? 0
        sourceLabel = session.sourceFile
        seedRows = []
        batch = restored
        persistedSessionId = sessionId
        phase = .ready(count: restored.elements.count)
        return true
    }

    /// Variante qui lit puis analyse — pour les appelants qui n'ont pas déjà
    /// fait passer les sources par la phase de lecture.
    func startAnalysis(sources: [ImportDocumentSource]) {
        job?.cancel()
        batch = ImportBatchResult()
        phase = .analyzing(done: 0, total: 0)
        let destination = self.destination

        job = Task { [weak self] in
            guard let self else { return }
            let readout = await ImportPipeline.read(sources: sources)
            guard !Task.isCancelled else { return }
            let result = await ImportPipeline.analyze(readout, destination: destination) { done, total in
                self.phase = .analyzing(done: done, total: total)
            }
            guard !Task.isCancelled else { return }
            self.batch = result
            self.persistIfInvestments(result)
            self.phase = .ready(count: result.elements.count + self.seedRows.count)
        }
    }

    /// Abandonne le travail en cours et remet le coordinateur à zéro.
    func cancel() {
        job?.cancel()
        job = nil
        clear()
    }

    /// Efface l'état une fois le résultat consommé (session créée, ou revue
    /// d'investissement terminée).
    func clear() {
        phase = .idle
        batch = ImportBatchResult()
        seedRows = []
        sourceLabel = nil
        accountId = 0
        // La session persistée a rempli son rôle (résultat consommé ou
        // abandonné) : la laisser derrière ferait réapparaître un import
        // fantôme au prochain lancement.
        if let id = persistedSessionId {
            ImportSessionRepository().deleteSession(id: id)
            ImportNotificationService.cancelReminder(forSessionId: id)
        }
        persistedSessionId = nil
    }

    // MARK: - Présentation

    /// Titre du bandeau selon l'état.
    var bannerTitle: String {
        switch phase {
        case .analyzing:
            return "Analyse du document…"
        case .ready(let count):
            let noun = destination == .transactions ? "opération" : "ligne"
            return count > 1 ? "\(count) \(noun)s prêtes" : "\(count) \(noun) prête"
        case .failed:
            return "Analyse impossible"
        case .idle:
            return ""
        }
    }

    var bannerSubtitle: String {
        switch phase {
        case .analyzing(let done, let total):
            // Un compteur « 0 / 1 » puis « 1 / 1 » n'apprend rien : on ne
            // l'affiche que quand il y a réellement plusieurs unités.
            return total > 1 ? "\(done) / \(total)" : "Lecture en cours…"
        case .ready:
            return "Toucher pour relire et importer"
        case .failed(let message):
            return message
        case .idle:
            return ""
        }
    }

    /// Fraction pour la barre de progression, `nil` quand une barre déterminée
    /// n'aurait rien à raconter : total encore inconnu, ou une seule unité (la
    /// barre sauterait de 0 % à 100 % alors que toute l'attente se passe DANS
    /// cette unique unité). Une barre indéterminée est alors plus honnête.
    var progressFraction: Double? {
        guard case .analyzing(let done, let total) = phase, total > 1 else { return nil }
        return Double(done) / Double(total)
    }
}
