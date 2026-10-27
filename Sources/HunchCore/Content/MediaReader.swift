import AVFoundation
import CoreGraphics
import Foundation
import Speech

/// Distinct video frames (every 4 s, perceptual-hash dedupe) and on-device transcripts (SpeechAnalyzer).
enum MediaReader {
    static let frameInterval: Double = 4
    /// Videos/audio longer than this are names-only.
    static let maxDuration: Double = 4 * 3600
    /// Hamming distance at or below which two frame hashes count as the same picture.
    static let duplicateBits = 6
    /// Transcript chunk span.
    static let transcriptSpan: Double = 30

    struct Frame {
        var time: Double
        var image: CGImage
    }

    /// Loads duration and track kinds; nil if AVFoundation can't open it.
    static func probe(_ url: URL) async -> (duration: Double, hasVideo: Bool, hasAudio: Bool)? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric,
            let tracks = try? await asset.load(.tracks)
        else { return nil }
        var video = false, audio = false
        for t in tracks {
            if t.mediaType == .video { video = true }
            if t.mediaType == .audio { audio = true }
        }
        return (duration.seconds, video, audio)
    }

    /// Calls `body` for each distinct frame, in time order.
    static func distinctFrames(_ url: URL, duration: Double, body: (Frame) async -> Void) async {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: ImageLoader.maxSide, height: ImageLoader.maxSide)
        // Snap forward to a nearby sync frame (cheap decode) but never before the requested time.
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let times = stride(from: 0, to: max(duration, 0.001), by: frameInterval).map {
            CMTime(seconds: $0, preferredTimescale: 600)
        }
        var last: ImageLoader.Signature?
        for await result in gen.images(for: times) {
            if Task.isCancelled { return }
            guard let image = try? result.image else { continue }
            let sig = ImageLoader.signature(image)
            if let last, last.isNear(sig, bits: duplicateBits) { continue }
            last = sig
            let t = (try? result.actualTime.seconds) ?? result.requestedTime.seconds
            await body(Frame(time: t.isFinite ? t : result.requestedTime.seconds, image: image))
        }
    }

    // MARK: Speech

    /// Why transcription can't run, or nil when it can.
    static func speechUnavailableReason(locale: Locale = .current) async -> String? {
        guard SpeechTranscriber.isAvailable else { return "SpeechTranscriber is not available on this Mac" }
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return "no speech model supports \(locale.identifier)"
        }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == loc.identifier(.bcp47) }) else {
            return "speech model for \(loc.identifier) is not installed"
        }
        return nil
    }

    /// Timed transcript chunks (~30 s each), or a reason it couldn't run.
    static func transcribe(_ url: URL, locale: Locale = .current) async -> Result<[ExtractedChunk], TranscriptFailure> {
        if let reason = await speechUnavailableReason(locale: locale) { return .failure(.unavailable(reason)) }
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            return .failure(.unavailable("unsupported locale"))
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { return .failure(.unreadable) }
        guard file.length > 0 else { return .success([]) }
        let transcriber = SpeechTranscriber(
            locale: loc, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [])
        var pieces: [(start: Double, text: String)] = []
        do {
            let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
            for try await r in transcriber.results {
                let s = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !s.isEmpty else { continue }
                let start = r.range.start.seconds
                pieces.append((start.isFinite ? start : 0, s))
            }
            _ = analyzer
        } catch {
            return pieces.isEmpty ? .failure(.unreadable) : .success(group(pieces))
        }
        return .success(group(pieces))
    }

    enum TranscriptFailure: Error {
        case unavailable(String)
        case unreadable
    }

    /// Joins results into chunks spanning ≤ 30 s (and ≤ 1,000 characters), keeping each chunk's start time.
    static func group(_ pieces: [(start: Double, text: String)]) -> [ExtractedChunk] {
        var out: [ExtractedChunk] = []
        var text = ""
        var start = 0.0
        for p in pieces.sorted(by: { $0.start < $1.start }) {
            if !text.isEmpty,
                p.start - start >= transcriptSpan || text.utf16.count + p.text.utf16.count > TextChunker.size
            {
                out.append(ExtractedChunk(kind: .transcript, text: text, location: ContentLocation(time: start)))
                text = ""
            }
            if text.isEmpty { start = p.start }
            text += text.isEmpty ? p.text : " " + p.text
        }
        if !text.isEmpty {
            out.append(ExtractedChunk(kind: .transcript, text: text, location: ContentLocation(time: start)))
        }
        return out
    }
}
