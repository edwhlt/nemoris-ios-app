import Foundation

/// Réparation des JSON produits par un modèle de langage.
///
/// Moteur PUR — couvert par `run_import_pipeline_tests.sh`.
///
/// ─── Pourquoi ça existe ────────────────────────────────────────────────────
///
/// Un modèle qui génère du JSON en texte libre le met en forme, et sa mise en
/// forme peut couper une chaîne au milieu :
///
/// ```
///     "payment_
///         type": "CB"
/// ```
///
/// C'est du JSON **invalide** — la norme interdit un caractère de contrôle brut
/// à l'intérieur d'une chaîne. `JSONDecoder` lève, et **tout le document est
/// perdu** : cas réel où huit opérations parfaitement extraites ont produit
/// « aucune transaction à importer ».
///
/// ⚠️ Réparation de MISE EN FORME uniquement. On ne devine aucune valeur, on ne
/// referme aucune accolade : si le modèle a inventé ou omis des données, elles
/// restent inventées ou omises. Recoller une chaîne coupée par un retour à la
/// ligne ne change pas le sens, c'est la seule chose qu'on s'autorise.
enum LenientJSON {

    /// Recolle les chaînes coupées par un retour à la ligne.
    ///
    /// ⚠️ La façon de recoller DÉPEND du rôle de la chaîne :
    ///   • une CLÉ se recolle sans rien (`"payment_\n  type"` → `"payment_type"`),
    ///     puisque la coupure est purement typographique ;
    ///   • une VALEUR se recolle avec une espace (`"CARREFOUR\n  CITY"` →
    ///     `"CARREFOUR CITY"`), parce que c'est un libellé dont les mots ont été
    ///     séparés par le retour à la ligne.
    /// Traiter les deux pareil casse l'un ou l'autre.
    static func repaired(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)

        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            guard character == "\"" else {
                output.append(character)
                index = raw.index(after: index)
                continue
            }

            // Début de chaîne : on la capture entièrement pour décider ensuite.
            var literal = ""
            var cursor = raw.index(after: index)
            var closed = false
            while cursor < raw.endIndex {
                let inner = raw[cursor]
                if inner == "\\" {
                    // Échappement : les deux caractères passent tels quels.
                    literal.append(inner)
                    cursor = raw.index(after: cursor)
                    if cursor < raw.endIndex {
                        literal.append(raw[cursor])
                        cursor = raw.index(after: cursor)
                    }
                    continue
                }
                if inner == "\"" { closed = true; break }
                literal.append(inner)
                cursor = raw.index(after: cursor)
            }

            guard closed else {
                // Chaîne jamais refermée : on rend le reste tel quel, le
                // décodeur signalera l'erreur — mieux qu'une réparation qui
                // inventerait une fin.
                output.append(contentsOf: raw[index...])
                break
            }

            // Rôle de la chaîne : suivie de `:` (après d'éventuels blancs) = clé.
            var lookahead = raw.index(after: cursor)
            while lookahead < raw.endIndex, raw[lookahead].isWhitespace {
                lookahead = raw.index(after: lookahead)
            }
            let isKey = lookahead < raw.endIndex && raw[lookahead] == ":"

            output.append("\"")
            output.append(collapseBreaks(in: literal, joiner: isKey ? "" : " "))
            output.append("\"")
            index = raw.index(after: cursor)
        }
        return output
    }

    /// Remplace chaque saut de ligne (et l'indentation qui le suit) par
    /// `joiner`. Les autres caractères de contrôle sont retirés : eux aussi
    /// sont interdits dans une chaîne JSON.
    private static func collapseBreaks(in literal: String, joiner: String) -> String {
        guard literal.contains(where: { $0.isNewline || $0 == "\t" }) else { return literal }
        var result = ""
        var index = literal.startIndex
        while index < literal.endIndex {
            let character = literal[index]
            if character.isNewline || character == "\t" {
                // Absorbe le saut ET l'indentation qui suit, sinon on
                // recollerait « payment_        type ».
                while index < literal.endIndex,
                      literal[index].isNewline || literal[index] == "\t" || literal[index] == " " {
                    index = literal.index(after: index)
                }
                // Pas de joiner en fin de chaîne : « CARREFOUR\n » ne doit pas
                // rendre « CARREFOUR ».
                if index < literal.endIndex, !result.isEmpty { result += joiner }
                continue
            }
            result.append(character)
            index = literal.index(after: index)
        }
        return result
    }

    /// Isole l'objet JSON d'une réponse (les modèles l'entourent volontiers de
    /// texte ou de balises de code) puis le répare.
    static func extractObject(from raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }
        return repaired(repairSyntax(cleaned))
    }

    // MARK: - Réparations lexicales

    /// Corrige les fautes de PONCTUATION les plus fréquentes des modèles.
    ///
    /// Chacune vient d'un cas réel :
    ///   • `"amount": -6.98,\n}` — virgule finale, interdite en JSON ;
    ///   • `, amount": -6.00` — guillemet ouvrant de clé oublié ;
    ///   • `,,` — virgule dupliquée.
    ///
    /// ⚠️ Ponctuation UNIQUEMENT. On ne complète aucune valeur, on ne referme
    /// aucune structure : une réponse tronquée doit rester une erreur visible.
    static func repairSyntax(_ raw: String) -> String {
        var text = raw

        // Guillemet ouvrant manquant sur une clé : `, amount":` → `, "amount":`.
        // Motif volontairement étroit (un identifiant nu suivi de `":`), pour ne
        // pas toucher au contenu des chaînes.
        text = replacing(text,
                         pattern: #"([,{])(\s*)([A-Za-z_][A-Za-z0-9_]*)"(\s*):"#,
                         template: "$1$2\"$3\"$4:")

        // Virgule FR comme séparateur décimal dans un nombre : `"amount":-19,50`
        // n'est pas du JSON valide (`,` y sépare deux champs, jamais deux
        // moitiés d'un nombre) — un modèle habitué à écrire en français
        // l'échappe malgré la consigne « point décimal ». Motif ancré
        // JUSTE APRÈS `:` (jamais après une apostrophe/guillemet), ce qui
        // exclut par construction tout ce qui est à l'intérieur d'une chaîne
        // — une valeur texte commence toujours par `"`, jamais par un
        // chiffre. Le lookahead sur `,`/`}`/`]` garantit qu'on s'arrête au
        // VRAI séparateur de champ suivant plutôt que de le consommer.
        text = replacing(text,
                         pattern: #"(\s*-?\d+),(\d+)(?=\s*[,}\]])"#,
                         template: "$1.$2")

        // Virgules dupliquées, puis virgule finale avant une fermeture.
        text = replacing(text, pattern: #",(\s*),"#, template: ",$1")
        text = replacing(text, pattern: #",(\s*)([}\]])"#, template: "$1$2")

        // Clés SANS aucun guillemet : `, effort:2` → `, "effort":2`.
        //
        // ⚠️ Distinct du motif d'entrée de cette fonction, qui ne rattrape que
        // le guillemet OUVRANT manquant (`, amount":`). Un modèle rend
        // couramment un objet dont une partie des clés est correctement
        // citée et l'autre pas du tout — vu en production : `"annual_impact":0,
        // effort:2, confidence:0.92`. Traité par un scanner plutôt qu'une
        // regex, parce qu'un `mot:` dans une phrase française (« Bilan: … »)
        // est fréquent dans les valeurs texte et ne doit surtout pas être
        // réécrit.
        return quotingBareKeys(text)
    }

    /// Ajoute les guillemets manquants autour des clés d'objet nues, en
    /// ignorant tout ce qui se trouve à l'intérieur d'une chaîne.
    static func quotingBareKeys(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)
        var inString = false
        var escaped = false
        /// Vrai quand la position courante peut accueillir une CLÉ : juste
        /// après `{` ou `,`. C'est ce qui évite de toucher à une valeur.
        var expectingKey = false

        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]

            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index = raw.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                expectingKey = false
                output.append(character)
                index = raw.index(after: index)
                continue
            }

            if character == "{" || character == "," {
                expectingKey = true
                output.append(character)
                index = raw.index(after: index)
                continue
            }

            if character.isWhitespace {
                output.append(character)
                index = raw.index(after: index)
                continue
            }

            // Un identifiant nu à un emplacement de clé, suivi de `:`.
            if expectingKey, character.isLetter || character == "_" {
                var cursor = index
                var identifier = ""
                while cursor < raw.endIndex, raw[cursor].isLetter || raw[cursor].isNumber || raw[cursor] == "_" {
                    identifier.append(raw[cursor])
                    cursor = raw.index(after: cursor)
                }
                var lookahead = cursor
                while lookahead < raw.endIndex, raw[lookahead].isWhitespace {
                    lookahead = raw.index(after: lookahead)
                }
                if lookahead < raw.endIndex, raw[lookahead] == ":" {
                    output.append("\"\(identifier)\"")
                    index = cursor
                    expectingKey = false
                    continue
                }
                // Pas une clé (`true`, `null`, un nombre…) : on recopie tel quel.
                output.append(identifier)
                index = cursor
                expectingKey = false
                continue
            }

            expectingKey = false
            output.append(character)
            index = raw.index(after: index)
        }
        return output
    }

    private static func replacing(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    // MARK: - Découpage objet par objet

    /// Les objets JSON les plus INTERNES d'une réponse, chacun réparé
    /// séparément.
    ///
    /// ─── Pourquoi décoder objet par objet ──────────────────────────────────
    ///
    /// Exiger que TOUT le document soit valide, c'est perdre huit opérations
    /// parfaitement extraites parce que le modèle a laissé une virgule en trop
    /// sur la troisième. Constaté deux fois de suite, avec deux fautes
    /// différentes : réparer chaque nouvelle faute au cas par cas est une course
    /// perdue d'avance.
    ///
    /// En décodant chaque objet indépendamment, une faute de syntaxe coûte UNE
    /// ligne au lieu de la capture entière. C'est le comportement qu'on veut :
    /// dégradation progressive, pas tout ou rien.
    ///
    /// « Les plus internes » = sans accolade imbriquée. Nos schémas d'opérations
    /// et d'ordres sont plats, donc ce sont exactement les objets à décoder ; le
    /// conteneur (`{"transactions": [...]}`) est ignoré, ce qui rend l'extraction
    /// insensible à sa forme.
    static func innermostObjects(in raw: String) -> [String] {
        let text = repairSyntax(raw)
        var objects: [String] = []
        var start: String.Index?
        var containsNested = false
        var inString = false
        var escaped = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            defer { index = text.index(after: index) }

            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            guard !inString else { continue }

            if character == "{" {
                // Une nouvelle ouverture pendant qu'on capture : le bloc courant
                // n'est pas le plus interne, on repart de celle-ci.
                if start != nil { containsNested = true }
                start = index
                containsNested = false
            } else if character == "}", let opened = start {
                if !containsNested {
                    objects.append(repaired(String(text[opened...index])))
                }
                start = nil
                containsNested = false
            }
        }
        return objects
    }
}
