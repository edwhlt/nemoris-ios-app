import Foundation
import SwiftLlama
import MLXLLM
import MLXLMCommon
import Tokenizers

/// "Embedded model" AI backend — a model run INSIDE the app, with no
/// external server and no Apple Intelligence. Two formats: **GGUF** (via
/// `SwiftLlama`/llama.cpp, runs on any device) and **MLX** (via
/// `mlx-swift-lm`, Apple Silicon only — faster on that hardware).
///
/// No marketplace, and not limited to Hugging Face: pasting an HF link is
/// still a shortcut (GGUF only, resolved via the HF API), but the
/// main path is IMPORTING a `.gguf` file or an MLX folder already
/// present on the device (Files/iCloud Drive/Mac) — any
/// source, no limit. See `EmbeddedModelManager.importFile`/`importFolder`.
///
/// Storage: `Application Support/LocalModels/` (not `Caches` — the OS can
/// purge `Caches` under storage pressure, which would silently lose a
/// download of several hundred MB). Excluded from iCloud backup
/// (`isExcludedFromBackup`): re-downloadable from Hugging Face, shouldn't
/// bloat a device backup.
///
/// Automatically visible in Settings → General → iPhone Storage → Nemoris
/// (the app container's content) — nothing special to code for that.

// MARK: - Downloaded/imported model (persisted in manifest.json)

/// GGUF: a single file. MLX: a whole folder (`.safetensors` weights +
/// `config.json` + tokenizer) — two distinct inference engines behind
/// `EmbeddedModelManager`, never mixed.
enum EmbeddedModelFormat: String, Codable, Sendable {
    case gguf
    case mlx
}

struct EmbeddedModelInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String
    let format: EmbeddedModelFormat
    /// Provenance, INFORMATIONAL only (never any logic on it) — e.g.
    /// "Hugging Face — org/repo", "Imported — file_name.gguf", "Imported —
    /// folder_name". Replaces an older non-optional `hfRepo` field that
    /// wrongly assumed Hugging Face was the only possible source.
    var sourceDescription: String
    /// GGUF file name — ignored if `format == .mlx` (the whole folder
    /// IS the model, not a named file inside it).
    let fileName: String
    var sizeBytes: Int64
    let downloadedAt: Date

    /// GGUF: path to the single file. MLX: the model's folder itself.
    var modelPathURL: URL {
        let dir = EmbeddedModelManager.modelDirectory(id: id)
        return format == .gguf ? dir.appendingPathComponent(fileName) : dir
    }
}

private struct EmbeddedModelManifest: Codable {
    var models: [EmbeddedModelInfo] = []
}

// MARK: - Result of analyzing a link/repo

/// A specific `.gguf` file, ready to be downloaded. Several candidates
/// are possible for A SINGLE repo (several quantizations) — this isn't a
/// suggested catalog, it's disambiguating the resource the
/// user pointed to themselves.
struct EmbeddedModelCandidate: Identifiable, Hashable, Sendable {
    var id: String { sourceLabel + "/" + fileName }
    /// Provenance already formatted for display — "Hugging Face — org/repo"
    /// for the HF shortcut, the bare host for any other direct link.
    let sourceLabel: String
    let fileName: String
    let sizeBytes: Int64?
    let downloadURL: URL
}

/// A remote file, with its size if known — a building block shared by an MLX
/// repo (always several files, unlike a GGUF).
struct EmbeddedRemoteFile: Hashable, Sendable {
    let fileName: String
    let url: URL
    let sizeBytes: Int64?
}

/// A whole MLX repo (`.safetensors` weights + `config.json` + tokenizer),
/// ready to be downloaded ALL AT ONCE — an MLX model is ALWAYS several
/// files, never a single one like a GGUF.
struct EmbeddedMLXRepoCandidate: Identifiable, Hashable, Sendable {
    var id: String { "mlx/" + repo }
    let repo: String
    let files: [EmbeddedRemoteFile]

    /// `nil` if the size of AT LEAST ONE file is unknown — we don't claim
    /// a total we don't actually have.
    var totalSizeBytes: Int64? {
        let sizes = files.map(\.sizeBytes)
        guard sizes.allSatisfy({ $0 != nil }) else { return nil }
        return sizes.compactMap { $0 }.reduce(0, +)
    }
}

/// Result of `analyze(_:)` — GGUF (one or several candidate files,
/// the user picks which) or a whole MLX repo (a single candidate, there's
/// nothing to disambiguate: it's the whole repo or nothing).
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

// MARK: - Manager: manifest, download, loaded model

actor EmbeddedModelManager {
    static let shared = EmbeddedModelManager()

    private var manifest = EmbeddedModelManifest()
    private var manifestLoaded = false

    // The GGUF model loaded in memory. Only one at a time — loading it is
    // costly, and `LlamaService` fixes its file at init (no in-place
    // mutation to switch models).
    private var loadedService: LlamaService?
    private var loadedModelID: String?

    // The loaded MLX container — the MLX equivalent of `loadedService`. Only
    // one format active at a time (GGUF OR MLX), but kept in separate
    // slots rather than an "either" type: the two engines' loading logic
    // isn't similar enough to share an abstraction.
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

    /// Pointer to the active model — `UserDefaults.standard`, like
    /// `LocalLLMService.baseURL`: device-specific, never synced.
    static var activeModelID: String? {
        get { UserDefaults.standard.string(forKey: activeModelIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeModelIDKey) }
    }

    static var hasConfiguration: Bool { activeModelID != nil }

    /// MLX requires actual Apple Silicon. On Apple platforms, `mlx-swift`
    /// ALWAYS builds with Metal (no CPU fallback like on Linux) — so there
    /// is no "MLX.isAvailable" to query at runtime, the real
    /// question is the architecture, not a framework capability. The
    /// Simulator is excluded: Metal isn't reliable there for heavy compute
    /// (same convention as the GGUF GPU offload below).
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

    // MARK: Analyzing a Hugging Face link / repo

    /// Accepts a direct link to a `.gguf` on ANY host (not just
    /// Hugging Face) or a bare HF `owner/repo`. For a repo, the Hugging Face
    /// API lists its files, and the FORMAT is detected from their
    /// content — with no checkbox: presence of `.gguf` → pick from GGUF
    /// files (usually one quantization per file); otherwise presence of
    /// `config.json` + `.safetensors` weights → a whole MLX repo (an MLX model
    /// is always several files, there's nothing to disambiguate). The
    /// `owner/repo` shortcut stays an HF-specific convenience; the direct
    /// link, on the other hand, was never limited to any particular host after
    /// this generalization.
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

        // No GGUF: is it an MLX repo? Same file patterns
        // mlx-swift-lm uses for its OWN internal downloader (weights +
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

    /// A direct link to a `.gguf`, ANY host (GitHub Releases, a
    /// personal server, etc. — not just Hugging Face). The HF form
    /// (`…/resolve/<rev>/xxx.gguf`) is recognized specifically to derive
    /// a "Hugging Face — org/repo" label; any other host falls back to a
    /// generic label based on its name.
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

    // MARK: RAM / storage safety net — INFORMATIONAL, never blocking

    /// `nil` if there's nothing to report. Tapping confirm is always possible
    /// even with a warning — the user decides, the app warns.
    /// ESTIMATED device jetsam limit — Apple publishes NO
    /// official figure (it varies by device, OS version, and memory
    /// pressure at time T; the only documented lever to raise it,
    /// the `com.apple.developer.kernel.increased-memory-limit`
    /// entitlement, is NOT enabled in this project). Calibrated on real
    /// community measurements rather than an Apple doc that doesn't exist:
    /// an iPhone SE 2020/2022 (3 GB total RAM) tolerates about 900 MB for
    /// a foreground app (~29%); an iPhone 16 Pro (8 GB) tolerates about
    /// 4,000 MB (~50%). The share available to ONE app grows with total
    /// RAM — the OS reserves an ever-LARGER share in absolute terms,
    /// but a smaller and smaller proportion, as the total grows.
    /// ⚠️ Thresholds deliberately STEPPED (not a continuous formula): beyond
    /// a handful of real measurement points, a smooth interpolation
    /// would give a false sense of precision.
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

    /// `nil` if there's nothing to report. Non-blocking BY DESIGN — a model
    /// that exceeds the estimated limit may still run fine on a real device
    /// (the estimate remains an estimate), and the user is the sole judge.
    /// Two tiers: clearly beyond the estimated limit (almost
    /// certain to get the app killed), or in the risky zone below it
    /// (the rest of Nemoris — SQLite, UI, the ONNX identification engine —
    /// already occupies part of that same limit, hence the 65% margin
    /// rather than 100%).
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

    // MARK: Shared storage (download + import)

    private func ensureExcludedFromBackup() throws {
        try FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
        var rootValues = URLResourceValues()
        rootValues.isExcludedFromBackup = true
        var rootURL = Self.rootDirectory
        try? rootURL.setResourceValues(rootValues)
    }

    /// Adds a model already present on disk to the manifest, and activates
    /// it automatically if it's the very first one — shared by all three ways
    /// of obtaining a model (HF download, file import, folder import).
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

    // MARK: Download (Hugging Face, or any direct link to a .gguf)

    /// Downloads, places the file in its final folder, records
    /// the entry in the manifest. Becomes the ACTIVE model if it's the very
    /// first one downloaded (otherwise the user activates it explicitly).
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

    /// Downloads ALL of an MLX repo's files into the same folder, in
    /// sequence (an MLX repo has few files — a handful of `.safetensors`
    /// shards + a handful of `.json`/`.jinja` — no need for
    /// parallelism).
    ///
    /// ⚠️ Progress by NUMBER OF FILES, not aggregated bytes. An
    /// earlier version weighted by size (`file.sizeBytes` per file,
    /// summed) — but an aggregate total becomes indeterminate as soon as A
    /// SINGLE file out of N has no usable size (a HEAD with no
    /// `Content-Length`, common on small `.json`/`.jinja` files), which
    /// made the WHOLE download indeterminate even though 10 files out of
    /// 11 had a known size (observed in real usage, 2026-09-01). Counting
    /// files is ALWAYS available and advances monotonically,
    /// refined by the CURRENT file's fraction when its size is known.
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

    /// Imports a `.gguf` file already present on the device (Files,
    /// iCloud Drive, Mac…), whatever its origin. `pickerURL` comes
    /// from a document picker — security-scoped access for the duration of the
    /// copy, same precedent as `DatabaseManager.linkExternalFile`. COPIES the
    /// file (never `Data(contentsOf:)`, which would load several GB into
    /// RAM at once).
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

    /// Imports an MLX model folder already present (a repo obtained by
    /// any means — Safari, a Mac, another app — then imported
    /// as-is). Checks for a `config.json` at the root: a
    /// minimal signal that it really is an MLX repo, not just any folder
    /// picked by mistake. `copyItem` copies the WHOLE folder recursively —
    /// `dir` must NOT be pre-created, `copyItem` creates it itself as the
    /// copy destination (it fails if the destination already exists).
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

    /// Re-evaluates the RAM warning at ACTIVATION time, not
    /// only on download/import — the user can activate a
    /// model downloaded a long time ago, or switch between several
    /// models already in place, and it's THAT moment that really matters
    /// (the moment the model will actually be loaded into memory).
    @discardableResult
    func setActive(id: String?) -> String? {
        EmbeddedModelManager.activeModelID = id
        guard let id else { return nil }
        ensureManifestLoaded()
        guard let info = manifest.models.first(where: { $0.id == id }) else { return nil }
        return sizeWarning(forBytes: info.sizeBytes)
    }

    // MARK: Inference — dispatch by format

    private func activeModelInfo() throws -> EmbeddedModelInfo {
        guard let activeID = EmbeddedModelManager.activeModelID else { throw EmbeddedModelError.notConfigured }
        ensureManifestLoaded()
        guard let info = manifest.models.first(where: { $0.id == activeID }) else { throw EmbeddedModelError.notConfigured }
        guard FileManager.default.fileExists(atPath: info.modelPathURL.path) else { throw EmbeddedModelError.modelFileMissing }
        return info
    }

    /// Text completion via the active model — GGUF or MLX depending on its
    /// format, entirely transparent to the caller (`EmbeddedModelService`).
    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        let info = try activeModelInfo()
        switch info.format {
        case .gguf:
            return try await completeGGUF(info: info, systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens)
        case .mlx:
            return try await completeMLX(info: info, systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens)
        }
    }

    // MARK: GGUF inference (SwiftLlama)

    private func ggufService(for info: EmbeddedModelInfo) -> LlamaService {
        if let loadedService, loadedModelID == info.id {
            return loadedService
        }
        // Different model (or first load): a new instance —
        // `LlamaService` fixes its `modelUrl` at init, no in-place
        // mutation possible to switch files.
        #if targetEnvironment(simulator)
        // llama.cpp/Metal unavailable in the Simulator — stays functional in pure
        // CPU mode, just slower (same convention as the rest of the app for
        // Metal offload).
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

    /// `LlamaService` doesn't expose an "output token count" parameter,
    /// only a total CONTEXT size
    /// (`LlamaConfig.maxTokenCount`) — the `maxTokens` cap is therefore applied by
    /// truncating the stream as soon as the estimate (~4 characters/token) is
    /// exceeded, then canceling generation via `stopCompletion()`.
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

    // MARK: MLX inference (mlx-swift-lm)

    /// Loads (or reuses) the `ModelContainer` — the weights, costly to
    /// load, are cached. The tokenizer is read DIRECTLY from the
    /// local folder (`LocalTokenizerLoader`), without going through a
    /// downloader: `Downloader` is ONLY required for remote weights,
    /// never for weights already on disk (per the official mlx-swift-lm docs).
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

    /// Unlike `LlamaService`, an MLX `ChatSession` accumulates a
    /// conversation history between two calls to `respond(to:)` — our
    /// contract is stateless PER CALL (each `complete()` can have a
    /// completely different `systemPrompt`: merchant identification, coach,
    /// SQL assistant…). A session is therefore rebuilt on EVERY call, with
    /// THAT call's instructions — only the `ModelContainer` (the loaded
    /// weights) is cached, the session itself is cheap.
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

    /// `nil` if not configured or on failure — same silent-failure contract as
    /// `LocalLLMService.identify`/`EnrichmentLLMService.identify`.
    func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        guard EmbeddedModelManager.hasConfiguration else { return nil }
        do {
            // `EnrichmentLLMService` is `@MainActor` — the `await` handles the actor
            // hop for its shared static members, as in
            // `LocalLLMService.identify`.
            let userPrompt = await EnrichmentLLMService.buildPrompt(context: context)
            let content = try await complete(
                systemPrompt: EnrichmentLLMService.instructions,
                userPrompt: userPrompt,
                maxTokens: AIFeature.merchantEnrichment.maxOutputTokens)
            guard var result = await EnrichmentLLMService.parseJSONResponse(content, context: context) else {
                return nil
            }
            // Reuses `.localLLM` rather than a new `MerchantEnrichmentSource`
            // case: the "LOCAL" badge / `server.rack` icon / `.teal` color already
            // in place describe "local inference via a server" just as well as
            // "local embedded inference" — neither ever leaves the
            // device.
            result.source = .localLLM
            return result
        } catch {
            print("[EmbeddedModelManager] identify error: \(error)")
            return nil
        }
    }
}

// MARK: - Pont tokenizer local (MLX) — swift-transformers → MLXLMCommon

/// `MLXLMCommon.Tokenizer` (the protocol `ChatSession` expects) and
/// `Tokenizers.Tokenizer` (swift-transformers's concrete implementation,
/// the one `AutoTokenizer.from(modelFolder:)` can load from a
/// local folder with no network) are two DIFFERENT types sharing the same
/// name — mlx-swift-lm only ships a ready-made adapter in its
/// `MLXHuggingFace` module (macros tied to HF downloading, deliberately not
/// a dependency here). A small hand-written bridge, as suggested by
/// mlx-swift-lm's own docs for any integration outside the macro.
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

/// Loads the tokenizer FROM A LOCAL FOLDER — `AutoTokenizer.from(modelFolder:)`
/// reads `tokenizer.json`/`tokenizer_config.json` from disk, no
/// network call (this overload's `hubApi` parameter isn't used for
/// local loading, per swift-transformers' docs).
private struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return MLXTokenizerAdapter(wrapped: tokenizer)
    }
}

// MARK: - Download with progress (delegate → async/await bridge)

/// `URLSession.shared.download(for:)` exposes no progress at all, and
/// `URLSession.shared.bytes(for:)` iterates byte by byte — unsuited to a
/// file of several hundred MB to several GB. The delegate remains the
/// right Foundation primitive for this exact case (no existing precedent
/// in this repo to reuse).
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

    /// `@unchecked Sendable`: an `NSObject`/delegate class required by
    /// URLSession's Objective-C API, whose state is mutable ONLY from
    /// URLSession's serial delegate queue (single-use, one download per
    /// instance) — never from our own code concurrently.
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
            // URLSession's temporary file is deleted as soon as this
            // callback returns — we IMMEDIATELY move it to a
            // second temporary file we control, before returning
            // control to `didCompleteWithError` (called right after, success
            // included).
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

// MARK: - Dispatch facade (same contract as `LocalLLMService`/`CloudLLMService`)

/// `Sendable` with no state of its own — the real state (manifest, loaded
/// model) lives in the `EmbeddedModelManager` actor. This facade is what
/// `AIEnrichmentBackend` calls, symmetrically to the other two backends.
struct EmbeddedModelService: Sendable {
    static let shared = EmbeddedModelService()

    static var hasConfiguration: Bool { EmbeddedModelManager.hasConfiguration }

    func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        await EmbeddedModelManager.shared.identify(context: context)
    }

    func complete(systemPrompt: String, userPrompt: String, maxTokens: Int) async throws -> String {
        try await EmbeddedModelManager.shared.complete(systemPrompt: systemPrompt, userPrompt: userPrompt, maxTokens: maxTokens)
    }

    /// Throws a typed error (unlike `identify`, which swallows everything
    /// silently) — the "Test" button in Settings wants a precise message.
    func testConnection() async throws -> String {
        guard Self.hasConfiguration else { throw EmbeddedModelError.notConfigured }
        let content = try await complete(systemPrompt: "Réponds uniquement par le mot OK.",
                                         userPrompt: "Ping de test.", maxTokens: 16)
        let preview = content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
        return "Le modèle a répondu : \(preview)"
    }
}

// MARK: - In-flight download state (survives navigation)

/// The download itself (a `Task {}` created in the button's action, not
/// `.task {}`) already survives closing the screen — nothing to change on
/// the network/file side for that. What was missing: the INDICATOR, which
/// lived in `AISettingsView`'s `@State` — reset every time the view
/// is recreated (leaving Settings then coming back = a new instance).
/// A `@MainActor @Observable` singleton, independent of any view, fixes
/// this: a view reading `inFlight` in its `body` subscribes to it automatically
/// (native `@Observable` mechanics), whether it just appeared or not —
/// no `onAppear` plumbing needed to "catch up" on the state.
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
