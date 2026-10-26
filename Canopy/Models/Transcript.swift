import Foundation
import CryptoKit

// MARK: - Transcript
// Timed text for one video. Kept in Canopy's own folder (see `cacheURL`) so later
// steps (clip finding, captions) can read it without re-running speech
// recognition, without leaving files next to the footage. A `.transcript.json`
// beside the clip, from before transcripts moved, is still read.

struct TranscriptWord: Codable, Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var words: [TranscriptWord] = []
}

struct Transcript: Codable, Hashable {
    var sourceFileName: String
    var locale: String
    var duration: TimeInterval
    var segments: [TranscriptSegment]

    var fullText: String { segments.map(\.text).joined(separator: " ") }

    // MARK: Sidecar files

    static let sidecarSuffix = ".transcript.json"

    static func sidecarURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("transcript.json")
    }

    static func srtURL(for video: URL) -> URL {
        video.deletingPathExtension().appendingPathExtension("srt")
    }

    // MARK: Canopy's transcript folder

    /// Transcripts live in Application Support, not beside the footage.
    static var cacheFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Canopy/Transcripts", isDirectory: true)
    }

    /// Where a video's transcript is kept: a folder per source folder (so two decks that both
    /// make "Clip0001" don't share one), then the clip's name.
    static func cacheURL(for video: URL) -> URL {
        let folder = video.deletingLastPathComponent().standardizedFileURL.path
        let key = SHA256.hash(data: Data(folder.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return cacheFolder.appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(video.deletingPathExtension().lastPathComponent + sidecarSuffix)
    }

    /// Output folders a step makes next to the source, whose clips share the source's name.
    private static let derivedFolders: Set<String> = ["Converted", "Reframed"]

    static func load(for video: URL) -> Transcript? {
        var candidates = [video]
        let parent = video.deletingLastPathComponent()
        if derivedFolders.contains(parent.lastPathComponent) {
            candidates.append(parent.deletingLastPathComponent().appendingPathComponent(video.lastPathComponent))
        }
        for candidate in candidates {
            for url in [cacheURL(for: candidate), sidecarURL(for: candidate)] {
                if let data = try? Data(contentsOf: url), let transcript = try? JSONDecoder().decode(Transcript.self, from: data) {
                    return transcript
                }
            }
        }
        return nil
    }

    func write(for video: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = Self.cacheURL(for: video)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
        Self.pruneOnce()
    }

    /// Drops transcripts nobody has needed for two months, once per launch, so the folder doesn't grow forever.
    private static let pruneOnce: () -> Void = {
        var done = false
        return {
            guard !done else { return }
            done = true
            let cutoff = Date().addingTimeInterval(-60 * 24 * 3600)
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let files = FileManager.default.enumerator(at: cacheFolder, includingPropertiesForKeys: keys) else { return }
            for case let file as URL in files where file.lastPathComponent.hasSuffix(sidecarSuffix) {
                if let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate, modified < cutoff {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }()

    func writeSRT(for video: URL) throws {
        try srt.write(to: Self.srtURL(for: video), atomically: true, encoding: .utf8)
    }

    // MARK: SRT

    var srt: String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(Self.srtTime(segment.start)) --> \(Self.srtTime(segment.end))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }

    private static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
