import Foundation
#if canImport(UIKit)
import UIKit
#endif
import CryptoKit
import NemorisEngine

/// Récupère et cache les favicons de marchands depuis Google.
///
/// Stratégie :
///   - Le domaine vient en priorité de `payees.domain` (rempli au fil de l'usage).
///   - Si vide, on tente le seed engine `MerchantDomains.map[engine_merchant_id]`.
///   - Si toujours rien → renvoie nil → l'UI affiche le fallback SF Symbol.
///
/// Cache :
///   - Image décodée en RAM (NSCache, limité par défaut iOS).
///   - PNG sur disque dans `Library/Caches/Logos/<sha1(domain)>.png`.
///   - Domaines qui ont rendu 404 sont stockés dans UserDefaults
///     (`logo.failed.domains`) pour éviter un nouvel appel réseau pendant la session.
///
/// Concurrence : un sémaphore limite à 4 téléchargements simultanés.
actor MerchantLogoService {
    static let shared = MerchantLogoService()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let cacheDirectory: URL
    private var failedDomains: Set<String>
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let maxParallelDownloads = 4
    private var activeDownloads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let failedDomainsKey = "logo.failed.domains"

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = caches.appendingPathComponent("Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let saved = UserDefaults.standard.array(forKey: Self.failedDomainsKey) as? [String] ?? []
        self.failedDomains = Set(saved)

        memoryCache.countLimit = 256
    }

    // MARK: Public API

    /// Résout le domaine effectif pour un payee.
    /// Synchrone, sans réseau : juste les colonnes locales + le seed engine.
    nonisolated static func resolveDomain(payeeDomain: String?, engineMerchantId: String?) -> String? {
        if let d = payeeDomain?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
        if let id = engineMerchantId?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            return MerchantDomains.domain(for: id)
        }
        return nil
    }

    /// Renvoie le logo en cache RAM si présent, sans toucher au disque ni au réseau.
    /// Sert au premier rendu pour éviter un flash placeholder.
    func cachedLogo(forDomain domain: String) -> UIImage? {
        memoryCache.object(forKey: domain as NSString)
    }

    /// Récupère le logo : RAM → disque → réseau.
    /// Renvoie nil si tout échoue (404, pas de réseau, etc.).
    func logo(forDomain domain: String) async -> UIImage? {
        let key = domain.lowercased()

        if let img = memoryCache.object(forKey: key as NSString) {
            return img
        }
        if failedDomains.contains(key) {
            return nil
        }
        if let existing = inFlight[key] {
            return await existing.value
        }

        let diskURL = diskCacheURL(for: key)
        if let img = loadFromDisk(diskURL) {
            memoryCache.setObject(img, forKey: key as NSString)
            return img
        }

        let task = Task<UIImage?, Never> { [weak self] in
            await self?.download(domain: key, diskURL: diskURL)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return await task.value
    }

    // MARK: Internals

    private func download(domain: String, diskURL: URL) async -> UIImage? {
        await acquireSlot()
        defer { releaseSlot() }

        let urlString = "https://www.google.com/s2/favicons?domain=\(domain)&sz=128"
        guard let url = URL(string: urlString) else {
            markFailed(domain)
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                markFailed(domain)
                return nil
            }
            guard let image = UIImage(data: data) else {
                markFailed(domain)
                return nil
            }
            // Google renvoie un favicon par défaut générique pour les domaines inexistants
            // (16x16 quasi-vide). Si l'image est suspectement petite, on la considère
            // comme un fallback et on marque le domaine comme failed.
            if image.size.width < 24 || image.size.height < 24 {
                markFailed(domain)
                return nil
            }
            try? data.write(to: diskURL, options: .atomic)
            memoryCache.setObject(image, forKey: domain as NSString)
            return image
        } catch {
            print("[MerchantLogoService] download failed for \(domain): \(error.localizedDescription)")
            return nil
        }
    }

    private func diskCacheURL(for domain: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(domain.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hex).png")
    }

    nonisolated private func loadFromDisk(_ url: URL) -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)
        else { return nil }
        return image
    }

    private func markFailed(_ domain: String) {
        failedDomains.insert(domain)
        UserDefaults.standard.set(Array(failedDomains), forKey: Self.failedDomainsKey)
    }

    // MARK: Throttling

    private func acquireSlot() async {
        if activeDownloads < maxParallelDownloads {
            activeDownloads += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
        activeDownloads += 1
    }

    private func releaseSlot() {
        activeDownloads -= 1
        if !waiters.isEmpty {
            let cont = waiters.removeFirst()
            cont.resume()
        }
    }
}
