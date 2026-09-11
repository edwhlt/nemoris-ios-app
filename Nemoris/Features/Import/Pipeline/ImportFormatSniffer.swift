import Foundation

// MARK: - Identifying the format from the BYTES
//
// PURE engine — covered by `ImportPipelineTests`.
//
// CARDINAL RULE: the format is NEVER inferred from the extension.
//
// Two facts behind this rule:
//   1. A capture shared through the share sheet arrives named `<uuid>.dat` —
//      the abstract `public.image` type has no `preferredFilenameExtension`.
//   2. `String(contentsOf:encoding:.isoLatin1)` NEVER fails: any byte sequence
//      is valid Latin-1. A "decoded" PNG gives hundreds of thousands of
//      binary characters, which would be sent to the model as if it were a
//      statement.
//
// The extension is therefore ONLY a last resort, when the bytes say nothing
// (empty file, exotic format).

enum ImportFormatSniffer {

    // MARK: - Entry point

    /// Actual nature of a content. `fileExtension` is only consulted as a last
    /// resort.
    static func detect(data: Data, fileExtension: String = "") -> ImportSourceKind {
        if let binary = binaryKind(data) { return binary }
        if looksLikeText(data) {
            return textualKind(data)
        }
        return fallbackFromExtension(fileExtension)
    }

    /// File extension inferred from the bytes, or `nil` if the format isn't
    /// recognized. Used by the inbox (share, Shortcuts) to name the dropped file
    /// correctly.
    static func fileExtension(for data: Data) -> String? {
        switch detect(data: data) {
        case .pdf:         return "pdf"
        case .spreadsheet: return "xlsx"
        case .xml:         return isOFX(data) ? "ofx" : "xml"
        case .image:       return imageExtension(data)
        case .text:        return "txt"
        case .unknown:     return nil
        }
    }

    // MARK: - Formats binaires

    /// Formats recognizable by their signature. `nil` if the bytes match no known
    /// binary format.
    private static func binaryKind(_ data: Data) -> ImportSourceKind? {
        let magic = [UInt8](data.prefix(12))

        func starts(_ bytes: [UInt8]) -> Bool {
            guard magic.count >= bytes.count else { return false }
            return Array(magic.prefix(bytes.count)) == bytes
        }

        if starts([0x25, 0x50, 0x44, 0x46]) { return .pdf }                     // %PDF
        if starts([0x89, 0x50, 0x4E, 0x47]) { return .image }                   // PNG
        if starts([0xFF, 0xD8, 0xFF])       { return .image }                   // JPEG
        if starts([0x47, 0x49, 0x46, 0x38]) { return .image }                   // GIF8
        if starts([0x42, 0x4D])             { return .image }                   // BM (BMP)
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return .image } // TIFF

        if magic.count >= 12 {
            // HEIC / HEIF / AVIF: the `ftyp` brand is at offset 4.
            if String(decoding: magic[4..<12], as: UTF8.self).hasPrefix("ftyp") { return .image }
            if starts([0x52, 0x49, 0x46, 0x46]),                                 // RIFF….WEBP
               String(decoding: magic[8..<12], as: UTF8.self) == "WEBP" { return .image }
        }

        // ZIP. An XLSX IS a ZIP archive: the signature alone can't tell it from any
        // .zip, its content must be looked at (see `looksLikeXLSX`).
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) {
            return looksLikeXLSX(data) ? .spreadsheet : .unknown
        }
        return nil
    }

    private static func imageExtension(_ data: Data) -> String {
        let magic = [UInt8](data.prefix(12))
        func starts(_ bytes: [UInt8]) -> Bool {
            guard magic.count >= bytes.count else { return false }
            return Array(magic.prefix(bytes.count)) == bytes
        }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF])       { return "jpg" }
        if starts([0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if starts([0x42, 0x4D])             { return "bmp" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if magic.count >= 12 {
            if String(decoding: magic[4..<12], as: UTF8.self).hasPrefix("ftyp") { return "heic" }
            if starts([0x52, 0x49, 0x46, 0x46]),
               String(decoding: magic[8..<12], as: UTF8.self) == "WEBP" { return "webp" }
        }
        return "png"
    }

    /// An XLSX workbook always declares `[Content_Types].xml` at the head of the
    /// archive, and stores its sheets under `xl/`. Entry names are stored IN
    /// CLEAR in the local headers, even when the data is compressed: they are
    /// readable without decompressing.
    static func looksLikeXLSX(_ data: Data) -> Bool {
        let head = data.prefix(4096)
        return contains(head, "[Content_Types].xml") || contains(head, "xl/workbook.xml")
    }

    // MARK: - Formats textuels

    /// Tells XML/OFX apart from ordinary tabular text.
    private static func textualKind(_ data: Data) -> ImportSourceKind {
        let head = data.prefix(2048)
        // OFX 1.x is NOT XML: it's SGML preceded by a plain-text `OFXHEADER:100`
        // header block. It's still classified as `.xml` — the reader handles both
        // dialects.
        if contains(head, "OFXHEADER") || contains(head, "<OFX>") || contains(head, "<OFX ") {
            return .xml
        }
        if contains(head, "<?xml") { return .xml }
        return .text
    }

    /// True if the bytes look like usable text.
    ///
    /// Tested on a sample: presence of NUL bytes (never in UTF-8 text) and the
    /// proportion of control characters. Essential precisely because no Latin-1
    /// decoding ever fails.
    ///
    /// UTF-16 is ruled out by the NUL test (ASCII text in UTF-16 has every other
    /// byte at zero) — on purpose here: binary sniffing comes first, and the
    /// reader's tolerant decoding handles UTF-16 afterwards.
    static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(2048)
        guard !sample.isEmpty else { return false }
        // UTF-16 is full of null bytes, which would get it rejected by the test
        // below. A UTF-16 BOM is an explicit declaration: it's text, period.
        // Without this case, a UTF-16 CSV shared without an extension would come
        // out as `.unknown` and couldn't be imported at all.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return true }
        if sample.contains(0x00) { return false }
        let control = sample.filter { byte in
            byte < 0x09 || (byte > 0x0D && byte < 0x20) || byte == 0x7F
        }.count
        return Double(control) / Double(sample.count) < 0.02
    }

    /// OFX/QFX dialect (as opposed to CAMT.053) — both are classified as `.xml`,
    /// only the reader separates them.
    static func isOFX(_ data: Data) -> Bool {
        let head = data.prefix(2048)
        return contains(head, "OFXHEADER") || contains(head, "<OFX>") || contains(head, "<OFX ")
    }

    // MARK: - Text decoding

    /// Tolerant decoding, in the order of the encodings met in practice on
    /// French bank statements.
    ///
    /// Call it only AFTER `detect`: `isoLatin1` NEVER fails (any byte sequence is
    /// valid), so calling it without having checked that the content IS text
    /// turns a PNG into hundreds of thousands of binary characters.
    static func decodeText(_ data: Data) -> String? {
        // THE BOM FIRST, AND BOTH ENDIANNESSES.
        //
        // Without it, a **big-endian** UTF-16 CSV would fall into the loop below,
        // where `.utf16LittleEndian` always "succeeds" — reading the bytes the wrong
        // way round. "date" (0x00 0x64 0x00 0x61…) becomes 搀愀: CJK ideographs. The
        // file would become unreadable, hence no longer tabular, hence routed to the
        // AI instead of the deterministic parser.
        //
        // A BOM is an explicit declaration of the encoding: it wins over any
        // heuristic.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }

        // Without a BOM: UTF-16 is recognized by its null bytes at regular
        // positions. On Western text, every other byte is null — the position (even
        // or odd) gives the endianness.
        if let utf16 = decodeUTF16WithoutBOM(data) { return utf16 }

        for encoding: String.Encoding in [.utf8, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// UTF-16 without a BOM, guessed from the position of the null bytes.
    ///
    /// Only tried if the text is massively made of them (> 30% nulls): an
    /// ordinary UTF-8 file contains none, so there's no risk of a false positive.
    private static func decodeUTF16WithoutBOM(_ data: Data) -> String? {
        let sample = Array(data.prefix(2048))
        guard sample.count >= 4 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (index, byte) in sample.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let total = Double(sample.count)
        // Nuls en position PAIRE ⇒ big-endian (l'octet de poids fort vient en
        // premier) ; en position impaire ⇒ little-endian.
        if Double(evenZeros) / total > 0.3, oddZeros == 0 {
            return String(data: data, encoding: .utf16BigEndian)
        }
        if Double(oddZeros) / total > 0.3, evenZeros == 0 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        return nil
    }

    // MARK: - Dernier recours

    private static func fallbackFromExtension(_ ext: String) -> ImportSourceKind {
        switch ext.lowercased() {
        case "pdf":                                  return .pdf
        case "jpg", "jpeg", "png", "heic", "heif",
             "tiff", "tif", "bmp", "webp", "gif":    return .image
        case "csv", "txt", "tsv":                    return .text
        case "xlsx", "xlsm":                         return .spreadsheet
        case "xml", "ofx", "qfx":                    return .xml
        default:                                     return .unknown
        }
    }

    // MARK: - Utilitaire

    /// Searches an ASCII string in bytes, without a full decoding (which would
    /// fail or be costly on binary).
    private static func contains<C: Collection>(_ haystack: C, _ needle: String) -> Bool
    where C.Element == UInt8 {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return true }
        let bytes = Array(haystack)
        guard bytes.count >= pattern.count else { return false }
        for start in 0...(bytes.count - pattern.count) {
            if Array(bytes[start..<(start + pattern.count)]) == pattern { return true }
        }
        return false
    }
}
