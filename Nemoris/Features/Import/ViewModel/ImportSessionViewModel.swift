import Foundation
import Observation
import NemorisEngine

enum ImportSortMode: String, CaseIterable {
    case byStatus    = "Statut"
    case byDateAsc   = "Date ↑"
    case byDateDesc  = "Date ↓"
    case byAmountAbs = "Montant"
}

/// Orchestrator for the import view. Loads the session from the DB,
/// runs engine resolution in the background, saves on every user action,
/// and triggers the final commit into the `transactions` table.
@MainActor
@Observable
final class ImportSessionViewModel {

    private(set) var session: ImportSession
    private(set) var isResolving: Bool = false
    private(set) var resolveProgress: Double = 0
    private(set) var isEnriching: Bool = false
    private(set) var enrichProgress: Double = 0
    private(set) var allTiers: [Tiers] = []
    private(set) var allCategories: [Category] = []
    private(set) var lastError: String?
    private(set) var commitSummary: ImportCommitSummary?
    /// Ephemeral info about the last cascaded action — the UI can show a toast.
    var lastBulkApply: BulkApplyInfo? = nil

    var sortMode: ImportSortMode = .byStatus

    private let sessionRepo: ImportSessionRepository
    private let txRepo: TransactionRepository
    private var saveTask: Task<Void, Never>? = nil

    /// `store` defaults to the app's database: no call site
    /// needs to change. Tests inject a temporary database.
    init(session: ImportSession, store: SQLiteStore = SQLiteStore()) {
        self.session = session
        self.sessionRepo = ImportSessionRepository(store: store)
        self.txRepo = TransactionRepository(store: store)
    }

    // MARK: - Lifecycle

    func loadReferenceData() {
        allTiers = txRepo.fetchTiers()
        allCategories = txRepo.fetchCategories()
    }

    /// Sorts + filters the rows for display.
    var displayedRows: [ImportSessionRow] {
        switch sortMode {
        case .byStatus:
            return session.rows.sorted { lhs, rhs in
                let l = statusOrder(lhs.userAction)
                let r = statusOrder(rhs.userAction)
                if l != r { return l < r }
                return lhs.date < rhs.date
            }
        case .byDateAsc:   return session.rows.sorted { $0.date < $1.date }
        case .byDateDesc:  return session.rows.sorted { $0.date > $1.date }
        case .byAmountAbs: return session.rows.sorted { abs($0.amount) > abs($1.amount) }
        }
    }

    // MARK: - Clustering by similar label

    /// Stable cluster key: groups rows that share the SAME raw label
    /// (case-insensitive + accent-insensitive + trimmed). Every "GRAB HEADQUARTERS SG"
    /// in an import shares a clusterKey → deciding on 1 → applies to N.
    static func clusterKey(_ rawLabel: String) -> String {
        rawLabel
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Number of rows sharing the same clusterKey (including the passed row).
    func clusterSize(for row: ImportSessionRow) -> Int {
        let key = Self.clusterKey(row.rawLabel)
        return session.rows.filter { Self.clusterKey($0.rawLabel) == key }.count
    }

    /// Indices of other rows clustered with `row` that are still pending.
    /// Rows already decided (.confirmed/.manuallySet/.skipped/.committed) are never cascaded.
    private func pendingSimilarIndices(to row: ImportSessionRow) -> [Int] {
        let key = Self.clusterKey(row.rawLabel)
        return session.rows.enumerated().compactMap { idx, r in
            guard r.id != row.id else { return nil }
            guard r.userAction == .pending else { return nil }
            guard Self.clusterKey(r.rawLabel) == key else { return nil }
            return idx
        }
    }

    private func statusOrder(_ a: ImportUserAction) -> Int {
        switch a {
        case .pending:      return 0
        case .manuallySet:  return 1
        case .confirmed:    return 2
        case .skipped:      return 3
        case .committed:    return 4
        }
    }

    // MARK: - Engine resolve

    /// Resolves ALL .pending rows through the engine. Streamed in batches of 20:
    /// the UI sees the progress bar and rows update as it goes
    /// (instead of waiting for EVERYTHING to resolve before the screen moves).
    func resolveAllPending() async {
        guard let engine = EngineBootstrap.shared.engine else {
            lastError = "Moteur pas encore prêt."
            return
        }
        guard !isResolving else { return }
        isResolving = true
        resolveProgress = 0
        defer { isResolving = false }

        let pendingIndices = session.rows.enumerated().compactMap { (i, r) -> Int? in
            r.resolution == .pending ? i : nil
        }
        guard !pendingIndices.isEmpty else { resolveProgress = 1; return }

        let batchSize = 20
        var processed = 0
        let chunks = stride(from: 0, to: pendingIndices.count, by: batchSize).map {
            Array(pendingIndices[$0..<min($0 + batchSize, pendingIndices.count)])
        }

        // Capture allTiers BEFORE the Task.detached so the app-side lookup is
        // available offline (no main-actor hop per row).
        let tiersForLookup = allTiers

        // AutoDiscovery: watches every .unknown / weak-.picker resolution during
        // the import (the main source of volume) to promote a merchant to
        // "learned" after N recurring occurrences (see NemorisEngine/Learning/AutoDiscovery).
        // Reuses engine.db/engine.store — no data is duplicated, the default config
        // (3 occurrences / 60 days) is the engine's own.
        let discovery = AutoDiscovery(db: engine.db, store: engine.store)

        for chunk in chunks {
            let labels = chunk.map { session.rows[$0].rawLabel }
            // Batch resolution in the background (CPU-bound).
            let (snapshots, promotedInBatch): ([TierResolutionSnapshot], Bool) = await Task.detached(priority: .userInitiated) {
                var promoted = false
                let snaps = labels.map { label -> TierResolutionSnapshot in
                    guard let resolved = try? engine.resolve(label) else {
                        return .needsManualPick(reason: "error", topMerchantId: nil, topName: nil, topScore: nil)
                    }
                    // Silent by design (like the `try?` on the resolution above):
                    // a write failure into engine.sqlite must never fail
                    // the import — learning is a bonus, not a hard dependency.
                    if (try? discovery.observe(resolved)) != nil {
                        promoted = true
                    }
                    return Self.snapshot(from: resolved, allTiers: tiersForLookup)
                }
                return (snaps, promoted)
            }.value

            // A merchant was promoted to "learned" during this batch → reload the
            // engine's snapshot so similar labels in LATER batches (same import,
            // or a future import) get recognized starting now.
            if promotedInBatch {
                try? engine.reloadMerchantSnapshot()
            }

            // Apply on MainActor + update progress after every batch.
            for (i, rowIdx) in chunk.enumerated() {
                let snap = snapshots[i]
                session.rows[rowIdx].resolution = snap
                if case .matched(let payeeId, _, let displayName, _, _) = snap {
                    session.rows[rowIdx].assignedPayeeId = payeeId
                    session.rows[rowIdx].assignedPayeeName = displayName
                    if let pid = payeeId,
                       let payee = allTiers.first(where: { $0.id == pid }) {
                        session.rows[rowIdx].assignedCategoryId = payee.categoryId
                    }
                }
            }
            processed += chunk.count
            resolveProgress = Double(processed) / Double(pendingIndices.count)
            // Yield to let the UI redraw between batches.
            await Task.yield()
        }
        scheduleSave()
    }

    /// Converts a `ResolvedTransaction` from the engine into a Codable snapshot.
    ///
    /// **Priority order (safest to least safe)**:
    ///   0. **REGEX MATCH**: if the user has a payee whose regex matches the rawLabel
    ///      → that's the one. Safest source, since it's EXPLICITLY set by the user.
    ///   1. ENGINE + engine_merchant_id lookup in allTiers → .matched
    ///   2. ENGINE + fallback name match in allTiers → .matched (+ backfill engine_id on commit)
    ///   3. ENGINE alone → .suggestCreate (will be created on commit)
    ///   4. .needsManualPick / .suggestContact / .systemOperation
    ///
    /// Step 0 (regex) short-circuits everything else — no engine call, no risk
    /// of a false positive from the engine. This lets the user override a
    /// bad engine detection just by pasting a regex onto their payee.
    ///
    private nonisolated static func snapshot(from r: ResolvedTransaction, allTiers: [Tiers]) -> TierResolutionSnapshot {
        // === STEP 0: REGEX-FIRST ===
        // The user explicitly defined a pattern → trust it.
        if let regexHit = regexMatch(rawLabel: r.parsed.rawLabel, allTiers: allTiers) {
            return .matched(
                payeeId: regexHit.id,
                engineMerchantId: regexHit.engineMerchantId,
                displayName: regexHit.name,
                city: regexHit.city ?? r.parsed.cityCandidate?.titleCased,
                score: 1.0  // confidence max : pattern utilisateur explicite
            )
        }

        switch r.decision {
        case .system:
            return .systemOperation(
                category: r.parsed.systemCategory.map { String(describing: $0) } ?? "unknown",
                displayName: r.parsed.systemDisplayName ?? "Opération bancaire"
            )
        case .contact:
            return .suggestContact(
                name: r.contactDisplayName ?? r.p2pMatch?.nameCandidate ?? "(contact)",
                hint: r.p2pMatch?.kind.rawValue
            )
        case .autoValidated, .suggested:
            guard let top = r.topCandidate else {
                return .needsManualPick(reason: "no_top_candidate", topMerchantId: nil, topName: nil, topScore: nil)
            }
            let canonicalDisplay = top.canonicalName.titleCased

            // 1) Lookup direct par engine_merchant_id
            if let existing = allTiers.first(where: { $0.engineMerchantId == top.merchantId }) {
                return .matched(
                    payeeId: existing.id,
                    engineMerchantId: top.merchantId,
                    displayName: existing.name,
                    city: existing.city ?? r.parsed.cityCandidate?.titleCased,
                    score: top.score
                )
            }
            // 2) Fallback name match (folded + lowercased) — useful for
            //    legacy payees created by hand without an engineMerchantId.
            let needle = top.canonicalName
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()
            if let existing = allTiers.first(where: {
                $0.name.folding(options: .diacriticInsensitive, locale: .current).lowercased() == needle
            }) {
                return .matched(
                    payeeId: existing.id,
                    engineMerchantId: top.merchantId,
                    displayName: existing.name,
                    city: existing.city ?? r.parsed.cityCandidate?.titleCased,
                    score: top.score
                )
            }
            // 3) A real suggestion to create one
            return .suggestCreate(
                engineMerchantId: top.merchantId,
                displayName: canonicalDisplay,
                city: r.parsed.cityCandidate?.titleCased,
                country: r.parsed.countryCandidate,
                score: top.score
            )
        case .picker, .unknown:
            return .needsManualPick(
                reason: "low_confidence",
                topMerchantId: r.topCandidate?.merchantId,
                topName: r.topCandidate?.canonicalName.titleCased,
                topScore: r.topCandidate?.score
            )
        }
    }

    /// Looks for a payee whose regex matches the raw label.
    ///
    /// - Compiles every `payees.regex` as a case-insensitive NSRegularExpression.
    /// - If EXACTLY 1 payee matches → returns that payee (a reliable signal).
    /// - If 0 or 2+ match → returns nil (ambiguous: let the engine decide).
    /// - Invalid regexes are silently ignored (`try?`).
    ///
    /// Typical case: the user has a payee "Payoo" with regex `(?i)PAYOO` → every
    /// "PAYOO …" label matches and is assigned to that payee directly, without
    /// going through the engine (which could hallucinate).
    private nonisolated static func regexMatch(rawLabel: String, allTiers: [Tiers]) -> Tiers? {
        var hits: [Tiers] = []
        let range = NSRange(rawLabel.startIndex..., in: rawLabel)
        for tier in allTiers {
            guard let pattern = tier.regex?.trimmingCharacters(in: .whitespaces),
                  !pattern.isEmpty,
                  let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            else { continue }
            if re.firstMatch(in: rawLabel, range: range) != nil {
                hits.append(tier)
                if hits.count > 1 { return nil }  // ambigu : early exit
            }
        }
        return hits.count == 1 ? hits.first : nil
    }

    // MARK: - User actions (all cascade to clustered pending rows by default)

    /// Confirms the engine's suggestion for this row. Cascades to similar pending
    /// rows if `cascade=true`. Keeps the resolution as-is (the suggestion stands).
    @discardableResult
    func confirm(rowId: UUID, cascade: Bool = true) -> Int {
        guard let idx = session.rows.firstIndex(where: { $0.id == rowId }) else { return 0 }
        session.rows[idx].userAction = .confirmed
        var cascaded = 0
        if cascade {
            let source = session.rows[idx]
            for sidx in pendingSimilarIndices(to: source) {
                session.rows[sidx].userAction = .confirmed
                // Copy the resolution if the target was .pending — so we know at
                // commit time what to create/link.
                if case .pending = session.rows[sidx].resolution {
                    session.rows[sidx].resolution = source.resolution
                    session.rows[sidx].assignedPayeeId = source.assignedPayeeId
                    session.rows[sidx].assignedPayeeName = source.assignedPayeeName
                    session.rows[sidx].assignedCategoryId = source.assignedCategoryId
                }
                cascaded += 1
            }
        }
        announceBulk(action: .confirmed, count: cascaded)
        scheduleSave()
        return cascaded
    }

    @discardableResult
    func skip(rowId: UUID, cascade: Bool = true) -> Int {
        guard let idx = session.rows.firstIndex(where: { $0.id == rowId }) else { return 0 }
        session.rows[idx].userAction = .skipped
        var cascaded = 0
        if cascade {
            let source = session.rows[idx]
            for sidx in pendingSimilarIndices(to: source) {
                session.rows[sidx].userAction = .skipped
                cascaded += 1
            }
        }
        announceBulk(action: .skipped, count: cascaded)
        scheduleSave()
        return cascaded
    }

    /// Reset never uses cascade (deliberately: we want to be able to revise 1 row).
    func resetAction(rowId: UUID) {
        guard let idx = session.rows.firstIndex(where: { $0.id == rowId }) else { return }
        session.rows[idx].userAction = .pending
        scheduleSave()
    }

    /// Assigns an existing payee to the row (and to similar pending rows if cascade).
    @discardableResult
    func assign(rowId: UUID, payee: Tiers, cascade: Bool = true) -> Int {
        guard let idx = session.rows.firstIndex(where: { $0.id == rowId }) else { return 0 }
        session.rows[idx].assignedPayeeId = payee.id
        session.rows[idx].assignedPayeeName = payee.name
        session.rows[idx].assignedCategoryId = payee.categoryId
        session.rows[idx].userAction = .manuallySet
        var cascaded = 0
        if cascade {
            for sidx in pendingSimilarIndices(to: session.rows[idx]) {
                session.rows[sidx].assignedPayeeId = payee.id
                session.rows[sidx].assignedPayeeName = payee.name
                session.rows[sidx].assignedCategoryId = payee.categoryId
                session.rows[sidx].userAction = .manuallySet
                cascaded += 1
            }
        }
        announceBulk(action: .manuallySet, count: cascaded)
        scheduleSave()
        return cascaded
    }

    private func announceBulk(action: ImportUserAction, count: Int) {
        guard count > 0 else { lastBulkApply = nil; return }
        lastBulkApply = BulkApplyInfo(action: action, count: count, timestamp: Date())
    }

    // MARK: - Enrichissement multi-sources

    /// For every .needsManualPick row: tries Sirene + LLM + MapKit, and if we get
    /// a usable signal, "upgrades" the resolution to .suggestCreate with the
    /// enriched info. Deduplicated by raw label to avoid spamming the APIs.
    /// 150ms delay between calls (Sirene is rate-limited to ~7 req/s).
    func enrichUnresolvedRows() async {
        guard !isEnriching else { return }
        isEnriching = true
        enrichProgress = 0
        defer { isEnriching = false }

        // Indices of the rows to enrich, deduplicated by raw label.
        var seen: Set<String> = []
        var indices: [Int] = []
        for (i, row) in session.rows.enumerated() {
            guard case .needsManualPick = row.resolution else { continue }
            if seen.insert(row.rawLabel.lowercased()).inserted {
                indices.append(i)
            }
        }
        guard !indices.isEmpty else { enrichProgress = 1; return }

        var processed = 0
        for idx in indices {
            let row = session.rows[idx]
            let canonical = EngineBootstrap.shared.engine?.normalizer.parse(row.rawLabel).merchantCandidate ?? row.rawLabel
            let context = MerchantEnrichmentContext(
                rawLabel: row.rawLabel,
                canonicalName: canonical,
                amount: row.amount,
                city: nil,
                country: "FR",
                engineMerchantId: nil
            )
            if let result = await EnrichmentOrchestrator.shared.enrich(context) {
                applyEnrichment(result, toRowsMatching: row.rawLabel)
            }
            processed += 1
            enrichProgress = Double(processed) / Double(indices.count)
            // Rate-limit Sirene
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        scheduleSave()
    }

    /// Applies an enrichment result to every row sharing the same rawLabel
    /// (deduplicated → 1 API call per unique label).
    private func applyEnrichment(_ result: MerchantEnrichment, toRowsMatching rawLabel: String) {
        let key = rawLabel.lowercased()
        for i in session.rows.indices where session.rows[i].rawLabel.lowercased() == key {
            // Upgrade needsManualPick → suggestCreate if we got a name + (siret or domain or coords)
            guard case .needsManualPick = session.rows[i].resolution else { continue }
            guard let name = result.displayName, !name.isEmpty else { continue }
            session.rows[i].resolution = .suggestCreate(
                engineMerchantId: result.siret ?? "enriched_\(key.hashValue)",
                displayName: name,
                city: result.city,
                country: result.country,
                score: result.confidence
            )
            session.rows[i].assignedCategoryId = result.categoryId
        }
    }

    /// Applies an enrichment result chosen via `EnrichmentSheetView` to a row.
    /// Marks the row `.manuallySet` (the user made an explicit choice).
    /// Cascades to similar pending rows.
    @discardableResult
    func apply(enrichment: MerchantEnrichment, toRowId rowId: UUID, cascade: Bool = true) -> Int {
        guard let idx = session.rows.firstIndex(where: { $0.id == rowId }) else { return 0 }
        let displayName = enrichment.displayName ?? session.rows[idx].rawLabel
        let snapshot: TierResolutionSnapshot = .suggestCreate(
            engineMerchantId: enrichment.siret ?? "enriched_\(rowId.uuidString.prefix(8))",
            displayName: displayName,
            city: enrichment.city,
            country: enrichment.country,
            score: enrichment.confidence
        )

        func applyTo(_ idx: Int) {
            session.rows[idx].assignedPayeeName = displayName
            session.rows[idx].assignedCategoryId = enrichment.categoryId ?? session.rows[idx].assignedCategoryId
            session.rows[idx].assignedPayeeId = nil
            session.rows[idx].userAction = .manuallySet
            session.rows[idx].resolution = snapshot
        }

        applyTo(idx)
        var cascaded = 0
        if cascade {
            for sidx in pendingSimilarIndices(to: session.rows[idx]) {
                applyTo(sidx)
                cascaded += 1
            }
        }
        announceBulk(action: .manuallySet, count: cascaded)
        scheduleSave()
        return cascaded
    }

    /// Creates a new payee from a creation form (PayeeCreationFormSheet) and assigns it to the row.
    /// `newPayee` is a Tiers with id=0 — inserting it into the DB gives it its real id.
    /// Cascades to similar pending rows.
    @discardableResult
    func createPayeeAndAssign(rowId: UUID, newPayee: Tiers, cascade: Bool = true) -> Int {
        // 1. Basic insert (name + regex + categoryId), grab the id
        let regex = newPayee.regex ?? ""
        guard let newId = txRepo.addTiersAndGetId(
            name: newPayee.name,
            regex: regex,
            categoryId: newPayee.categoryId
        ) else {
            lastError = "Échec de la création du tier."
            return 0
        }
        // 2. Update the extended fields (domain, city, country, address, engine_merchant_id, group_id, custom, note)
        var withId = newPayee
        withId = Tiers(
            id: newId,
            name: newPayee.name,
            regex: newPayee.regex,
            categoryId: newPayee.categoryId,
            linkedCompteId: newPayee.linkedCompteId,
            engineMerchantId: newPayee.engineMerchantId,
            domain: newPayee.domain,
            address: newPayee.address,
            city: newPayee.city,
            country: newPayee.country,
            groupId: newPayee.groupId,
            custom: newPayee.custom,
            note: newPayee.note
        )
        _ = txRepo.updatePayeeFull(withId)
        // 3. Reload allTiers
        allTiers = txRepo.fetchTiers()
        let final = allTiers.first(where: { $0.id == newId }) ?? withId
        // 4. Assign the row + cascade
        let cascaded = assign(rowId: rowId, payee: final, cascade: cascade)
        // 5. Track the created payee against the source row → can be cleaned up on cancel.
        if let idx = session.rows.firstIndex(where: { $0.id == rowId }) {
            session.rows[idx].createdPayeeId = newId
            scheduleSave()
        }
        return cascaded
    }

    /// Unique ids of the payees CREATED during this session (via "Create a new payee").
    /// Used for optional cleanup on cancel.
    var createdPayeeIds: [Int] {
        Array(Set(session.rows.compactMap { $0.createdPayeeId }))
    }

    var createdPayeeCount: Int { createdPayeeIds.count }

    /// Variant of `assign` that also pushes extra fields onto the existing payee
    /// (update via TierUpdateSheet). Cascades to similar rows.
    @discardableResult
    func assignAndUpdatePayee(rowId: UUID, payee: Tiers, updatedPayee: Tiers, cascade: Bool = true) -> Int {
        // 1. Persist the updated payee
        _ = txRepo.updatePayeeFull(updatedPayee)
        // 2. Reload allTiers so the rest of the flow sees the new version
        allTiers = txRepo.fetchTiers()
        let resolved = allTiers.first(where: { $0.id == payee.id }) ?? updatedPayee
        // 3. Delegate to assign with the up-to-date payee
        return assign(rowId: rowId, payee: resolved, cascade: cascade)
    }

    func bulkConfirmAuto() {
        for i in session.rows.indices where session.rows[i].userAction == .pending {
            switch session.rows[i].resolution {
            case .matched, .suggestCreate, .systemOperation, .suggestContact:
                session.rows[i].userAction = .confirmed
            default:
                break
            }
        }
        scheduleSave()
    }

    // MARK: - Persistance

    /// Debounced save: if several actions arrive in a burst, write only once after 500ms.
    private func scheduleSave() {
        saveTask?.cancel()
        let s = session
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            var updated = s
            updated.updatedAt = Date()
            _ = self?.sessionRepo.saveSession(updated)
            if let self {
                self.session.updatedAt = updated.updatedAt
            }
        }
    }

    /// Forces an immediate save (call before a commit or a critical dismiss).
    func saveNow() {
        saveTask?.cancel()
        session.updatedAt = Date()
        _ = sessionRepo.saveSession(session)
    }

    // MARK: - Commit

    /// Inserts every ready row (confirmed / manuallySet) into the `transactions` table.
    /// Creates payees for confirmed suggestions. Cancels the session at the end (status=completed).
    func commit() async {
        guard let accountId = session.accountId else {
            lastError = "Session sans compte cible."
            return
        }
        let resolver: TierResolver? = {
            // Legacy gate: we only write a suggested payee if the engine is ready
            // (TierResolver itself no longer needs the engine since the cleanup
            // of the dead resolve() path — see TierResolver.swift).
            guard EngineBootstrap.shared.engine != nil else { return nil }
            return TierResolver(dbPath: DatabaseManager.shared.sqliteURL().path)
        }()

        var summary = ImportCommitSummary()
        var pendingInserts: [PendingTransaction] = []
        var rowToInsertIndex: [UUID: Int] = [:]
        /// Intra-batch cache of payees created/resolved by engine_merchant_id.
        /// Avoids recreating N Apple/Grab payees when N lines share the same canonical.
        var resolvedByEngineId: [String: Int] = [:]
        // Intra-batch cache by normalized name (fallback when engine_id isn't known).
        var resolvedByNameKey: [String: Int] = [:]

        // Local helper: looks up an existing payee on the app side by engine_id or by name.
        // Backfills engine_merchant_id when matched by name (so future imports find it directly).
        func findOrLink(engineMerchantId eid: String, canonicalName: String) -> Int? {
            // 1) Cache intra-batch
            if let pid = resolvedByEngineId[eid] { return pid }
            // 2) Match by engine_merchant_id in allTiers
            if let existing = allTiers.first(where: { $0.engineMerchantId == eid }) {
                resolvedByEngineId[eid] = existing.id
                return existing.id
            }
            // 3) Fallback : match par nom (case + accent insensible)
            let needle = canonicalName.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            if let pid = resolvedByNameKey[needle] { return pid }
            if let existing = allTiers.first(where: {
                $0.name.folding(options: .diacriticInsensitive, locale: .current).lowercased() == needle
            }) {
                // Backfill: record the engine_id on this existing payee so
                // future imports find it directly (step 2).
                var updated = existing
                updated.engineMerchantId = eid
                _ = txRepo.updatePayeeFull(updated)
                resolvedByEngineId[eid] = existing.id
                resolvedByNameKey[needle] = existing.id
                return existing.id
            }
            return nil
        }

        // Local helper: same principle as findOrLink but for P2P contacts,
        // who have no engine_merchant_id (the engine only detects THAT it's a
        // named transfer, never WHO). Without this lookup, "Dad" got a new payee on
        // every import. Restricted to tierType == .contact so it never latches onto
        // a merchant homonym (e.g. a shop sharing the same name).
        // "contact:" prefix so it doesn't share the namespace of resolvedByNameKey
        // with merchant names (an identical needle is possible between the two).
        func findContactByName(_ name: String) -> Int? {
            let needle = name.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            let cacheKey = "contact:" + needle
            if let pid = resolvedByNameKey[cacheKey] { return pid }
            if let existing = allTiers.first(where: {
                $0.tierType == .contact &&
                $0.name.folding(options: .diacriticInsensitive, locale: .current).lowercased() == needle
            }) {
                resolvedByNameKey[cacheKey] = existing.id
                return existing.id
            }
            return nil
        }

        for row in session.rows where row.userAction == .confirmed || row.userAction == .manuallySet {
            var payeeId: Int? = row.assignedPayeeId

            // If .confirmed on a suggestion, create the payee on the fly
            if payeeId == nil, row.userAction == .confirmed {
                switch row.resolution {
                case .matched(let pid, let eid, _, _, _):
                    // The snapshot said .matched: REUSE the captured payee_id.
                    // Plus the safety net via findOrLink (intra-batch cache).
                    if let pid {
                        payeeId = pid
                    } else if let eid {
                        payeeId = findOrLink(engineMerchantId: eid, canonicalName: "")
                    }
                case .suggestCreate(let eid, let displayName, let city, let country, _):
                    // Re-check first on the app side + the batch cache (similar
                    // previous rows may already have created the payee in THIS commit).
                    if let pid = findOrLink(engineMerchantId: eid, canonicalName: displayName) {
                        payeeId = pid
                    } else if let resolver {
                        let suggestion = PayeeSuggestion(
                            displayName: displayName,
                            canonicalName: displayName.lowercased(),
                            engineMerchantId: eid,
                            city: city,
                            country: country,
                            existingGroup: nil,
                            suggestedGroupName: nil
                        )
                        if let newId = resolver.commitNewPayee(suggestion, useGroup: false) {
                            payeeId = newId
                            resolvedByEngineId[eid] = newId
                            let nameKey = displayName.folding(options: .diacriticInsensitive, locale: .current).lowercased()
                            resolvedByNameKey[nameKey] = newId
                            summary.newPayees += 1
                        }
                    }
                case .suggestContact(let name, _):
                    // Link first to an already-created contact (same person detected on a
                    // previous import, or on a previous row of THIS commit) before
                    // creating a new one — otherwise "Dad" got duplicated on every import.
                    if let existingId = findContactByName(name) {
                        payeeId = existingId
                    } else if let newId = txRepo.addTiersAndGetId(name: name, regex: "", categoryId: nil) {
                        // Mark it as custom (a person) without re-fetching the whole table.
                        // tierType: .contact — otherwise the payee kept the .merchant default
                        // (wrong fallback icon, wrong sort order in Data).
                        let contactTiers = Tiers(
                            id: newId, name: name, regex: nil,
                            categoryId: nil, linkedCompteId: nil,
                            engineMerchantId: nil, domain: nil,
                            address: nil, city: nil, country: nil,
                            groupId: nil, custom: true, note: nil,
                            tierType: .contact
                        )
                        _ = txRepo.updatePayeeFull(contactTiers)
                        payeeId = newId
                        summary.newContacts += 1
                        let needle = name.folding(options: .diacriticInsensitive, locale: .current).lowercased()
                        resolvedByNameKey["contact:" + needle] = newId
                    }
                case .systemOperation, .needsManualPick, .pending:
                    // payee_id stays nil — the transaction is inserted without a payee
                    break
                }
            }

            let pending = PendingTransaction(
                sourceRowNumber: row.sourceRowNumber,
                accountId: accountId,
                tiersId: payeeId,
                mdpId: row.assignedPaymentTypeId,
                information: row.rawLabel,
                amount: row.amount,
                date: row.date,
                tiersName: row.assignedPayeeName ?? "",
                mdpName: ""
            )
            pendingInserts.append(pending)
            rowToInsertIndex[row.id] = pendingInserts.count - 1
        }

        let result = txRepo.insertTransactionsDetailed(pendingInserts)
        summary.rowsConfirmed = result.insertedCount

        // ⚠️ The payment-method hint inferred from the label (CB, TRANSFER…)
        // no longer feeds `payment_type_id` but the metadata that carries the
        // matching role — and ONLY if the user created one.
        //
        // With no key carrying this role, the hint is simply ignored: we don't
        // create a metadata entry behind the user's back. This is what lets
        // a fresh database have no metadata at all until the user wants one,
        // while preserving the behavior of migrated databases (where the
        // "Payment method" key was recreated from existing data).
        let metadataRepo = TransactionMetadataRepository()
        if let paymentKeyId = metadataRepo.key(withRole: .paymentMethod)?.id {
            for row in session.rows {
                guard let hint = row.paymentTypeHint,
                      let transactionId = result.insertedIds[row.sourceRowNumber] else { continue }
                metadataRepo.setValue(hint, keyId: paymentKeyId, transactionId: transactionId)
            }
        }

        // Count the skipped ones
        summary.rowsSkipped = session.rows.filter { $0.userAction == .skipped }.count

        // Marque session completed + annule notif
        session.status = .completed
        for i in session.rows.indices where session.rows[i].userAction == .confirmed || session.rows[i].userAction == .manuallySet {
            session.rows[i].userAction = .committed
        }
        saveNow()
        ImportNotificationService.cancelReminder(forSessionId: session.id)
        commitSummary = summary
    }

    /// Cancels the session (status = cancelled, removed from the DB).
    /// - Parameter deletingCreatedPayees: if true, also deletes the payees created
    ///   during the session (cleanup of ghost payees). Any linked transactions
    ///   are unassigned (SET NULL), never lost.
    func cancel(deletingCreatedPayees: Bool = false) {
        if deletingCreatedPayees {
            let ids = Set(createdPayeeIds)
            if !ids.isEmpty { txRepo.deleteTiers(ids: ids) }
        }
        sessionRepo.deleteSession(id: session.id)
        ImportNotificationService.cancelReminder(forSessionId: session.id)
    }
}

struct ImportCommitSummary: Equatable {
    var newPayees: Int = 0
    var newContacts: Int = 0
    var rowsConfirmed: Int = 0
    var rowsSkipped: Int = 0
}

/// Ephemeral info about the last cascaded action — shown as a toast in the UI.
struct BulkApplyInfo: Equatable, Identifiable {
    var id: Date { timestamp }
    let action: ImportUserAction
    let count: Int
    let timestamp: Date

    var message: String {
        let verb: String
        switch action {
        case .confirmed:    verb = "validée(s)"
        case .skipped:      verb = "ignorée(s)"
        case .manuallySet:  verb = "mise(s) à jour"
        default:            verb = "appliquée(s)"
        }
        return "Cascade : \(count) ligne(s) similaire(s) \(verb)"
    }
}
