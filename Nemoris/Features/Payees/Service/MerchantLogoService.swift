import Foundation
#if canImport(UIKit)
import UIKit
#endif
import CryptoKit
import NemorisEngine

/// Fetches and caches merchant favicons from Google.
///
/// Strategy:
///   - The domain comes first from `payees.domain` (filled in over time).
///   - If empty, the engine seed `MerchantDomains.map[engine_merchant_id]` is tried.
///   - If still nothing → returns nil → the UI shows the SF Symbol fallback.
///
/// Caching:
///   - Decoded image in RAM (NSCache, bounded by the iOS default).
///   - PNG on disk under `Library/Caches/Logos/<sha1(domain)>.png`.
///   - Domains that returned 404 are stored in UserDefaults
///     (`logo.failed.domains`) to avoid another network call during the session.
///
/// Concurrency: a semaphore caps concurrent downloads at 4.
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

    /// Resolves the effective domain for a payee.
    /// Synchronous, no network: just the local columns plus the engine seed.
    nonisolated static func resolveDomain(payeeDomain: String?, engineMerchantId: String?) -> String? {
        if let d = payeeDomain?.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
        if let id = engineMerchantId?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
            return MerchantDomains.domain(for: id)
        }
        return nil
    }

    /// Returns the RAM-cached logo when present, touching neither disk nor
    /// network. Used on first render to avoid a placeholder flash.
    func cachedLogo(forDomain domain: String) -> UIImage? {
        memoryCache.object(forKey: domain as NSString)
    }

    /// Fetches the logo: RAM → disk → network.
    /// Returns nil if everything fails (404, no network, etc.).
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
            // Google returns a generic default favicon for non-existent
            // domains (a near-empty 16x16). If the image is suspiciously
            // small, treat it as that fallback and mark the domain failed.
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
