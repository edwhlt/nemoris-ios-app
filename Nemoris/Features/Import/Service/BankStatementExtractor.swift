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
struct ExtractedBankTransaction: Equatable, Codable, Hashable, Sendable {
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
    ///
    /// `referenceDate` sert à résoudre les dates SANS année (« 2 juil. »,
    /// « Hier »), omniprésentes dans les captures d'applis bancaires. Paramètre
    /// explicite plutôt que `Date()` en dur : le moteur reste déterministe et
    /// testable.
    static func extractTransactions(from text: String,
                                    referenceDate: Date = Date()) -> [ExtractedBankTransaction] {
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
            guard let date = resolvedDate(info, reference: referenceDate), !info.isSummary else { continue }
            // Une ligne déjà absorbée comme montant ou continuation d'un bloc
            // précédent n'ouvre pas un nouveau bloc.
            guard index > lastConsumed else { continue }

            // ─── Mise en page à EN-TÊTES DE DATE ────────────────────────────
            // Les applis bancaires regroupent la journée sous un seul en-tête,
            // puis enchaînent les opérations : « 22 juillet » / marchand /
            // catégorie / montant / marchand / catégorie / montant…
            // Le modèle « une date = une opération » n'en retenait donc qu'une
            // par journée, et prenait pour libellé la ligne de texte la plus
            // proche — c'est-à-dire la CATÉGORIE de l'opération précédente.
            if info.isDateOnlyLine, info.amounts.isEmpty {
                let consumedBefore = lastConsumed
                let emitted = collectUnderDateHeader(infos: infos, headerIndex: index,
                                                     date: date, lastConsumed: &lastConsumed)
                if !emitted.isEmpty {
                    results.append(contentsOf: emitted)
                    continue
                }
                // Rien sous l'en-tête : on rejoue le chemin classique.
                lastConsumed = consumedBefore
            }

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
                    if next.hasDate { break }
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

            // Une ligne de date pure n'a pas de libellé, même si le mot de la
            // date y survit en résidu (« Hier », « 2 juil. ») — sinon le
            // libellé de l'opération devient « Hier ».
            var label = info.isDateOnlyLine ? "" : info.residual
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
                    guard !next.hasDate, next.amounts.isEmpty,
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

    /// Extrait TOUTES les opérations regroupées sous un en-tête de date, jusqu'à
    /// l'en-tête suivant.
    ///
    /// ⚠️ Le libellé d'un bloc est sa PREMIÈRE ligne de texte (le marchand) : les
    /// suivantes sont la catégorie ou un sous-titre de l'appli (« Grande
    /// surface », « Café / jeux / tabac »). Prendre la plus proche du montant
    /// donnait systématiquement la catégorie à la place du marchand.
    private static func collectUnderDateHeader(infos: [LineInfo],
                                               headerIndex: Int,
                                               date: String,
                                               lastConsumed: inout Int) -> [ExtractedBankTransaction] {
        var results: [ExtractedBankTransaction] = []
        var pendingLabel = ""
        var cursor = headerIndex + 1
        // ⚠️ On ne consomme QUE jusqu'au dernier montant émis. Les lignes de
        // texte qui suivent appartiennent déjà au bloc suivant : les marquer
        // consommées privait celui-ci de son libellé (fenêtre arrière bornée
        // par `lastConsumed`) dans la mise en page où chaque opération porte sa
        // propre date, et l'opération était alors perdue.
        var consumedUpTo = headerIndex

        while cursor < infos.count {
            let line = infos[cursor]
            // Une autre date ouvre la journée suivante.
            if line.hasDate { break }
            if line.isSummary { cursor += 1; continue }

            if let token = line.amounts.first {
                var label = pendingLabel
                var fromBackward = false
                if label.isEmpty {
                    // Mise en page inverse (marchand AU-DESSUS de la date) :
                    // c'est le cas des applis qui datent chaque opération.
                    label = backwardLabel(infos: infos, before: headerIndex, notBefore: lastConsumed)
                    fromBackward = !label.isEmpty
                }
                if let tx = makeTransaction(date: date, token: token,
                                            multipleAmounts: line.amounts.count > 1,
                                            label: label, labelFromBackward: fromBackward) {
                    results.append(tx)
                    consumedUpTo = cursor
                }
                pendingLabel = ""
            } else if pendingLabel.isEmpty, !line.residual.isEmpty {
                pendingLabel = line.residual
            }
            cursor += 1
        }
        if !results.isEmpty { lastConsumed = consumedUpTo }
        return results
    }

    /// Fabrique commune aux deux mises en page (en-tête de date et tabulaire).
    private static func makeTransaction(date: String,
                                        token: AmountToken,
                                        multipleAmounts: Bool,
                                        label: String,
                                        labelFromBackward: Bool) -> ExtractedBankTransaction? {
        let cleaned = cleanLabel(label)
        // Pas de libellé = ligne de synthèse déguisée : on préfère ne rien
        // importer plutôt qu'une opération anonyme.
        guard !cleaned.isEmpty else { return nil }
        var confidence = 0.9
        if multipleAmounts { confidence -= 0.15 }
        if !token.isSignExplicit { confidence -= 0.15 }
        if labelFromBackward { confidence -= 0.05 }
        return ExtractedBankTransaction(
            date: date,
            amount: resolveSign(magnitude: token.value,
                                explicit: token.isSignExplicit, label: cleaned),
            label: cleaned,
            paymentTypeHint: detectPaymentType(in: cleaned),
            isSignExplicit: token.isSignExplicit,
            confidence: max(0.3, confidence)
        )
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
            guard !candidate.hasDate, candidate.amounts.isEmpty, !candidate.isSummary else { continue }
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
        let dateHit: DateHit?
        let amounts: [AmountToken]
        /// Ligne débarrassée de la date d'ancrage et des montants : la base
        /// du libellé.
        let residual: String
        let isSummary: Bool
        /// La ligne ne porte QUE la date (aux caractères de ponctuation près).
        /// C'est la condition pour accepter une date sans année comme ancre :
        /// dans « CARTE 01/07 CARREFOUR », « 01/07 » est la date de l'opération
        /// carte, pas celle du relevé — la vraie date est ailleurs.
        let isDateOnlyLine: Bool

        var hasDate: Bool { dateHit != nil }

        init(raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let hit = BankStatementExtractor.detectDate(in: trimmed)
            self.dateHit = hit
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
            self.isDateOnlyLine = hit != nil && BankStatementExtractor.isDateOnly(trimmed)
        }
    }

    // MARK: - Dates : formes reconnues

    /// Une date repérée sur une ligne.
    enum DateHit {
        /// Date complète (jour, mois ET année) : ancrable n'importe où dans la
        /// ligne, y compris au milieu d'un libellé tabulaire.
        case complete(String)             // yyyy-MM-dd
        /// Jour + mois sans année (« 2 juil. », « 02/07 ») : l'année est
        /// déduite, et la ligne doit être une ligne de date pure.
        case dayMonth(day: Int, month: Int)
        /// « Aujourd'hui » / « Hier » — omniprésents en tête de liste dans les
        /// applis bancaires.
        case relative(daysAgo: Int)
    }

    /// Résout la date d'une ligne en `yyyy-MM-dd`, ou `nil` si la ligne n'en
    /// porte pas d'exploitable.
    private static func resolvedDate(_ info: LineInfo, reference: Date) -> String? {
        switch info.dateHit {
        case .complete(let iso):
            return iso
        case .dayMonth(let day, let month):
            guard info.isDateOnlyLine else { return nil }
            return isoDate(day: day, month: month, reference: reference)
        case .relative(let daysAgo):
            guard info.isDateOnlyLine else { return nil }
            guard let shifted = gregorian.date(byAdding: .day, value: -daysAgo, to: reference) else { return nil }
            let c = gregorian.dateComponents([.year, .month, .day], from: shifted)
            guard let y = c.year, let m = c.month, let d = c.day else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        case nil:
            return nil
        }
    }

    private static let gregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return cal
    }()

    /// Année déduite pour un jour+mois nu : celle de la référence, sauf si la
    /// date obtenue serait DANS LE FUTUR — un relevé est toujours historique,
    /// donc « 28 décembre » lu un 3 janvier désigne l'année précédente.
    private static func isoDate(day: Int, month: Int, reference: Date) -> String? {
        let c = gregorian.dateComponents([.year, .month, .day], from: reference)
        guard let refYear = c.year, let refMonth = c.month, let refDay = c.day else { return nil }
        let year = (month, day) > (refMonth, refDay) ? refYear - 1 : refYear
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Détecte la date d'une ligne, de la forme la plus fiable à la moins
    /// contrainte.
    static func detectDate(in line: String) -> DateHit? {
        // 1) Date numérique complète (dd/MM/yyyy, yyyy-MM-dd…) — la plus sûre.
        if let iso = InvestmentStatementExtractor.firstDate(in: line) {
            return .complete(iso)
        }
        // 2) Date en toutes lettres, avec ou sans année (« 12 juin 2026 »,
        //    « 2 juil. », « Jul 2 »).
        if let named = monthNameDate(in: line) {
            if let year = named.year {
                return .complete(String(format: "%04d-%02d-%02d", year, named.month, named.day))
            }
            return .dayMonth(day: named.day, month: named.month)
        }
        // 3) Mots-clés relatifs des applis bancaires.
        //
        // ⚠️ Comparaison par MOT ENTIER, jamais par sous-chaîne : « hier » est
        // contenu dans « fichier », « cahier », « trésorier »…
        let words = Set(tokens(of: line))
        if !words.isDisjoint(with: ["aujourd", "today"]) { return .relative(daysAgo: 0) }
        if !words.isDisjoint(with: ["hier", "yesterday"]) { return .relative(daysAgo: 1) }
        // 4) Jour/mois numérique sans année (« 02/07 »).
        if let dm = numericDayMonth(in: line) {
            return .dayMonth(day: dm.day, month: dm.month)
        }
        return nil
    }

    /// Noms de mois FR et EN, formes longues et abrégées. Les clés sont
    /// « pliées » (sans accent, minuscules) : un OCR rend souvent « aout » ou
    /// « fevrier ».
    private static let monthsByName: [String: Int] = {
        let table: [(Int, [String])] = [
            (1,  ["janvier", "janv", "jan", "january"]),
            (2,  ["fevrier", "fevr", "fev", "february", "feb"]),
            (3,  ["mars", "march", "mar"]),
            (4,  ["avril", "avr", "april", "apr"]),
            (5,  ["mai", "may"]),
            (6,  ["juin", "june", "jun"]),
            (7,  ["juillet", "juil", "july", "jul"]),
            (8,  ["aout", "august", "aug"]),
            (9,  ["septembre", "sept", "sep", "september"]),
            (10, ["octobre", "oct", "october"]),
            (11, ["novembre", "nov", "november"]),
            (12, ["decembre", "dec", "december"])
        ]
        var out: [String: Int] = [:]
        for (number, names) in table {
            for name in names { out[name] = number }
        }
        return out
    }()

    /// « 2 juil. », « 12 juin 2026 », « Jul 2 », « July 2, 2026 ».
    static func monthNameDate(in line: String) -> (day: Int, month: Int, year: Int?)? {
        let folded = line
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        // Les mots sont isolés sur la ponctuation ET les espaces : « 2 juil. »
        // comme « July 2, 2026 ».
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard words.count >= 2 else { return nil }

        for (index, word) in words.enumerated() {
            guard let month = monthsByName[word] else { continue }
            // Jour AVANT (FR : « 2 juil. ») ou APRÈS (EN : « Jul 2 »).
            var day: Int?
            if index > 0, let d = Int(words[index - 1]), (1...31).contains(d) { day = d }
            if day == nil, index + 1 < words.count,
               let d = Int(words[index + 1]), (1...31).contains(d) { day = d }
            guard let day else { continue }

            // Année : un nombre à 4 chiffres plausible n'importe où sur la ligne.
            let year = words.compactMap(Int.init).first { (1900...2200).contains($0) }
            return (day, month, year)
        }
        return nil
    }

    /// « 02/07 » ou « 02-07 » — jour/mois nu, convention FR (jour d'abord).
    private static let numericDayMonthRegex = try? NSRegularExpression(
        pattern: "\\b(\\d{1,2})[/-](\\d{1,2})\\b")

    static func numericDayMonth(in line: String) -> (day: Int, month: Int)? {
        guard let regex = numericDayMonthRegex else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let dayRange = Range(match.range(at: 1), in: line),
              let monthRange = Range(match.range(at: 2), in: line),
              let day = Int(line[dayRange]), let month = Int(line[monthRange]),
              (1...31).contains(day), (1...12).contains(month)
        else { return nil }
        return (day, month)
    }

    /// Normalise une date PRODUITE PAR UN MODÈLE en `yyyy-MM-dd`.
    ///
    /// ⚠️ Un modèle à qui l'on demande `yyyy-MM-dd` ne l'honore pas toujours :
    /// sur une capture d'appli bancaire, l'année n'est écrite NULLE PART, et il
    /// rend alors des formes comme « 22-07-00 » ou « 22/07 ». Rejeter ces
    /// lignes revenait à jeter TOUTE l'extraction alors que le jour et le mois
    /// étaient corrects — symptôme : « aucune opération reconnue » avec un JSON
    /// pourtant juste sous les yeux.
    ///
    /// Convention FR (comme le reste du moteur) : jour d'abord quand l'ordre
    /// est ambigu. L'année manquante ou implausible est déduite de
    /// `referenceDate`, avec la même règle qu'ailleurs — une date qui tomberait
    /// dans le futur appartient à l'année précédente.
    static func normalizeDate(_ raw: String, referenceDate: Date = Date()) -> String? {
        let parts = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }

        // Année explicite : le composant à 4 chiffres, où qu'il soit.
        let explicitYear = parts.first { (1900...2200).contains($0) }
        let rest = parts.filter { !(1900...2200).contains($0) }
        guard rest.count >= 2 else { return nil }

        let day: Int, month: Int
        if rest[0] > 12, rest[1] <= 12 {
            day = rest[0]; month = rest[1]          // 22-07 → jour-mois
        } else if rest[0] <= 12, rest[1] > 12 {
            day = rest[1]; month = rest[0]          // 07-22 → mois-jour (anglo)
        } else {
            day = rest[0]; month = rest[1]          // ambigu → convention FR
        }
        guard (1...31).contains(day), (1...12).contains(month) else { return nil }

        if let year = explicitYear {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return isoDate(day: day, month: month, reference: referenceDate)
    }

    /// Mots d'une ligne, sans accents ni casse, ponctuation retirée.
    static func tokens(of line: String) -> [String] {
        line.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static let relativeKeywords: Set<String> = [
        "aujourd", "hui", "hier", "today", "yesterday"
    ]

    /// Vrai si la ligne ne porte QU'UNE date, aux mots de date et à la
    /// ponctuation près : « 2 juil. », « Hier », « 02/07 », « 12 juin 2026 ».
    ///
    /// C'est la condition qui autorise une date SANS année à servir d'ancre.
    /// Sans elle, le « 01/07 » de « CARTE 01/07 CARREFOUR » (la date de
    /// l'opération carte, pas celle du relevé) ouvrirait une fausse opération.
    static func isDateOnly(_ line: String) -> Bool {
        // Les dates numériques complètes ont déjà été retirées par `strippingDates`.
        let remaining = tokens(of: strippingDates(line)).filter { token in
            if monthsByName[token] != nil { return false }
            if relativeKeywords.contains(token) { return false }
            // Nombres appartenant à une date : le jour, ou l'année.
            if let n = Int(token), (1...31).contains(n) || (1900...2200).contains(n) { return false }
            return true
        }
        return remaining.isEmpty
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
