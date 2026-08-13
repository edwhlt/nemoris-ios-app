import Foundation
import Observation
import NemorisEngine

enum ImportSortMode: String, CaseIterable {
    case byStatus    = "Statut"
    case byDateAsc   = "Date ↑"
    case byDateDesc  = "Date ↓"
    case byAmountAbs = "Montant"
}

/// Orchestrateur de la vue d'import. Charge la session depuis la DB,
/// lance la résolution moteur en arrière-plan, persiste à chaque action user,
/// et déclenche le commit final dans la table `transactions`.
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
    /// Info éphémère sur la dernière action cascadée — l'UI peut afficher un toast.
    var lastBulkApply: BulkApplyInfo? = nil

    var sortMode: ImportSortMode = .byStatus

    private let sessionRepo: ImportSessionRepository
    private let txRepo: TransactionRepository
    private var saveTask: Task<Void, Never>? = nil

    /// `store` a une valeur par défaut visant la base de l'application :
    /// aucun site d'appel ne change. Les tests injectent une base temporaire.
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

    /// Trie + filtre les rows pour l'affichage.
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

    // MARK: - Clustering par libellé similaire

    /// Clé de cluster stable : on regroupe les rows qui partagent le MÊME libellé brut
    /// (insensible à la casse + sans accents + trim). Tous les "GRAB HEADQUARTERS SG"
    /// d'un import vont avoir le même clusterKey → décider sur 1 → s'applique aux N.
    static func clusterKey(_ rawLabel: String) -> String {
        rawLabel
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Nombre de rows partageant le même clusterKey (incluant la row passée).
    func clusterSize(for row: ImportSessionRow) -> Int {
        let key = Self.clusterKey(row.rawLabel)
        return session.rows.filter { Self.clusterKey($0.rawLabel) == key }.count
    }

    /// Indices des autres rows en cluster avec `row` qui sont encore en pending.
    /// Les rows déjà décidées (.confirmed/.manuallySet/.skipped/.committed) ne sont jamais cascadées.
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

    /// Résout TOUTES les rows .pending via le moteur. Streaming par batches de 20 :
    /// l'UI voit la progress bar et les rows se mettre à jour au fur et à mesure
    /// (au lieu d'attendre que TOUT soit résolu pour voir bouger l'écran).
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

        // Capture allTiers AVANT le Task.detached pour que le lookup app-side soit
        // disponible offline (sans hop main actor par row).
        let tiersForLookup = allTiers

        for chunk in chunks {
            let labels = chunk.map { session.rows[$0].rawLabel }
            // Résolution du batch en background (CPU-bound).
            let snapshots: [TierResolutionSnapshot] = await Task.detached(priority: .userInitiated) {
                labels.map { label in
                    (try? engine.resolve(label)).map {
                        Self.snapshot(from: $0, allTiers: tiersForLookup)
                    } ?? .needsManualPick(reason: "error", topMerchantId: nil, topName: nil, topScore: nil)
                }
            }.value

            // Apply sur MainActor + update progress après chaque batch.
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
            // Yield pour laisser l'UI redessiner entre les batches.
            await Task.yield()
        }
        scheduleSave()
    }

    /// Convertit une `ResolvedTransaction` engine en snapshot Codable.
    ///
    /// **Ordre de priorité (du plus sûr au moins sûr)** :
    ///   0. **REGEX MATCH** : si l'utilisateur a un tier dont la regex match le rawLabel
    ///      → c'est lui. Source la plus sûre car définie EXPLICITEMENT par l'utilisateur.
    ///   1. ENGINE + lookup engine_merchant_id dans allTiers → .matched
    ///   2. ENGINE + fallback name match dans allTiers → .matched (+ backfill engine_id au commit)
    ///   3. ENGINE seul → .suggestCreate (sera créé au commit)
    ///   4. .needsManualPick / .suggestContact / .systemOperation
    ///
    /// L'étape 0 (regex) court-circuite tout le reste — pas d'appel engine, pas de risque
    /// de faux positif du moteur. C'est ce qui permet à l'utilisateur d'écraser une
    /// mauvaise détection engine en collant simplement une regex sur son tier.
    private nonisolated static func snapshot(from r: ResolvedTransaction, allTiers: [Tiers]) -> TierResolutionSnapshot {
        // === ÉTAPE 0 : REGEX-FIRST ===
        // L'utilisateur a explicitement défini un pattern → on lui fait confiance.
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
            // 2) Fallback name match (folded + lowercased) — utile pour les tiers
            //    legacy créés à la main sans engineMerchantId.
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
            // 3) Vraie suggestion de création
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

    /// Cherche un tier dont la regex match le libellé brut.
    ///
    /// - Compile chaque `payees.regex` en NSRegularExpression case-insensitive.
    /// - Si EXACTEMENT 1 tier match → renvoie ce tier (signal sûr).
    /// - Si 0 ou 2+ matches → renvoie nil (ambigu : on laisse le moteur trancher).
    /// - Les regex invalides sont silencieusement ignorées (`try?`).
    ///
    /// Cas typique : l'utilisateur a un tier "Payoo" avec regex `(?i)PAYOO` → tous les
    /// libellés "PAYOO …" matchent et sont assignés à ce tier directement, sans passer
    /// par le moteur (qui pourrait halluciner).
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

    // MARK: - User actions (toutes cascadent par défaut sur les rows en cluster pending)

    /// Confirme la suggestion engine pour cette row. Cascade aux similaires pending si
    /// `cascade=true`. Garde la resolution intacte (la suggestion reste).
    @discardableResult
    func confirm(rowId: UUID, cascade: Bool = true) -> Int {
        guard let idx = session.rows.firstIndex(where: { $0.id == rowId }) else { return 0 }
        session.rows[idx].userAction = .confirmed
        var cascaded = 0
        if cascade {
            let source = session.rows[idx]
            for sidx in pendingSimilarIndices(to: source) {
                session.rows[sidx].userAction = .confirmed
                // Copie la resolution si la cible était .pending — pour qu'au commit
                // on sache quoi créer/lier.
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

    /// Reset n'utilise jamais le cascade (volontairement : on veut pouvoir réviser 1 row).
    func resetAction(rowId: UUID) {
        guard let idx = session.rows.firstIndex(where: { $0.id == rowId }) else { return }
        session.rows[idx].userAction = .pending
        scheduleSave()
    }

    /// Assigne un payee existant à la row (et aux similaires pending si cascade).
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

    /// Pour chaque row .needsManualPick : tente Sirene + LLM + MapKit, et si on récupère
    /// un signal exploitable, "upgrade" la résolution vers .suggestCreate avec les infos
    /// enrichies. Dedupe par libellé brut pour ne pas spammer les API.
    /// Délai inter-appels 150ms (Sirene est limitée ~7 req/s).
    func enrichUnresolvedRows() async {
        guard !isEnriching else { return }
        isEnriching = true
        enrichProgress = 0
        defer { isEnriching = false }

        // Indices des rows à enrichir, dédupliqués par raw label.
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
            let canonical = (try? EngineBootstrap.shared.engine?.normalizer.parse(row.rawLabel).merchantCandidate) ?? row.rawLabel
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

    /// Applique le résultat d'enrichissement à toutes les rows partageant le même rawLabel
    /// (dedupe → 1 appel API par libellé unique).
    private func applyEnrichment(_ result: MerchantEnrichment, toRowsMatching rawLabel: String) {
        let key = rawLabel.lowercased()
        for i in session.rows.indices where session.rows[i].rawLabel.lowercased() == key {
            // Upgrade needsManualPick → suggestCreate si on a un name + (siret ou domain ou coords)
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

    /// Applique un résultat d'enrichissement choisi via `EnrichmentSheetView` à une row.
    /// Marque la row `.manuallySet` (l'utilisateur a pris une décision explicite).
    /// Cascade aux rows similaires pending.
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

    /// Crée un nouveau payee depuis une fiche de création (PayeeCreationFormSheet) et l'assigne à la row.
    /// `newPayee` est un Tiers avec id=0 — l'insertion en DB lui donne son vrai id.
    /// Cascade aux rows similaires pending.
    @discardableResult
    func createPayeeAndAssign(rowId: UUID, newPayee: Tiers, cascade: Bool = true) -> Int {
        // 1. Insert basique (name + regex + categoryId), récupère l'id
        let regex = newPayee.regex ?? ""
        guard let newId = txRepo.addTiersAndGetId(
            name: newPayee.name,
            regex: regex,
            categoryId: newPayee.categoryId
        ) else {
            lastError = "Échec de la création du tier."
            return 0
        }
        // 2. Met à jour les champs étendus (domain, city, country, address, engine_merchant_id, group_id, custom, note)
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
        // 4. Assign la row + cascade
        let cascaded = assign(rowId: rowId, payee: final, cascade: cascade)
        // 5. Trace le tier créé sur la row source → nettoyage possible si annulation.
        if let idx = session.rows.firstIndex(where: { $0.id == rowId }) {
            session.rows[idx].createdPayeeId = newId
            scheduleSave()
        }
        return cascaded
    }

    /// Ids uniques des tiers CRÉÉS pendant cette session (via « Créer un nouveau tier »).
    /// Sert au nettoyage optionnel à l'annulation.
    var createdPayeeIds: [Int] {
        Array(Set(session.rows.compactMap { $0.createdPayeeId }))
    }

    var createdPayeeCount: Int { createdPayeeIds.count }

    /// Variante de `assign` qui pousse aussi des champs supplémentaires sur le payee existant
    /// (mise à jour via TierUpdateSheet). Cascade aux rows similaires.
    @discardableResult
    func assignAndUpdatePayee(rowId: UUID, payee: Tiers, updatedPayee: Tiers, cascade: Bool = true) -> Int {
        // 1. Persiste le payee mis à jour
        _ = txRepo.updatePayeeFull(updatedPayee)
        // 2. Recharge allTiers pour que la suite voie la nouvelle version
        allTiers = txRepo.fetchTiers()
        let resolved = allTiers.first(where: { $0.id == payee.id }) ?? updatedPayee
        // 3. Délègue à assign avec le payee à jour
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

    /// Debounced save : si plusieurs actions arrivent en rafale, on n'écrit qu'une fois après 500ms.
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

    /// Force la sauvegarde immédiate (à appeler avant un commit ou un dismiss critique).
    func saveNow() {
        saveTask?.cancel()
        session.updatedAt = Date()
        _ = sessionRepo.saveSession(session)
    }

    // MARK: - Commit

    /// Insère toutes les rows ready (confirmed / manuallySet) dans la table `transactions`.
    /// Crée les payees pour les suggestions confirmées. Annule la session à la fin (status=completed).
    func commit() async {
        guard let accountId = session.accountId else {
            lastError = "Session sans compte cible."
            return
        }
        let resolver: TierResolver? = {
            guard let engine = EngineBootstrap.shared.engine else { return nil }
            return TierResolver(engine: engine, dbPath: DatabaseManager.shared.sqliteURL().path)
        }()

        var summary = ImportCommitSummary()
        var pendingInserts: [PendingTransaction] = []
        var rowToInsertIndex: [UUID: Int] = [:]
        /// Cache intra-batch des payees créés/résolus par engine_merchant_id.
        /// Évite de recréer N payees Apple/Grab quand N lignes partagent le même canonical.
        var resolvedByEngineId: [String: Int] = [:]
        /// Cache intra-batch par nom normalisé (fallback quand engine_id n'est pas connu).
        var resolvedByNameKey: [String: Int] = [:]

        // Helper local : cherche un payee existant côté app par engine_id ou par nom.
        // Backfill engine_merchant_id si on match par nom (pour les futurs imports).
        func findOrLink(engineMerchantId eid: String, canonicalName: String) -> Int? {
            // 1) Cache intra-batch
            if let pid = resolvedByEngineId[eid] { return pid }
            // 2) Match par engine_merchant_id dans allTiers
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
                // Backfill : on enregistre l'engine_id sur ce tier existant pour
                // que les prochains imports le retrouvent directement (étape 2).
                var updated = existing
                updated.engineMerchantId = eid
                _ = txRepo.updatePayeeFull(updated)
                resolvedByEngineId[eid] = existing.id
                resolvedByNameKey[needle] = existing.id
                return existing.id
            }
            return nil
        }

        for row in session.rows where row.userAction == .confirmed || row.userAction == .manuallySet {
            var payeeId: Int? = row.assignedPayeeId

            // Si .confirmed sur une suggestion, créer le payee à la volée
            if payeeId == nil, row.userAction == .confirmed {
                switch row.resolution {
                case .matched(let pid, let eid, _, _, _):
                    // Le snapshot disait .matched : on REUTILISE le payee_id capturé.
                    // Plus la safety net via findOrLink (cache intra-batch).
                    if let pid {
                        payeeId = pid
                    } else if let eid {
                        payeeId = findOrLink(engineMerchantId: eid, canonicalName: "")
                    }
                case .suggestCreate(let eid, let displayName, let city, let country, _):
                    // Re-vérifie d'abord côté app + cache batch (rows similaires
                    // précédentes ont peut-être déjà créé le payee dans CE commit).
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
                    if let newId = txRepo.addTiersAndGetId(name: name, regex: "", categoryId: nil) {
                        // Marquer comme custom (personne) sans re-fetcher toute la table.
                        let contactTiers = Tiers(
                            id: newId, name: name, regex: nil,
                            categoryId: nil, linkedCompteId: nil,
                            engineMerchantId: nil, domain: nil,
                            address: nil, city: nil, country: nil,
                            groupId: nil, custom: true, note: nil
                        )
                        _ = txRepo.updatePayeeFull(contactTiers)
                        payeeId = newId
                        summary.newContacts += 1
                    }
                case .systemOperation, .needsManualPick, .pending:
                    // payee_id reste nil — la transaction sera insérée sans tier
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

        // ⚠️ L'indice de moyen de paiement déduit du libellé (CB, VIREMENT…)
        // n'alimente plus `payment_type_id` mais la métadonnée qui porte le rôle
        // correspondant — et SEULEMENT si l'utilisateur en a créé une.
        //
        // Sans clé portant ce rôle, l'indice est simplement ignoré : on ne crée
        // pas une métadonnée dans le dos de l'utilisateur. C'est ce qui permet à
        // une base neuve de n'avoir aucune métadonnée tant qu'il n'en veut pas,
        // tout en préservant le comportement des bases migrées (où la clé
        // « Mode de paiement » a été recréée à partir des données existantes).
        let metadataRepo = TransactionMetadataRepository()
        if let paymentKeyId = metadataRepo.key(withRole: .paymentMethod)?.id {
            for row in session.rows {
                guard let hint = row.paymentTypeHint,
                      let transactionId = result.insertedIds[row.sourceRowNumber] else { continue }
                metadataRepo.setValue(hint, keyId: paymentKeyId, transactionId: transactionId)
            }
        }

        // Compte les skipped
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

    /// Annule la session (status = cancelled, supprime de la DB).
    /// - Parameter deletingCreatedPayees: si true, supprime aussi les tiers créés pendant
    ///   la session (nettoyage des tiers fantômes). Les transactions éventuellement liées
    ///   sont désassignées (SET NULL), jamais perdues.
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

/// Info éphémère sur la dernière action cascadée — affichée comme toast dans l'UI.
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
