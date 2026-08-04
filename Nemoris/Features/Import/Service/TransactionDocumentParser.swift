import Foundation
import PDFKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Extraction d'opérations bancaires depuis un PDF, une capture d'écran ou un
/// texte — le pendant de `InvestmentPDFParser` pour le module Transactions.
///
/// **Pourquoi une classe distincte du parseur d'investissements :** ce qu'on
/// cherche n'a rien à voir (date + montant + libellé contre ISIN + quantité +
/// cours), le schéma guidé et le prompt diffèrent entièrement, et l'aval est
/// une `ImportSession` et non des ordres. En revanche tout ce qui est
/// GÉNÉRIQUE — sniffing du format par les octets, OCR Vision, extraction PDF,
/// découpage en blocs — est réutilisé tel quel depuis `InvestmentPDFParser`
/// plutôt que dupliqué.
///
/// **Trois étages par unité**, chacun rattrapant l'échec du précédent :
///   1. génération guidée `@Generable` (Foundation Models, iOS/macOS 26+) ;
///   2. génération JSON via `AIEnrichmentBackend.completeText` — donc aussi
///      un serveur local configuré (AXE T), pas seulement Apple ;
///   3. `BankStatementExtractor`, déterministe, exécuté SYSTÉMATIQUEMENT.
///
/// L'étage 3 n'est pas qu'un repli : il fait autorité sur la date et le
/// montant. Un petit modèle recopie facilement une ligne sur l'autre dans un
/// OCR en colonnes, là où l'ancrage déterministe lit les champs à leur place.
@MainActor
final class TransactionDocumentParser {

    static let shared = TransactionDocumentParser()

    /// Un fichier à analyser, déjà chargé en mémoire. Le nom sert à tracer
    /// l'origine de chaque ligne quand une session agrège plusieurs fichiers.
    struct DocumentSource {
        let data: Data
        let displayName: String
    }

    /// Résultat de l'analyse d'une unité (page PDF, capture, bloc de texte).
    struct UnitResult: Identifiable {
        let id = UUID()
        let unitNumber: Int
        let sourceName: String
        let rawText: String
        var transactions: [ExtractedBankTransaction]
        var diagnostic: PDFPageDiagnostic
        /// Type réel du document — l'enum est partagée avec le module
        /// Investissements (son préfixe est historique) : elle porte le
        /// vocabulaire d'affichage « pages / captures / blocs analysés ».
        var kind: InvestmentDocumentKind
        var usedDeterministicFallback: Bool
    }

    /// Vrai si un backend IA est utilisable. L'extraction fonctionne SANS —
    /// contrairement à l'import d'investissements, aucun bouton ne doit être
    /// grisé sur cette base : le moteur déterministe suffit à produire des
    /// lignes exploitables.
    var isAIAvailable: Bool { AIEnrichmentBackend.isAvailable }

    // MARK: - Point d'entrée

    /// Analyse N fichiers et renvoie les unités dans l'ordre de lecture.
    /// `onProgress(unitsDone, unitsTotal)` est appelé à chaque unité terminée ;
    /// le total est réévalué au fil de l'eau (le nombre de pages d'un PDF n'est
    /// connu qu'une fois ouvert).
    func parse(sources: [DocumentSource],
               onProgress: @escaping (Int, Int) -> Void) async -> [UnitResult] {
        // Phase 1 — extraction du TEXTE de chaque unité (OCR, pages PDF,
        // découpage en blocs), entièrement hors du main actor. Le nombre réel
        // d'unités n'est connu qu'à la fin : un PDF n'annonce son nombre de
        // pages qu'une fois ouvert, une image en vaut une.
        var pending: [(text: String, kind: InvestmentDocumentKind, source: String)] = []
        for source in sources {
            for unit in await units(for: source) {
                pending.append((unit.text, unit.kind, source.displayName))
            }
        }

        // Phase 2 — analyse unité par unité, avec une progression EXACTE
        // (l'ancienne version rapportait toujours `done / done`, soit 100 %
        // en permanence, donc une barre qui ne voulait rien dire).
        onProgress(0, pending.count)
        var results: [UnitResult] = []
        for (index, unit) in pending.enumerated() {
            results.append(await parseUnit(text: unit.text,
                                           unitNumber: index + 1,
                                           sourceName: unit.source,
                                           kind: unit.kind))
            onProgress(index + 1, pending.count)
        }
        return results
    }

    /// Découpe un fichier en unités de texte analysables, selon son type RÉEL
    /// (sniffé sur les octets, jamais déduit de l'extension — cf. la classe de
    /// bug documentée dans `InvestmentPDFParser.detectKind`).
    private func units(for source: DocumentSource) async -> [(text: String, kind: InvestmentDocumentKind)] {
        let kind = InvestmentPDFParser.detectKind(data: source.data,
                                                  fileExtension: (source.displayName as NSString).pathExtension)
        switch kind {
        case .pdf:
            let data = source.data
            // Lecture et rendu PDF hors du main actor : sur N fichiers, les
            // faire sur le thread principal fige l'UI pendant tout l'import.
            let pages: [String] = await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(data: data) else { return [] }
                return (0..<document.pageCount).compactMap { index in
                    guard let text = document.page(at: index)?.string,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return nil }
                    return text
                }
            }.value
            guard !pages.isEmpty else { return [("", .pdf)] }
            return pages.map { ($0, .pdf) }

        case .image:
            // OCR Vision hors du main actor : synchrone et coûteux (1-5 s sur
            // une capture plein écran), il fige sinon toute l'app et la barre
            // de progression ne se peint jamais.
            let data = source.data
            let text = await Task.detached(priority: .userInitiated) {
                InvestmentPDFParser.ocrText(from: data)
            }.value ?? ""
            return [(text, .image)]

        case .text:
            let text = Self.decodeText(source.data) ?? ""
            guard !text.isEmpty else { return [("", .text)] }
            // La fenêtre de contexte du modèle embarqué est étroite : un relevé
            // entier envoyé d'un bloc la fait déborder et la page est perdue.
            return InvestmentPDFParser.splitTextIntoChunks(text, maxChars: 4000).map { ($0, .text) }

        case .unknown:
            return [("", .unknown)]
        }
    }

    /// Décodage texte tolérant, même ordre que l'import CSV.
    ///
    /// ⚠️ N'est appelé qu'après le sniffing : `isoLatin1` n'échoue JAMAIS
    /// (toute suite d'octets en est valide), donc l'appeler sans vérifier au
    /// préalable que le contenu EST du texte transforme un PNG en centaines de
    /// milliers de caractères de binaire.
    static func decodeText(_ data: Data) -> String? {
        for encoding: String.Encoding in [.utf8, .utf16LittleEndian, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    // MARK: - Analyse d'une unité

    private func parseUnit(text: String, unitNumber: Int, sourceName: String,
                           kind: InvestmentDocumentKind) async -> UnitResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let diagnostic: PDFPageDiagnostic = kind == .unknown ? .notTextContent : .noTextExtracted
            return UnitResult(unitNumber: unitNumber, sourceName: sourceName, rawText: "",
                              transactions: [], diagnostic: diagnostic, kind: kind,
                              usedDeterministicFallback: false)
        }

        let (aiLines, aiDiagnostic) = await extractWithAI(text: text)
        // Moteur pur mais gourmand en regex sur un relevé dense : hors du main
        // actor, comme l'OCR, pour que l'UI reste vivante pendant l'analyse.
        let deterministic = await Task.detached(priority: .userInitiated) {
            BankStatementExtractor.extractTransactions(from: text)
        }.value
        let merged = Self.reconcile(ai: aiLines, deterministic: deterministic)
        let usedFallback = !deterministic.isEmpty && aiLines.isEmpty

        if !merged.isEmpty {
            return UnitResult(
                unitNumber: unitNumber, sourceName: sourceName, rawText: text,
                transactions: merged,
                // On garde la trace d'un échec IA même quand le déterministe a
                // sauvé la mise : c'est l'information utile en support.
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

    // MARK: - Réconciliation

    /// Clé de rapprochement : date + montant au centime, en valeur absolue.
    ///
    /// Le signe est volontairement HORS de la clé : c'est justement le champ
    /// que les deux sources peuvent lire différemment (une colonne DÉBIT n'a
    /// aucun signe, seule la sémantique du libellé ou la mise en page le
    /// donne). L'inclure ferait échouer le rapprochement au moment précis où
    /// il sert le plus.
    private static func matchKey(_ tx: ExtractedBankTransaction) -> String {
        "\(tx.date)|\(Int((abs(tx.amount) * 100).rounded()))"
    }

    /// Fusionne extraction IA et extraction déterministe.
    ///
    /// Répartition des autorités :
    ///   • date et montant → DÉTERMINISTE (il lit les chiffres à leur place) ;
    ///   • libellé → IA quand elle a vu la même opération (elle recompose
    ///     mieux un texte OCR éclaté en colonnes) ;
    ///   • signe → déterministe s'il était EXPLICITE (« - » collé au montant),
    ///     sinon celui de l'IA, qui voit la mise en page débit/crédit ;
    ///   • opérations que seule l'IA a vues → ajoutées (formats en prose que
    ///     l'ancrage date+montant ne peut pas voir).
    static func reconcile(ai: [ExtractedBankTransaction],
                          deterministic: [ExtractedBankTransaction]) -> [ExtractedBankTransaction] {
        guard !deterministic.isEmpty else { return ai }
        guard !ai.isEmpty else { return deterministic }

        // Plusieurs opérations peuvent partager la même clé (deux achats du
        // même montant le même jour) : on consomme dans l'ordre d'apparition.
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
                tx.confidence = min(1, tx.confidence + 0.1)   // corroboré par deux sources
            }
            merged.append(tx)
        }
        for (_, rest) in pending { merged.append(contentsOf: rest) }
        return merged.sorted { $0.date < $1.date }
    }

    // MARK: - Étages IA

    private func extractWithAI(text: String) async -> ([ExtractedBankTransaction], PDFPageDiagnostic) {
        // La fenêtre de contexte du modèle embarqué est étroite : un dépassement
        // fait échouer l'unité ENTIÈRE, pas seulement la ligne fautive.
        let payload = String(text.prefix(4000))

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *),
           // ⚠️ Gate sur la préférence, pas seulement sur la disponibilité :
           // appeler Foundation Models en direct ferait ignorer un « serveur
           // local » ou un « désactivé » choisis dans les Réglages — la classe
           // de bug que le point de dispatch unique (AXE T) a servi à éteindre.
           AIBackendPreference.current == .automatic,
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

        // 2e étage : JSON via le point de dispatch — couvre Foundation Models
        // en génération libre ET un serveur local compatible OpenAI.
        guard AIEnrichmentBackend.isAvailable else { return ([], .aiUnavailable) }
        guard let raw = await AIEnrichmentBackend.completeText(
            system: Self.jsonInstructions,
            user: Self.buildPrompt(text: payload)
        ) else {
            return ([], .aiFailed("le moteur n'a rien renvoyé"))
        }
        let lines = Self.parseJSON(raw)
        return (lines, lines.isEmpty ? .nothingRecognized : .extracted)
    }

    // MARK: - Schéma de génération guidée

    #if canImport(FoundationModels)
    /// Schéma imposé au modèle : plus de JSON à réparer, le décodage est
    /// contraint côté génération.
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
            guard Self.isValidDate(line.date) else { return nil }
            let label = line.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, line.amount != 0 else { return nil }
            let type = line.paymentType.trimmingCharacters(in: .whitespaces).uppercased()
            return ExtractedBankTransaction(
                date: line.date,
                amount: line.isDebit ? -abs(line.amount) : abs(line.amount),
                label: label,
                paymentTypeHint: type.isEmpty ? nil : type,
                // Le modèle a tranché débit/crédit explicitement : c'est une
                // décision, pas un défaut.
                isSignExplicit: true,
                confidence: 0.7
            )
        }
    }
    #endif

    // MARK: - Prompts

    /// Instructions de la génération guidée — volontairement COURTES : le
    /// schéma porte déjà la structure, et chaque token d'instruction est pris
    /// sur la fenêtre de contexte disponible pour le document lui-même.
    static let guidedInstructions = """
    Tu extrais les opérations d'un relevé de compte bancaire, d'une capture d'écran d'application bancaire ou d'un export de transactions (le texte peut venir d'un OCR, donc être en colonne et mal aligné).

    Une opération = une date + un montant + un libellé. Ignore les en-têtes, les soldes (ancien solde, nouveau solde, report), les totaux et les coordonnées de l'agence : ce ne sont pas des opérations.
    Quand une ligne porte plusieurs montants, celui de l'opération vient AVANT le solde courant.
    Les dates sortent en yyyy-MM-dd. Les montants sortent en valeur absolue avec un point décimal (42.50, jamais 42,50) et le sens est porté par isDebit.
    N'invente jamais une opération : n'extrais que ce qui est écrit.
    """

    /// Variante JSON pour le 2e étage (génération libre / serveur local).
    /// Ici le sens est porté par le SIGNE du montant : un booléen mal typé par
    /// un petit modèle (« "true" » en chaîne) est une source d'échec de plus,
    /// alors qu'un nombre négatif est sans ambiguïté.
    static let jsonInstructions = """
    Tu extrais les opérations d'un relevé de compte bancaire ou d'une capture d'écran d'application bancaire.

    Une opération = une date + un montant + un libellé. Ignore les en-têtes, les soldes (ancien solde, nouveau solde, report), les totaux et les coordonnées de l'agence.
    Quand une ligne porte plusieurs montants, celui de l'opération vient AVANT le solde courant.
    N'invente jamais une opération : n'extrais que ce qui est écrit.

    Réponds UNIQUEMENT par un objet JSON valide, sans texte autour et sans balises de code :
    {"transactions":[{"date":"yyyy-MM-dd","label":"libellé complet","amount":-42.50,"payment_type":"CB"}]}

    Règles : le montant est NÉGATIF quand l'argent sort du compte (achat, prélèvement, retrait) et POSITIF quand il entre (salaire, virement reçu, remboursement). Le séparateur décimal est le point. payment_type vaut CB, VIREMENT, PRELEVEMENT, RETRAIT, CHEQUE ou une chaîne vide.
    """

    static func buildPrompt(text: String) -> String {
        """
        Extrais toutes les opérations de ce document :

        \(text)
        """
    }

    // MARK: - Décodage JSON (2e étage)

    private struct AIResponse: Decodable {
        let transactions: [AILine]?
    }

    private struct AILine: Decodable {
        let date: String?
        let label: String?
        /// Tolérant : un petit modèle écrit souvent `"amount": "-42,50"`.
        let amount: InvestmentPDFParser.LenientDouble?
        let payment_type: String?
    }

    static func parseJSON(_ raw: String) -> [ExtractedBankTransaction] {
        // Les modèles ajoutent volontiers des balises de code markdown autour
        // du JSON demandé.
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }
        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AIResponse.self, from: data) else {
            return []
        }
        return (decoded.transactions ?? []).compactMap { line in
            guard let date = line.date, isValidDate(date),
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
    }

    /// Une date inventée par le modèle (« 2026-13-45 ») doit disqualifier la
    /// ligne, pas produire une transaction datée n'importe quand.
    static func isValidDate(_ raw: String) -> Bool {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return false }
        return true
    }

    // MARK: - Pont vers la session d'import

    private static let rowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Convertit les unités analysées en lignes de session d'import.
    /// `startingAt` permet de continuer une numérotation globale quand la
    /// session agrège plusieurs fichiers — deux fichiers repartant à 1
    /// produiraient des numéros de ligne en collision.
    static func rows(from units: [UnitResult], startingAt startNumber: Int = 1) -> [ImportSessionRow] {
        var number = startNumber
        var rows: [ImportSessionRow] = []
        for unit in units {
            for tx in unit.transactions {
                guard let date = rowDateFormatter.date(from: tx.date) else { continue }
                rows.append(ImportSessionRow(
                    sourceRowNumber: number,
                    rawLabel: tx.label,
                    date: date,
                    amount: tx.amount,
                    paymentTypeHint: tx.paymentTypeHint,
                    sourceFile: unit.sourceName
                ))
                number += 1
            }
        }
        return rows
    }
}
