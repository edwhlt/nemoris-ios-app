import Foundation

// MARK: - Identification du format par les OCTETS
//
// Moteur PUR — testable via `run_import_pipeline_tests.sh`.
//
// ⚠️ RÈGLE CARDINALE : le format ne se déduit JAMAIS de l'extension.
//
// Deux bugs de production sont derrière cette règle :
//   1. Une capture partagée par la share sheet arrive nommée `<uuid>.dat` — le
//      type abstrait `public.image` n'a pas de `preferredFilenameExtension`.
//   2. `String(contentsOf:encoding:.isoLatin1)` n'échoue JAMAIS : toute suite
//      d'octets est du Latin-1 valide. Un PNG « décodé » donnait 670 000
//      caractères de binaire, envoyés au modèle comme s'il s'agissait d'un
//      relevé — d'où « 1 page analysée · Rien à importer ».
//
// L'extension ne sert donc QUE de dernier recours, quand les octets ne disent
// rien (fichier vide, format exotique).

enum ImportFormatSniffer {

    // MARK: - Point d'entrée

    /// Nature réelle d'un contenu. `fileExtension` n'est consulté qu'en dernier
    /// recours.
    static func detect(data: Data, fileExtension: String = "") -> ImportSourceKind {
        if let binary = binaryKind(data) { return binary }
        if looksLikeText(data) {
            return textualKind(data)
        }
        return fallbackFromExtension(fileExtension)
    }

    /// Extension de fichier déduite des octets, ou `nil` si le format n'est pas
    /// reconnu. Utilisée par la boîte de réception (partage, Raccourcis) pour
    /// nommer correctement le fichier déposé.
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

    /// Formats reconnaissables à leur signature. `nil` si les octets ne
    /// correspondent à aucun format binaire connu.
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
            // HEIC / HEIF / AVIF : la marque `ftyp` est à l'offset 4.
            if String(decoding: magic[4..<12], as: UTF8.self).hasPrefix("ftyp") { return .image }
            if starts([0x52, 0x49, 0x46, 0x46]),                                 // RIFF….WEBP
               String(decoding: magic[8..<12], as: UTF8.self) == "WEBP" { return .image }
        }

        // ZIP. Un XLSX EST une archive ZIP : la signature seule ne suffit pas à
        // le distinguer d'un .zip quelconque, il faut regarder ce qu'il y a
        // dedans (cf. `looksLikeXLSX`).
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

    /// Un classeur XLSX déclare toujours `[Content_Types].xml` en tête
    /// d'archive, et range ses feuilles sous `xl/`. Les noms d'entrée sont
    /// stockés EN CLAIR dans les en-têtes locaux, même quand les données sont
    /// compressées : ils sont donc lisibles sans décompresser.
    static func looksLikeXLSX(_ data: Data) -> Bool {
        let head = data.prefix(4096)
        return contains(head, "[Content_Types].xml") || contains(head, "xl/workbook.xml")
    }

    // MARK: - Formats textuels

    /// Distingue XML/OFX d'un texte tabulaire ordinaire.
    private static func textualKind(_ data: Data) -> ImportSourceKind {
        let head = data.prefix(2048)
        // OFX 1.x n'est PAS du XML : c'est du SGML précédé d'un bloc d'en-têtes
        // `OFXHEADER:100` en texte clair. On le range quand même en `.xml`,
        // c'est le lecteur qui gère les deux dialectes.
        if contains(head, "OFXHEADER") || contains(head, "<OFX>") || contains(head, "<OFX ") {
            return .xml
        }
        if contains(head, "<?xml") { return .xml }
        return .text
    }

    /// Vrai si les octets ressemblent à du texte exploitable.
    ///
    /// Test sur un échantillon : présence d'octets NUL (jamais dans du texte
    /// UTF-8) et proportion de caractères de contrôle. Indispensable
    /// précisément parce qu'aucun décodage Latin-1 n'échoue jamais.
    ///
    /// ⚠️ L'UTF-16 est écarté par le test NUL (un texte ASCII en UTF-16 est un
    /// octet sur deux à zéro) — c'est voulu ici : le sniffing binaire passe
    /// d'abord, et le décodage tolérant du lecteur gère l'UTF-16 ensuite.
    static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(2048)
        guard !sample.isEmpty else { return false }
        if sample.contains(0x00) { return false }
        let control = sample.filter { byte in
            byte < 0x09 || (byte > 0x0D && byte < 0x20) || byte == 0x7F
        }.count
        return Double(control) / Double(sample.count) < 0.02
    }

    /// Dialecte OFX/QFX (par opposition à CAMT.053) — les deux sont rangés en
    /// `.xml`, seul le lecteur les sépare.
    static func isOFX(_ data: Data) -> Bool {
        let head = data.prefix(2048)
        return contains(head, "OFXHEADER") || contains(head, "<OFX>") || contains(head, "<OFX ")
    }

    // MARK: - Décodage texte

    /// Décodage tolérant, dans l'ordre des encodages qu'on rencontre en pratique
    /// sur les relevés bancaires français.
    ///
    /// ⚠️ À n'appeler qu'APRÈS `detect` : `isoLatin1` n'échoue JAMAIS (toute
    /// suite d'octets en est valide), donc l'appeler sans avoir vérifié que le
    /// contenu EST du texte transforme un PNG en centaines de milliers de
    /// caractères de binaire — le bug qui a motivé tout ce sniffing.
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let text = String(data: data.dropFirst(3), encoding: .utf8) { return text }
        for encoding: String.Encoding in [.utf8, .utf16LittleEndian, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
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

    /// Recherche d'une chaîne ASCII dans des octets, sans passer par un
    /// décodage complet (qui échouerait ou coûterait cher sur du binaire).
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
