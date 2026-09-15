import Foundation

/// Resolves the install URL of the Apple Pay Shortcuts automation from a
/// small JSON manifest hosted on nemoris-site
/// (`assets/shortcuts/versions.json`), instead of a URL baked into the app
/// binary.
///
/// This is what removes the need for a new app build every time the
/// automation changes: overwriting `versions.json` (and, when available, the
/// matching `.shortcut` file) on the site and pushing is enough — whether
/// the new "latest" entry points to a self-hosted file or to a freshly
/// generated iCloud share link. `AppConstants.Shortcuts` still keeps a
/// hardcoded fallback for when the manifest can't be reached at all.
enum ApplePayShortcutManifest {

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let version: String
            let url: URL
        }
        let latest: String
        let versions: [Entry]
    }

    private static let manifestURL = URL(string: "https://nemorisapp.com/assets/shortcuts/versions.json")!

    /// The URL to open to install or update the automation. Any failure
    /// (offline, site unreachable, malformed manifest, unknown `latest` key)
    /// falls back to `AppConstants.Shortcuts.applePayInstallFallbackURL` —
    /// this is a manual, on-demand button tap, it must never be a dead end.
    static func resolveInstallURL() async -> URL {
        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = 5
        // Always re-fetches: the whole point of this manifest is to reflect
        // an update made minutes ago, a stale URLCache entry would defeat it.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
            let entry = manifest.versions.first(where: { $0.version == manifest.latest })
        else {
            return AppConstants.Shortcuts.applePayInstallFallbackURL
        }
        return entry.url
    }
}
