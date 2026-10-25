import Foundation

/// The app's on-disk homes, so every store spells the `Kite/…` folder once.
enum KiteDirectories {
    /// `~/Library/Application Support/Kite/<sub>`, created on first use.
    static func applicationSupport(_ sub: String? = nil) -> URL {
        directory(for: .applicationSupportDirectory, sub: sub)
    }

    /// `~/Library/Caches/Kite/<sub>`, created on first use.
    static func caches(_ sub: String? = nil) -> URL {
        directory(for: .cachesDirectory, sub: sub)
    }

    private static func directory(for base: FileManager.SearchPathDirectory, sub: String?) -> URL {
        var url = FileManager.default.urls(for: base, in: .userDomainMask)[0]
            .appendingPathComponent("Kite", isDirectory: true)
        if let sub { url.appendPathComponent(sub, isDirectory: true) }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
