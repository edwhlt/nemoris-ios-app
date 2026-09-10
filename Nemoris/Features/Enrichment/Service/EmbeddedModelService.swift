import Foundation
import SwiftLlama
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Backend IA « modèle embarqué » — un modèle exécuté DANS l'app, sans
/// serveur externe ni Apple Intelligence. Deux formats : **GGUF** (via
/// `SwiftLlama`/llama.cpp, tourne sur tout appareil) et **MLX** (via
/// `mlx-swift-lm`, Apple Silicon seulement — plus rapide sur ce matériel).
///
/// Pas de marketplace, et pas limité à Hugging Face : coller un lien HF reste
/// un raccourci (GGUF uniquement, résolu via l'API HF), mais le chemin
/// principal est l'IMPORT d'un fichier `.gguf` ou d'un dossier MLX déjà
/// présent sur l'appareil (Fichiers/iCloud Drive/Mac) — n'importe quelle
/// source, aucune limite. Cf. `EmbeddedModelManager.importFile`/`importFolder`.
///
/// Stockage : `Application Support/LocalModels/` (pas `Caches` — l'OS peut
/// purger `Caches` sous pression de stockage, ce qui perdrait un téléchargement
/// de plusieurs centaines de Mo sans prévenir). Exclu de la sauvegarde iCloud
/// (`isExcludedFromBackup`) : regénérable depuis Hugging Face, ne doit pas
/// gonfler une sauvegarde device.
///
/// Visible automatiquement dans Réglages → Général → Stockage iPhone → Nemoris
/// (contenu du conteneur de l'app) — rien à coder de spécial pour ça.

// MARK: - Modèle téléchargé/importé (persisté dans manifest.json)

/// GGUF : un seul fichier. MLX : un dossier entier (poids `.safetensors` +
/// `config.json` + tokenizer) — deux moteurs d'inférence distincts derrière
/// `EmbeddedModelManager`, jamais mélangés.
enum EmbeddedModelFormat: String, Codable, Sendable {
    case gguf
    case mlx
}

struct EmbeddedModelInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    let format: EmbeddedModelFormat
    /// Provenance, INFORMATIVE seulement (jamais de logique dessus) — par ex.
    /// "Hugging Face — org/repo", "Importé — nom_du_fichier.gguf", "Importé —
    /// nom_du_dossier". Remplace un ancien champ `hfRepo` non optionnel qui
    /// supposait à tort que Hugging Face était la seule source possible.
    var sourceDescription: String
    /// Nom du fichier GGUF — ignoré si `format == .mlx` (le dossier entier
    /// EST le modèle, pas un fichier nommé dedans).
    let fileName: String
    var sizeBytes: Int64
    let downloadedAt: Date

    /// GGUF : chemin du fichier unique. MLX : le dossier du modèle lui-même.
    var modelPathURL: URL {
        let dir = EmbeddedModelManager.modelDirectory(id: id)
        return format == .gguf ? dir.appendingPathComponent(fileName) : dir
    }
}

private struct EmbeddedModelManifest: Codable {
    var models: [EmbeddedModelInfo] = []
}

// MARK: - Résultat de l'analyse d'un lien/repo

/// Un fichier `.gguf` précis, prêt à être téléchargé. Plusieurs candidats
/// possibles pour UN SEUL repo (plusieurs quantizations) — ce n'est pas un
/// catalogue suggéré, c'est la désambiguïsation de la ressource que
/// l'utilisateur a lui-même désignée.
struct EmbeddedModelCandidate: Identifiable, Hashable, Sendable {
    var id: String { sourceLabel + "/" + fileName }
    /// Provenance déjà formée pour l'affichage — "Hugging Face — org/repo"
    /// pour le raccourci HF, l'hôte nu pour tout autre lien direct.
    let sourceLabel: String
    let fileName: String
    let sizeBytes: Int64?
    let downloadURL: URL
}

/// Un fichier distant, avec sa taille si connue — brique commune à un repo
/// MLX (toujours plusieurs fichiers, contrairement à un GGUF).
struct EmbeddedRemoteFile: Hashable, Sendable {
    let fileName: String
    let url: URL
    let sizeBytes: Int64?
}

/// Un repo MLX entier (poids `.safetensors` + `config.json` + tokenizer),
/// prêt à être téléchargé EN UNE FOIS — un modèle MLX est TOUJOURS plusieurs
/// fichiers, jamais un seul comme un GGUF.
struct EmbeddedMLXRepoCandidate: Identifiable, Hashable, Sendable {
    var id: String { "mlx/" + repo }
    let repo: String
    let files: [EmbeddedRemoteFile]

    /// `nil` si la taille d'AU MOINS UN fichier est inconnue — on ne prétend
    /// pas à un total qu'on n'a pas réellement.
    var totalSizeBytes: Int64? {
        let sizes = files.map(\.sizeBytes)
        guard sizes.allSatisfy({ $0 != nil }) else { return nil }
        return sizes.compactMap { $0 }.reduce(0, +)
    }
}

/// Résultat de `analyze(_:)` — GGUF (un ou plusieurs fichiers candidats,
/// l'utilisateur choisit lequel) ou un repo MLX entier (un seul candidat, il
/// n'y a rien à désambiguïser : c'est le repo entier ou rien).
enum EmbeddedModelAnalysis: Sendable {
    case ggufFiles([EmbeddedModelCandidate])
    case mlxRepo(EmbeddedMLXRepoCandidate)
}

// MARK: - Erreurs

enum EmbeddedModelError: Error, LocalizedError, Sendable {
    case invalidInput
    case noModelFilesFound
    case mlxNotSupportedOnDevice
    case sizeUnknown
    case notConfigured
    case modelFileMissing
    case notAGGUFFile
    case notAnMLXFolder
    case networkError(String)
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "Lien ou repo Hugging Face invalide (attendu : « owner/repo » ou un lien vers un fichier .gguf)."
        case .noModelFilesFound:
            return "Aucun modèle GGUF ou MLX reconnu dans ce repo."
        case .mlxNotSupportedOnDevice:
            return "Ce repo est un modèle MLX — non supporté sur cet appareil (nécessite Apple Silicon)."
        case .sizeUnknown:
            return "Impossible de déterminer la taille du fichier."
        case .notConfigured:
            return "Aucun modèle embarqué actif."
        case .modelFileMissing:
            return "Le fichier du modèle actif est introuvable sur le disque — retélécharge-le."
        case .notAGGUFFile:
            return "Le fichier choisi n'est pas un .gguf."
        case .notAnMLXFolder:
            return "Ce dossier ne contient pas de config.json — ce n'est pas un modèle MLX valide."
        case .networkError(let detail):
            return "Téléchargement impossible. (\(detail))"
        case .generationFailed(let detail):
            return "Le modèle embarqué n'a pas pu générer de réponse. (\(detail))"
        }
    }
}

// MARK: - Gestionnaire : manifeste, téléchargement, modèle chargé

actor EmbeddedModelManager {
    static let shared = EmbeddedModelManager()

    private var manifest = EmbeddedModelManifest()
    private var manifestLoaded = false

    // Le modèle GGUF chargé en mémoire. Un seul à la fois — le charger est
    // coûteux, et `LlamaService` fige son fichier à l'init (pas de mutation en
    // place pour changer de modèle).
    private var loadedService: LlamaService?
    private var loadedModelID: String?

    // Le conteneur MLX chargé — équivalent MLX de `loadedService`. Un seul
    // format actif à la fois (GGUF OU MLX), mais gardés dans des slots
    // distincts plutôt qu'un type "either" : la logique de chargement des
    // deux moteurs ne se ressemble pas assez pour partager une abstraction.
    private var loadedMLXContainer: ModelContainer?
    private var loadedMLXModelID: String?

    private static let activeModelIDKey = "ai.embeddedModel.activeID"

    // MARK: Chemins

    nonisolated static var rootDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("LocalModels", isDirectory: true)
    }

    nonisolated static func modelDirectory(id: String) -> URL {
        rootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    private static var manifestURL: URL { rootDirectory.appendingPathComponent("manifest.json") }

    /// Pointeur vers le modèle actif — `UserDefaults.standard`, comme
    /// `LocalLLMService.baseURL` : propre à l'appareil, jamais synchronisé.
    static var activeModelID: String? {
        get { UserDefaults.standard.string(forKey: activeModelIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeModelIDKey) }
    }

    static var hasConfiguration: Bool { activeModelID != nil }

    /// MLX exige de l'Apple Silicon réel. Sur plateformes Apple, `mlx-swift`
    /// compile TOUJOURS avec Metal (pas de repli CPU comme sur Linux) — il
    /// n'y a donc pas de "MLX.isAvailable" à interroger au runtime, la vraie
    /// question est l'architecture, pas une capacité du framework. Le
    /// Simulator est exclu : Metal n'y est pas fiable pour du calcul lourd
    /// (même convention que l'offload GPU GGUF ci-dessous).
    static var mlxSupported: Bool {
        #if arch(arm64) && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    // MARK: Manifeste

    private func ensureManifestLoaded() {
        guard !manifestLoaded else { return }
        manifestLoaded = true
        guard let data = try? Data(contentsOf: Self.manifestURL),
              let decoded = try? JSONDecoder().decode(EmbeddedModelManifest.self, from: data) else { return }
        manifest = decoded
    }

    private func saveManifest() {
        try? FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: Self.manifestURL, options: .atomic)
    }

    func downloadedModels() -> [EmbeddedModelInfo] {
        ensureManifestLoaded()
        return manifest.models.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    // MARK: Analyse d'un lien / repo Hugging Face

    /// Accepte un lien direct vers un `.gguf` sur N'IMPORTE QUEL hôte (pas
    /// seulement Hugging Face) ou un `owner/repo` HF nu. Pour un repo, l'API
    /// Hugging Face liste ses fichiers, et le FORMAT est détecté depuis leur
    /// contenu — sans champ à cocher : présence de `.gguf` → fichiers GGUF au
    /// choix (une quantization par fichier, en général) ; sinon présence de
    /// `config.json` + poids `.safetensors` → repo MLX entier (un modèle MLX
    /// est toujours plusieurs fichiers, il n'y a rien à désambiguïser). Le
    /// raccourci `owner/repo` reste une convenance propre à HF ; le lien
    /// direct, lui, n'a jamais été limité à un hôte en particulier après
    /// cette généralisation.
    func analyze(_ input: String) async throws -> EmbeddedModelAnalysis {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddedModelError.invalidInput }

        if let direct = Self.parseDirectFileURL(trimmed) {
            let size = try? await Self.remoteFileSize(direct.url)
            return .ggufFiles([EmbeddedModelCandidate(sourceLabel: direct.sourceLabel, fileName: direct.fileName,
                                                       sizeBytes: size, downloadURL: direct.url)])
        }

        let repo = Self.normalizedRepoID(trimmed)
        guard Self.isPlausibleRepoID(repo) else { throw EmbeddedModelError.invalidInput }

        let siblings = try await Self.fetchRepoFileNames(repo)

        let ggufFiles = siblings.filter { $0.lowercased().hasSuffix(".gguf") }.sorted()
        if !ggufFiles.isEmpty {
            var candidates: [EmbeddedModelCandidate] = []
            for file in ggufFiles {
                guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)") else { continue }
                let size = try? await Self.remoteFileSize(url)
                candidates.append(EmbeddedModelCandidate(sourceLabel: "Hugging Face — \(repo)", fileName: file, sizeBytes: size, downloadURL: url))
            }
            return .ggufFiles(candidates)
        }

        // Pas de GGUF : est-ce un repo MLX ? Mêmes motifs de fichiers que
        // mlx-swift-lm utilise pour son PROPRE téléchargeur interne (poids +
        // config + tokenizer) — `*.safetensors` + `*.json` + `*.jinja`.
        let hasConfig = siblings.contains { $0.lowercased() == "config.json" }
        let mlxFiles = siblings.filter { name in
            let lower = name.lowercased()
            return lower.hasSuffix(".safetensors") || lower.hasSuffix(".json") || lower.hasSuffix(".jinja")
        }.sorted()
        guard hasConfig, !mlxFiles.isEmpty else { throw EmbeddedModelError.noModelFilesFound }
        guard Self.mlxSupported else { throw EmbeddedModelError.mlxNotSupportedOnDevice }

        var remoteFiles: [EmbeddedRemoteFile] = []
        for file in mlxFiles {
            guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)") else { continue }
            let size = try? await Self.remoteFileSize(url)
            remoteFiles.append(EmbeddedRemoteFile(fileName: file, url: url, sizeBytes: size))
        }
        return .mlxRepo(EmbeddedMLXRepoCandidate(repo: repo, files: remoteFiles))
    }

    private static func fetchRepoFileNames(_ repo: String) async throws -> [String] {
        guard let apiURL = URL(string: "https://huggingface.co/api/models/\(repo)") else {
            throw EmbeddedModelError.invalidInput
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: apiURL)
        } catch {
            throw EmbeddedModelError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw EmbeddedModelError.networkError("Repo introuvable sur Hugging Face.")
        }
        struct Sibling: Decodable { let rfilename: String }
        struct ModelInfo: Decodable { let siblings: [Sibling] }
        guard let info = try? JSONDecoder().decode(ModelInfo.self, from: data) else {
            throw EmbeddedModelError.networkError("Réponse Hugging Face illisible.")
        }
        return info.siblings.map(\.rfilename)
    }

    private static func remoteFileSize(_ url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EmbeddedModelError.sizeUnknown
        }
        guard let http = response as? HTTPURLResponse else { throw EmbeddedModelError.sizeUnknown }
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
            ?? (http.expectedContentLength > 0 ? http.expectedContentLength : nil)
        guard let length else { throw EmbeddedModelError.sizeUnknown }
        return length
    }

    /// Lien direct vers un `.gguf`, N'IMPORTE QUEL hôte (GitHub Releases, un
    /// serveur perso, etc. — pas seulement Hugging Face). La forme HF
    /// (`…/resolve/<rev>/xxx.gguf`) est reconnue spécifiquement pour en tirer
    /// un libellé "Hugging Face — org/repo" ; tout autre hôte retombe sur un
    /// libellé générique basé sur son nom.
    private static func parseDirectFileURL(_ input: String) -> (url: URL, sourceLabel: String, fileName: String)? {
        guard let url = URL(string: input), let host = url.host,
              url.pathExtension.lowercased() == "gguf" else { return nil }
        let fileName = url.lastPathComponent

        if host.contains("huggingface.co") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let resolveIdx = parts.firstIndex(of: "resolve"), resolveIdx >= 2 {
                let repo = parts[0...(resolveIdx - 1)].joined(separator: "/")
                return (url, "Hugging Face — \(repo)", fileName)
            }
        }
        return (url, host, fileName)
    }

    private static func normalizedRepoID(_ input: String) -> String {
        if let url = URL(string: input), let host = url.host, host.contains("huggingface.co") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 { return "\(parts[0])/\(parts[1])" }
        }
        return input
    }

    private static func isPlausibleRepoID(_ s: String) -> Bool {
        let parts = s.split(separator: "/")
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
    }

    // MARK: Garde-fou RAM / stockage — INFORMATIF, jamais bloquant

    /// `nil` si rien à signaler. Le tap de confirmation reste toujours possible
    /// même avec un avertissement — l'utilisateur décide, l'app prévient.
    /// Limite jetsam ESTIMÉE d'un appareil — Apple ne publie AUCUN chiffre
    /// officiel (elle varie par appareil, version d'OS, et pression mémoire
    /// au moment T ; le seul levier documenté pour l'augmenter,
    /// l'entitlement `com.apple.developer.kernel.increased-memory-limit`,
    /// n'est PAS activé dans ce projet). Calibré sur des mesures
    /// communautaires réelles plutôt qu'une doc Apple qui n'existe pas :
    /// iPhone SE 2020/2022 (3 Go de RAM totale) tolère environ 900 Mo pour
    /// une app au premier plan (~29 %) ; iPhone 16 Pro (8 Go) tolère environ
    /// 4 000 Mo (~50 %). La part disponible pour UNE app croît avec la RAM
    /// totale — l'OS se réserve une part de plus en plus GRANDE en absolu,
    /// mais de moins en moins en proportion, à mesure que le total grandit.
    /// ⚠️ Seuils délibérément PAR PALIER (pas une formule continue) : au-delà
    /// d'une poignée de points de mesure réels, une interpolation lisse
    /// donnerait une fausse précision.
    private static func estimatedJetsamLimitBytes(physicalMemoryBytes: Int64) -> Int64 {
        let gb = Double(physicalMemoryBytes) / 1_073_741_824
        let fraction: Double
        switch gb {
        case ..<3.5: fraction = 0.30
        case ..<5:   fraction = 0.40
        case ..<7:   fraction = 0.45
        default:     fraction = 0.50
        }
        return Int64(Double(physicalMemoryBytes) * fraction)
    }

    /// `nil` si rien à signaler. Non bloquant PAR CONCEPTION — un modèle qui
    /// dépasse la limite estimée peut malgré tout tenir sur un appareil réel
    /// (l'estimation reste une estimation), et l'utilisateur reste seul juge.
    /// Deux paliers : franchement au-delà de la limite estimée (quasi
    /// certain de faire fermer l'app), ou dans la zone risquée en-dessous
    /// (le reste de Nemoris — SQLite, UI, moteur d'identification ONNX —
    /// occupe déjà une partie de cette même limite, d'où la marge de 65 %
    /// plutôt que 100 %).
    func sizeWarning(forBytes sizeBytes: Int64) -> String? {
        let physicalMemory = Int64(ProcessInfo.processInfo.physicalMemory)
        guard physicalMemory > 0 else { return nil }
        let jetsamLimit = Self.estimatedJetsamLimitBytes(physicalMemoryBytes: physicalMemory)
        let projectedNeed = Double(sizeBytes) * 1.2
        let limitGB = Double(jetsamLimit) / 1_073_741_824
        let sizeGB = Double(sizeBytes) / 1_073_741_824

        if projectedNeed > Double(jetsamLimit) {
            return String(format: "Ce modèle pèse %.1f Go — presque certainement trop pour cet appareil (limite estimée ~%.1f Go pour une app au premier plan). L'app risque fortement de fermer brutalement pendant l'utilisation.", sizeGB, limitGB)
        }
        if projectedNeed > Double(jetsamLimit) * 0.65 {
            return String(format: "Ce modèle pèse %.1f Go, proche de la limite estimée pour cet appareil (~%.1f Go pour une app) — le reste de Nemoris a aussi besoin de mémoire. Le chargement risque d'être lent, voire de faire quitter l'app.", sizeGB, limitGB)
        }
        if let free = Self.freeDiskSpace(), free < sizeBytes + 200_000_000 {
            let freeGB = Double(free) / 1_073_741_824
            return String(format: "Espace disque limité (%.1f Go libres) — le téléchargement pourrait échouer avant la fin.", freeGB)
        }
        return nil
    }

    private static func freeDiskSpace() -> Int64? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard let values = try? appSupport.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }

    // MARK: Stockage partagé (téléchargement + import)

    private func ensureExcludedFromBackup() throws {
        try FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
        var rootValues = URLResourceValues()
        rootValues.isExcludedFromBackup = true
        var rootURL = Self.rootDirectory
        try? rootURL.setResourceValues(rootValues)
    }

    /// Ajoute un modèle déjà en place sur le disque au manifeste, et l'active
    /// automatiquement si c'est le tout premier — commun aux trois façons
    /// d'obtenir un modèle (téléchargement HF, import fichier, import dossier).
    private func registerNewModel(_ info: EmbeddedModelInfo) {
        ensureManifestLoaded()
        manifest.models.append(info)
        saveManifest()
        if EmbeddedModelManager.activeModelID == nil {
            EmbeddedModelManager.activeModelID = info.id
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let num = attrs[.size] as? NSNumber else { return nil }
        return num.int64Value
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: Téléchargement (Hugging Face, ou tout lien direct vers un .gguf)

    /// Télécharge, place le fichier dans son dossier définitif, enregistre
    /// l'entrée dans le manifeste. Devient le modèle ACTIF s'il s'agit du tout
    /// premier téléchargé (sinon l'utilisateur active explicitement).
    func download(candidate: EmbeddedModelCandidate,
                  onProgress: @escaping @Sendable (Double?) -> Void) async throws -> EmbeddedModelInfo {
        try ensureExcludedFromBackup()

        let id = UUID().uuidString
        let dir = Self.modelDirectory(id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(candidate.fileName)

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await EmbeddedModelDownloader.download(url: candidate.downloadURL, onProgress: onProgress)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw EmbeddedModelError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            try? FileManager.default.removeItem(at: dir)
            throw EmbeddedModelError.networkError("Le serveur a répondu une erreur.")
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw EmbeddedModelError.networkError(error.localizedDescription)
        }

        let sizeBytes = Self.fileSize(at: destination) ?? candidate.sizeBytes ?? 0
        let info = EmbeddedModelInfo(id: id, displayName: candidate.fileName, format: .gguf,
                                     sourceDescription: candidate.sourceLabel,
                                     fileName: candidate.fileName, sizeBytes: sizeBytes, downloadedAt: Date())
        registerNewModel(info)
        return info
    }

    /// Télécharge TOUS les fichiers d'un repo MLX dans le même dossier, en
    /// séquence (un repo MLX a peu de fichiers — quelques shards
    /// `.safetensors` + une poignée de `.json`/`.jinja` — pas besoin de
    /// parallélisme).
    ///
    /// ⚠️ Progression par NOMBRE DE FICHIERS, pas par octets agrégés. Une
    /// première version pondérait par taille (`file.sizeBytes` par fichier,
    /// sommés) — mais un total agrégé tombe en indéterminé dès qu'UN SEUL
    /// fichier sur N n'a pas de taille exploitable (HEAD sans
    /// `Content-Length`, fréquent sur les petits `.json`/`.jinja`), ce qui
    /// rendait TOUT le téléchargement indéterminé alors que 10 fichiers sur
    /// 11 avaient une taille connue (retour d'usage réel, 2026-09-01). Compter
    /// les fichiers est TOUJOURS disponible et avance de façon monotone,
    /// affiné par la fraction du fichier COURANT quand sa taille est connue.
    func downloadMLXRepo(candidate: EmbeddedMLXRepoCandidate,
                         onProgress: @escaping @Sendable (Double?) -> Void) async throws -> EmbeddedModelInfo {
        try ensureExcludedFromBackup()

        let id = UUID().uuidString
        let dir = Self.modelDirectory(id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let totalFiles = candidate.files.count
        guard totalFiles > 0 else { throw EmbeddedModelError.noModelFilesFound }

        for (index, file) in candidate.files.enumerated() {
            let destination = dir.appendingPathComponent(file.fileName)

            let tempURL: URL
            let response: URLResponse
            do {
                (tempURL, response) = try await EmbeddedModelDownloader.download(url: file.url) { fraction in
                    let currentFileFraction = fraction ?? 0
                    onProgress((Double(index) + currentFileFraction) / Double(totalFiles))
                }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw EmbeddedModelError.networkError(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                try? FileManager.default.removeItem(at: dir)
                throw EmbeddedModelError.networkError("Le serveur a répondu une erreur pour \(file.fileName).")
            }
            do {
                try FileManager.default.moveItem(at: tempURL, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw EmbeddedModelError.networkError(error.localizedDescription)
            }
            onProgress(Double(index + 1) / Double(totalFiles))
        }

        let sizeBytes = Self.directorySize(at: dir)
        let info = EmbeddedModelInfo(id: id, displayName: candidate.repo, format: .mlx,
                                     sourceDescription: "Hugging Face — \(candidate.repo)",
                                     fileName: "", sizeBytes: sizeBytes, downloadedAt: Date())
        registerNewModel(info)
        return info
    }

    // MARK: Import local — n'importe quelle source, aucune limite

    /// Importe un fichier `.gguf` déjà présent sur l'appareil (Fichiers,
    /// iCloud Drive, Mac…), quelle que soit son origine. `pickerURL` vient
    /// d'un document picker — accès security-scoped le temps de la copie,
    /// même précédent que `DatabaseManager.linkExternalFile`. COPIE le
    /// fichier (jamais `Data(contentsOf:)`, qui chargerait plusieurs Go en
    /// RAM d'un coup).
    func importFile(from pickerURL: URL) throws -> (info: EmbeddedModelInfo, warning: String?) {
        guard pickerURL.pathExtension.lowercased() == "gguf" else {
            throw EmbeddedModelError.notAGGUFFile
        }
        let hasAccess = pickerURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { pickerURL.stopAccessingSecurityScopedResource() } }

        try ensureExcludedFromBackup()
        let id = UUID().uuidString
        let dir = Self.modelDirectory(id: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = pickerURL.lastPathComponent
        let destination = dir.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: pickerURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw EmbeddedModelError.networkError(error.localizedDescription)
        }

        let sizeBytes = Self.fileSize(at: destination) ?? 0
        let info = EmbeddedModelInfo(id: id, displayName: fileName, format: .gguf,
                                     sourceDescription: "Importé — \(fileName)",
                                     fileName: fileName, sizeBytes: sizeBytes, downloadedAt: Date())
        registerNewModel(info)
        return (info, sizeWarning(forBytes: sizeBytes))
    }

    /// Importe un dossier de modèle MLX déjà présent (repo récupéré par
    /// n'importe quel moyen — Safari, un Mac, une autre app — puis importé
    /// tel quel). Vérifie la présence d'un `config.json` à la racine : signal
    /// minimal qu'il s'agit bien d'un repo MLX, pas n'importe quel dossier
    /// choisi par erreur. `copyItem` copie le dossier ENTIER récursivement —
    /// `dir` ne doit PAS être pré-créé, `copyItem` le crée lui-même comme
    /// destination de la copie (il échoue si la destination existe déjà).
    func importFolder(from pickerURL: URL) throws -> (info: EmbeddedModelInfo, warning: String?) {
        let hasAccess = pickerURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { pickerURL.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(
            atPath: pickerURL.appendingPathComponent("config.json").path) else {
            throw EmbeddedModelError.notAnMLXFolder
        }

        try ensureExcludedFromBackup()
        let id = UUID().uuidString
        let dir = Self.modelDirectory(id: id)
        do {
            try FileManager.default.copyItem(at: pickerURL, to: dir)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw EmbeddedModelError.networkError(error.localizedDescription)
        }

        let displayName = pickerURL.lastPathComponent
        let sizeBytes = Self.directorySize(at: dir)
        let info = EmbeddedModelInfo(id: id, displayName: displayName, format: .mlx,
                                     sourceDescription: "Importé — \(displayName)",
                                     fileName: "", sizeBytes: sizeBytes, downloadedAt: Date())
        registerNewModel(info)
        return (info, sizeWarning(forBytes: sizeBytes))
    }

    // MARK: Gestion (supprimer, renommer, activer)

    func delete(id: String) {
        ensureManifestLoaded()
        guard let index = manifest.models.firstIndex(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: Self.modelDirectory(id: id))
        manifest.models.remove(at: index)
        saveManifest()
        if EmbeddedModelManager.activeModelID == id {
            EmbeddedModelManager.activeModelID = manifest.models.first?.id
        }
        if loadedModelID == id {
            loadedService = nil
            loadedModelID = nil
        }
        if loadedMLXModelID == id {
            loadedMLXContainer = nil
            loadedMLXModelID = nil
        }
    }

    func rename(id: String, to newName: String) {
        ensureManifestLoaded()
        guard let index = manifest.models.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        manifest.models[index].displayName = trimmed
        saveManifest()
    }

    /// Réévalue l'avertissement RAM au moment de l'ACTIVATION, pas
    /// seulement au téléchargement/import — l'utilisateur peut activer un
    /// modèle téléchargé il y a longtemps, ou switcher entre plusieurs
    /// modèles déjà en place, et c'est CE moment-là qui compte vraiment
    /// (celui où le modèle sera réellement chargé en mémoire).
    @discardableResult
    func setActive(id: String?) -> String? {
        EmbeddedModelManager.activeModelID = id
        guard let id else { return nil }
        ensureManifestLoaded()
        guard let info = manifest.models.first(where: { $0.id == id }) else { return nil }
        return sizeWarning(forBytes: info.sizeBytes)
    }

    // MARK: Inférence — dispatch par format

    private func activeModelInfo() throws -> EmbeddedModelInfo {
        guard let activeID = EmbeddedModelManager.activeModelID else { throw EmbeddedModelError.notConfigured }
        ensureManifestLoaded()
        guard let info = manifest.models.first(where: { $0.id == activeID }) else { throw EmbeddedModelError.notConfigured }
        guard FileManager.default.fileExists(atPath: info.modelPathURL.path) else { throw EmbeddedModelError.modelFileMissing }
        return info
    }

    /// Complétion texte via le modèle actif — GGUF ou MLX selon son format,
    /// totalement transparent pour l'appelant (`EmbeddedModelService`).
    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        let info = try activeModelInfo()
        switch info.format {
        case .gguf:
            return try await completeGGUF(info: info, systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens)
        case .mlx:
            return try await completeMLX(info: info, systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens)
        }
    }

    // MARK: Inférence GGUF (SwiftLlama)

    private func ggufService(for info: EmbeddedModelInfo) -> LlamaService {
        if let loadedService, loadedModelID == info.id {
            return loadedService
        }
        // Modèle différent (ou premier chargement) : nouvelle instance —
        // `LlamaService` fige son `modelUrl` à l'init, aucune mutation en place
        // possible pour changer de fichier.
        #if targetEnvironment(simulator)
        // llama.cpp/Metal indisponible en Simulator — reste fonctionnel en CPU
        // pur, juste plus lent (même convention que le reste de l'app pour
        // l'offload Metal).
        let useGPU = false
        #else
        let useGPU = true
        #endif
        let service = LlamaService(modelUrl: info.modelPathURL,
                                   config: LlamaConfig(batchSize: 512, maxTokenCount: 4_096, useGPU: useGPU))
        loadedService = service
        loadedModelID = info.id
        return service
    }

    /// `LlamaService` n'expose pas de paramètre « nombre de tokens de
    /// SORTIE », seulement une taille de CONTEXTE totale
    /// (`LlamaConfig.maxTokenCount`) — le cap `maxTokens` est donc appliqué en
    /// tronquant le flux dès que l'estimation (~4 caractères/token) est
    /// dépassée, puis en annulant la génération via `stopCompletion()`.
    private func completeGGUF(info: EmbeddedModelInfo, systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        let service = ggufService(for: info)
        let messages = [
            LlamaChatMessage(role: .system, content: systemPrompt),
            LlamaChatMessage(role: .user, content: userPrompt)
        ]
        let characterBudget = max(maxTokens, 1) * 4
        do {
            let stream = try await service.streamCompletion(
                of: messages,
                samplingConfig: LlamaSamplingConfig(temperature: 0.2, seed: .random(in: 0...UInt32.max)))
            var accumulated = ""
            for try await chunk in stream {
                accumulated += chunk
                if accumulated.count >= characterBudget {
                    await service.stopCompletion()
                    break
                }
            }
            return accumulated
        } catch {
            throw EmbeddedModelError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: Inférence MLX (mlx-swift-lm)

    /// Charge (ou réutilise) le `ModelContainer` — les poids, coûteux à
    /// charger, mis en cache. Le tokenizer est lu DIRECTEMENT depuis le
    /// dossier local (`LocalTokenizerLoader`), sans passer par un
    /// téléchargeur : `Downloader` n'est requis QUE pour des poids distants,
    /// jamais pour des poids déjà sur le disque (doc officielle mlx-swift-lm).
    private func mlxContainer(for info: EmbeddedModelInfo) async throws -> ModelContainer {
        if let loadedMLXContainer, loadedMLXModelID == info.id {
            return loadedMLXContainer
        }
        let container = try await LLMModelFactory.shared.loadContainer(
            from: info.modelPathURL, using: LocalTokenizerLoader())
        loadedMLXContainer = container
        loadedMLXModelID = info.id
        return container
    }

    /// Contrairement à `LlamaService`, une `ChatSession` MLX accumule un
    /// historique de conversation entre deux appels à `respond(to:)` — notre
    /// contrat est sans état PAR APPEL (chaque `complete()` peut avoir un
    /// `systemPrompt` complètement différent : identification marchand, coach,
    /// assistant SQL…). Une session est donc reconstruite à CHAQUE appel, avec
    /// les instructions de CET appel — seul le `ModelContainer` (les poids
    /// chargés) est mis en cache, la session elle-même est bon marché.
    private func completeMLX(info: EmbeddedModelInfo, systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        do {
            let container = try await mlxContainer(for: info)
            let session = ChatSession(
                container,
                instructions: systemPrompt,
                generateParameters: GenerateParameters(maxTokens: maxTokens))
            return try await session.respond(to: userPrompt)
        } catch {
            throw EmbeddedModelError.generationFailed(error.localizedDescription)
        }
    }

    /// `nil` si non configuré ou en cas d'échec — même contrat de silence que
    /// `LocalLLMService.identify`/`EnrichmentLLMService.identify`.
    func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        guard EmbeddedModelManager.hasConfiguration else { return nil }
        do {
            // `EnrichmentLLMService` est `@MainActor` — le `await` gère le hop
            // d'acteur pour ses membres statiques partagés, comme dans
            // `LocalLLMService.identify`.
            let userPrompt = await EnrichmentLLMService.buildPrompt(context: context)
            let content = try await complete(
                systemPrompt: EnrichmentLLMService.instructions,
                userPrompt: userPrompt,
                maxTokens: AIFeature.merchantEnrichment.maxOutputTokens)
            guard var result = await EnrichmentLLMService.parseJSONResponse(content, context: context) else {
                return nil
            }
            // Réutilise `.localLLM` plutôt qu'un nouveau cas de
            // `MerchantEnrichmentSource` : le badge « LOCAL »/icône
            // `server.rack`/couleur `.teal` déjà en place décrivent aussi bien
            // « inférence locale via un serveur » que « inférence locale
            // embarquée » — les deux ne quittent jamais l'appareil.
            result.source = .localLLM
            return result
        } catch {
            print("[EmbeddedModelManager] identify error: \(error)")
            return nil
        }
    }
}

// MARK: - Pont tokenizer local (MLX) — swift-transformers → MLXLMCommon

/// `MLXLMCommon.Tokenizer` (protocole attendu par `ChatSession`) et
/// `Tokenizers.Tokenizer` (implémentation concrète de swift-transformers,
/// celle que `AutoTokenizer.from(modelFolder:)` sait charger depuis un
/// dossier local sans réseau) sont deux types DIFFÉRENTS portant le même nom
/// — mlx-swift-lm ne fournit d'adaptateur tout fait que dans son module
/// `MLXHuggingFace` (macros liées au téléchargement HF, volontairement pas
/// une dépendance ici). Petit pont écrit à la main, comme suggéré par la doc
/// mlx-swift-lm elle-même pour toute intégration hors macro.
private struct MLXTokenizerAdapter: MLXLMCommon.Tokenizer {
    let wrapped: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        wrapped.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        wrapped.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { wrapped.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { wrapped.convertIdToToken(id) }
    var bosToken: String? { wrapped.bosToken }
    var eosToken: String? { wrapped.eosToken }
    var unknownToken: String? { wrapped.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try wrapped.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

/// Charge le tokenizer DEPUIS UN DOSSIER LOCAL — `AutoTokenizer.from(modelFolder:)`
/// lit `tokenizer.json`/`tokenizer_config.json` sur le disque, aucun appel
/// réseau (le paramètre `hubApi` de cette surcharge n'est pas utilisé pour le
/// chargement local, per la doc de swift-transformers).
private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return MLXTokenizerAdapter(wrapped: tokenizer)
    }
}

// MARK: - Téléchargement avec progression (pont delegate → async/await)

/// `URLSession.shared.download(for:)` n'expose aucune progression, et
/// `URLSession.shared.bytes(for:)` itère octet par octet — inadapté à un
/// fichier de plusieurs centaines de Mo à plusieurs Go. Le delegate reste donc
/// la bonne primitive Foundation pour ce cas précis (aucun précédent existant
/// dans ce repo à réutiliser).
private enum EmbeddedModelDownloader {
    static func download(url: URL, onProgress: @escaping @Sendable (Double?) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = DownloadDelegate(onProgress: onProgress) { result in
                continuation.resume(with: result)
            }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: url)
            delegate.retain(session: session)
            task.resume()
        }
    }

    /// `@unchecked Sendable` : classe `NSObject`/delegate imposée par
    /// l'API Objective-C d'URLSession, dont l'état n'est mutable QUE depuis la
    /// file delegate série d'URLSession (mono-usage, un seul téléchargement par
    /// instance) — jamais depuis notre propre code en parallèle.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double?) -> Void
        private let onFinished: (Result<(URL, URLResponse), Error>) -> Void
        private var session: URLSession?
        private var safeTempURL: URL?

        init(onProgress: @escaping @Sendable (Double?) -> Void,
             onFinished: @escaping (Result<(URL, URLResponse), Error>) -> Void) {
            self.onProgress = onProgress
            self.onFinished = onFinished
        }

        func retain(session: URLSession) {
            self.session = session
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            onProgress(totalBytesExpectedToWrite > 0
                       ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                       : nil)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // Le fichier temporaire d'URLSession est supprimé dès que ce
            // callback rend la main — on le déplace IMMÉDIATEMENT vers un
            // second temporaire qu'on contrôle, avant de rendre la main à
            // `didCompleteWithError` (appelé juste après, succès compris).
            let safe = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            safeTempURL = (try? FileManager.default.moveItem(at: location, to: safe)) != nil ? safe : nil
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            self.session?.finishTasksAndInvalidate()
            if let error {
                onFinished(.failure(error))
                return
            }
            guard let safeTempURL, let response = task.response else {
                onFinished(.failure(EmbeddedModelError.networkError("Téléchargement interrompu.")))
                return
            }
            onFinished(.success((safeTempURL, response)))
        }
    }
}

// MARK: - Façade de dispatch (même contrat que `LocalLLMService`/`CloudLLMService`)

/// `Sendable` sans état propre — l'état réel (manifeste, modèle chargé) vit
/// dans l'acteur `EmbeddedModelManager`. Cette façade est ce que
/// `AIEnrichmentBackend` appelle, symétriquement aux deux autres backends.
struct EmbeddedModelService: Sendable {
    static let shared = EmbeddedModelService()

    static var hasConfiguration: Bool { EmbeddedModelManager.hasConfiguration }

    func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        await EmbeddedModelManager.shared.identify(context: context)
    }

    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        try await EmbeddedModelManager.shared.complete(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens)
    }

    /// Jette une erreur typée (contrairement à `identify`, qui avale tout en
    /// silence) — le bouton « Tester » des Réglages veut un message précis.
    func testConnection() async throws -> String {
        guard Self.hasConfiguration else { throw EmbeddedModelError.notConfigured }
        let content = try await complete(systemPrompt: "Réponds uniquement par le mot OK.",
                                         userPrompt: "Ping de test.", maxTokens: 16)
        let preview = content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
        return "Le modèle a répondu : \(preview)"
    }
}

// MARK: - État du téléchargement en cours (survit à la navigation)

/// Le téléchargement lui-même (`Task {}` créée dans l'action du bouton, pas
/// `.task {}`) survit déjà à la fermeture de l'écran — rien à changer côté
/// réseau/fichiers pour ça. Ce qui manquait : l'INDICATION, qui vivait dans
/// des `@State` de `AISettingsView` — remis à zéro à chaque fois que la vue
/// est recréée (on quitte Réglages puis on y revient = nouvelle instance).
/// Un singleton `@MainActor @Observable`, indépendant de toute vue, corrige
/// ça : une vue qui lit `inFlight` dans son `body` s'y abonne automatiquement
/// (mécanique native d'`@Observable`), qu'elle vienne d'apparaître ou non —
/// pas de plomberie `onAppear` à écrire pour "rattraper" l'état.
@MainActor
@Observable
final class EmbeddedModelDownloadStatus {
    static let shared = EmbeddedModelDownloadStatus()
    private init() {}

    struct InFlight: Equatable {
        var candidateID: String
        var label: String
        var progress: Double?
    }

    private(set) var inFlight: InFlight?

    func start(candidateID: String, label: String) {
        inFlight = InFlight(candidateID: candidateID, label: label, progress: nil)
    }

    func update(progress: Double?) {
        inFlight?.progress = progress
    }

    func finish() {
        inFlight = nil
    }
}
