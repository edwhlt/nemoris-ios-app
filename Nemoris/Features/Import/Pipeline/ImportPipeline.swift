import Foundation

/// The SINGLE ingestion path: N files of N formats in, `ImportElement`s
/// out.
///
/// ─── Two phases, and it's structural ───────────────────────────────────────
///
///   1. `read`    — open, sniff, split into units. Parallelizable, and
///                  this is the phase that discovers HOW MUCH there is to do (the
///                  number of pages in a PDF is only known once it's opened).
///   2. `analyze` — interpret each unit. This is where time goes
///                  when a model is involved.
///
/// ⚠️ Merging the two would lose exact progress reporting: a loop per
/// file can only announce an approximate total, revised upward as it
/// goes — and the old version reported `done / done`, i.e. 100%
/// all the time, so a bar that meant nothing.
///
/// The split also serves the UX: `read` renders the TABLES to map (CSV,
/// workbook sheets) before anything long starts, so
/// the user does their mapping while they're there, and analysis then
/// runs in the background.
@MainActor
enum ImportPipeline {

    // MARK: - Read result

    /// A table awaiting the user: the structure is there, column
    /// semantics aren't.
    struct PendingGrid: Identifiable {
        let id = UUID()
        var grid: ImportGrid
        var origin: ImportElementOrigin
        /// Source text, kept to allow RE-PARSING if
        /// the user corrects the separator from the mapping screen.
        /// `nil` for a workbook, whose cells don't depend on any
        /// separator.
        var rawText: String?
        /// The OTHER sheets of the same workbook.
        ///
        /// ⚠️ A workbook produces ONE mapping step, not one per sheet.
        /// The initial version made one for each: the user had to
        /// map "Notes", "Summary" and every side tab before
        /// reaching the one they cared about, with no way to pick
        /// one. Here they pick, and only one sheet is imported.
        var siblingSheets: [ImportGrid] = []

        /// Name shown on the mapping screen: the file, plus the sheet
        /// name when a workbook has several.
        var displayName: String {
            guard let sheet = grid.sheetName, !sheet.isEmpty else { return origin.sourceName }
            return "\(origin.sourceName) · \(sheet)"
        }
    }

    /// What reading produced, before any interpretation.
    struct Readout {
        /// Units to analyze, in batch order and already numbered.
        var units: [NumberedUnit] = []
        /// Tables awaiting mapping — they do NOT go through `analyze`.
        var pendingGrids: [PendingGrid] = []

        var isEmpty: Bool { units.isEmpty && pendingGrids.isEmpty }
    }

    struct NumberedUnit {
        var unit: ImportDocumentReader.Unit
        var origin: ImportElementOrigin
    }

    /// Number of files read concurrently.
    ///
    /// ⚠️ Bounded, and not just for form's sake: every read loads a
    /// rendered PDF page or a decoded image into memory. On a batch of large
    /// documents, an unbounded `TaskGroup` materializes ALL of them at
    /// once — that's how you get killed by iOS's memory watchdog,
    /// not by being slow.
    static let readConcurrency = 4

    // MARK: - Phase 1 — reading

    /// Opens and splits the sources, IN PARALLEL.
    ///
    /// ⚠️ One file's failure never cancels the others: each source at worst
    /// produces one empty unit carrying its diagnosis. A batch of ten
    /// statements must not be lost because the third one is unreadable.
    static func read(sources: [ImportDocumentSource],
                     destination: ImportDestination,
                     allowsImagePassthrough: Bool = true) async -> Readout {
        // The AI feature on whose behalf we're reading: it
        // decides whether a screenshot goes to the model as-is or through OCR,
        // since the backend is chosen per feature.
        let feature: AIFeature = destination == .transactions
            ? .transactionImport : .investmentImport
        guard !sources.isEmpty else { return Readout() }

        // Indexed to reassemble in order: a `TaskGroup` returns results
        // in COMPLETION order, which depends on file size. Without
        // this, the order of imported rows would depend on the luck of
        // read durations — the bug class already encountered here
        // (`results.first` on a `withTaskGroup` concatenation).
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

        // GLOBAL numbering: two files each restarting at 1 would produce
        // colliding unit numbers, and a failure report would then point at
        // an ambiguous unit.
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
                    // Following sheets of the same workbook: they join the step
                    // already opened for that file instead of creating
                    // a new one (see `siblingSheets`).
                    if let existing = readout.pendingGrids.lastIndex(where: {
                        $0.origin.sourceIndex == index
                    }) {
                        readout.pendingGrids[existing].siblingSheets.append(grid)
                    } else {
                        readout.pendingGrids.append(PendingGrid(
                            grid: grid,
                            origin: origin,
                            // ⚠️ Reused from the unit, NOT re-decoded here: this
                            // loop runs on the main actor, and re-decoding a
                            // large CSV to a String there caused a visible freeze —
                            // for work already done off the main actor
                            // during reading. `nil` for a workbook, whose
                            // cells don't depend on any separator.
                            rawText: unit.sourceText))
                    }
                } else {
                    readout.units.append(NumberedUnit(unit: unit, origin: origin))
                }
            }
        }
        return readout
    }

    // MARK: - Phase 2 — analysis

    /// Interprets the units read, based on the chosen destination.
    ///
    /// ⚠️ SEQUENTIAL, and it's deliberate. The constraint isn't the code but
    /// the model: several `LanguageModelSession`s running at once on the small
    /// embedded model fight over the same memory and the same compute
    /// unit, for zero gain and a risk of eviction. Everything that genuinely
    /// benefits from parallelization (PDF opening, OCR, inflate) already is,
    /// in phase 1.
    ///
    /// Progress stays exact because the total is known BEFORE entering
    /// the loop.
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

    /// Analyzes ONE unit, routed by the destination.
    ///
    /// This is where the decision to NOT have a business-classification
    /// step materializes: the destination was chosen by the user
    /// before analysis, and it's what calibrates the model's instructions.
    /// Reclassifying afterward would introduce a second source of truth, which
    /// could contradict the first.
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

    // MARK: - UI models → pure models

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

// MARK: - Elements → models consumed downstream

extension ImportBatchResult {

    /// Import-session rows.
    ///
    /// `startingAt` continues a GLOBAL numbering: two sources each
    /// restarting at 1 would produce colliding `sourceRowNumber`s in an
    /// aggregated session, and failure reports at commit would point at
    /// an ambiguous row.
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

    /// Per-unit view for the investments review screen, which still
    /// reasons in terms of "pages". Rebuilt from the elements rather than
    /// carried twice: the pipeline stays the single source.
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

    /// Neutral per-unit view, for the shared diagnostic blocks.
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
