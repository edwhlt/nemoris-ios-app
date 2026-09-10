import Foundation

/// Résolution ROBUSTE de l'historique de cours d'une position, extraite de
/// `InvestmentsViewModel` pour être réutilisée par le widget (`WidgetDataStore`)
/// sans dupliquer la logique — même doctrine que `PortfolioEvolutionBuilder`
/// (AXE Q/AA : un calcul, jamais deux implémentations divergentes).
///
/// `@MainActor` car `PriceHistoryCache` l'est (cache disque JSON partagé).
@MainActor
enum PositionHistoryResolver {

    /// Historique à agréger pour une position sur une plage donnée.
    /// Granularité adaptée : la vue 1J utilise la série INTRADAY 30 min (la série
    /// quotidienne n'a qu'un point sur 24 h glissantes). Si l'intraday manque
    /// pour cette position, on retombe sur son QUOTIDIEN (non filtré) : le
    /// builder la maintiendra à plat sur son dernier cours réel — jamais sur le PRU.
    static func seriesHistory(for position: InvestmentPosition,
                              range: InvestmentTimeRange) -> [InvestmentPricePoint] {
        if range == .oneDay {
            let intraday = intradaySeries(for: position)
            if !intraday.isEmpty { return intraday }
            return resolveHistory(for: position, cutoff: nil, resolution: .daily)
        }
        return resolveHistory(for: position, cutoff: range.startDate, resolution: .daily)
    }

    /// Série intrajournalière d'une position, bornée aux dernières 24 h COTÉES.
    ///
    /// ⚠️ Pas de `cutoff: range.startDate` : une fenêtre calée sur `Date()` est
    /// VIDE dès qu'on consulte hors séance (le samedi, la dernière cotation du
    /// vendredi a plus de 24 h). On lit la série entière (rétention 96 h) puis
    /// on garde les dernières 24 h ancrées sur le dernier point réel.
    static func intradaySeries(for position: InvestmentPosition) -> [InvestmentPricePoint] {
        resolveHistory(for: position, cutoff: nil, resolution: .intraday30m)
            .lastQuotedWindow()
    }

    /// Essaie dans l'ordre : ISIN → ticker → symboles retenus par la dernière
    /// synchro réussie (ex. un ISIN résolu en "PUST.PA" via OpenFIGI est stocké
    /// sous ce symbole). Source unique utilisée par TOUS les niveaux de chart
    /// (global, compte, position, widget) — sinon un niveau peut rester vide
    /// alors qu'un autre affiche.
    static func resolveHistory(for position: InvestmentPosition, cutoff: Date?,
                               resolution: PriceResolution = .daily) -> [InvestmentPricePoint] {
        func load(_ identifier: String) -> [InvestmentPricePoint] {
            PriceHistoryCache.shared.fetch(identifier: identifier, resolution: resolution)
                .sorted { $0.date < $1.date }
                .filter { point in
                    guard let cutoff else { return true }
                    return point.date >= cutoff
                }
        }

        let candidates = [position.isin, position.ticker].filter { !$0.isEmpty }
        for candidate in candidates {
            let history = load(candidate)
            if !history.isEmpty { return history }
        }
        if let trace = InvestmentSyncTraceStore.fetchBest(identifiers: candidates),
           trace.status == .success {
            for symbol in trace.symbolsTried {
                let history = load(symbol)
                if !history.isEmpty { return history }
            }
        }
        return []
    }
}
