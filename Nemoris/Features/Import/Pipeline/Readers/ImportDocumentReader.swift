import Foundation
import PDFKit
import CoreGraphics

/// Un document à analyser, déjà chargé en mémoire. Le nom sert à tracer
/// l'origine de chaque ligne quand un import agrège plusieurs fichiers.
struct ImportDocumentSource: Sendable {
    let data: Data
    let displayName: String

    init(data: Data, displayName: String) {
        self.data = data
        self.displayName = displayName
    }

    var fileExtension: String { (displayName as NSString).pathExtension }
}

/// Découpage d'un document en UNITÉS analysables, partagé par les deux imports.
///
/// Le type réel est sniffé sur les octets (jamais l'extension), puis :
///   • un PDF donne une unité par page,
///   • une image donne une unité — l'image elle-même si un modèle sait la lire,
///     son OCR sinon,
///   • un texte long est découpé en blocs qui tiennent dans la fenêtre de
///     contexte du modèle,
///   • un classeur donne une table par feuille,
///   • un relevé CAMT/OFX donne directement des enregistrements structurés.
///
/// Mutualisé parce que strictement identique des deux côtés — seule
/// l'interprétation diffère ensuite (opérations bancaires contre ordres de
/// bourse).
enum ImportDocumentReader {

    /// Contenu d'une unité.
    ///
    /// ⚠️ Une énumération et non un agrégat de champs optionnels : les quatre
    /// formes sont mutuellement exclusives, et un `struct` à quatre optionnels
    /// laisse le compilateur indifférent à un appelant qui oublie d'en traiter
    /// une. Ici, ajouter un format CASSE tous les `switch` — ce qu'on veut.
    enum Content {
        /// Texte à interpréter (page PDF, OCR, bloc).
        case text(String)
        /// L'image elle-même, pour un modèle multimodal.
        ///
        /// ⚠️ Passer l'image plutôt que son OCR est un changement de nature,
        /// pas une optimisation : la mise en page (colonnes, en-têtes de
        /// journée, sous-titres de catégorie) porte du sens que
        /// l'aplatissement en texte détruit — et qu'aucune heuristique d'ordre
        /// de lignes ne reconstitue de façon générale, puisqu'elle diffère
        /// d'une appli bancaire à l'autre.
        case image(CGImage)
        /// Table à mapper (CSV, feuille de classeur) : la structure est là,
        /// mais la SÉMANTIQUE des colonnes demande l'utilisateur.
        case grid(ImportGrid)
        /// Enregistrements déjà structurés ET nommés (CAMT.053, OFX) : ni
        /// modèle, ni mapping — les champs sont désignés par le format.
        case records([ImportPayload])
        /// Rien d'exploitable, avec la raison.
        case empty(ImportUnitDiagnostic)
    }

    struct Unit {
        var content: Content
        var kind: ImportSourceKind
        /// Rang de l'unité dans son fichier (1-indexé) : n° de page, rang de
        /// feuille, index de bloc.
        var indexInSource: Int = 1
        /// Texte source d'une table, conservé pour un éventuel re-parsing avec
        /// un autre séparateur.
        ///
        /// ⚠️ Porté PAR L'UNITÉ parce qu'il est décodé ici, hors du main actor.
        /// Le redécoder plus tard depuis `source.data` — ce que faisait
        /// `ImportPipeline.read` — refaisait le travail une seconde fois, ET
        /// sur le thread principal : sur un gros CSV, un gel visible.
        var sourceText: String?

        /// Raccourci de lecture — vide pour les formes non textuelles.
        var text: String {
            if case .text(let value) = content { return value }
            return ""
        }

        var image: CGImage? {
            if case .image(let value) = content { return value }
            return nil
        }
    }

    // MARK: - Point d'entrée

    /// ⚠️ Tout le travail lourd (ouverture PDF, OCR Vision, inflate ZIP) tourne
    /// en `Task.detached` : ces appels sont SYNCHRONES et coûteux, les laisser
    /// sur le main actor fige l'app et la barre de progression ne se peint
    /// jamais.
    ///
    /// `feature` : la fonctionnalité au nom de laquelle on lit.
    ///
    /// ⚠️ Elle décide si une capture est passée TELLE QUELLE au modèle ou
    /// océrisée : le backend est choisi par fonctionnalité, donc l'import de
    /// relevés peut lire les images (serveur local multimodal) pendant que
    /// l'import de portefeuille en est réduit à l'OCR, ou l'inverse. Poser la
    /// question globalement donnerait la mauvaise réponse à l'un des deux.
    ///
    /// `allowsImagePassthrough` : à `false`, une capture est toujours océrisée
    /// même si un modèle multimodal existe. Utile pour les formats dont on veut
    /// l'extraction déterministe (le moteur d'ancrage a besoin de texte).
    static func units(for source: ImportDocumentSource,
                      feature: AIFeature,
                      allowsImagePassthrough: Bool = true) async -> [Unit] {
        let data = source.data
        let kind = ImportFormatSniffer.detect(data: data, fileExtension: source.fileExtension)

        switch kind {
        case .pdf:         return await pdfUnits(data)
        case .image:       return await imageUnits(data, feature: feature,
                                                   allowsPassthrough: allowsImagePassthrough)
        case .text:        return textUnits(data)
        case .spreadsheet: return await spreadsheetUnits(data)
        case .xml:         return await structuredUnits(data)
        case .unknown:     return [Unit(content: .empty(.notTextContent), kind: .unknown)]
        }
    }

    // MARK: - PDF

    private static func pdfUnits(_ data: Data) async -> [Unit] {
        let pages: [String] = await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(data: data) else { return [] }
            return (0..<document.pageCount).compactMap { index in
                guard let text = document.page(at: index)?.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return text
            }
        }.value
        guard !pages.isEmpty else {
            return [Unit(content: .empty(.noTextExtracted), kind: .pdf)]
        }
        return pages.enumerated().map { index, text in
            Unit(content: .text(text), kind: .pdf, indexInSource: index + 1)
        }
    }

    // MARK: - Image

    private static func imageUnits(_ data: Data, feature: AIFeature,
                                   allowsPassthrough: Bool) async -> [Unit] {
        if allowsPassthrough, await AIEnrichmentBackend.supportsImageInput(for: feature),
           let cgImage = await Task.detached(priority: .userInitiated, operation: {
               InvestmentPDFParser.decodeImage(from: data)
           }).value {
            return [Unit(content: .image(cgImage), kind: .image)]
        }
        let text = await Task.detached(priority: .userInitiated) {
            InvestmentPDFParser.ocrText(from: data)
        }.value ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [Unit(content: .empty(.noTextExtracted), kind: .image)]
        }
        return [Unit(content: .text(text), kind: .image)]
    }

    // MARK: - Texte

    private static func textUnits(_ data: Data) -> [Unit] {
        guard let text = decodeText(data), !text.isEmpty else {
            return [Unit(content: .empty(.noTextExtracted), kind: .text)]
        }
        // Un texte réellement tabulaire part au mapping de colonnes ; le reste
        // (relevé en prose, export sans structure) part au parseur de documents.
        if let grid = CSVParserV3.parse(content: text), grid.isTabular {
            return [Unit(content: .grid(grid), kind: .text, sourceText: text)]
        }
        // La fenêtre de contexte du modèle embarqué est étroite : un relevé
        // entier envoyé d'un bloc la fait déborder et l'unité est perdue.
        let chunks = InvestmentPDFParser.splitTextIntoChunks(text, maxChars: 4000)
        return chunks.enumerated().map { index, chunk in
            Unit(content: .text(chunk), kind: .text, indexInSource: index + 1)
        }
    }

    // MARK: - Classeur

    private static func spreadsheetUnits(_ data: Data) async -> [Unit] {
        let sheets = await Task.detached(priority: .userInitiated) {
            XLSXReader.grids(from: data)
        }.value
        switch sheets {
        case .success(let grids) where !grids.isEmpty:
            return grids.enumerated().map { index, grid in
                Unit(content: .grid(grid), kind: .spreadsheet, indexInSource: index + 1)
            }
        case .success:
            return [Unit(content: .empty(.malformedStructure("le classeur ne contient aucune feuille exploitable")),
                         kind: .spreadsheet)]
        case .failure(let error):
            return [Unit(content: .empty(.malformedStructure(error.reason)), kind: .spreadsheet)]
        }
    }

    // MARK: - Relevé structuré (CAMT.053 / OFX)

    private static func structuredUnits(_ data: Data) async -> [Unit] {
        let parsed = await Task.detached(priority: .userInitiated) {
            LedgerXMLReader.parse(data: data)
        }.value
        switch parsed {
        case .success(let payloads) where !payloads.isEmpty:
            return [Unit(content: .records(payloads), kind: .xml)]
        case .success:
            return [Unit(content: .empty(.nothingRecognized), kind: .xml)]
        case .failure(let error):
            return [Unit(content: .empty(.malformedStructure(error.reason)), kind: .xml)]
        }
    }

    // MARK: - Décodage texte

    /// Façade vers le décodage du sniffer — qui est PUR, donc couvert par le
    /// harnais, alors que ce lecteur dépend de PDFKit et de Vision.
    static func decodeText(_ data: Data) -> String? {
        ImportFormatSniffer.decodeText(data)
    }
}
