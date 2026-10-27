import AVFoundation
import AppKit
import HunchCore
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One row's icon. U3: each row observes its own slot, so an icon that arrives re-renders that row's leading
/// column only; a cache-wide revision counter used to re-render every visible row per arrival batch.
/// The icon is a bitmap rasterised off the main thread at the largest size shown (the 48 pt shelf), so a commit
/// only uploads pixels; an `NSImage` here made every commit re-resolve its IconServices rep (≈ 9% of the commit).
@MainActor
@Observable
final class IconSlot {
    fileprivate(set) var image: CGImage?

    fileprivate init(_ image: CGImage?) { self.image = image }
}

/// File icons, loaded off the main thread and cached by path, handed out as per-path observable slots.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, CGImageBox>()
    /// Slots by path. Bounded: past 512, filled slots are dropped (their rows already show the image, and the next
    /// body gets a fresh slot from the cache); empty ones are waiting for an arrival and stay.
    private var slots: [String: IconSlot] = [:]
    private var inFlight = Set<String>()
    private var arrived: [(String, CGImage)] = []
    private let bump = CoalescedBump()

    private init() {
        cache.countLimit = 256
        MemoryPressure.shared.onWarning { [weak self] in self?.cache.removeAllObjects() }
    }

    func cached(_ path: String) -> CGImage? {
        cache.object(forKey: path as NSString)?.image
    }

    /// The slot for an item's icon; starts the off-main load the first time the icon is missing.
    func slot(for item: Item) -> IconSlot {
        let image = cached(item.path)
        if let slot = slots[item.path] {
            if slot.image == nil, let image { slot.image = image }
            if image == nil { request(item) }
            return slot
        }
        if slots.count >= 512 { slots = slots.filter { $0.value.image == nil } }
        let slot = IconSlot(image)
        slots[item.path] = slot
        if image == nil { request(item) }
        return slot
    }

    /// Starts an off-main load unless the icon is cached or already loading.
    func request(_ item: Item) {
        let path = item.path
        guard cached(path) == nil, inFlight.insert(path).inserted else { return }
        let kind = item.kind
        let pixels = Int((48 * DisplayScale.current).rounded(.up))
        Task { [weak self] in
            // Created on a background queue and handed over with `sending` region transfer.
            let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.rasterize(Self.load(path, kind), pixels: pixels))
                }
            }
            guard let self else { return }
            guard let image = loaded else { inFlight.remove(path); return }
            cache.setObject(CGImageBox(image), forKey: path as NSString)
            inFlight.remove(path)
            // Arrivals settle for one frame and land on their slots together.
            arrived.append((path, image))
            bump.schedule {
                for (path, image) in self.arrived { self.slots[path]?.image = image }
                self.arrived.removeAll()
            }
        }
    }

    /// The icon drawn once into a square sRGB bitmap of `pixels` (off the main thread, own graphics context).
    nonisolated private static func rasterize(_ image: NSImage, pixels: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// Missing files fall back to the generic icon for their type, never a blank square.
    nonisolated private static func load(_ path: String, _ kind: ItemKind) -> NSImage {
        let workspace = NSWorkspace.shared
        if FileManager.default.fileExists(atPath: path) {
            // /Applications/Safari.app is a symlink into the system cryptex; its icon would carry the alias badge.
            // Apps show their real icon, like Spotlight and the Dock. Symlinked documents keep the honest badge.
            let resolved = kind == .app ? (path as NSString).resolvingSymlinksInPath : path
            return workspace.icon(forFile: resolved)
        }
        let type: UTType =
            switch kind {
            case .app: .applicationBundle
            case .folder: .folder
            case .file: UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
            }
        return workspace.icon(for: type)
    }
}

/// One row's proof crop (U3, like `IconSlot`).
@MainActor
@Observable
final class ProofSlot {
    fileprivate(set) var image: CGImage?

    fileprivate init(_ image: CGImage?) { self.image = image }
}

/// Proof crops for image, scan and video hits: a square centred on the OCR box or the matched frame, decoded off the
/// main thread to a fixed pixel size (so rows never jump), LRU-cached, purged on memory pressure.
@MainActor
final class ProofCache {
    static let shared = ProofCache()
    private let cache = NSCache<NSString, CGImageBox>()
    private var slots: [String: ProofSlot] = [:]  // bounded like IconCache's
    private var inFlight = Set<String>()
    private var failed = Set<String>()
    private var arrived: [(String, CGImage)] = []
    private let bump = CoalescedBump()

    private init() {
        cache.countLimit = 300
        MemoryPressure.shared.onWarning { [weak self] in self?.cache.removeAllObjects() }
    }

    /// The slot for a result's proof; starts the off-main decode the first time it is missing.
    func slot(for result: SearchResult, points: CGFloat, scale: CGFloat) -> ProofSlot {
        let key = Self.key(result)
        let image = cache.object(forKey: key as NSString)?.image
        let slot: ProofSlot
        if let live = slots[key] {
            if live.image == nil, let image { live.image = image }
            slot = live
        } else {
            if slots.count >= 512 { slots = slots.filter { $0.value.image == nil && inFlight.contains($0.key) } }
            slot = ProofSlot(image)
            slots[key] = slot
        }
        if image == nil { request(result, points: points, scale: scale) }
        return slot
    }

    /// Whether a result gets a proof crop rather than an icon.
    static func wantsProof(_ result: SearchResult) -> Bool {
        guard result.item.kind == .file else { return false }
        switch FileKind.of(result.item.path) {
        case .image, .video: return true
        case .pdf: return result.match?.kind == .ocr || result.match?.location.region != nil
        case .audio, .other: return false
        }
    }

    static func key(_ result: SearchResult) -> String {
        let loc = result.match?.location
        return "\(result.item.path)#\(loc?.page ?? 0)#\(loc?.time ?? -1)#\(loc?.region.map { "\($0.x),\($0.y)" } ?? "")"
    }

    func cached(_ result: SearchResult) -> CGImage? {
        cache.object(forKey: Self.key(result) as NSString)?.image
    }

    func hasFailed(_ result: SearchResult) -> Bool { failed.contains(Self.key(result)) }

    func request(_ result: SearchResult, points: CGFloat, scale: CGFloat) {
        let key = Self.key(result)
        guard cache.object(forKey: key as NSString) == nil, !failed.contains(key), inFlight.insert(key).inserted else {
            return
        }
        let url = URL(fileURLWithPath: result.item.path)
        let location = result.match?.location ?? .whole
        let isVideo = FileKind.of(result.item.path) == .video
        let pixels = Int((points * scale).rounded())
        Task { [weak self] in
            let image: CGImage? =
                if isVideo {
                    await Self.videoFrame(url, at: location.time ?? 0, pixels: pixels, region: location.region)
                } else {
                    await Self.thumbnail(url, pixels: pixels, region: location.region, scale: scale)
                }
            guard let self else { return }
            inFlight.remove(key)
            if let image {
                cache.setObject(CGImageBox(image), forKey: key as NSString)
                arrived.append((key, image))
                bump.schedule {
                    for (key, image) in self.arrived { self.slots[key]?.image = image }
                    self.arrived.removeAll()
                }
            } else {
                failed.insert(key)
            }
        }
    }

    /// QuickLook thumbnail at 3× the proof size, then a square crop around the region (or the centre).
    nonisolated private static func thumbnail(
        _ url: URL, pixels: Int, region: ContentRegion?,
        scale: CGFloat
    ) async -> CGImage? {
        // A text-line box needs the source near full size, or the crop is a blur of a 264 px thumbnail.
        let source = region.map { isTextLine($0) ? max(pixels * 3, 1600) : pixels * 3 } ?? pixels * 3 / 2
        let side = CGFloat(source) / scale
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale,
            representationTypes: .thumbnail)
        let image: CGImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
        guard let image else { return nil }
        return crop(image, around: region, pixels: pixels)
    }

    nonisolated private static func videoFrame(
        _ url: URL, at seconds: Double, pixels: Int,
        region: ContentRegion?
    ) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        let source = region.map { isTextLine($0) ? max(pixels * 4, 1280) : pixels * 4 } ?? pixels * 4
        generator.maximumSize = CGSize(width: source, height: source)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let frame = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else {
            return nil
        }
        return crop(frame, around: region, pixels: pixels)
    }

    /// OCR line boxes are much wider than tall; object boxes (video frames) are not.
    nonisolated private static func isTextLine(_ r: ContentRegion) -> Bool {
        r.width > r.height * 2
    }

    /// Square crop scaled to `pixels`. A text line: sized from the line height (≈ 3 lines tall) and anchored at the
    /// line's start, so the first matched words are legible at 44 pt; a square that fits the whole line would shrink
    /// the text to a few pixels. Other regions: centred, at least as big as the box. No region: the centred square.
    nonisolated private static func crop(_ image: CGImage, around region: ContentRegion?, pixels: Int) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var side = min(w, h)
        var cx = w / 2, cy = h / 2
        if let region, isTextLine(region) {
            side = min(min(w, h), max(region.height * h * 3.2, CGFloat(pixels), min(w, h) * 0.08))
            cx = region.x * w - side * 0.06 + side / 2
            cy = (region.y + region.height / 2) * h
        } else if let region {
            cx = (region.x + region.width / 2) * w
            cy = (region.y + region.height / 2) * h
            side = min(min(w, h), max(region.width * w, region.height * h, min(w, h) * 0.35) * 1.3)
        }
        let originX = min(max(0, cx - side / 2), w - side)
        let originY = min(max(0, cy - side / 2), h - side)
        guard let cropped = image.cropping(to: CGRect(x: originX, y: originY, width: side, height: side).integral),
            let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        return context.makeImage()
    }
}

/// One main-thread pass per frame for any number of arrivals: nine icons landing one by one after a keystroke were
/// nine SwiftUI updates, the first of them usually before the results' own frame had been drawn. Arrivals settle for
/// one frame and land on their slots together.
@MainActor
final class CoalescedBump {
    private var pending: Task<Void, Never>?

    func schedule(_ body: @escaping @MainActor () -> Void) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            self?.pending = nil
            body()
        }
    }
}

/// NSCache needs a class value.
private final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Drops caches on memory pressure warnings.
@MainActor
final class MemoryPressure {
    static let shared = MemoryPressure()
    private var handlers: [() -> Void] = []
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    private init() {
        source.setEventHandler {
            MainActor.assumeIsolated { MemoryPressure.shared.handlers.forEach { $0() } }
        }
        source.activate()
    }

    func onWarning(_ handler: @escaping () -> Void) {
        handlers.append(handler)
    }
}
