import Foundation

/// Repairing JSON produced by a language model.
///
/// PURE engine — covered by `run_import_pipeline_tests.sh`.
///
/// ─── Why this exists ────────────────────────────────────────────────────────
///
/// A model generating free-form JSON formats it, and its formatting
/// can break a string in the middle:
///
/// ```
///     "payment_
///         type": "CB"
/// ```
///
/// This is **invalid** JSON — the spec forbids a raw control character
/// inside a string. `JSONDecoder` throws, and **the whole document is
/// lost**: a real case where eight perfectly extracted operations produced
/// "no transaction to import".
///
/// ⚠️ FORMATTING repair only. We never guess a value, we never
/// close a brace: if the model invented or omitted data, it
/// stays invented or omitted. Stitching a string broken by a line
/// break back together doesn't change its meaning, that's the only thing we allow ourselves.
enum LenientJSON {

    /// Stitches strings broken by a line break back together.
    ///
    /// ⚠️ How they're stitched DEPENDS on the string's role:
    ///   • a KEY is stitched with nothing in between (`"payment_\n  type"` →
    ///     `"payment_type"`), since the break is purely typographical;
    ///   • a VALUE is stitched with a space (`"CARREFOUR\n  CITY"` →
    ///     `"CARREFOUR CITY"`), because it's a label whose words were
    ///     split by the line break.
    /// Treating both the same breaks one or the other.
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

            // Start of a string: capture it whole to decide later.
            var literal = ""
            var cursor = raw.index(after: index)
            var closed = false
            while cursor < raw.endIndex {
                let inner = raw[cursor]
                if inner == "\\" {
                    // Escape sequence: both characters pass through as-is.
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
                // String never closed: return the rest as-is, the
                // decoder will report the error — better than a repair that
                // would invent an ending.
                output.append(contentsOf: raw[index...])
                break
            }

            // The string's role: followed by `:` (after optional whitespace) = a key.
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

    /// Replaces every line break (and the indentation following it) with
    /// `joiner`. Other control characters are stripped: they too
    /// are forbidden inside a JSON string.
    private static func collapseBreaks(in literal: String, joiner: String) -> String {
        guard literal.contains(where: { $0.isNewline || $0 == "\t" }) else { return literal }
        var result = ""
        var index = literal.startIndex
        while index < literal.endIndex {
            let character = literal[index]
            if character.isNewline || character == "\t" {
                // Absorbs the break AND the indentation that follows, otherwise
                // we'd stitch "payment_        type".
                while index < literal.endIndex,
                      literal[index].isNewline || literal[index] == "\t" || literal[index] == " " {
                    index = literal.index(after: index)
                }
                // No joiner at the end of a string: "CARREFOUR\n" must not
                // become "CARREFOUR".
                if index < literal.endIndex, !result.isEmpty { result += joiner }
                continue
            }
            result.append(character)
            index = literal.index(after: index)
        }
        return result
    }

    /// Isolates the JSON object in a response (models are happy to
    /// surround it with text or code fences) then repairs it.
    static func extractObject(from raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[start...end])
        }
        return repaired(repairSyntax(cleaned))
    }

    // MARK: - Lexical repairs

    /// Fixes the most common PUNCTUATION mistakes made by models.
    ///
    /// Each one comes from a real case:
    ///   • `"amount": -6.98,\n}` — trailing comma, forbidden in JSON;
    ///   • `, amount": -6.00` — missing opening quote on a key;
    ///   • `,,` — duplicated comma.
    ///
    /// ⚠️ PUNCTUATION ONLY. We never fill in a value, we never close
    /// a structure: a truncated response must remain a visible error.
    static func repairSyntax(_ raw: String) -> String {
        var text = raw

        // Missing opening quote on a key: `, amount":` → `, "amount":`.
        // Deliberately narrow pattern (a bare identifier followed by `":`), so as
        // not to touch string contents.
        text = replacing(text,
                         pattern: #"([,{])(\s*)([A-Za-z_][A-Za-z0-9_]*)"(\s*):"#,
                         template: "$1$2\"$3\"$4:")

        // FR comma as a decimal separator in a number: `"amount":-19,50`
        // isn't valid JSON (`,` there separates two fields, never two
        // halves of a number) — a model used to writing in French
        // slips into this despite the "decimal point" instruction. Pattern anchored
        // RIGHT AFTER `:` (never after a quote/apostrophe), which
        // excludes by construction anything inside a string
        // — a text value always starts with `"`, never with a
        // digit. The lookahead on `,`/`}`/`]` guarantees we stop at the
        // REAL next field separator instead of consuming it.
        text = replacing(text,
                         pattern: #"(\s*-?\d+),(\d+)(?=\s*[,}\]])"#,
                         template: "$1.$2")

        // Duplicated commas, then a trailing comma before a closing bracket.
        text = replacing(text, pattern: #",(\s*),"#, template: ",$1")
        text = replacing(text, pattern: #",(\s*)([}\]])"#, template: "$1$2")

        // Keys with NO quotes at all: `, effort:2` → `, "effort":2`.
        //
        // ⚠️ Distinct from this function's entry pattern, which only catches
        // a missing OPENING quote (`, amount":`). A model commonly
        // produces an object where some keys are correctly
        // quoted and some aren't at all — seen in production: `"annual_impact":0,
        // effort:2, confidence:0.92`. Handled by a scanner rather than a
        // regex, because a `word:` inside a French sentence ("Bilan: …")
        // is common in text values and must never be
        // rewritten.
        return quotingBareKeys(text)
    }

    /// Adds missing quotes around bare object keys, while
    /// ignoring anything inside a string.
    static func quotingBareKeys(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)
        var inString = false
        var escaped = false
        /// True when the current position can hold a KEY: right
        /// after `{` or `,`. That's what keeps a value from being touched.
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

            // A bare identifier in a key position, followed by `:`.
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
                // Not a key (`true`, `null`, a number…): copy it as-is.
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

    // MARK: - Splitting object by object

    /// The most DEEPLY NESTED (innermost) JSON objects in a response, each
    /// repaired separately.
    ///
    /// ─── Why decode object by object ────────────────────────────────────────
    ///
    /// Requiring the WHOLE document to be valid means losing eight
    /// perfectly extracted operations because the model left an extra comma
    /// on the third one. Observed twice in a row, with two
    /// different mistakes: patching each new mistake case by case is a race
    /// already lost.
    ///
    /// By decoding each object independently, one syntax mistake costs ONE
    /// line instead of the whole batch. That's the behavior we want:
    /// graceful degradation, not all-or-nothing.
    ///
    /// "Innermost" = with no nested brace. Our operation and order
    /// schemas are flat, so these are exactly the objects to decode; the
    /// container (`{"transactions": [...]}`) is ignored, which makes
    /// extraction indifferent to its shape.
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
                // A new opening while we're capturing: the current block
                // isn't the innermost, start over from this one.
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
