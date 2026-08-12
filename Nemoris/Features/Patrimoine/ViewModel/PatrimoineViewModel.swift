import Foundation
import Observation

// MARK: - PatrimoineViewModel
//
// VM principal du module Patrimoine. Orchestre :
//   • Les 3 collections persistées (assets / real estate / loans)
//   • La résolution dynamique des valeurs liées aux comptes existants
//   • La persistance opportuniste de `last_known_value` pour les assets linkés
//
// **Étape 2** : seuls les assets sont vraiment "live" (chargement + résolution).
// Real estate et loans sont chargés mais pas encore consommés par l'UI — leurs
// sections arriveront aux étapes 3 et 4. On charge tout dès maintenant pour éviter
// d'éparpiller des `load()` partiels au fur et à mesure.

/// Provenance de la valeur résolue d'un asset. Sert à afficher un badge contextuel
/// dans la liste (lié, manuel, lien rompu).
enum AssetValueSource {
    case manual              // Mode standalone, valeur saisie par l'user
    case linkedAccount       // Lié à un compte bancaire (Account)
    case linkedInvestment    // Lié à un compte investissement (InvestmentAccount)
    case brokenLink          // L'ID lié existe encore en mémoire mais le compte est introuvable
                             // (cas edge — SQL devrait avoir SET NULL côté delete cascade)
}

@Observable
final class PatrimoineViewModel {

    // MARK: - State persistant

    var assets: [PatrimoineAsset] = []
    var realEstates: [PatrimoineRealEstate] = []
    var loans: [PatrimoineLoan] = []

    /// Cache des comptes "transactions" — sert au picker, au libellé "Lié à : Livret A",
    /// et à valider rapidement qu'un lien pointe vers un compte qui existe encore.
    var availableBankAccounts: [Account] = []

    /// Cache des comptes investissements — même usage.
    var availableInvestmentAccounts: [InvestmentAccount] = []

    /// Valeurs résolues : assetId → valeur courante. Recalculé à chaque `load()`.
    /// On garde la map plutôt que de recalculer à chaque accès UI : évite de
    /// retoucher la DB sur chaque scroll de la liste.
    var resolvedAssetValues: [Int: Double] = [:]

    /// Source de la valeur résolue par asset — utile pour les badges dans l'UI.
    var resolvedAssetSources: [Int: AssetValueSource] = [:]

    /// Set des assets dont le lien est cassé (compte source supprimé alors qu'il
    /// existe une trace de lien). Recalculé à chaque `load()` à partir des sources
    /// résolues. Permet à la View de cibler les rows à mettre en avant.
    var brokenLinkAssetIds: Set<Int> = []

    /// Vrai s'il existe au moins 1 asset au lien rompu — utilisé pour décider
    /// d'afficher une banner d'alerte en tête de la List.
    var hasBrokenLinks: Bool { !brokenLinkAssetIds.isEmpty }

    var isLoading = false

    // MARK: - Repositories

    private let patrimoineRepo: PatrimoineRepository
    private let transactionRepo: TransactionRepository
    private let investmentRepo: InvestmentRepository
    private let goalRepo: GoalRepository

    /// La valeur par défaut vise la base de l'application : aucun site d'appel
    /// ne change. Les tests injectent une base temporaire.
    init(store: SQLiteStore = SQLiteStore()) {
        patrimoineRepo = PatrimoineRepository(store: store)
        transactionRepo = TransactionRepository(store: store)
        investmentRepo = InvestmentRepository(store: store)
        goalRepo = GoalRepository(store: store)
    }

    // MARK: - Computed (agrégats)

    /// Somme de tous les assets résolus (mobilier & liquidités).
    var totalAssetsValue: Double {
        PatrimoineSnapshotBuilder.totalAssetsValue(assets: assets, resolvedValues: resolvedAssetValues)
    }

    /// Somme de la valeur actuelle estimée de tous les biens immobiliers.
    /// `currentValue` est saisi manuellement par l'user — pas de résolution dynamique
    /// nécessaire (l'immobilier ne s'apparente pas à un compte qui bouge tout seul).
    var totalRealEstateValue: Double {
        realEstates.reduce(0) { $0 + $1.currentValue }
    }

    /// Plus-value brute estimée agrégée (Σ currentValue − Σ purchasePrice).
    /// Affichée dans le header de la section Immobilier.
    var totalRealEstateCapitalGain: Double {
        realEstates.reduce(0) { $0 + $1.capitalGain }
    }

    // MARK: - Snapshot agrégé (vue globale)

    /// Snapshot complet du patrimoine à un instant T — utilisé par le hero éditorial
    /// du module et par le bandeau Dashboard. Calculé en mémoire à chaque accès
    /// (toutes les opérations sont des sommations O(n) sur des collections en RAM,
    /// donc négligeable même pour des centaines d'items).
    var snapshot: PatrimoineSnapshot {
        PatrimoineSnapshotBuilder.snapshot(
            assets: assets,
            realEstates: realEstates,
            loans: loans,
            resolvedValues: resolvedAssetValues,
            loanStates: loanStates
        )
    }

    /// Ratio dette/patrimoine brut (0…1+). Utilisé pour la barre dans le hero qui
    /// matérialise le "poids" du passif. Renvoie 0 si pas de brut (évite la /0).
    var leverageRatio: Double {
        let assets = snapshot.totalAssets
        guard assets > 0 else { return 0 }
        return min(2.0, snapshot.totalLiabilities / assets)
    }

    /// États des prêts calculés via `LoanCalculator` (cache rafraîchi à chaque load).
    /// `loanId → LoanState` pour éviter de recalculer à chaque accès UI.
    var loanStates: [Int: LoanState] = [:]

    /// Somme des capitaux restants dus sur tous les prêts (côté passif du patrimoine).
    var totalLoansRemainingCapital: Double {
        PatrimoineSnapshotBuilder.totalLiabilities(loans: loans, loanStates: loanStates)
    }

    // MARK: - Goals state

    /// Goals chargés depuis SQLite. Rafraîchi à chaque `load()`.
    var goals: [Goal] = []

    /// Cache des progressions calculées via `GoalCalculator`. `goalId → progress`.
    /// Recalculé à chaque `load()` pour rester aligné avec le snapshot patrimoine.
    var goalProgresses: [Int: GoalProgress] = [:]

    /// Baseline de dette pour les goals `.debtPayoff`. Stockée en UserDefaults
    /// par goal_id — l'idée : au moment où l'user crée un goal de remboursement,
    /// on capture la dette MAX (= snapshot.totalLiabilities à cet instant) qui
    /// devient le 100% à atteindre. Sans ça, le progress serait toujours 0%
    /// (current dette / current dette = 1 → ratio = 0).
    private func debtBaseline(forGoalId id: Int) -> Double {
        UserDefaults.standard.double(forKey: "goalDebtBaseline_\(id)")
    }

    private func captureDebtBaseline(forGoalId id: Int, value: Double) {
        UserDefaults.standard.set(value, forKey: "goalDebtBaseline_\(id)")
    }

    /// IDs des comptes déjà liés à un asset Patrimoine. Utilisé par le picker pour
    /// griser les choix indisponibles (un compte ne peut être lié qu'à 1 seul asset
    /// à la fois — règle métier renforcée par UNIQUE INDEX SQL).
    var linkedBankAccountIds: Set<Int> {
        Set(assets.compactMap { $0.linkedAccountId })
    }

    var linkedInvestmentAccountIds: Set<Int> {
        Set(assets.compactMap { $0.linkedInvestmentAccountId })
    }

    // MARK: - Public API

    /// Charge l'intégralité des données du module et résout les valeurs liées.
    /// Synchronie volontaire — SQLite est local, pas la peine de Task.detached pour
    /// quelques dizaines de rows.
    func load() {
        isLoading = true
        // Caches comptes d'abord — la résolution des assets en a besoin.
        availableBankAccounts = transactionRepo.fetchAccounts()
        availableInvestmentAccounts = investmentRepo.fetchAccounts()

        // Puis les 3 entités Patrimoine.
        assets = patrimoineRepo.fetchAssets()
        realEstates = patrimoineRepo.fetchRealEstate()
        loans = patrimoineRepo.fetchLoans()

        // Résolution des valeurs assets via le moteur pur, partagé avec le Dashboard.
        // Les soldes bancaires sont fetchés UNE fois, et seulement pour les comptes
        // réellement liés (un `fetchAccountBalance` = un SUM sur toute la table).
        let (values, sources) = PatrimoineSnapshotBuilder.resolveValues(
            assets: assets,
            existingBankAccountIds: Set(availableBankAccounts.map(\.id)),
            bankBalances: bankBalances(for: assets),
            investmentAccounts: availableInvestmentAccounts
        )
        resolvedAssetValues = values
        resolvedAssetSources = sources

        // Persistance opportuniste de last_known_value — uniquement si le lien a été
        // résolu vivant, pour ne pas écraser une valeur historique avec 0 quand le
        // lien est cassé. Reste ici : un moteur pur n'écrit pas en base.
        for asset in assets where sources[asset.id] == .linkedAccount || sources[asset.id] == .linkedInvestment {
            guard let value = values[asset.id], abs(value - asset.lastKnownValue) > 0.005 else { continue }
            patrimoineRepo.updateLastKnownValue(assetId: asset.id, value: value)
        }

        // Recense les liens rompus pour mettre en avant les rows concernées et
        // permettre une bannière d'alerte au sommet de la List.
        brokenLinkAssetIds = Set(sources.compactMap { $0.value == .brokenLink ? $0.key : nil })

        // Calcul des états de prêt — Swift pur, ultra rapide même pour 50 prêts.
        var states: [Int: LoanState] = [:]
        for loan in loans {
            states[loan.id] = LoanCalculator.compute(loan: loan)
        }
        loanStates = states

        // Goals — chargés après loans (la baseline debt_payoff a besoin du snapshot
        // courant, et le snapshot dépend des assets/realEstates/loans déjà chargés).
        goals = goalRepo.fetchGoals()
        let snap = snapshot  // appel unique du computed
        let assetsTotal = totalAssetsValue
        var progresses: [Int: GoalProgress] = [:]
        for goal in goals {
            // Pour debt_payoff : on lit la baseline persistée. Si absente (cas d'un
            // goal qui vient d'être créé ou import d'une vieille DB), on la capture
            // maintenant avec la dette courante — au moins le progress sera stable
            // dans le temps même s'il commence à 0.
            var baseline: Double? = nil
            if goal.kind == .debtPayoff {
                let stored = debtBaseline(forGoalId: goal.id)
                if stored > 0 {
                    baseline = stored
                } else if snap.totalLiabilities > 0 {
                    captureDebtBaseline(forGoalId: goal.id, value: snap.totalLiabilities)
                    baseline = snap.totalLiabilities
                }
            }
            progresses[goal.id] = GoalCalculator.progress(
                for: goal,
                snapshot: snap,
                totalAssetsValue: assetsTotal,
                initialDebtForPayoff: baseline
            )
        }
        goalProgresses = progresses

        isLoading = false
    }

    // MARK: - Goals — CRUD wrappers

    @discardableResult
    func createGoal(name: String, kind: GoalKind, targetAmount: Double,
                    deadlineDate: Date?, customCurrentAmount: Double,
                    notes: String?) -> Bool {
        let ok = goalRepo.addGoal(
            name: name, kind: kind, targetAmount: targetAmount,
            deadlineDate: deadlineDate, customCurrentAmount: customCurrentAmount,
            notes: notes
        )
        if ok { load() }
        return ok
    }

    @discardableResult
    func updateGoal(_ goal: Goal) -> Bool {
        let ok = goalRepo.updateGoal(goal)
        if ok { load() }
        return ok
    }

    @discardableResult
    func deleteGoal(id: Int) -> Bool {
        // Nettoie aussi la baseline persistée (sinon UserDefaults grossit pour rien
        // au fil des goals supprimés et recréés avec le même id auto-incrémenté).
        UserDefaults.standard.removeObject(forKey: "goalDebtBaseline_\(id)")
        let ok = goalRepo.deleteGoal(id: id)
        if ok { load() }
        return ok
    }

    /// Résout la valeur d'un asset selon son mode (linked ou standalone).
    /// Exposée pour le form et le picker (pour afficher la valeur lue en preview).
    /// Délègue au moteur pur — la règle de résolution n'existe qu'à un seul endroit.
    func resolveValue(for asset: PatrimoineAsset) -> (value: Double, source: AssetValueSource) {
        PatrimoineSnapshotBuilder.resolveValue(
            for: asset,
            existingBankAccountIds: Set(availableBankAccounts.map(\.id)),
            bankBalances: bankBalances(for: [asset]),
            investmentAccounts: availableInvestmentAccounts
        )
    }

    /// Soldes des comptes bancaires liés aux assets fournis. Un seul
    /// `fetchAccountBalance` par compte, et uniquement pour les comptes existants —
    /// un compte supprimé doit rester détecté comme lien rompu, pas lu à 0 €.
    private func bankBalances(for assets: [PatrimoineAsset]) -> [Int: Double] {
        let existing = Set(availableBankAccounts.map(\.id))
        var balances: [Int: Double] = [:]
        for id in PatrimoineSnapshotBuilder.linkedBankAccountIds(in: assets) where existing.contains(id) {
            balances[id] = transactionRepo.fetchAccountBalance(accountId: id, upToDate: nil)
        }
        return balances
    }

    /// Wrapper côté VM qui calcule la valeur fraîche d'un compte source sans toucher
    /// au state du VM. Utilisé par le picker pour afficher "Valeur lue : X €" à côté
    /// de chaque compte sélectionnable.
    func liveValue(forBankAccountId id: Int) -> Double {
        transactionRepo.fetchAccountBalance(accountId: id, upToDate: nil)
    }

    func liveValue(forInvestmentAccountId id: Int) -> Double {
        guard let acc = availableInvestmentAccounts.first(where: { $0.id == id }) else { return 0 }
        return acc.currentValue + acc.cashBalance
    }

    // MARK: - Assets — CRUD wrapper

    /// Crée un asset. Si linked, `lastKnownValue` est initialisé avec la valeur lue
    /// fraîchement pour pouvoir l'afficher en fallback si le compte source disparaît.
    @discardableResult
    func createAsset(name: String, kind: AssetKind,
                     linkedAccountId: Int?, linkedInvestmentAccountId: Int?,
                     manualValue: Double, notes: String?) -> Bool {
        // Détection conflit avant l'INSERT (l'UNIQUE INDEX est la 2nde ligne de défense).
        if let conflict = patrimoineRepo.assetIdLinkedTo(
            accountId: linkedAccountId,
            investmentAccountId: linkedInvestmentAccountId,
            excludingAssetId: nil
        ) {
            print("[Patrimoine] createAsset refused — link conflict with asset id \(conflict)")
            return false
        }
        // Pour un asset linked, on calcule la valeur initiale du snapshot last_known_value
        // pour qu'il ne soit pas à 0 même si l'user ne consulte pas la liste tout de suite.
        var lastKnown: Double = manualValue
        if let bankId = linkedAccountId {
            lastKnown = transactionRepo.fetchAccountBalance(accountId: bankId, upToDate: nil)
        } else if let invId = linkedInvestmentAccountId,
                  let acc = availableInvestmentAccounts.first(where: { $0.id == invId }) {
            lastKnown = acc.currentValue + acc.cashBalance
        }

        let ok = patrimoineRepo.addAsset(
            name: name,
            assetKind: kind,
            linkedAccountId: linkedAccountId,
            linkedInvestmentAccountId: linkedInvestmentAccountId,
            manualValue: manualValue,
            lastKnownValue: lastKnown,
            notes: notes
        )
        if ok { load() }
        return ok
    }

    @discardableResult
    func updateAsset(_ asset: PatrimoineAsset) -> Bool {
        // Conflit possible aussi sur update si l'user re-link vers un autre compte
        if let conflict = patrimoineRepo.assetIdLinkedTo(
            accountId: asset.linkedAccountId,
            investmentAccountId: asset.linkedInvestmentAccountId,
            excludingAssetId: asset.id
        ) {
            print("[Patrimoine] updateAsset refused — link conflict with asset id \(conflict)")
            return false
        }
        let ok = patrimoineRepo.updateAsset(asset)
        if ok { load() }
        return ok
    }

    @discardableResult
    func deleteAsset(id: Int) -> Bool {
        let ok = patrimoineRepo.deleteAsset(id: id)
        if ok { load() }
        return ok
    }

    // MARK: - Real estate — CRUD wrapper

    @discardableResult
    func createRealEstate(name: String, purchasePrice: Double, purchaseDate: Date,
                          currentValue: Double, estimatedAt: Date?,
                          address: String?, notes: String?) -> Bool {
        let ok = patrimoineRepo.addRealEstate(
            name: name,
            purchasePrice: purchasePrice,
            purchaseDate: purchaseDate,
            currentValue: currentValue,
            estimatedAt: estimatedAt,
            address: address,
            notes: notes
        )
        if ok { load() }
        return ok
    }

    @discardableResult
    func updateRealEstate(_ item: PatrimoineRealEstate) -> Bool {
        let ok = patrimoineRepo.updateRealEstate(item)
        if ok { load() }
        return ok
    }

    @discardableResult
    func deleteRealEstate(id: Int) -> Bool {
        // ON DELETE SET NULL côté SQL fait que les prêts liés à ce bien (loan.linked_real_estate_id)
        // passent automatiquement en "prêt orphelin" sans être supprimés — exactement
        // la sémantique souhaitée (le user peut continuer à suivre la dette même
        // après vente du bien).
        let ok = patrimoineRepo.deleteRealEstate(id: id)
        if ok { load() }
        return ok
    }

    // MARK: - Loans — CRUD wrapper

    @discardableResult
    func createLoan(name: String, loanType: LoanType, principal: Double,
                    annualRate: Double, durationMonths: Int, deferralMonths: Int,
                    startDate: Date, insuranceMonthly: Double,
                    linkedRealEstateId: Int?, notes: String?) -> Bool {
        let ok = patrimoineRepo.addLoan(
            name: name,
            loanType: loanType,
            principal: principal,
            annualRate: annualRate,
            durationMonths: durationMonths,
            deferralMonths: deferralMonths,
            startDate: startDate,
            insuranceMonthly: insuranceMonthly,
            linkedRealEstateId: linkedRealEstateId,
            notes: notes
        )
        if ok { load() }
        return ok
    }

    /// Coût mensuel total (mensualité d'amortissement + assurance) sommé sur tous
    /// les prêts actifs (non terminés et non pending). Affiché dans le header de
    /// la section Prêts pour donner le "poids" mensuel total du passif.
    var totalMonthlyLoanCost: Double {
        loans.reduce(0) { acc, loan in
            let state = loanStates[loan.id]
            // On compte la mensualité uniquement si le prêt est en cours d'amortissement.
            // L'assurance, elle, court tant que le prêt n'est pas terminé (différé inclus).
            let m = (state?.isPending == true || state?.isCompleted == true) ? 0 : (state?.monthlyPayment ?? 0)
            let ins = (state?.isCompleted == true) ? 0 : loan.insuranceMonthly
            return acc + m + ins
        }
    }

    @discardableResult
    func updateLoan(_ loan: PatrimoineLoan) -> Bool {
        let ok = patrimoineRepo.updateLoan(loan)
        if ok { load() }
        return ok
    }

    @discardableResult
    func deleteLoan(id: Int) -> Bool {
        let ok = patrimoineRepo.deleteLoan(id: id)
        if ok { load() }
        return ok
    }

    /// Nom du bien immobilier lié à un prêt, ou nil si aucun lien (ou bien supprimé).
    func realEstateName(forLoanLinked id: Int?) -> String? {
        guard let id else { return nil }
        return realEstates.first(where: { $0.id == id })?.name
    }

    // MARK: - Helpers d'affichage (libellés "Lié à …")

    /// Texte descriptif court pour la source d'un asset, prêt à être affiché en
    /// sous-titre de row. Pas de logique conditionnelle dans la View.
    func sourceLabel(for asset: PatrimoineAsset) -> String {
        if let bankId = asset.linkedAccountId,
           let acc = availableBankAccounts.first(where: { $0.id == bankId }) {
            return "Lié à \(acc.name)"
        }
        if let invId = asset.linkedInvestmentAccountId,
           let acc = availableInvestmentAccounts.first(where: { $0.id == invId }) {
            return "Lié à \(acc.name)"
        }
        if asset.isLinked {
            // Le lien existe en mémoire mais le compte source a disparu — l'UNIQUE
            // INDEX et le ON DELETE SET NULL devraient empêcher ce cas, mais on
            // tient ce libellé en filet de sécurité.
            return "Lien rompu (dernière valeur connue)"
        }
        return "Valeur saisie manuellement"
    }
}
