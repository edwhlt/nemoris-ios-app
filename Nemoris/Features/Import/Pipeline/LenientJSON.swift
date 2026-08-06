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
        return repaired(cleaned)
    }
}
