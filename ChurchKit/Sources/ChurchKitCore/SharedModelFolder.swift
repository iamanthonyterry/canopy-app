import Foundation

/// Where downloaded speech models live, shared by Canopy and Transcriber so
/// each model is stored once: `~/Library/Application Support/Church Landing Page/Models`.
/// Both apps are unsandboxed, so a plain folder in Application Support is enough.
public enum SharedModelFolder {
    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static var root: URL { appSupport.appendingPathComponent("Church Landing Page/Models", isDirectory: true) }

    /// WhisperKit's download base. It makes `models/<repo>/<variant>` below this.
    public static var whisper: URL { root.appendingPathComponent("whisper", isDirectory: true) }

    /// Transcriber's folder before models were shared. Read-only for Canopy;
    /// Transcriber moves its contents into `whisper` on first launch.
    public static var legacyTranscriberWhisper: URL { appSupport.appendingPathComponent("Transcriber/Models", isDirectory: true) }

    /// The Whisper folder, created, with any models from the old Transcriber
    /// folder moved in. Cheap to call again: the move only does work once.
    public static func preparedWhisper() -> URL {
        let url = whisper
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        migrate(from: legacyTranscriberWhisper, to: url)
        return url
    }

    /// A model folder is complete when its compiled audio encoder is present.
    public static func isModelFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    /// Finds an already-downloaded Whisper variant, shared folder first. `base` is
    /// the folder WhisperKit should use as its download base: it keeps the
    /// tokenizer beside the model and fetches it from the network if missing, so
    /// the base the model was found under keeps an offline Mac working.
    public static func whisperModel(variant: String, repo: String) -> (folder: URL, base: URL)? {
        for base in [whisper, legacyTranscriberWhisper] {
            let candidates = [
                base.appendingPathComponent("models/\(repo)/\(variant)"),
                base.appendingPathComponent(variant),
            ]
            if let hit = candidates.first(where: isModelFolder) { return (hit, base) }
        }
        return nil
    }

    /// Moves everything from `old` into `new`, merging folders that exist in both
    /// and never overwriting a file already in `new`. `old` is removed once empty.
    /// A move on the same volume is instant, so a 600 MB model doesn't copy.
    /// Safe to run on every launch.
    public static func migrate(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
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
            // A file already in the shared folder stays; the old copy is left behind.
        }
    }

    /// Serializes work between processes, so the app and the helper never download
    /// the same model at once. The lock is released when `body` returns.
    public static func withDownloadLock<T: Sendable>(_ name: String, _ body: @Sendable () async throws -> T) async throws -> T {
        let dir = root.appendingPathComponent(".locks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("\(name).lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try await body() }
        defer { close(fd) }
        // flock blocks, so wait off the calling thread rather than freeze the UI.
        await Task.detached { _ = flock(fd, LOCK_EX) }.value
        defer { flock(fd, LOCK_UN) }
        return try await body()
    }
}
