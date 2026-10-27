#if DEBUG
import AppKit
import QuartzCore

/// DEBUG `--measure`: prints `panel_show_ms=` (hotkey handler → first frame on screen) and `first_results_ms=`
/// (keystroke → first name results rendered). "On screen" = the first display-link tick after the CA commit that
/// carries the change. Targets: ≤ 30 and ≤ 16.
@MainActor
final class Measure {
    static let shared = Measure()
    var enabled = false
    weak var view: NSView?
    private var hotKeyAt: CFTimeInterval?
    private var keyAt: CFTimeInterval?
    private var queryAt: (generation: Int, at: CFTimeInterval)?
    private var waiters: [FrameWaiter] = []
    private(set) var showSamples: [Double] = []
    private(set) var resultSamples: [Double] = []
    /// Model applied → SwiftUI update + CA commit flushed (the "commit" gate, ≤ 12 ms).
    private(set) var commitSamples: [Double] = []
    private var flushedAt: CFTimeInterval = 0

    func hotKeyPressed() {
        guard enabled else { return }
        hotKeyAt = CACurrentMediaTime()
    }

    func keyDown() {
        guard enabled else { return }
        keyAt = CACurrentMediaTime()
    }

    /// Label of the next result samples (the harness tags its cold warm-up keystroke).
    var resultLabel = "first_results_ms"

    func resetResultSamples() {
        resultSamples.removeAll()
        commitSamples.removeAll()
    }

    func panelShown() {
        guard enabled, let t0 = hotKeyAt else { return }
        hotKeyAt = nil
        afterNextFrame { now in
            let ms = (now - t0) * 1000
            self.showSamples.append(ms)
            Self.emit("panel_show_ms=\(String(format: "%.2f", ms))")
        }
    }

    func queryChanged(generation: Int) {
        guard enabled, let t0 = keyAt else { return }
        keyAt = nil
        queryAt = (generation, t0)
    }

    func resultsApplied(generation: Int) {
        guard enabled, let pending = queryAt, pending.generation == generation else { return }
        queryAt = nil
        let tApply = CACurrentMediaTime()
        afterNextFrame { now in
            // Where the time went: key → model applied, SwiftUI update + CA commit, commit → frame tick.
            Self.emit(String(format: "split key_to_apply=%.2f apply_to_commit=%.2f commit_to_frame=%.2f",
                             (tApply - pending.at) * 1000, (self.flushedAt - tApply) * 1000, (now - self.flushedAt) * 1000))
            let ms = (now - pending.at) * 1000
            self.resultSamples.append(ms)
            self.commitSamples.append((self.flushedAt - tApply) * 1000)
            Self.emit("\(self.resultLabel)=\(String(format: "%.2f", ms))")
        }
    }

    private func afterNextFrame(_ body: @escaping (CFTimeInterval) -> Void) {
        guard let view else { return }
        // Commit now so the change is in the next frame, then wait for that frame's tick.
        let t0 = CACurrentMediaTime()
        view.window?.displayIfNeeded()
        let t1 = CACurrentMediaTime()
        CATransaction.flush()
        flushedAt = CACurrentMediaTime()
        if ProcessInfo.processInfo.environment["BS_COMMIT_SPLIT"] == "1" {
            Self.emit(String(format: "commit_split display=%.2f flush=%.2f", (t1 - t0) * 1000, (flushedAt - t1) * 1000))
        }
        let waiter = FrameWaiter { [weak self] waiter, now in
            body(now)
            self?.waiters.removeAll { $0 === waiter }
        }
        waiters.append(waiter)
        waiter.start(on: view)
    }

    static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// User + system CPU seconds of this process.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    /// `phys_footprint` of this process in MB (what Activity Monitor shows as Memory).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : .nan
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}

/// One-shot display-link callback (the view's own display, so the tick matches its screen's refresh).
@MainActor
private final class FrameWaiter: NSObject {
    private var link: CADisplayLink?
    private let done: (FrameWaiter, CFTimeInterval) -> Void

    init(_ done: @escaping (FrameWaiter, CFTimeInterval) -> Void) {
        self.done = done
    }

    func start(on view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        link.invalidate()
        self.link = nil
        done(self, CACurrentMediaTime())
    }
}
#endif
