import SwiftUI
import Charts

// MARK: - AXE J Phase 2 — Niveau Valeur (Position Detail)
//
// Écran de détail d'une position individuelle, accessible via NavigationLink depuis
// AccountDetailView. Affiche :
//   - Hero card position (current value + variation sur la plage)
//   - KPIs : Quantité · PRU · Valeur actuelle · P&L abs+%
//   - Chart évolution avec point d'entrée (purchase_date) highlighté
//   - Time range chips
//   - Bouton sync historique en toolbar
//
// Le "point d'entrée" est marqué par un PointMark distinct sur le chart à la
// date d'achat (`position.purchaseDate`) avec une annotation "Entrée @ PRU".

struct InvestmentPositionDetailView: View {
    @Bindable var viewModel: InvestmentsViewModel
    let account: InvestmentAccount
    let position: InvestmentPosition

    @State private var localTimeRange: InvestmentTimeRange = .all
    @State private var priceHistory: [InvestmentPricePoint] = []
    /// Série INTRADAY 30 min (plage 1J uniquement) — chargée on-demand quand
    /// l'user sélectionne 1J, cache 48 h avec skip fraîcheur < 25 min.
    @State private var intradayHistory: [InvestmentPricePoint] = []
    @State private var isSyncing = false
    @State private var statusMessage: String?
    @State private var showEditForm = false

    // AXE K — ordres
    // Pour éviter le bug "tap pour modifier crée un nouveau ordre", on utilise
    // 2 sheets distinctes (pattern recommandé Apple) :
    //   - showOrderAddForm  : nouvelle saisie (order = nil)
    //   - editingOrder (Identifiable) : édition d'un ordre existant
    // Une seule `sheet(isPresented:)` partagée avec un `@State` optionnel
    // souffrait d'une race de capture de closure — la sheet se présentait
    // parfois avec `editingOrder = nil` même si on venait de l'assigner.
    @State private var orders: [InvestmentOrder] = []
    @State private var showOrderAddForm = false
    @State private var editingOrder: InvestmentOrder?

    // AXE M : scrub interactif sur la position chart. Permet de "fixer" la chart
    // sous le doigt (consomme les gestures horizontaux), tout en laissant le scroll
    // vertical fonctionner (le gesture refuse les drags verticaux).
    @State private var chartSelectedDate: Date?

    // Suppression position
    @State private var showDeletePositionConfirm = false
    /// Skeleton tant que `.task` n'a pas terminé loadCachedHistory + loadOrders.
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismissDetail
    @Environment(AppState.self) private var appState

    private let repository = InvestmentRepository()

    // MARK: - Derived

    /// Valeur de la position dans le temps = qty_à_cette_date × close.
    ///
    /// On utilise la quantité HISTORIQUE à chaque point (calculée depuis les
    /// ordres : Σ BUY − Σ SELL avant la date) au lieu de la qty actuelle.
    /// Sans ça, une position vendue afficherait une ligne plate à 0 alors
    /// qu'elle avait bien une valeur de marché tant qu'elle était détenue.
    private var positionValuePoints: [PortfolioEvolutionPoint] {
        let cutoff = localTimeRange.startDate
        return priceHistory
            .sorted { $0.date < $1.date }
            .filter { point in
                guard let cutoff else { return true }
                return point.date >= cutoff
            }
            .map { point in
                PortfolioEvolutionPoint(
                    date: point.date,
                    value: point.close * quantityAt(date: point.date)
                )
            }
    }

    /// Quantité détenue à une date donnée, reconstruite depuis les ordres.
    /// Σ BUY − Σ SELL avant ou égal à `date`. Les DIV n'affectent pas la qty.
    /// Clampée à 0 si plus de SELL que de BUY (edge case data corruption).
    private func quantityAt(date: Date) -> Double {
        var qty: Double = 0
        for order in orders where order.executedAt <= date {
            switch order.orderType {
            case .buy:      qty += order.quantity
            case .sell:     qty -= order.quantity
            case .dividend: break
            }
        }
        return max(0, qty)
    }

    /// PRU pondéré à une date donnée, calculé à partir des BUYs antérieurs.
    /// Σ(qty × price + fees) des BUYs / Σ qty des BUYs.
    /// Sert au shading "zone gain/perte" sur le chart : la zone entre la courbe
    /// du cours et la ligne du PRU à cet instant montre le gain/perte latent.
    private func pruAt(date: Date) -> Double {
        var totalQty: Double = 0
        var totalCost: Double = 0
        for order in orders.sorted(by: { $0.executedAt < $1.executedAt })
            where order.executedAt <= date && order.orderType == .buy {
            totalQty += order.quantity
            totalCost += order.quantity * order.unitPrice + order.fees
        }
        return totalQty > 0 ? totalCost / totalQty : 0
    }

    /// PRU pondéré "actuel" (toutes les BUYs cumulées). Utilisé pour la RuleMark
    /// horizontale qui matérialise le seuil de break-even.
    private var currentWeightedPRU: Double {
        pruAt(date: Date())
    }

    /// Points de cours filtrés à la plage temporelle. Sert au chart principal
    /// (close × 1, pas × qty — on visualise le titre, pas la poche).
    private var positionPricePoints: [InvestmentPricePoint] {
        let cutoff = localTimeRange.startDate
        return priceHistory
            .sorted { $0.date < $1.date }
            .filter { point in
                guard let cutoff else { return true }
                return point.date >= cutoff
            }
    }

    /// Points ASSAINIS pour le rendu du chart : triés par date, un seul point
    /// par pas de temps, `close` fini et strictement positif, ET valeurs
    /// aberrantes rejetées (`rejectOutliers`).
    ///
    /// Granularité adaptée à la plage : en 1J on trace la série INTRADAY 30 min
    /// des dernières 24 h glissantes (la série quotidienne n'a qu'un point sur
    /// cette fenêtre — rien à tracer) ; sinon la série quotidienne, dédupliquée
    /// par jour calendaire (prévention "code-barres").
    private var chartPoints: [InvestmentPricePoint] {
        if localTimeRange == .oneDay && !intradayHistory.isEmpty {
            // Intraday : un point par HORODATAGE (pas par jour !), fenêtre 24 h.
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            var seen = Set<Date>()
            let deduped = intradayHistory
                .filter { $0.close.isFinite && $0.close > 0 && $0.date >= cutoff }
                .sorted { $0.date < $1.date }
                .filter { seen.insert($0.date).inserted }
            return rejectOutliers(deduped)
        }

        var seenDays = Set<Date>()
        let cal = Calendar.current
        let deduped = positionPricePoints
            .filter { $0.close.isFinite && $0.close > 0 }
            .filter { seenDays.insert(cal.startOfDay(for: $0.date)).inserted }
        return rejectOutliers(deduped)
    }

    /// Prévention "code-barres" (2e ligne de défense) : une série de cours peut
    /// être CONTAMINÉE par deux échelles de prix incompatibles fusionnées sous
    /// le même identifiant — ex. un ticker qui résout vers le mauvais instrument
    /// Yahoo. Le chart alternerait alors entre 35 € et 300 € d'un point à
    /// l'autre → un peigne. On écarte tout point hors de l'intervalle
    /// [médiane / 4, médiane × 4] : une seule échelle survit, le rendu reste lisse.
    private func rejectOutliers(_ points: [InvestmentPricePoint]) -> [InvestmentPricePoint] {
        guard points.count >= 4 else { return points }
        let sortedCloses = points.map(\.close).sorted()
        let median = sortedCloses[sortedCloses.count / 2]
        guard median > 0 else { return points }
        let lower = median / 4, upper = median * 4
        let cleaned = points.filter { $0.close >= lower && $0.close <= upper }
        // Si le filtre écarte tout (médiane pathologique), on retombe sur la
        // série dédupliquée plutôt que d'afficher un chart vide.
        return cleaned.isEmpty ? points : cleaned
    }

    /// Domaine Y du chart calculé à partir des valeurs MEANINGFUL pour le cours :
    /// les `close` des price points + les `unitPrice` des BUY/SELL visibles + le PRU.
    /// On EXCLUT volontairement les dividendes (qui valent quelques centimes à
    /// quelques euros par titre, écrasaient l'axe Y vers 0 si inclus).
    /// Padding de ±8% pour ne pas coller aux bords.
    private var chartYDomain: ClosedRange<Double> {
        // chartPoints (et pas positionPricePoints) : en 1J le domaine doit
        // suivre la série intraday effectivement tracée.
        var values: [Double] = chartPoints.map(\.close)
        values.append(contentsOf:
            visibleOrders
                .filter { $0.orderType != .dividend }
                .map(\.unitPrice)
        )
        if currentWeightedPRU > 0 { values.append(currentWeightedPRU) }
        guard let lo = values.min(), let hi = values.max(), hi > lo else {
            return 0...100  // fallback safe
        }
        // Padding 8% en bas / 8% en haut. Si lo*0.92 < 0, on borne à 0 (les
        // cours sont positifs).
        let padded_lo = max(0, lo * 0.92)
        let padded_hi = hi * 1.08
        return padded_lo...padded_hi
    }

    /// Indique si la date d'achat est visible dans la plage actuelle.
    /// (Conservé pour compat — utilisé nulle part depuis le refacto multi-ordres.)
    private var entryPointInRange: Bool {
        guard let cutoff = localTimeRange.startDate else { return true }
        return position.purchaseDate >= cutoff
    }

    /// AXE K — ordres à afficher sur le chart : ceux qui tombent dans la plage temporelle
    /// sélectionnée. Pour "Max" (cutoff == nil) on prend tous les ordres.
    private var visibleOrders: [InvestmentOrder] {
        guard let cutoff = localTimeRange.startDate else { return orders }
        return orders.filter { $0.executedAt >= cutoff }
    }

    /// Couleur d'annotation sur le chart pour chaque type d'ordre.
    private func annotationColor(_ type: InvestmentOrderType) -> Color {
        switch type {
        case .buy:      return AppTheme.Colors.success         // achat = entrée à long terme = vert
        case .sell:     return AppTheme.Colors.danger          // vente = sortie = rouge
        case .dividend: return AppTheme.Colors.accentSecondary // dividende = brun secondaire
        }
    }

    /// True si la valeur de marché est inconnue (pas encore syncée) mais qu'on
    /// connaît au moins un cost basis via les ordres BUY. Dans ce cas on affiche
    /// le cost basis à la place et on cache le P&L (qui sinon serait -100%).
    private var valuationIsEstimated: Bool {
        position.currentValue <= 0 && position.investedAmount > 0
    }
    /// True si la position a été ouverte (au moins 1 BUY) puis fermée (qty
    /// nette actuelle = 0). On change le narratif du hero/KPIs : on ne parle
    /// plus de "valeur" mais de "P&L réalisé" sur toute la durée de détention.
    private var isClosedPosition: Bool {
        position.quantity <= 0 && orders.contains { $0.orderType == .buy }
    }
    /// Valeur à afficher dans le hero : valeur de marché si syncée, sinon cost
    /// basis pour ne pas montrer €0 alors qu'on a investi.
    private var displayedValuation: Double {
        valuationIsEstimated ? position.investedAmount : position.currentValue
    }

    /// Titre du hero adapté au cycle de vie de la position.
    private var heroTitle: String {
        if isClosedPosition { return "P&L réalisé sur la position" }
        if valuationIsEstimated { return "Valeur estimée (PRU × qty)" }
        return "Valeur de la position"
    }

    /// Valeur du hero adaptée :
    /// - Position fermée → P&L réalisé total (peut être positif ou négatif)
    /// - Pas sync → cost basis
    /// - Sync OK → valeur de marché
    private var heroValue: Double {
        if isClosedPosition { return realizedPnL }
        return displayedValuation
    }

    /// P&L réalisé = gains sur ventes passées + dividendes reçus.
    /// Méthode : pour chaque SELL, on calcule (sell_price − PRU_moyen_à_ce_moment)
    /// × qty_vendue − frais. Pour chaque DIV, on additionne qty × unit_price.
    /// Le PRU moyen évolue au fil des BUY (chronologique).
    private var realizedPnL: Double {
        var pnl: Double = 0
        var cumulativeBuyQty: Double = 0
        var cumulativeBuyCost: Double = 0
        let sorted = orders.sorted { $0.executedAt < $1.executedAt }
        for order in sorted {
            switch order.orderType {
            case .buy:
                cumulativeBuyQty += order.quantity
                cumulativeBuyCost += order.quantity * order.unitPrice + order.fees
            case .sell:
                // PRU pondéré à cet instant
                let avgPRU = cumulativeBuyQty > 0 ? cumulativeBuyCost / cumulativeBuyQty : 0
                let saleProceeds = order.quantity * order.unitPrice - order.fees
                let costBasis = order.quantity * avgPRU
                pnl += saleProceeds - costBasis
            case .dividend:
                pnl += order.quantity * order.unitPrice
            }
        }
        return pnl
    }

    /// P&L latent (non réalisé) = current_value − qty × PRU. C'est ce qui
    /// disparaît à la prochaine vente totale.
    private var unrealizedPnL: Double {
        position.currentValue - position.investedAmount
    }

    /// P&L total = latent + réalisé. C'est ce qu'on veut montrer en priorité.
    private var totalPnL: Double { unrealizedPnL + realizedPnL }

    /// Capital total investi cumulé (Σ BUY costs, sans déduction des SELL).
    /// Sert de dénominateur pour la variation % — plus stable que `investedAmount`
    /// (qui chute à 0 quand la position est fermée et fausserait la variation %).
    private var totalInvestedEver: Double {
        var cost: Double = 0
        for order in orders where order.orderType == .buy {
            cost += order.quantity * order.unitPrice + order.fees
        }
        return cost
    }

    private var totalPnLPct: Double {
        totalInvestedEver > 0 ? (totalPnL / totalInvestedEver) * 100 : 0
    }
    private var pnl: Double { totalPnL }
    private var pnlPct: Double { totalPnLPct }
    private var pnlColor: Color {
        pnl >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            AppTheme.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: AppTheme.Spacing.md) {
                    if !hasLoaded {
                        positionDetailSkeleton
                    } else {
                        heroAndChartCard
                        kpisCard
                        ordersCard       // AXE K — historique des ordres BUY/SELL/DIV
                        detailsCard
                        syncTraceCard    // Diagnostic dernière tentative de sync
                        if let statusMessage {
                            AppCard {
                                Text(statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
            }
            .refreshable {
                await syncHistory()
            }
        }
        .navigationTitle(position.assetName.isEmpty ? position.ticker : position.assetName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Sync déclenchée par pull-to-refresh sur la ScrollView — pas de bouton dédié.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showEditForm = true
                    } label: {
                        Label("Modifier la position", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showDeletePositionConfirm = true
                    } label: {
                        Label("Supprimer la position", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .tint(AppTheme.Colors.accent)
                }
            }
        }
        .sheet(isPresented: $showEditForm) {
            InvestmentPositionFormView(accountId: account.id, position: position) { p, isNew in
                viewModel.savePosition(p, isNew: isNew)
                appState.dataRefreshToken = UUID()
            }
        }
        .sheet(isPresented: $showOrderAddForm) {
            InvestmentOrderFormView(
                positionId: position.id,
                currency: account.currency,
                order: nil
            ) { savedOrder, _ in
                repository.addOrder(savedOrder)
                repository.recomputePositionFromOrders(positionId: position.id)
                loadOrders()
                viewModel.load()
                appState.dataRefreshToken = UUID()
            }
        }
        .sheet(item: $editingOrder) { orderToEdit in
            InvestmentOrderFormView(
                positionId: position.id,
                currency: account.currency,
                order: orderToEdit
            ) { savedOrder, _ in
                repository.updateOrder(savedOrder)
                repository.recomputePositionFromOrders(positionId: position.id)
                loadOrders()
                viewModel.load()
                appState.dataRefreshToken = UUID()
            }
        }
        .confirmationDialog(
            "Supprimer cette position ?",
            isPresented: $showDeletePositionConfirm,
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                viewModel.deletePosition(id: position.id)
                appState.dataRefreshToken = UUID()
                dismissDetail()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Tous les ordres rattachés (\(orders.count) au total) seront supprimés en cascade. Cette action est irréversible.")
        }
        .task {
            await Task.yield()
            loadCachedHistory()
            loadOrders()
            hasLoaded = true
            // Si la vue s'ouvre déjà sur 1J (état restauré), charge l'intraday.
            if localTimeRange == .oneDay {
                await loadIntradayHistory()
            }
        }
        .onChange(of: localTimeRange) { _, newRange in
            // Plage 1J → fetch on-demand de la série intraday 30 min (skip si
            // fraîche < 25 min côté service). Les autres plages n'en ont pas besoin.
            if newRange == .oneDay {
                Task { await loadIntradayHistory() }
            }
        }
    }

    /// Chargement de la série intraday : sync réseau (avec skip fraîcheur) puis
    /// lecture du cache sous les identifiants candidats (ISIN puis ticker —
    /// le service stocke sous `bestSyncIdentifier`).
    private func loadIntradayHistory() async {
        let identifier = position.bestSyncIdentifier
        guard !identifier.isEmpty else { return }
        _ = await InvestmentAutoSyncService.shared.syncIntradayHistory(identifier: identifier)
        let candidates = [position.isin, position.ticker].filter { !$0.isEmpty }
        for candidate in candidates {
            let points = PriceHistoryCache.shared.fetch(identifier: candidate, resolution: .intraday30m)
            if !points.isEmpty {
                intradayHistory = points
                return
            }
        }
        intradayHistory = []
    }

    // MARK: - Skeleton

    @ViewBuilder private var positionDetailSkeleton: some View {
        // Hero + chart
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            SkeletonHero()
            HStack(spacing: 6) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonBlock(width: 38, height: 26, cornerRadius: 13)
                }
                Spacer()
            }
            SkeletonChart(height: 200)
        }
        // KPIs
        AppCard {
            HStack(spacing: AppTheme.Spacing.sm) {
                SkeletonStatBadge()
                SkeletonStatBadge()
                SkeletonStatBadge()
                SkeletonStatBadge()
            }
        }
        // Orders
        AppCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    SkeletonLine(width: 110, height: 15)
                    Spacer()
                    SkeletonCircle(size: 22)
                }
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        SkeletonCircle(size: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            SkeletonLine(width: 110, height: 13)
                            SkeletonLine(width: 70, height: 11)
                        }
                        Spacer()
                        SkeletonLine(width: 60, height: 13)
                    }
                }
            }
        }
        // Details
        AppCard {
            SkeletonFormSection(rows: 4)
        }
    }

    // MARK: - Cards

    // AXE M : `syncIconButton` retiré — la sync est désormais déclenchée par le
    // bouton refresh dans la toolbar (à gauche du menu ⋯), pas dans le hero.
    /// Chantier B — hero + chart à plat (sans carte), chips SOUS le chart.
    private var heroAndChartCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            InvestmentHeroCard(
                title: heroTitle,
                currentValue: heroValue,
                // Pas de variation visible quand on est sur l'estimation
                // ou la position fermée — ce serait trompeur.
                previousValue: (valuationIsEstimated || isClosedPosition)
                    ? heroValue
                    : positionValuePoints.first?.value,
                currency: account.currency,
                rangeLabel: variationRangeLabel(localTimeRange)
            )

            if isClosedPosition {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(AppTheme.Colors.accent)
                    Text("Position clôturée — \(realizedPnL >= 0 ? "plus-value" : "moins-value") réalisée \(realizedPnL, format: .currency(code: account.currency))")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if valuationIsEstimated {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text("Cours non synchronisé — la valeur affichée correspond au coût d'acquisition. Synchronise pour voir le P&L réel.")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            positionChart
                .padding(.top, AppTheme.Spacing.xs)

            TimeRangeChips(selection: $localTimeRange)

            // Info sur la profondeur de données disponible. Permet à l'user
            // de comprendre qu'un chart 10A tronqué n'est pas un bug mais
            // simplement que l'ETF/action est récent (Yahoo ne fournit que
            // l'historique depuis l'inception du titre).
            if let earliest = priceHistoryEarliestDate {
                Text("Données disponibles depuis \(earliest, format: .dateTime.day().month(.abbreviated).year())")
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
    }

    /// Date du plus ancien point de cours stocké pour cette position. Utilisé
    /// pour afficher "Données disponibles depuis ..." et expliquer pourquoi
    /// un chart 10A peut être tronqué (Yahoo ne renvoie que depuis l'inception).
    private var priceHistoryEarliestDate: Date? {
        priceHistory.map(\.date).min()
    }

    /// Chart de COURS du titre (close × 1, pas multiplié par qty).
    /// Affiche en plus :
    ///   - PRU horizontal (RuleMark) = seuil de break-even pour toutes les BUYs
    ///   - Zone gain/perte (AreaMark) entre le PRU et la courbe quand position
    ///     est détenue : vert si cours > PRU, rouge sinon
    ///   - Markers BUY/SELL/DIV à (executedAt, unitPrice) du cercle
    @ViewBuilder
    private var positionChart: some View {
        if chartPoints.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                Text("Aucun historique synchronisé")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Button("Synchroniser maintenant") {
                    Task { await syncHistory() }
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.Colors.accent)
                .disabled(position.bestSyncIdentifier.isEmpty || isSyncing)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            let pru = currentWeightedPRU
            let firstPrice = chartPoints.first?.close ?? 0
            let lastPrice = chartPoints.last?.close ?? 0
            let trendColor: Color = lastPrice >= firstPrice
                ? AppTheme.Colors.success
                : AppTheme.Colors.danger
            let baseline = chartYDomain.lowerBound

            Chart {
                // Aire + courbe dans UN SEUL ForEach (pattern identique à
                // EvolutionChart, qui rend correctement). Deux ForEach séparés
                // ou un `if` à l'intérieur cassent la continuité de la série et
                // font rendre chaque point comme une barre verticale isolée
                // (bug "code-barres"). La position détenue (gain/perte vs PRU)
                // se lit via la courbe au-dessus/en-dessous de la RuleMark PRU.
                ForEach(chartPoints) { point in
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Min", baseline),
                        yEnd: .value("Cours", point.close)
                    )
                    .foregroundStyle(trendColor.opacity(0.14))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Cours", point.close)
                    )
                    .foregroundStyle(trendColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                }

                // Ligne horizontale au PRU = seuil de break-even visuel.
                // Au-dessus = profit zone, en-dessous = loss zone.
                if pru > 0 {
                    RuleMark(y: .value("PRU", pru))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("PRU \(pru, format: .currency(code: account.currency))")
                                .font(.system(size: 9))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(AppTheme.Colors.surface.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                }

                // Markers BUY/SELL au cours unitaire de l'ordre.
                // DIV placés sur la ligne du COURS à leur date — le montant du
                // dividende (€1.70) n'a aucun rapport avec le cours (€60), donc
                // les plotter à €1.70 écrasait l'axe Y vers 0 et masquait toute
                // l'amplitude réelle du cours. On garde la position temporelle
                // (date verticale) qui est l'info utile pour un DIV.
                ForEach(visibleOrders) { order in
                    let markerY: Double = {
                        switch order.orderType {
                        case .dividend:
                            // Position sur le cours à la date du dividende.
                            // Fallback au PRU si pas de cours à cette date.
                            let closeAtDate = priceHistory
                                .filter { $0.date <= order.executedAt }
                                .max(by: { $0.date < $1.date })?
                                .close
                            return closeAtDate ?? pru
                        case .buy, .sell:
                            return order.unitPrice
                        }
                    }()
                    RuleMark(x: .value("Ordre", order.executedAt))
                        .foregroundStyle(annotationColor(order.orderType).opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))

                    PointMark(
                        x: .value("Ordre", order.executedAt),
                        y: .value("Cours", markerY)
                    )
                    .foregroundStyle(annotationColor(order.orderType))
                    .symbol {
                        ZStack {
                            Circle()
                                .fill(AppTheme.Colors.surface)
                                .frame(width: 10, height: 10)
                            Circle()
                                .strokeBorder(annotationColor(order.orderType), lineWidth: 2)
                                .frame(width: 10, height: 10)
                        }
                    }
                    .symbolSize(70)
                }

                // Indicateur visuel quand l'user scrub la chart (vertical line + dot
                // sur la courbe). N'apparaît que si chartSelectedDate est set.
                if let selected = chartSelectedDate,
                   let snapped = closestPoint(to: selected) {
                    RuleMark(x: .value("Scrub", snapped.date))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Scrub", snapped.date),
                              y: .value("Cours", snapped.close))
                        .foregroundStyle(trendColor)
                        .symbolSize(120)
                }
            }
            .chartYScale(domain: chartYDomain)
            .chartXAxis {
                // Ticks adaptatifs selon la plage temporelle (5A/10A/Max → ticks
                // annuels avec format yyyy, 1J → heures, etc.).
                let span: TimeInterval = {
                    guard let first = positionPricePoints.first?.date,
                          let last = positionPricePoints.last?.date else { return 0 }
                    return max(0, last.timeIntervalSince(first))
                }()
                let config = InvestmentChartXAxisConfig.config(for: localTimeRange, span: span)
                // ⚠️ `.stride(by:count:)` peut produire des DIZAINES de graduations
                // sur les longues plages (5A/Max) : les labels se chevauchent ET
                // gonflent la largeur intrinsèque du chart, ce qui rend toute la
                // vue scrollable horizontalement. On plafonne à ~5 graduations.
                AxisMarks(position: .bottom, values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: config.labelFormat)
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                        .font(.system(size: 10))
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisValueLabel()
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                        .font(.system(size: 10))
                    AxisGridLine()
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.08))
                }
            }
            // AXE M : scrub interactif (consomme les drags horizontaux pour que la
            // chart se sente "fixe" sous le doigt, laisse les drags verticaux passer
            // au ScrollView parent pour le scroll de page).
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    let dx = abs(value.translation.width)
                                    let dy = abs(value.translation.height)
                                    guard dx > dy else {
                                        if chartSelectedDate != nil { chartSelectedDate = nil }
                                        return
                                    }
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let origin = geo[plotFrame].origin
                                    let locationX = value.location.x - origin.x
                                    if let date: Date = proxy.value(atX: locationX) {
                                        chartSelectedDate = date
                                    }
                                }
                                .onEnded { _ in chartSelectedDate = nil }
                        )
                }
            }
            // maxWidth borne le chart à la largeur disponible : sans ça, un axe
            // trop dense pouvait lui donner une largeur intrinsèque supérieure à
            // l'écran et rendre toute la vue déplaçable latéralement.
            // (Pas de .clipped() : ça couperait les labels d'axe X sous le plot.)
            .frame(maxWidth: .infinity)
            .frame(height: 220)
        }
    }

    /// Trouve le point d'historique le plus proche temporellement de `date`.
    /// Utilisé pour snapper le scrub à un vrai data point (pas une interpolation).
    private func closestPoint(to date: Date) -> InvestmentPricePoint? {
        chartPoints.min(by: { a, b in
            abs(a.date.timeIntervalSince(date)) < abs(b.date.timeIntervalSince(date))
        })
    }

    /// Total des dividendes reçus sur la durée de vie de la position. Utile
    /// pour le breakdown dans la card Performance.
    private var totalDividends: Double {
        orders.filter { $0.orderType == .dividend }
              .reduce(0) { $0 + $1.quantity * $1.unitPrice }
    }

    /// P&L réalisé sur les ventes uniquement (sans dividendes), utile pour le
    /// breakdown affiché en mode position fermée.
    private var realizedSellsPnL: Double {
        realizedPnL - totalDividends
    }

    private var kpisCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                SectionHeader(title: "Performance")
                if valuationIsEstimated {
                    // Pas de cours synché → un P&L à -100% serait faux et alarmant.
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Text("P&L disponible après synchronisation du cours")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                } else if isClosedPosition {
                    // Position fermée : on détaille le réalisé pour ne pas
                    // afficher un P&L = 0 trompeur.
                    HStack(spacing: AppTheme.Spacing.sm) {
                        StatBadge(
                            label: "P&L total",
                            value: realizedPnL.formatted(.currency(code: account.currency)),
                            valueColor: realizedPnL >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
                        )
                        StatBadge(
                            label: "Variation",
                            value: String(format: "%@%.2f %%",
                                          realizedPnL >= 0 ? "+" : "",
                                          totalInvestedEver > 0 ? (realizedPnL / totalInvestedEver) * 100 : 0),
                            valueColor: realizedPnL >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
                        )
                    }
                    // Breakdown : plus-value sur ventes + dividendes
                    VStack(alignment: .leading, spacing: 4) {
                        breakdownRow(
                            label: "Plus-value sur ventes",
                            value: realizedSellsPnL,
                            currency: account.currency
                        )
                        if totalDividends > 0 {
                            breakdownRow(
                                label: "Dividendes reçus",
                                value: totalDividends,
                                currency: account.currency
                            )
                        }
                    }
                    .padding(.top, AppTheme.Spacing.xs)
                } else {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        StatBadge(
                            label: "P&L total",
                            value: totalPnL.formatted(.currency(code: account.currency)),
                            valueColor: pnlColor
                        )
                        StatBadge(
                            label: "Variation",
                            value: String(format: "%@%.2f %%", totalPnL >= 0 ? "+" : "", totalPnLPct),
                            valueColor: pnlColor
                        )
                    }
                    // Breakdown si réalisé > 0 (dividendes ou ventes partielles)
                    if realizedPnL != 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            breakdownRow(
                                label: "dont latent (sur titres détenus)",
                                value: unrealizedPnL,
                                currency: account.currency
                            )
                            breakdownRow(
                                label: "dont réalisé (ventes + dividendes)",
                                value: realizedPnL,
                                currency: account.currency
                            )
                        }
                        .padding(.top, AppTheme.Spacing.xs)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func breakdownRow(label: String, value: Double, currency: String) -> some View {
        HStack {
            Text(label)
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Text(value, format: .currency(code: currency))
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(value >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
        }
    }

    private var detailsCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Détails")
                detailRow("Ticker", value: position.ticker.isEmpty ? "—" : position.ticker)
                detailRow("ISIN", value: position.isin.isEmpty ? "— (à renseigner pour sync fiable)" : position.isin)
                detailRow("Type", value: InvestmentAssetType(rawValue: position.assetType)?.label ?? position.assetType)
                detailRow("Quantité", value: String(format: "%.6f", position.quantity).trimmedZeros)
                detailRow("PRU", value: position.averageBuyPrice.formatted(.currency(code: account.currency)))
                detailRow("Investi", value: position.investedAmount.formatted(.currency(code: account.currency)))
                detailRow("Date d'achat", value: position.purchaseDate.formatted(date: .abbreviated, time: .omitted))
                detailRow("Compte", value: "\(account.name) · \(account.accountType)", isLast: true)
            }
        }
    }

    /// Card "Dernière sync" — visible seulement si une tentative a été
    /// enregistrée. Sinon on n'encombre pas l'UI.
    @ViewBuilder
    private var syncTraceCard: some View {
        let identifiers = [position.isin, position.ticker].filter { !$0.isEmpty }
        if let trace = InvestmentSyncTraceStore.fetchBest(identifiers: identifiers) {
            AppCard {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    SectionHeader(title: "Dernière synchro du cours")
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: trace.status.icon)
                            .foregroundStyle(syncTraceColor(trace.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(trace.status.label) — \(trace.humanizedAttemptedAt)")
                                .font(AppTheme.Typography.titleSmall)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Text(trace.message)
                                .font(AppTheme.Typography.bodySmall)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !trace.symbolsTried.isEmpty {
                                Text("Symbole(s) essayé(s) : \(trace.symbolsTried.joined(separator: ", "))")
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func syncTraceColor(_ status: InvestmentSyncTraceStore.Status) -> Color {
        switch status {
        case .success:                      return AppTheme.Colors.success
        case .noData, .invalidId:           return AppTheme.Colors.warning
        case .rateLimited:                  return AppTheme.Colors.warning
        case .error:                        return AppTheme.Colors.danger
        }
    }

    private func detailRow(_ label: String, value: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
            .padding(.vertical, 8)
            if !isLast {
                Divider().background(AppTheme.Colors.textSecondary.opacity(0.1))
            }
        }
    }

    // MARK: - Helpers

    /// Charge le price history en essayant plusieurs identifiers :
    /// ISIN > ticker > symbole(s) résolu(s) depuis la dernière trace de sync.
    ///
    /// Le bug avant cette logique : sync via "Synchroniser tous les cours"
    /// utilisait `bestSyncIdentifier` (ISIN si dispo). OpenFIGI résolvait l'ISIN
    /// (ex: FR0011871110 → PUST.PA) puis Yahoo renvoyait des points stockés
    /// sous l'ISIN. Mais ce loader cherchait par `position.ticker` (AMUN.PEA),
    /// donc le chart restait vide même quand 256 points existaient en base.
    private func loadCachedHistory() {
        // 1. Essai par ISIN d'abord (priorité haute, identifier canonique)
        // 2. Puis par ticker
        let candidates = [position.isin, position.ticker]
            .filter { !$0.isEmpty }

        for candidate in candidates {
            let history = repository.fetchPriceHistory(identifier: candidate)
            if !history.isEmpty {
                priceHistory = history
                return
            }
        }

        // 3. Fallback : si la dernière sync a réussi via un symbole résolu
        //    (ex: ISIN → PUST.PA via OpenFIGI), on essaie de retrouver les
        //    points stockés sous ce symbole résolu.
        if let trace = InvestmentSyncTraceStore.fetchBest(identifiers: candidates),
           trace.status == .success {
            for symbol in trace.symbolsTried {
                let history = repository.fetchPriceHistory(identifier: symbol)
                if !history.isEmpty {
                    priceHistory = history
                    return
                }
            }
        }

        priceHistory = []
    }

    /// AXE K — recharge la liste des ordres de cette position (chronologique ASC).
    private func loadOrders() {
        orders = repository.fetchOrders(positionId: position.id)
    }

    /// Card "Ordres" — historique des opérations + bouton + pour en ajouter.
    /// Liste les BUY/SELL/DIV en ordre antichronologique (le plus récent en haut).
    /// AXE M : tap inactif (anti-modif accidentelle). Swipe leading = Modifier,
    /// swipe trailing = Supprimer (avec recompute auto qty/PRU).
    private var ordersCard: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    SectionHeader(title: "Ordres (\(orders.count))")
                    Spacer()
                    Button {
                        showOrderAddForm = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                    .buttonStyle(.plain)
                }

                if orders.isEmpty {
                    Text("Aucun ordre enregistré. Tape + pour ajouter un achat, une vente ou un dividende.")
                        .font(.system(size: 12))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .padding(.vertical, 8)
                } else {
                    // AXE M : List scrollDisabled pour `.swipeActions` natif.
                    // AXE M : pas de Button → tap inactif. L'édition d'un ordre passe
                    // exclusivement par swipe leading "Modifier" (ou trailing "Supprimer").
                    // Choix UX : un ordre affecte le PnL, on évite les modifs accidentelles
                    // par tap involontaire.
                    let reversed = orders.reversed().map { $0 }
                    List {
                        ForEach(reversed) { order in
                            orderRowContent(order)
                                .listRowBackground(AppTheme.Colors.surface)
                                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                                .listRowSeparatorTint(AppTheme.Colors.textSecondary.opacity(0.1))
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button {
                                        editingOrder = order
                                    } label: {
                                        Label("Modifier", systemImage: "pencil")
                                    }
                                    .tint(AppTheme.Colors.accent)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        deleteOrder(order)
                                    } label: {
                                        Label("Supprimer", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    // ~62pt par ligne d'ordre (icône + label + sous-titre + montant)
                    .frame(height: CGFloat(reversed.count) * 62)
                }
            }
        }
    }

    /// Contenu visuel d'un ordre — extrait pour pouvoir être inséré comme label
    /// d'un Button dans une List (au lieu de SwipeableRow custom).
    @ViewBuilder
    private func orderRowContent(_ order: InvestmentOrder) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: order.orderType.systemIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(orderColor(order.orderType))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(order.orderType.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                HStack(spacing: 4) {
                    Text("\(order.quantity, specifier: "%.4f") @ \(order.unitPrice, format: .currency(code: account.currency))")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    if order.fees > 0 {
                        Text("· frais \(order.fees, format: .currency(code: account.currency))")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(order.totalCost, format: .currency(code: account.currency))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(orderColor(order.orderType))
                Text(order.executedAt, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func orderColor(_ type: InvestmentOrderType) -> Color {
        switch type {
        case .buy:      return AppTheme.Colors.danger    // sortie cash = rouge
        case .sell:     return AppTheme.Colors.success   // entrée cash = vert
        case .dividend: return AppTheme.Colors.accentSecondary
        }
    }

    private func deleteOrder(_ order: InvestmentOrder) {
        _ = repository.deleteOrder(id: order.id)
        repository.recomputePositionFromOrders(positionId: position.id)
        loadOrders()
        viewModel.load()
        appState.dataRefreshToken = UUID()
    }

    private func syncHistory() async {
        isSyncing = true
        defer { isSyncing = false }

        // Identifier à privilégier : ISIN si présent (titres traditionnels)
        // SINON ticker (cryptos n'ont pas d'ISIN ; "BTC", "ETH" etc).
        // syncMarketHistory route automatiquement vers CoinGecko ou Yahoo
        // selon que l'identifier soit reconnu comme crypto ou pas.
        let identifier = position.bestSyncIdentifier
        guard !identifier.isEmpty else {
            statusMessage = "Aucun ISIN ni ticker — impossible de synchroniser."
            return
        }
        await viewModel.syncMarketHistory(for: identifier)
        statusMessage = viewModel.marketStatusMessage
        loadCachedHistory()
    }

    private func variationRangeLabel(_ range: InvestmentTimeRange) -> String {
        switch range {
        case .oneDay:     return "sur 1 jour"
        case .oneWeek:    return "sur 1 semaine"
        case .oneMonth:   return "sur 1 mois"
        case .threeMonth: return "sur 3 mois"
        case .sixMonth:   return "sur 6 mois"
        case .oneYear:    return "sur 1 an"
        case .fiveYear:   return "sur 5 ans"
        case .tenYear:    return "sur 10 ans"
        case .all:        return "depuis l'origine"
        }
    }
}

// MARK: - String trimming helper

private extension String {
    /// Retire les zéros inutiles en fin de décimale ("12.5000" → "12.5", "10.000000" → "10")
    var trimmedZeros: String {
        guard contains(".") else { return self }
        var s = self
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
