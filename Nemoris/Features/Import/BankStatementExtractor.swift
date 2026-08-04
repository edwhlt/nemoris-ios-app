import Foundation

// MARK: - Extraction déterministe d'opérations depuis un relevé bancaire
//
// Moteur PUR (aucun accès réseau, disque, IA ni SwiftUI) — même doctrine que
// `InvestmentStatementExtractor`, `PortfolioEvolutionBuilder` et
// `MerchantQueryPlanner` : testable hors Xcode via `run_bank_statement_tests.sh`.
//
// ─── Pourquoi ce moteur existe ─────────────────────────────────────────────
//
// L'import de transactions ne connaissait que le CSV. Un relevé PDF ou une
// capture d'écran d'appli bancaire n'avait aucun chemin d'entrée, alors que
// c'est un format tabulaire très régulier. Le confier à 100 % à l'IA aurait
// reproduit les trois défauts déjà payés côté investissements : rien du tout
// sans Apple Intelligence, échec indiscernable d'un document vide, et aucun
// garde-fou face à une extraction probabiliste.
//
// ─── Ancrage sur la DATE, pas sur un identifiant ───────────────────────────
//
// Un relevé bancaire n'a pas d'équivalent de l'ISIN. L'invariant exploitable
// est qu'une opération porte TOUJOURS une date complète et un montant. On
// ancre donc sur la date (jour/mois/année, jamais une forme courte) et on
// cherche le montant sur la même ligne — ou juste en dessous quand le texte
// arrive en colonne, ce que produit l'OCR d'une capture d'écran.
//
// Ce moteur ne cherche pas à battre l'IA sur les mises en page exotiques : il
// couvre le cas dominant et sert de filet systématique. La réconciliation
// (`TransactionDocumentParser.reconcile`) lui laisse l'autorité sur la date et
// le montant — là où un petit modèle recopie ou dérive — et prend le libellé
// de l'IA, qui reconstitue mieux un texte OCR éclaté en colonnes.

/// Une opération bancaire reconnue sans IA. Volontairement distincte
/// d'`ImportSessionRow` (qui porte l'état de résolution et d'UI) : ce moteur
/// reste pur et ne connaît ni la base ni le moteur d'identification.
struct ExtractedBankTransaction: Equatable {
    /// Date au format yyyy-MM-dd (chaîne : le moteur ne dépend pas de Calendar).
    var date: String
    /// Montant SIGNÉ, convention de l'app : négatif = dépense.
    var amount: Double
    var label: String
    /// "CB" | "VIREMENT" | "PRELEVEMENT" | "RETRAIT" | "CHEQUE", si reconnaissable.
    var paymentTypeHint: String?
    /// Vrai quand le signe vient d'un marqueur explicite (+ ou − collé au
    /// montant). Faux quand il a été déduit d'un mot-clé du libellé ou du
    /// défaut « dépense » — c'est l'information dont la réconciliation a
    /// besoin pour savoir si elle peut faire confiance au signe de l'IA.
    var isSignExplicit: Bool
    /// Confiance : dégradée quand un champ a dû être déduit plutôt que lu.
    var confidence: Double
}

enum BankStatementExtractor {

    // MARK: - Point d'entrée

    /// Extrait toutes les opérations reconnaissables d'un texte brut.
    /// Renvoie un tableau vide plutôt que d'inventer : un document sans date
    /// ni montant ne produit rien, jamais une ligne « au cas où ».
    static func extractTransactions(from text: String) -> [ExtractedBankTransaction] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return [] }

        let infos = lines.map(LineInfo.init(raw:))
        var results: [ExtractedBankTransaction] = []
        /// Dernière ligne déjà rattachée à une opération — borne les fenêtres
        /// de libellé pour qu'un bloc n'aille jamais piocher dans le précédent.
        var lastConsumed = -1

        for index in infos.indices {
            let info = infos[index]
            guard let date = info.date, !info.isSummary else { continue }
            // Une ligne déjà absorbée comme montant ou continuation d'un bloc
            // précédent n'ouvre pas un nouveau bloc.
            guard index > lastConsumed else { continue }

            var amounts = info.amounts
            var amountLine = index
            var fromColumnLayout = false

            if amounts.isEmpty {
                // Mise en page en colonne (OCR de capture d'écran) : le montant
                // est sur une ligne suivante, séparé du libellé et de la date.
                // On ne franchit jamais une ligne portant une autre date : ce
                // serait déjà l'opération suivante.
                var cursor = index + 1
                while cursor < infos.count, cursor <= index + 3 {
                    let next = infos[cursor]
                    if next.date != nil { break }
                    if !next.amounts.isEmpty, !next.isSummary {
                        amounts = next.amounts
                        amountLine = cursor
                        fromColumnLayout = true
                        break
                    }
                    cursor += 1
                }
            }
            guard let first = amounts.first else { continue }

            var confidence = 0.9
            // ⚠️ Plusieurs montants sur la ligne = mise en page à colonnes
            // (DÉBIT | CRÉDIT | SOLDE). Le PREMIER est le montant de
            // l'opération dans toutes les dispositions observées : sur une
            // ligne de débit la colonne crédit est vide, et réciproquement,
            // tandis que le solde courant est toujours en dernier. Prendre le
            // dernier ferait importer le solde du compte à la place.
            if amounts.count > 1 { confidence -= 0.15 }

            var label = info.residual
            var labelFromBackward = false
            if fromColumnLayout {
                // La ligne d'ancrage ne portait qu'une date : le libellé est
                // au-dessus (toutes les captures d'app observées l'y placent).
                if label.isEmpty {
                    label = backwardLabel(infos: infos, before: index, notBefore: lastConsumed)
                    labelFromBackward = !label.isEmpty
                }
            } else {
                // Mise en page tabulaire : un libellé long peut déborder sur
                // les lignes suivantes, qui ne portent alors ni date ni
                // montant. Sans date sur ces lignes, aucun risque de voler le
                // libellé de l'opération suivante.
                var cursor = amountLine + 1
                var appended = 0
                while cursor < infos.count, appended < 2 {
                    let next = infos[cursor]
                    guard next.date == nil, next.amounts.isEmpty,
                          !next.isSummary, !next.residual.isEmpty else { break }
                    label = label.isEmpty ? next.residual : label + " " + next.residual
                    amountLine = cursor
                    appended += 1
                    cursor += 1
                }
                if label.isEmpty {
                    label = backwardLabel(infos: infos, before: index, notBefore: lastConsumed)
                    labelFromBackward = !label.isEmpty
                }
            }

            label = cleanLabel(label)
            // Pas de libellé = ligne de synthèse déguisée (report, total
            // intermédiaire non nommé). On préfère ne rien importer.
            guard !label.isEmpty else { continue }

            let hint = detectPaymentType(in: label)
            let signed = resolveSign(magnitude: first.value,
                                     explicit: first.isSignExplicit,
                                     label: label)
            if !first.isSignExplicit { confidence -= 0.15 }
            if labelFromBackward { confidence -= 0.05 }

            results.append(ExtractedBankTransaction(
                date: date,
                amount: signed,
                label: label,
                paymentTypeHint: hint,
                isSignExplicit: first.isSignExplicit,
                confidence: max(0.3, confidence)
            ))
            lastConsumed = max(index, amountLine)
        }
        return results
    }

    // MARK: - Libellé

    /// Libellé cherché AU-DESSUS de l'ancre, sans jamais franchir le bloc
    /// précédent. Prend la ligne textuelle la plus proche (celle qui ne porte
    /// ni date ni montant), ce qui correspond à l'ordre observé dans les
    /// captures : nom du marchand, puis date, puis montant.
    private static func backwardLabel(infos: [LineInfo], before index: Int, notBefore: Int) -> String {
        let lower = max(notBefore + 1, index - 3)
        guard lower < index else { return "" }
        for cursor in stride(from: index - 1, through: lower, by: -1) {
            let candidate = infos[cursor]
            guard candidate.date == nil, candidate.amounts.isEmpty, !candidate.isSummary else { continue }
            if !candidate.residual.isEmpty { return candidate.residual }
        }
        return ""
    }

    /// Collapse les espaces et retire la ponctuation de colonne résiduelle.
    private static func cleanLabel(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|:;,."))
    }

    // MARK: - Signe

    /// Mots-clés de CRÉDIT. Sur une mise en page à colonnes, le nombre n'a
    /// aucun signe : seule la sémantique du libellé permet de trancher.
    private static let creditMarkers = [
        "VIR RECU", "VIREMENT RECU", "VIR DE ", "VIR INST DE", "VIR SEPA RECU",
        "SALAIRE", "REMISE", "REMBOURSEMENT", "RBT ", "VERSEMENT", "DEPOT",
        "INTERETS", "CREDIT ", "AVOIR", "ANNULATION", "ALLOCATION", "PENSION"
    ]

    /// Signe final. Priorité au marqueur explicite (+/− collé au montant),
    /// sinon aux mots-clés, sinon dépense — l'immense majorité des lignes d'un
    /// relevé personnel. La réconciliation avec l'IA n'écrase ce choix que
    /// lorsqu'il n'était PAS explicite (cf. `isSignExplicit`).
    private static func resolveSign(magnitude: Double, explicit: Bool, label: String) -> Double {
        if explicit { return magnitude }
        let upper = label.uppercased()
        let isCredit = creditMarkers.contains { upper.contains($0) }
        return isCredit ? abs(magnitude) : -abs(magnitude)
    }

    // MARK: - Type de paiement

    /// Type de paiement déduit du libellé, `nil` si aucun marqueur reconnu.
    /// L'ordre compte : « PAIEMENT PSC » est une opération carte, il doit être
    /// testé avant le générique « PAIEMENT ».
    static func detectPaymentType(in label: String) -> String? {
        let upper = " " + label.uppercased() + " "
        let table: [(markers: [String], type: String)] = [
            (["RETRAIT", "DAB ", "DISTRIB"], "RETRAIT"),
            (["CHEQUE", " CHQ", "CHQ "], "CHEQUE"),
            (["CARTE ", " CB ", "PAIEMENT PSC", "PAIEMENT CB", "ACHAT CB", "PAYWEB"], "CB"),
            (["PRLV", "PRELEVEMENT", "PRELV"], "PRELEVEMENT"),
            (["VIR ", "VIREMENT", "VIRT "], "VIREMENT")
        ]
        for (markers, type) in table where markers.contains(where: { upper.contains($0) }) {
            return type
        }
        return nil
    }

    // MARK: - Analyse d'une ligne

    private struct LineInfo {
        let date: String?
        let amounts: [AmountToken]
        /// Ligne débarrassée de la date d'ancrage et des montants : la base
        /// du libellé.
        let residual: String
        let isSummary: Bool

        init(raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            self.date = InvestmentStatementExtractor.firstDate(in: trimmed)
            // ⚠️ Les montants sont cherchés sur un texte SANS dates. Sinon
            // « 02.07.2026 » est lu comme le montant 2,07 : le motif de montant
            // accepte le point décimal, et une date à points en est une
            // sous-chaîne parfaite.
            let dateless = BankStatementExtractor.strippingDates(
                BankStatementExtractor.normalizingSpaces(trimmed)
            )
            let tokens = BankStatementExtractor.amountTokens(in: dateless)
            self.amounts = tokens
            var residual = dateless
            for token in tokens.reversed() {
                residual = residual.replacingCharacters(in: token.range, with: " ")
            }
            self.residual = BankStatementExtractor.cleanLabel(residual)
            self.isSummary = BankStatementExtractor.isSummaryLine(trimmed)
        }
    }

    /// Lignes de synthèse d'un relevé : elles portent une date ET un montant
    /// sans être des opérations.
    ///
    /// ⚠️ Aucun marqueur ne peut être un simple « TOTAL » : TOTALENERGIES est
    /// un marchand courant sur un relevé français. Chaque marqueur est donc
    /// une locution complète.
    private static let summaryMarkers = [
        "ANCIEN SOLDE", "NOUVEAU SOLDE", "SOLDE PRECEDENT", "SOLDE PRÉCÉDENT",
        "SOLDE CREDITEUR", "SOLDE CRÉDITEUR", "SOLDE DEBITEUR", "SOLDE DÉBITEUR",
        "SOLDE AU ", "SOLDE INITIAL", "SOLDE FINAL", "TOTAL DES", "TOTAUX",
        "SOUS-TOTAL", "REPORT A NOUVEAU", "REPORT À NOUVEAU", "TOTAL DEBIT", "TOTAL CREDIT"
    ]

    static func isSummaryLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        return summaryMarkers.contains { upper.contains($0) }
    }

    // MARK: - Dates

    /// Formes longues d'abord (elles consomment le token entier), puis formes
    /// courtes à SLASH ou TIRET uniquement.
    ///
    /// ⚠️ Ne jamais ajouter le point aux formes courtes : « 12.50 » y répondrait
    /// et tous les montants à point décimal disparaîtraient du texte analysé.
    private static let datePatternsToStrip: [NSRegularExpression?] = [
        try? NSRegularExpression(pattern: "\\b\\d{1,2}[/.-]\\d{1,2}[/.-]\\d{2,4}\\b"),
        try? NSRegularExpression(pattern: "\\b\\d{4}[/.-]\\d{1,2}[/.-]\\d{1,2}\\b"),
        try? NSRegularExpression(pattern: "\\b\\d{1,2}[/-]\\d{1,2}\\b")
    ]

    static func strippingDates(_ text: String) -> String {
        var out = text
        for regex in datePatternsToStrip {
            guard let regex else { continue }
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: " ")
        }
        return out
    }

    // MARK: - Montants

    struct AmountToken {
        let value: Double
        /// Le token portait un « + » ou un « − » collé.
        let isSignExplicit: Bool
        let range: Range<String.Index>
    }

    /// Même discipline que `InvestmentStatementExtractor.signedAmount` : un
    /// montant porte des centimes OU une devise. Un entier nu ne peut pas être
    /// un montant, sinon un numéro de téléphone ou un IBAN en deviendrait un.
    /// Différence : on renvoie TOUS les tokens de la ligne, pour distinguer la
    /// colonne d'opération de la colonne de solde.
    ///
    /// Deux branches, et la distinction est la garantie de non-invention :
    ///   • partie décimale présente → devise facultative ;
    ///   • entier seul → devise OBLIGATOIRE.
    ///
    /// ⚠️ Le groupe des milliers doit être décrit explicitement
    /// (`\d{1,3}(?:[ .,]\d{3})+`). Un `[\d ]*` permissif ne couvre que
    /// l'espace : « 1,234.56 » y était lu « 234.56 », soit un montant amputé
    /// de son millier — silencieusement, puisque la ligne restait valide.
    private static let amountRegex = try? NSRegularExpression(pattern:
        "[+-]?(?:\\d{1,3}(?:[ .,]\\d{3})+|\\d+)[.,]\\d{1,2}(?![\\d])\\s*(?:€|EUR|\\$|USD)?"
        + "|"
        + "[+-]?(?:\\d{1,3}(?:[ .,]\\d{3})+|\\d+)(?![\\d.,])\\s*(?:€|EUR|\\$|USD)")

    /// Remplace les espaces insécables par des espaces simples.
    ///
    /// ⚠️ À appliquer AVANT `amountTokens`, jamais dedans : les `Range` rendus
    /// indexent la chaîne exactement telle qu'elle a été passée. Normaliser à
    /// l'intérieur produirait des index pointant vers une autre instance de
    /// `String` que celle de l'appelant — indices invalides au découpage.
    static func normalizingSpaces(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static func amountTokens(in cleaned: String) -> [AmountToken] {
        guard let regex = amountRegex else { return [] }
        var tokens: [AmountToken] = []
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        regex.enumerateMatches(in: cleaned, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: cleaned) else { return }
            let raw = String(cleaned[r])
            let stripped = raw
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "EUR", with: "")
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: "USD", with: "")
                // ⚠️ Le `\s*` final du motif avale le saut de ligne : sans ce
                // trim, `Double("+1.70\n")` renvoie nil et le montant est
                // silencieusement perdu.
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = InvestmentStatementExtractor.parseNumber(
                stripped.replacingOccurrences(of: " ", with: "")
            ) else { return }
            let explicit = stripped.hasPrefix("+") || stripped.hasPrefix("-")
            tokens.append(AmountToken(value: value, isSignExplicit: explicit, range: r))
        }
        return tokens
    }
}
