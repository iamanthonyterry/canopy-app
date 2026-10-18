import Foundation

/// Where speech models live. Shared with Canopy so each model is stored once:
/// `~/Library/Application Support/Church Landing Page/Models/whisper`. Macs set
/// up before this had them in `Transcriber/Models`; the first launch moves them.
enum ModelFolder {
    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var legacy: URL { appSupport.appendingPathComponent("Transcriber/Models", isDirectory: true) }

    /// The shared folder, created on first use after any old one has been moved in.
    static let root: URL = {
        let url = appSupport.appendingPathComponent("Church Landing Page/Models/whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        migrate(from: legacy, to: url)
        return url
    }()

    /// Moves everything from `old` into `new`, merging folders that exist in both
    /// and never overwriting a file already in `new` (Canopy may have put its own
    /// copy there). `old` is removed once it is empty. A move on the same volume
    /// is instant, so a 600 MB model doesn't copy. Safe to run on every launch.
    static func migrate(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        merge(old, into: new, fm)
        if (try? fm.contentsOfDirectory(atPath: old.path))?.isEmpty ?? false {
            try? fm.removeItem(at: old)
        }
    }

    private static func merge(_ source: URL, into dest: URL, _ fm: FileManager) {
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        for item in items {
            let target = dest.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: item, to: target)
            } else if isDir {
                merge(item, into: target, fm)
                if (try? fm.contentsOfDirectory(atPath: item.path))?.isEmpty ?? false { try? fm.removeItem(at: item) }
            }
            // A file that already exists in the shared folder stays; the old copy is left behind.
        }
    }
}
