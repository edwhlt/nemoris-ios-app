import Foundation

/// Le chemin d'ingestion UNIQUE : N fichiers de N formats en entrée, des
/// `ImportElement` en sortie.
///
/// ─── Deux phases, et c'est structurel ──────────────────────────────────────
///
///   1. `read`    — ouvrir, sniffer, découper en unités. Parallélisable, et
///                  c'est la phase qui découvre COMBIEN il y a à faire (le
///                  nombre de pages d'un PDF n'est connu qu'une fois ouvert).
///   2. `analyze` — interpréter chaque unité. C'est là que passe le temps
///                  quand un modèle est impliqué.
///
/// ⚠️ Fusionner les deux ferait perdre la progression exacte : une boucle par
/// fichier ne peut annoncer qu'un total approximatif, réévalué à la hausse en
/// cours de route — et l'ancienne version rapportait `done / done`, soit 100 %
/// en permanence, donc une barre qui ne voulait rien dire.
///
/// La séparation sert aussi l'UX : `read` rend les TABLES à mapper (CSV,
/// feuilles de classeur) avant que quoi que ce soit de long ne démarre, donc
/// l'utilisateur fait ses mappings pendant qu'il est là, puis l'analyse part en
/// arrière-plan.
@MainActor
enum ImportPipeline {

    // MARK: - Résultat de lecture

    /// Une table qui attend l'utilisateur : la structure est là, la sémantique
    /// des colonnes non.
    struct PendingGrid: Identifiable {
        let id = UUID()
        var grid: ImportGrid
        var origin: ImportElementOrigin
        /// Texte d'origine, conservé pour permettre un RE-PARSING si
        /// l'utilisateur corrige le séparateur depuis l'écran de mapping.
        /// `nil` pour un classeur, dont les cellules ne dépendent d'aucun
        /// séparateur.
        var rawText: String?
        /// Les AUTRES feuilles du même classeur.
        ///
        /// ⚠️ Un classeur produit UNE étape de mapping, pas une par feuille.
        /// La version initiale en faisait une chacune : l'utilisateur devait
        /// mapper « Notes », « Récapitulatif » et tout onglet annexe avant
        /// d'atteindre celui qui l'intéressait, sans jamais pouvoir en choisir
        /// un. Ici il choisit, et une seule feuille est importée.
        var siblingSheets: [ImportGrid] = []

        /// Nom affiché dans l'écran de mapping : le fichier, plus l'onglet
        /// quand un classeur en compte plusieurs.
        var displayName: String {
            guard let sheet = grid.sheetName, !sheet.isEmpty else { return origin.sourceName }
            return "\(origin.sourceName) · \(sheet)"
        }
    }

    /// Ce que la lecture a produit, avant toute interprétation.
    struct Readout {
        /// Unités à analyser, dans l'ordre du batch et déjà numérotées.
        var units: [NumberedUnit] = []
        /// Tables en attente de mapping — elles ne passent PAS par `analyze`.
        var pendingGrids: [PendingGrid] = []

        var isEmpty: Bool { units.isEmpty && pendingGrids.isEmpty }
    }

    struct NumberedUnit {
        var unit: ImportDocumentReader.Unit
        var origin: ImportElementOrigin
    }

    /// Nombre de fichiers lus de front.
    ///
    /// ⚠️ Borné, et pas seulement pour la forme : chaque lecture charge une
    /// page PDF rendue ou une image décodée en mémoire. Sur un lot de gros
    /// documents, un `TaskGroup` sans limite les matérialise TOUS en même
    /// temps — c'est ainsi qu'on se fait tuer par le watchdog mémoire d'iOS,
    /// pas en étant lent.
    static let readConcurrency = 4

    // MARK: - Phase 1 — lecture

    /// Ouvre et découpe les sources, EN PARALLÈLE.
    ///
    /// ⚠️ L'échec d'un fichier n'annule jamais les autres : chaque source rend
    /// au pire une unité vide porteuse de son diagnostic. Un lot de dix
    /// relevés ne doit pas être perdu parce que le troisième est illisible.
    static func read(sources: [ImportDocumentSource],
                     destination: ImportDestination,
                     allowsImagePassthrough: Bool = true) async -> Readout {
        // La fonctionnalité IA au nom de laquelle on lit : c'est elle qui
        // décide si une capture part telle quelle au modèle ou passe par l'OCR,
        // puisque le backend se choisit par fonctionnalité.
        let feature: AIFeature = destination == .transactions
            ? .transactionImport : .investmentImport
        guard !sources.isEmpty else { return Readout() }

        // Indexé pour recoller dans l'ordre : un `TaskGroup` rend les résultats
        // dans l'ordre d'ACHÈVEMENT, qui dépend de la taille des fichiers. Sans
        // ça, l'ordre des lignes importées dépendrait du hasard des durées de
        // lecture — la classe de bug déjà payée en AXE S (`results.first` sur
        // une concaténation de `withTaskGroup`).
        var readUnits: [Int: [ImportDocumentReader.Unit]] = [:]

        await withTaskGroup(of: (Int, [ImportDocumentReader.Unit]).self) { group in
            var next = 0
            var running = 0

            func schedule() {
                guard next < sources.count else { return }
                let index = next
                let source = sources[index]
                next += 1
                running += 1
                group.addTask {
                    (index, await ImportDocumentReader.units(
                        for: source, feature: feature,
                        allowsImagePassthrough: allowsImagePassthrough))
                }
            }

            while running < readConcurrency && next < sources.count { schedule() }
            while let (index, units) = await group.next() {
                readUnits[index] = units
                running -= 1
                schedule()
            }
        }

        // Numérotation GLOBALE : deux fichiers repartant à 1 produiraient des
        // numéros d'unité en collision, et un rapport d'échec désignerait alors
        // une unité ambiguë.
        var readout = Readout()
        var unitNumber = 1

        for index in sources.indices {
            let source = sources[index]
            for unit in readUnits[index] ?? [] {
                let origin = ImportElementOrigin(
                    sourceName: source.displayName,
                    sourceIndex: index,
                    unitNumber: unitNumber,
                    unitIndexInSource: unit.indexInSource,
                    kind: unit.kind)
                unitNumber += 1

                if case .grid(let grid) = unit.content {
                    // Feuilles suivantes d'un même classeur : elles rejoignent
                    // l'étape déjà ouverte pour ce fichier au lieu d'en créer
                    // une nouvelle (cf. `siblingSheets`).
                    if let existing = readout.pendingGrids.lastIndex(where: {
                        $0.origin.sourceIndex == index
                    }) {
                        readout.pendingGrids[existing].siblingSheets.append(grid)
                    } else {
                        readout.pendingGrids.append(PendingGrid(
                            grid: grid,
                            origin: origin,
                            // ⚠️ Repris de l'unité, PAS redécodé ici : cette
                            // boucle tourne sur le main actor, et redécoder un
                            // gros CSV en String y provoquait un gel visible —
                            // pour un travail déjà fait hors du main actor
                            // pendant la lecture. `nil` pour un classeur, dont
                            // les cellules ne dépendent d'aucun séparateur.
                            rawText: unit.sourceText))
                    }
                } else {
                    readout.units.append(NumberedUnit(unit: unit, origin: origin))
                }
            }
        }
        return readout
    }

    // MARK: - Phase 2 — analyse

    /// Interprète les unités lues, selon la destination choisie.
    ///
    /// ⚠️ SÉQUENTIEL, et c'est délibéré. La contrainte n'est pas le code mais
    /// le modèle : plusieurs `LanguageModelSession` de front sur le petit
    /// modèle embarqué se disputent la même mémoire et la même unité de calcul,
    /// pour un gain nul et un risque d'éviction. Tout ce qui gagne réellement à
    /// être parallélisé (ouverture PDF, OCR, inflate) l'est déjà en phase 1.
    ///
    /// La progression reste exacte parce que le total est connu AVANT d'entrer
    /// dans la boucle.
    static func analyze(_ readout: Readout,
                        destination: ImportDestination,
                        onProgress: @escaping (Int, Int) -> Void) async -> ImportBatchResult {
        let total = readout.units.count
        onProgress(0, total)

        var result = ImportBatchResult()
        for (index, numbered) in readout.units.enumerated() {
            if Task.isCancelled { break }
            let extracted = await extract(numbered, destination: destination)
            result.elements += extracted.elements
            result.units.append(extracted.report)
            onProgress(index + 1, total)
        }
        return result
    }

    /// Analyse d'UNE unité, aiguillée par la destination.
    ///
    /// C'est ici que se matérialise la décision de ne PAS avoir d'étape de
    /// classification métier : la destination a été choisie par l'utilisateur
    /// avant l'analyse, et c'est elle qui calibre les instructions du modèle.
    /// Reclassifier après coup introduirait une seconde source de vérité, qui
    /// pourrait contredire la première.
    private static func extract(_ numbered: NumberedUnit,
                                destination: ImportDestination)
    async -> (elements: [ImportElement], report: ImportUnitReport) {
        let origin = numbered.origin

        switch destination {
        case .transactions:
            let unit = await TransactionDocumentParser.shared.analyze(
                numbered.unit, unitNumber: origin.unitNumber, sourceName: origin.sourceName)
            let elements = unit.transactions.map {
                ImportElement(origin: origin, payload: .transaction($0))
            }
            return (elements, ImportUnitReport(
                origin: origin, rawText: unit.rawText,
                recognizedCount: elements.count, diagnostic: unit.diagnostic,
                usedDeterministicFallback: unit.usedDeterministicFallback))

        case .investments:
            let page = await InvestmentPDFParser.shared.analyze(
                numbered.unit, unitNumber: origin.unitNumber)
            var elements = page.orders.map {
                ImportElement(origin: origin, payload: .investmentOrder(Self.pure($0)),
                              confidence: $0.confidence)
            }
            elements += page.positions.map {
                ImportElement(origin: origin, payload: .investmentPosition(Self.pure($0)),
                              confidence: $0.confidence)
            }
            return (elements, ImportUnitReport(
                origin: origin, rawText: page.rawText,
                recognizedCount: elements.count, diagnostic: page.diagnostic,
                usedDeterministicFallback: page.usedDeterministicFallback))
        }
    }

    // MARK: - Modèles d'UI → modèles purs

    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func pure(_ order: PDFExtractedOrder) -> ExtractedStatementOrder {
        ExtractedStatementOrder(
            orderType: order.orderType, assetName: order.assetName, isin: order.isin,
            ticker: order.ticker, quantity: order.quantity, unitPrice: order.unitPrice,
            fees: order.fees, executedAt: isoDay.string(from: order.executedAt),
            currency: order.currency, notes: order.notes, confidence: order.confidence)
    }

    static func pure(_ position: PDFExtractedPosition) -> ExtractedStatementPosition {
        ExtractedStatementPosition(
            assetName: position.assetName, ticker: position.ticker, isin: position.isin,
            quantity: position.quantity, averageBuyPrice: position.averageBuyPrice,
            currentValue: position.currentValue, currency: position.currency,
            confidence: position.confidence)
    }
}

// MARK: - Éléments → modèles consommés en aval

extension ImportBatchResult {

    /// Lignes de session d'import.
    ///
    /// `startingAt` continue une numérotation GLOBALE : deux sources repartant
    /// chacune à 1 produiraient des `sourceRowNumber` en collision dans une
    /// session agrégée, et les rapports d'échec au commit désigneraient une
    /// ligne ambiguë.
    func sessionRows(startingAt startNumber: Int = 1) -> [ImportSessionRow] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var number = startNumber
        var rows: [ImportSessionRow] = []
        for element in elements {
            guard case .transaction(let tx) = element.payload,
                  let date = formatter.date(from: tx.date) else { continue }
            rows.append(ImportSessionRow(
                sourceRowNumber: number,
                rawLabel: tx.label,
                date: date,
                amount: tx.amount,
                paymentTypeHint: tx.paymentTypeHint,
                sourceFile: element.origin.sourceName))
            number += 1
        }
        return rows
    }

    /// Vue par unité pour l'écran de revue des investissements, qui raisonne
    /// encore en « pages ». Reconstruite depuis les éléments plutôt que portée
    /// en double : le pipeline reste la seule source.
    func investmentPages() -> [PDFPageResult] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var byUnit: [Int: (orders: [PDFExtractedOrder], positions: [PDFExtractedPosition])] = [:]
        for element in elements {
            let unit = element.origin.unitNumber
            var bucket = byUnit[unit] ?? ([], [])
            switch element.payload {
            case .investmentOrder(let order):
                bucket.orders.append(PDFExtractedOrder(
                    orderType: order.orderType, assetName: order.assetName,
                    ticker: order.ticker, isin: order.isin, quantity: order.quantity,
                    unitPrice: order.unitPrice, fees: order.fees,
                    executedAt: formatter.date(from: order.executedAt) ?? Date(),
                    currency: order.currency, notes: order.notes,
                    pageNumber: unit, confidence: order.confidence))
            case .investmentPosition(let position):
                bucket.positions.append(PDFExtractedPosition(
                    assetName: position.assetName, ticker: position.ticker,
                    isin: position.isin, quantity: position.quantity,
                    averageBuyPrice: position.averageBuyPrice,
                    currentValue: position.currentValue, currency: position.currency,
                    pageNumber: unit, confidence: position.confidence))
            case .transaction:
                continue
            }
            byUnit[unit] = bucket
        }

        return units.map { report in
            let bucket = byUnit[report.origin.unitNumber] ?? ([], [])
            let mode: PDFDocumentMode = {
                if !bucket.orders.isEmpty { return .orders }
                if !bucket.positions.isEmpty { return .positionsSnapshot }
                return .unknown
            }()
            return PDFPageResult(
                pageNumber: report.origin.unitNumber,
                rawText: report.rawText,
                orders: bucket.orders,
                positions: bucket.positions,
                detectedMode: mode,
                parsingNote: report.diagnostic.isFailure ? report.diagnostic.userMessage : nil,
                diagnostic: report.diagnostic,
                kind: report.origin.kind,
                usedDeterministicFallback: report.usedDeterministicFallback,
                sourceName: report.origin.sourceName)
        }
    }

    /// Vue neutre par unité, pour les blocs de diagnostic partagés.
    func analysisUnits() -> [AnalysisUnit] {
        units.map { report in
            AnalysisUnit(id: report.id, unitNumber: report.origin.unitNumber,
                         sourceName: report.origin.sourceName, rawText: report.rawText,
                         recognizedCount: report.recognizedCount,
                         diagnostic: report.diagnostic, kind: report.origin.kind,
                         usedDeterministicFallback: report.usedDeterministicFallback)
        }
    }
}
