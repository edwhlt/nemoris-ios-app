import Foundation
import PDFKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Extracts bank operations from a PDF, a screenshot, or
/// text — the counterpart of `InvestmentPDFParser` for the Transactions module.
///
/// **Why a class separate from the investments parser:** what we're
/// looking for has nothing in common (date + amount + label versus ISIN +
/// quantity + price), the guided schema and the prompt differ entirely, and
/// the output is an `ImportSession` rather than orders. On the other hand,
/// everything that is GENERIC — byte-based format sniffing, Vision OCR, PDF
/// extraction, chunking into blocks — is reused as-is from
/// `InvestmentPDFParser` rather than duplicated.
///
/// **Three stages per unit**, each catching the previous one's failure:
///   1. `@Generable` guided generation (Foundation Models, iOS/macOS 26+);
///   2. JSON generation via `AIEnrichmentBackend.completeText` — so also
///      a configured local server, not just Apple's;
///   3. `BankStatementExtractor`, deterministic, run SYSTEMATICALLY.
///
/// Stage 3 isn't just a fallback: it's the authority on date and
/// amount. A small model can easily copy one line's data onto another in a
/// column-based OCR, where deterministic anchoring reads fields in their place.
@MainActor
final class TransactionDocumentParser {

    static let shared = TransactionDocumentParser()

    /// Source type shared with the investments import.
    typealias DocumentSource = ImportDocumentSource

    /// Result of analyzing one unit (PDF page, screenshot, text block).
    struct UnitResult: Identifiable {
        let id = UUID()
        let unitNumber: Int
        let sourceName: String
        let rawText: String
        var transactions: [ExtractedBankTransaction]
        var diagnostic: ImportUnitDiagnostic
        /// The document's actual type — the enum is shared with the
        /// Investments module (its prefix is historical): it carries the
        /// display vocabulary "pages / screenshots / blocks analyzed".
        var kind: ImportSourceKind
        var usedDeterministicFallback: Bool
    }

    /// True if an AI backend is usable. Extraction works WITHOUT it —
    /// unlike the investments import, no button should be
    /// grayed out here: the deterministic engine is enough to produce
    /// usable rows.
    var isAIAvailable: Bool { AIEnrichmentBackend.isAvailable(for: .transactionImport) }

    // MARK: - Analyzing a unit

    /// Interprets ONE already-read unit.
    ///
    /// ⚠️ This parser no longer opens files or orchestrates a batch:
    /// reading (sniffing, PDF pages, OCR, chunking) belongs to
    /// `ImportPipeline`, which runs it in parallel and shares it with the
    /// investments import. Keeping ONLY the interpretation is what keeps the
    /// two modules from each redeveloping their own chunking — which they
    /// used to do, with two diverging format detections.
    func analyze(_ unit: ImportDocumentReader.Unit,
                 unitNumber: Int, sourceName: String) async -> UnitResult {
        let kind = unit.kind
        let text: String

        switch unit.content {
        // ─── The unit IS an image and a model can read it ──────────────
        // We pass it as-is: the layout (columns, day headers,
        // category subtitles) carries meaning that OCR flattens and
        // that no line-ordering heuristic reconstructs in a
        // general way — it differs from one banking app to another, and we have
        // no visibility into what users will import.
        case .image(let image):
            let raw = await AIEnrichmentBackend.completeText(
                feature: .transactionImport,
                system: Self.jsonInstructions,
                user: "Extrais toutes les opérations visibles sur cette capture.",
                image: image
            )
            guard let raw else {
                return UnitResult(unitNumber: unitNumber, sourceName: sourceName, rawText: "",
                                  transactions: [], diagnostic: .aiFailed("le modèle n'a pas pu lire l'image"),
                                  kind: kind, usedDeterministicFallback: false)
            }
            let lines = Self.parseJSON(raw)
            return UnitResult(
                unitNumber: unitNumber, sourceName: sourceName,
                // The diagnosis's "text read" becomes the model's response:
                // that's what lets us understand a failed extraction.
                rawText: raw,
                transactions: lines,
                diagnostic: lines.isEmpty ? .nothingRecognized : .extracted,
                kind: kind, usedDeterministicFallback: false
            )

        // ─── Structured format: fields are NAMED ──────────────────────────
        // Neither model nor deterministic extraction — the data is exact,
        // reinterpreting it could only degrade it.
        case .records(let payloads):
            let lines: [ExtractedBankTransaction] = payloads.compactMap { payload in
                if case .transaction(let tx) = payload { return tx }
                return nil
            }
            return UnitResult(
                unitNumber: unitNumber, sourceName: sourceName,
                rawText: "", transactions: lines,
                diagnostic: lines.isEmpty ? .nothingRecognized : .extracted,
                kind: kind, usedDeterministicFallback: true
            )

        // ─── A table to map ─────────────────────────────────────────────────
        // Shouldn't reach here: tables go through the column-mapping
        // screen upstream. Flagged rather than silently ignored.
        case .grid:
            return UnitResult(unitNumber: unitNumber, sourceName: sourceName, rawText: "",
                              transactions: [],
                              diagnostic: .malformedStructure("table non mappée"),
                              kind: kind, usedDeterministicFallback: false)

        case .empty(let diagnostic):
            return UnitResult(unitNumber: unitNumber, sourceName: sourceName, rawText: "",
                              transactions: [], diagnostic: diagnostic, kind: kind,
                              usedDeterministicFallback: false)

        case .text(let value):
            text = value
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let diagnostic: ImportUnitDiagnostic = kind == .unknown ? .notTextContent : .noTextExtracted
            return UnitResult(unitNumber: unitNumber, sourceName: sourceName, rawText: "",
                              transactions: [], diagnostic: diagnostic, kind: kind,
                              usedDeterministicFallback: false)
        }

        let (aiLines, aiDiagnostic) = await extractWithAI(text: text)
        // Pure engine but heavy on regex over a dense statement: off the main
        // actor, like OCR, so the UI stays responsive during analysis.
        let deterministic = await Task.detached(priority: .userInitiated) {
            BankStatementExtractor.extractTransactions(from: text)
        }.value
        let merged = Self.reconcile(ai: aiLines, deterministic: deterministic)
        let usedFallback = !deterministic.isEmpty && aiLines.isEmpty

        if !merged.isEmpty {
            return UnitResult(
                unitNumber: unitNumber, sourceName: sourceName, rawText: text,
                transactions: merged,
                // We keep the trace of an AI failure even when the deterministic
                // engine saved the day: that's useful information for support.
                diagnostic: aiDiagnostic.isFailure ? aiDiagnostic : .extracted,
                kind: kind, usedDeterministicFallback: usedFallback
            )
        }
        return UnitResult(
            unitNumber: unitNumber, sourceName: sourceName, rawText: text,
            transactions: [],
            diagnostic: aiDiagnostic.isFailure ? aiDiagnostic : .nothingRecognized,
            kind: kind, usedDeterministicFallback: false
        )
    }

    // MARK: - Reconciliation

    /// Matching key: date + amount to the cent, absolute value.
    ///
    /// The sign is deliberately OUTSIDE the key: that's precisely the field
    /// the two sources can read differently (a DEBIT column carries no
    /// sign at all, only the label's meaning or the layout gives it). Including
    /// it would make the matching fail exactly when it matters most.
    private static func matchKey(_ tx: ExtractedBankTransaction) -> String {
        "\(tx.date)|\(Int((abs(tx.amount) * 100).rounded()))"
    }

    /// Merges AI extraction and deterministic extraction.
    ///
    /// Division of authority:
    ///   • date and amount → DETERMINISTIC (it reads the digits in their place);
    ///   • label → AI when it saw the same operation (it reconstructs a
    ///     column-broken OCR text better);
    ///   • sign → deterministic when it was EXPLICIT ("-" attached to the
    ///     amount), otherwise the AI's, which sees the debit/credit layout;
    ///   • operations only AI saw → added (prose formats that
    ///     date+amount anchoring can't see).
    static func reconcile(ai: [ExtractedBankTransaction],
                          deterministic: [ExtractedBankTransaction]) -> [ExtractedBankTransaction] {
        guard !deterministic.isEmpty else { return ai }
        guard !ai.isEmpty else { return deterministic }

        // Several operations can share the same key (two purchases of the
        // same amount the same day): consume them in order of appearance.
        var pending: [String: [ExtractedBankTransaction]] = [:]
        for line in ai { pending[matchKey(line), default: []].append(line) }

        var merged: [ExtractedBankTransaction] = []
        for var tx in deterministic {
            let key = matchKey(tx)
            if var bucket = pending[key], !bucket.isEmpty {
                let match = bucket.removeFirst()
                pending[key] = bucket
                if !match.label.isEmpty { tx.label = match.label }
                if tx.paymentTypeHint == nil { tx.paymentTypeHint = match.paymentTypeHint }
                if !tx.isSignExplicit {
                    tx.amount = abs(tx.amount) * (match.amount < 0 ? -1 : 1)
                    tx.isSignExplicit = true
                }
                tx.confidence = min(1, tx.confidence + 0.1)   // corroborated by two sources
            }
            merged.append(tx)
        }
        for (_, rest) in pending { merged.append(contentsOf: rest) }
        return merged.sorted { $0.date < $1.date }
    }

    // MARK: - AI stages

    private func extractWithAI(text: String) async -> ([ExtractedBankTransaction], ImportUnitDiagnostic) {
        // The embedded model's context window is narrow: an overflow
        // fails the WHOLE unit, not just the offending line.
        let payload = String(text.prefix(4000))

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           // ⚠️ Gated by the dispatch point, NOT by a direct availability
           // check: calling Foundation Models without this would ignore
           // a "local server", "cloud" or "disabled" choice made
           // for THIS feature in Settings.
           AIEnrichmentBackend.usesGuidedGeneration(for: .transactionImport),
           SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: Self.guidedInstructions)
            do {
                let response = try await session.respond(
                    to: Self.buildPrompt(text: payload),
                    generating: AITransactionExtraction.self
                )
                let lines = Self.convert(response.content)
                if !lines.isEmpty { return (lines, .extracted) }
            } catch {
                print("[TransactionDocumentParser] Génération guidée KO : \(error)")
            }
        }
        #endif

        // 2nd stage: JSON via the dispatch point — covers Foundation Models
        // in free-form generation AND an OpenAI-compatible local server.
        guard AIEnrichmentBackend.isAvailable(for: .transactionImport) else {
            return ([], .aiUnavailable)
        }
        guard let raw = await AIEnrichmentBackend.completeText(
            feature: .transactionImport,
            system: Self.jsonInstructions,
            user: Self.buildPrompt(text: payload)
        ) else {
            return ([], .aiFailed("le moteur n'a rien renvoyé"))
        }
        let lines = Self.parseJSON(raw)
        return (lines, lines.isEmpty ? .nothingRecognized : .extracted)
    }

    // MARK: - Guided-generation schema

    #if canImport(FoundationModels)
    /// Schema imposed on the model: no more JSON to repair, decoding is
    /// constrained at generation time.
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct AITransactionExtraction {
        @Guide(description: "Opérations bancaires datées trouvées dans le document", .count(0...40))
        var transactions: [AITransactionLine]
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct AITransactionLine {
        @Guide(description: "Date de l'opération au format yyyy-MM-dd")
        var date: String
        @Guide(description: "Libellé complet de l'opération tel qu'il est écrit, sans la date ni le montant")
        var label: String
        @Guide(description: "Montant en valeur absolue, avec un point décimal")
        var amount: Double
        @Guide(description: "true si l'argent SORT du compte (achat, prélèvement, retrait), false si l'argent ENTRE (salaire, virement reçu, remboursement)")
        var isDebit: Bool
        @Guide(description: "CB, VIREMENT, PRELEVEMENT, RETRAIT, CHEQUE, ou chaîne vide si indéterminé")
        var paymentType: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    static func convert(_ extraction: AITransactionExtraction) -> [ExtractedBankTransaction] {
        extraction.transactions.compactMap { line in
            guard let date = BankStatementExtractor.normalizeDate(line.date) else { return nil }
            let label = line.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, line.amount != 0 else { return nil }
            let type = line.paymentType.trimmingCharacters(in: .whitespaces).uppercased()
            return ExtractedBankTransaction(
                date: date,
                amount: line.isDebit ? -abs(line.amount) : abs(line.amount),
                label: label,
                paymentTypeHint: type.isEmpty ? nil : type,
                // The model decided debit/credit explicitly: that's a
                // decision, not a defect.
                isSignExplicit: true,
                confidence: 0.7
            )
        }
    }
    #endif

    // MARK: - Prompts

    /// Guided-generation instructions — deliberately SHORT: the
    /// schema already carries the structure, and every instruction token is
    /// taken from the context window available to the document itself.
    static let guidedInstructions = """
    Tu extrais les opérations d'un relevé de compte bancaire, d'une capture d'écran d'application bancaire ou d'un export de transactions (le texte peut venir d'un OCR, donc être en colonne et mal aligné).

    Une opération = une date + un montant + un libellé. Ignore les en-têtes, les soldes (ancien solde, nouveau solde, report), les totaux et les coordonnées de l'agence : ce ne sont pas des opérations.
    Quand une ligne porte plusieurs montants, celui de l'opération vient AVANT le solde courant.
    Les dates sortent en yyyy-MM-dd. Les montants sortent en valeur absolue avec un point décimal (42.50, jamais 42,50) et le sens est porté par isDebit.
    N'invente jamais une opération : n'extrais que ce qui est écrit.
    """

    /// JSON variant for the 2nd stage (free-form generation / local server).
    /// Here the meaning is carried by the amount's SIGN: a boolean mistyped by
    /// a small model ("\"true\"" as a string) is one more failure source,
    /// whereas a negative number is unambiguous.
    /// ⚠️ Today's date is INJECTED into the instructions. A banking app
    /// screenshot almost never shows the year: without a reference, the
    /// model produces forms like "22-07-00" and every line got
    /// rejected — "no operations recognized" with a correct JSON right
    /// there. `BankStatementExtractor.normalizeDate` catches what still
    /// gets through, but it's still better to give the model what it needs to answer well.
    static var jsonInstructions: String {
        let today = isoDateOnly.string(from: Date())
        return baseJSONInstructions + """


        Nous sommes le \(today). Si l'année n'apparaît pas dans le document, déduis-la : une date qui tomberait APRÈS aujourd'hui appartient à l'année précédente (un relevé est toujours historique). Ne rends jamais une année inventée comme 0000 ou 00.
        """
    }

    private static let baseJSONInstructions = """
    Tu extrais les opérations d'un relevé de compte bancaire ou d'une capture d'écran d'application bancaire.

    Une opération = une date + un montant + un libellé. Ignore les en-têtes, les soldes (ancien solde, nouveau solde, report), les totaux et les coordonnées de l'agence.
    Quand une ligne porte plusieurs montants, celui de l'opération vient AVANT le solde courant.
    N'invente jamais une opération : n'extrais que ce qui est écrit.

    LE LIBELLÉ EST LE NOM DU MARCHAND, ET RIEN D'AUTRE.
    Une application bancaire affiche sous ce nom la CATÉGORIE qu'elle a devinée : « Grande surface », « Hébergement / restauration », « Café / jeux / tabac », « Sorties / restaurant », « À catégoriser », « Divers », « Alimentation », « Transport »… Ce texte n'appartient PAS au libellé.
    Écris « Carrefour City », jamais « Carrefour City Grande surface ».
    Écris « Terrys Cafe », jamais « Terrys Cafe Café / jeux / tabac ».
    Une icône, un logo ou une pastille de couleur ne se décrivent pas : ignore-les.

    Réponds UNIQUEMENT par un objet JSON valide, sans texte autour et sans balises de code :
    {"transactions":[{"date":"yyyy-MM-dd","label":"libellé complet","amount":-42.50,"payment_type":"CB"}]}

    Règles : le montant est NÉGATIF quand l'argent sort du compte (achat, prélèvement, retrait) et POSITIF quand il entre (salaire, virement reçu, remboursement). Le séparateur décimal est le point. payment_type vaut CB, VIREMENT, PRELEVEMENT, RETRAIT, CHEQUE ou une chaîne vide.
    """

    /// Local date formatter (yyyy-MM-dd) for injection into the prompt.
    private static let isoDateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func buildPrompt(text: String) -> String {
        """
        Extrais toutes les opérations de ce document :

        \(text)
        """
    }

    // MARK: - JSON decoding (2nd stage)

    private struct AILine: Decodable {
        let date: String?
        let label: String?
        /// Tolerant: a small model often writes `"amount": "-42,50"`.
        let amount: InvestmentPDFParser.LenientDouble?
        let payment_type: String?
    }

    /// Decodes a model response's operations, OBJECT BY OBJECT.
    ///
    /// ⚠️ Deliberately NOT a decode of the whole document. A single syntax
    /// mistake — a trailing comma, a missing key quote — used to throw
    /// `JSONDecoder` and lose ALL the operations, including the seven
    /// perfectly well-formed ones. Observed twice in a row with two
    /// different mistakes: patching each new mistake case by case doesn't
    /// converge.
    ///
    /// Here a broken line costs one line. The container (`{"transactions":
    /// [...]}`) doesn't even need to be valid, or to exist.
    static func parseJSON(_ raw: String) -> [ExtractedBankTransaction] {
        let decoder = JSONDecoder()
        return LenientJSON.innermostObjects(in: raw).compactMap { object in
            guard let data = object.data(using: .utf8),
                  let line = try? decoder.decode(AILine.self, from: data) else { return nil }
            return convert(line)
        }
    }

    /// A decoded line becomes an operation, or nothing.
    ///
    /// The same safety nets apply: with no usable date, no amount, or
    /// no label, we don't invent anything — we discard it.
    private static func convert(_ line: AILine) -> ExtractedBankTransaction? {
        guard let raw = line.date,
              let date = BankStatementExtractor.normalizeDate(raw),
              let amount = line.amount?.value, amount != 0 else { return nil }
        let label = (line.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        let type = (line.payment_type ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return ExtractedBankTransaction(
            date: date,
            amount: amount,
            label: label,
            paymentTypeHint: type.isEmpty ? nil : type,
            isSignExplicit: true,
            confidence: 0.65
        )
    }

    /// A date invented by the model ("2026-13-45") must disqualify the
    /// line, not produce a transaction dated whenever.
    static func isValidDate(_ raw: String) -> Bool {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return false }
        return true
    }

}
