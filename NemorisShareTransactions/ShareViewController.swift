//
//  ShareViewController.swift
//  NemorisShareTransactions
//
//  AXE P (2026-07-22) — share extension « Transactions » : activée quand
//  l'utilisateur partage un fichier CSV/TSV (relevé bancaire). Dépose le fichier
//  dans la boîte de réception App Group et informe l'utilisateur. AUCUN import
//  silencieux : Nemoris ouvre l'import V3 pré-rempli à sa prochaine ouverture
//  (une extension de partage ne PEUT PAS lancer son app conteneur — restriction
//  Apple, pas un choix).
//
//  ⚠️ `ShareInboxWriter` est un MIROIR de l'écriture de
//  `Nemoris/Services/PendingImportInbox.swift` (même convention que les modèles
//  mirrorés du widget) — garder clés / nom de dossier / format synchronisés.
//

import UIKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Configuration de CETTE extension

private enum ShareConfig {
    /// Clé App Group relue par l'app (= `PendingImportInbox.Kind.transactions`).
    static let pendingPathKey = "nemoris.pendingTransactionImportPath"
    /// Types acceptés, par ordre de préférence de chargement. L'activation est
    /// déjà filtrée par le prédicat de l'Info.plist (CSV/TSV uniquement) ;
    /// plainText/data ne servent que de replis de LECTURE pour des providers
    /// qui déclarent le CSV sous un type générique.
    static let acceptedTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText, .plainText, .data]
    static let fallbackExtension = "csv"
    static let processingText = "Réception du relevé…"
    static let doneTitle = "Relevé transmis à Nemoris"
    static let doneMessage = "Ouvrez Nemoris pour choisir le compte, mapper les colonnes et valider l'import. Rien n'est enregistré sans votre relecture."
}

// MARK: - Principal class (référencée par NSExtensionPrincipalClass)

final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let root = ShareSheetView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        model.process(extensionContext: extensionContext)
    }
}

// MARK: - Modèle (état + traitement de l'attachment)

final class ShareModel: ObservableObject {
    enum State {
        case processing
        /// Nombre de fichiers effectivement déposés.
        case done(Int)
        case failed(String)
    }

    @Published var state: State = .processing

    func process(extensionContext: NSExtensionContext?) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        // TOUTES les pièces jointes compatibles, pas seulement la première :
        // iOS autorise le partage multiple (plusieurs relevés d'un coup) et les
        // suivantes étaient silencieusement ignorées.
        let matches: [(provider: NSItemProvider, type: UTType)] = providers.compactMap { provider in
            guard let type = ShareConfig.acceptedTypes.first(where: {
                provider.hasItemConformingToTypeIdentifier($0.identifier)
            }) else { return nil }
            return (provider, type)
        }
        guard !matches.isEmpty else {
            state = .failed("Aucun fichier compatible dans le partage.")
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [(data: Data, fileExtension: String)] = []

        for match in matches {
            group.enter()
            Self.load(provider: match.provider, type: match.type) { result in
                if let result {
                    lock.lock()
                    loaded.append(result)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard !loaded.isEmpty else {
                self?.state = .failed("Impossible de lire le ou les fichiers partagés.")
                return
            }
            self?.finish(files: loaded)
        }
    }

    /// Charge une pièce jointe : représentation fichier d'abord (URL temporaire
    /// valide uniquement dans le handler → lecture immédiate), sinon données.
    private static func load(provider: NSItemProvider, type: UTType,
                             completion: @escaping ((data: Data, fileExtension: String)?) -> Void) {
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
            if let url, let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.isEmpty
                    ? (type.preferredFilenameExtension ?? ShareConfig.fallbackExtension)
                    : url.pathExtension
                completion((data, ext))
                return
            }
            // Repli : représentation data (ex. contenu partagé sans fichier).
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { completion(nil); return }
                completion((data, type.preferredFilenameExtension ?? ShareConfig.fallbackExtension))
            }
        }
    }

    private func finish(files: [(data: Data, fileExtension: String)]) {
        if ShareInboxWriter.stash(files: files) {
            state = .done(files.count)
        } else {
            state = .failed("Impossible d'enregistrer le fichier (conteneur partagé inaccessible).")
        }
    }
}

// MARK: - UI

struct ShareSheetView: View {
    @ObservedObject var model: ShareModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            switch model.state {
            case .processing:
                ProgressView()
                    .controlSize(.large)
                Text(ShareConfig.processingText)
                    .font(.headline)
            case .done(let count):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text(count > 1 ? "\(count) fichiers transmis à Nemoris" : ShareConfig.doneTitle)
                    .font(.headline)
                Text(ShareConfig.doneMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
                Text("Partage impossible")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button(action: onClose) {
                Text(buttonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isProcessing)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }

    private var isProcessing: Bool {
        if case .processing = model.state { return true }
        return false
    }

    private var buttonTitle: String {
        if case .failed = model.state { return "Fermer" }
        return "OK"
    }
}

// MARK: - Écriture dans la boîte de réception App Group

/// Devine l'extension réelle à partir des OCTETS du fichier.
///
/// ⚠️ Indispensable : le type retenu ici est souvent le type ABSTRAIT
/// `public.image` (ou `public.data`), dont `preferredFilenameExtension` vaut
/// **nil** — le fichier atterrissait donc en `.dat` dans la boîte de réception.
/// Côté app, un `.dat` ne ressemble ni à un PDF ni à une image : il partait
/// dans la branche « texte brut », où le décodage Latin-1 (qui n'échoue jamais)
/// transformait le PNG en centaines de milliers de caractères binaires. Le
/// document semblait analysé et l'écran affichait « Rien à importer ».
enum ShareDataSniffer {
    static func fileExtension(for data: Data) -> String? {
        let magic = [UInt8](data.prefix(12))
        func starts(_ bytes: [UInt8]) -> Bool {
            guard magic.count >= bytes.count else { return false }
            return Array(magic.prefix(bytes.count)) == bytes
        }
        if starts([0x25, 0x50, 0x44, 0x46]) { return "pdf" }
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
        return nil
    }
}

/// ⚠️ MIROIR de `PendingImportInbox` (app) — ne modifier qu'en gardant les deux
/// implémentations synchronisées (appGroupID, dossier, clé, purge 24 h).
enum ShareInboxWriter {
    static let appGroupID = "group.fr.hedwin.nemoris"
    private static let folderName = "PendingImports"
    private static let maxAge: TimeInterval = 24 * 3600

    static func stash(files: [(data: Data, fileExtension: String)]) -> Bool {
        guard !files.isEmpty else { return false }
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return false }
        let dir = container.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        purgeStale(in: dir)

        guard let defaults = UserDefaults(suiteName: appGroupID) else { return false }
        // Sémantique d'AJOUT : deux partages successifs avant le retour dans
        // l'app s'accumulent au lieu que le second écrase le premier (le
        // fichier écrasé restait sur disque sans que rien ne pointe dessus).
        var paths = storedPaths(defaults: defaults)

        for file in files {
            // Les octets font foi : une extension issue d'un type abstrait
            // (public.image / public.data) est inexploitable côté app.
            let sniffed = ShareDataSniffer.fileExtension(for: file.data)
            let declared = file.fileExtension.lowercased()
            let ext = sniffed ?? (declared.isEmpty || declared == "dat" ? "txt" : declared)
            let fileURL = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            do {
                try file.data.write(to: fileURL, options: .atomic)
                paths.append(fileURL.path)
            } catch {
                continue
            }
        }
        guard !paths.isEmpty,
              let encoded = try? JSONEncoder().encode(paths),
              let json = String(data: encoded, encoding: .utf8) else { return false }
        defaults.set(json, forKey: ShareConfig.pendingPathKey)
        return true
    }

    /// Lecture tolérante : tableau JSON (format courant) ou chemin brut (clé
    /// posée par une version antérieure de l'extension, jamais consommée).
    private static func storedPaths(defaults: UserDefaults) -> [String] {
        guard let raw = defaults.string(forKey: ShareConfig.pendingPathKey), !raw.isEmpty else { return [] }
        if let data = raw.data(using: .utf8),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            return list
        }
        return [raw]
    }

    private static func purgeStale(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-maxAge)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
