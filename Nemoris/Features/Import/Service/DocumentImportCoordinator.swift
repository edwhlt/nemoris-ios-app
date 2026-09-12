import Foundation
import Observation

/// Carries document-import analysis OUTSIDE the screen that launched it,
/// so the user can keep using the app while it works.
///
/// **Why this coordinator exists:** analysis used to live in the pushed
/// view. Closing the screen lost the work, and while it ran the user
/// was stuck on a progress screen — on a multi-page PDF with an AI
/// generation per page, that adds up to tens of seconds.
///
/// The work is started here, progress is published, and the import
/// banner (`MainTabView`) serves as the return point: it shows progress
/// then "Continue" once the result is ready to review.
///
/// ⚠️ This coordinator does NO heavy work on the main actor: it
/// orchestrates parsers that themselves offload OCR, PDF reading and
/// deterministic extraction into detached tasks.
@MainActor
@Observable
final class DocumentImportCoordinator {

    static let shared = DocumentImportCoordinator()

    enum Phase: Equatable {
        case idle
        /// `total == 0` until the number of units is known (it only
        /// is once PDFs are opened and images are OCR'd).
        case analyzing(done: Int, total: Int)
        /// Analysis done: `count` items recognized, awaiting review.
        case ready(count: Int)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var destination: ImportDestination = .transactions
    private(set) var accountId: Int = 0
    /// Source label, reused as the session's `source_file`.
    private(set) var sourceLabel: String?
    /// Session persisted for an investments analysis — this is what
    /// lets the result be recovered after an app restart.
    private(set) var persistedSessionId: UUID?

    /// Pipeline output — a single model regardless of destination.
    private(set) var batch = ImportBatchResult()
    /// Rows already produced by this import's mapped tables (CSV,
    /// spreadsheet sheets), to be merged with the ones extracted from documents.
    private(set) var seedRows: [ImportSessionRow] = []

    /// True as long as the user still has tables to map in the funnel.
    ///
    /// ⚠️ Document analysis starts NOW, while the user
    /// maps their columns — that's the whole point: on a batch of 2 CSVs and 3 PDFs,
    /// the PDFs no longer wait for mapping to finish. But the result must
    /// not be offered for review just yet:
    ///   • the import would be INCOMPLETE (rows from tables not yet
    ///     mapped aren't in it);
    ///   • and presenting the review on top of the mapping screen means
    ///     presenting a second sheet while the first is on screen — the
    ///     crash/lost-presentation pattern documented in §N.1 and
    private(set) var awaitingUserMapping = false

    private var job: Task<Void, Never>?

    var isRunning: Bool { if case .analyzing = phase { return true }; return false }
    /// Ready to review — so finished AND nothing left to wait on from the user.
    var isReady: Bool {
        if case .ready = phase { return !awaitingUserMapping }
        return false
    }
    var isActive: Bool { phase != .idle }

    /// The funnel reports that it holds (or has released) tables to map.
    func setAwaitingUserMapping(_ value: Bool) {
        awaitingUserMapping = value
    }

    /// Every transaction row ready to become a session.
    var transactionRows: [ImportSessionRow] {
        seedRows + batch.sessionRows(startingAt: seedRows.count + 1)
    }

    /// Per-source detail, for the end-of-analysis banner. Already-mapped
    /// tables show up here too: that's the whole point of this block, checking
    /// that NO source got lost on an import mixing several formats.
    var sourceBreakdown: [ImportSourceSummary] {
        var summaries = batch.perSource()
        let mappedSources = Dictionary(grouping: seedRows.compactMap(\.sourceFile), by: { $0 })
        // Index shift so mapped tables and analyzed documents don't
        // overlap in the list.
        let offset = (summaries.map(\.sourceIndex).max() ?? -1) + 1
        for (index, entry) in mappedSources.sorted(by: { $0.key < $1.key }).enumerated() {
            summaries.append(ImportSourceSummary(
                sourceIndex: offset + index, sourceName: entry.key, kind: .text,
                unitCount: 1, failedUnitCount: 0, elementCount: entry.value.count))
        }
        return summaries
    }

    // MARK: - Accumulating sources

    /// Opens an import job and resets the row counter to zero.
    ///
    /// ⚠️ It's the coordinator — not the import screen — that owns the
    /// accumulated rows. The funnel goes through several steps (one mapping per
    /// CSV, then document analysis) and closes before the end: keeping the
    /// accumulation in its `@State` made it depend on a view
    /// surviving, and not every source ended up in the final import.
    /// One owner, from the start to the end of the job.
    func beginJob(destination: ImportDestination, accountId: Int, sourceLabel: String?) {
        job?.cancel()
        job = nil
        self.destination = destination
        self.accountId = accountId
        self.sourceLabel = sourceLabel
        seedRows = []
        batch = ImportBatchResult()
        persistedSessionId = nil
        awaitingUserMapping = false
        phase = .idle
    }

    /// Adds rows from a deterministic source (one mapped CSV). Cumulative:
    /// called once per file, in processing order.
    func addRows(_ rows: [ImportSessionRow]) {
        seedRows.append(contentsOf: rows)
    }

    // MARK: - Cycle de vie

    /// Starts analyzing the current job's documents.
    ///
    /// ⚠️ Does NOT touch `seedRows`: rows from deterministic sources
    /// (already-mapped CSVs) were accumulated by `addRows` and must survive
    /// analysis — that's what guarantees every source ends up in the final
    /// import, regardless of its type or count.
    func startAnalysis(readout: ImportPipeline.Readout) {
        job?.cancel()
        batch = ImportBatchResult()
        phase = .analyzing(done: 0, total: 0)
        let destination = self.destination

        job = Task { [weak self] in
            guard let self else { return }
            let result = await ImportPipeline.analyze(readout, destination: destination) { done, total in
                // ⚠️ Progress from a unit already IN FLIGHT when `cancel()` fires
                // keeps arriving — Swift cancellation is cooperative, it
                // doesn't stop anything already running. `ImportPipeline.analyze`
                // does check between two units, but the one ALREADY launched
                // finishes its turn and calls THIS callback one more
                // time. Without this guard, it re-armed
                // `.analyzing(...)` right after `cancel()` had reset
                // `phase` to `.idle` — and since the `guard !Task.isCancelled`
                // below just returns WITHOUT ever going back to
                // `.idle`, the banner stayed stuck on "Analyzing…" for good.
                // Hence the *sometimes* symptom: it only happens if
                // the cancel lands exactly while a unit is in flight.
                guard !Task.isCancelled else { return }
                self.phase = .analyzing(done: done, total: total)
            }
            guard !Task.isCancelled else { return }
            self.batch = result
            self.persistIfInvestments(result)
            // Rows from already-mapped tables count toward the total: it's
            // the number of items across the WHOLE import that's announced, not just
            // this one analysis pass.
            self.phase = .ready(count: result.elements.count + self.seedRows.count)
        }
    }

    /// Persists the result of an INVESTMENTS analysis into a session.
    ///
    /// ⚠️ Without this, the result only lived in memory: quitting the app
    /// lost it, even though a statement analysis can take tens of
    /// seconds. Transactions have always had this safety net — their
    /// session is created by the review screen, after confirmation, because
    /// it also carries each row's resolution state.
    private func persistIfInvestments(_ result: ImportBatchResult) {
        guard destination == .investments, !result.elements.isEmpty,
              accountId > 0, persistedSessionId == nil else { return }
        persistedSessionId = ImportSessionRepository()
            .createSession(batch: result, accountId: accountId, sourceFile: sourceLabel)?.id
        // Mirrors `clear()`: the in-memory mirror must reflect the database
        // both on creation and on deletion.
        NotificationCenter.default.post(name: .nemorisImportSessionsDidChange, object: nil)
    }

    /// Reloads an investments analysis from its persisted session.
    ///
    /// This is the read counterpart of `persistIfInvestments`: the app has
    /// restarted, the coordinator is empty, but the session still exists in the
    /// database. Without this path, persistence would be pointless — the
    /// banner would show a session that nothing could reopen.
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

    /// Variant that reads then analyzes — for callers who haven't already
    /// pushed their sources through the read phase.
    func startAnalysis(sources: [ImportDocumentSource]) {
        job?.cancel()
        batch = ImportBatchResult()
        phase = .analyzing(done: 0, total: 0)
        let destination = self.destination

        job = Task { [weak self] in
            guard let self else { return }
            let readout = await ImportPipeline.read(sources: sources, destination: destination)
            guard !Task.isCancelled else { return }
            let result = await ImportPipeline.analyze(readout, destination: destination) { done, total in
                // Same guard as above, same reason: a unit already in
                // flight when cancel fires still calls this callback one
                // more time — without the guard, that re-arms the banner right
                // after `cancel()` turned it off.
                guard !Task.isCancelled else { return }
                self.phase = .analyzing(done: done, total: total)
            }
            guard !Task.isCancelled else { return }
            self.batch = result
            self.persistIfInvestments(result)
            self.phase = .ready(count: result.elements.count + self.seedRows.count)
        }
    }

    /// Abandons the work in progress and resets the coordinator.
    func cancel() {
        job?.cancel()
        job = nil
        clear()
    }

    /// Clears the state once the result has been consumed (session created, or
    /// investment review finished).
    func clear() {
        phase = .idle
        batch = ImportBatchResult()
        seedRows = []
        sourceLabel = nil
        accountId = 0
        // The persisted session has served its purpose (result consumed or
        // abandoned): leaving it behind would resurrect a ghost import
        // on the next launch.
        if let id = persistedSessionId {
            ImportSessionRepository().deleteSession(id: id)
            ImportNotificationService.cancelReminder(forSessionId: id)
        }
        persistedSessionId = nil
        awaitingUserMapping = false
        // ⚠️ Notify the in-memory MIRROR (`AppState.activeImportSession`).
        //
        // Real bug: this mirror drives the SESSION banner, shown as soon as
        // the ANALYSIS banner clears — the two are branches of the same
        // `if/else` (`MainTabView.importBanner`). Deleting the row in the
        // database without invalidating the mirror made the banner REAPPEAR
        // right after cancellation, this time with the session's dialog,
        // different from the one just confirmed. It had to be canceled
        // TWICE, and the second time targeted an already-deleted session.
        //
        // Notified HERE, not by the caller: `clear()` is the only place
        // that deletes this session, and three sites call it (cancel from
        // the banner, end of analysis review, end of session review).
        // Leaving each of them to remember it means leaving one of them
        // forgetting it — which was the case for two of the three.
        NotificationCenter.default.post(name: .nemorisImportSessionsDidChange, object: nil)
    }

    // MARK: - Presentation

    /// Banner title based on state.
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
            // A "0 / 1" then "1 / 1" counter says nothing useful: only
            // show it once there really are several units.
            return total > 1 ? "\(done) / \(total)" : "Lecture en cours…"
        case .ready where awaitingUserMapping:
            // Analysis finished before the user could see it: say so, rather
            // than showing a "ready" the user can't act on.
            return "Terminée — finis le mapping des colonnes"
        case .ready:
            return "Toucher pour relire et importer"
        case .failed(let message):
            return message
        case .idle:
            return ""
        }
    }

    /// Fraction for the progress bar, `nil` when a determinate
    /// bar wouldn't say anything useful: total still unknown, or a single unit (the
    /// bar would jump from 0% to 100% while all the waiting happens INSIDE
    /// that one unit). An indeterminate bar is then more honest.
    var progressFraction: Double? {
        guard case .analyzing(let done, let total) = phase, total > 1 else { return nil }
        return Double(done) / Double(total)
    }
}

extension Notification.Name {
    /// The import sessions in the database have changed (created or deleted by
    /// the coordinator) — `AppState.activeImportSession`, which mirrors them
    /// in memory to drive the banner, needs reloading.
    static let nemorisImportSessionsDidChange = Notification.Name("nemorisImportSessionsDidChange")
}
