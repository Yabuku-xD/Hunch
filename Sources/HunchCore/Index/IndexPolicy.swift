import Foundation

/// K18: one answer to "may background indexing run now?", shared by the coordinator's name-embedding loop and the
/// content pipeline's lanes. Low Power Mode or thermal state serious+ pauses everything; on battery, or outside the
/// optional hours window, the deferrable tiers (T2 images/OCR, T3 audio/video) wait. Tests inject closures.
public struct IndexPolicy: Sendable {
    public var lowPower: @Sendable () -> Bool
    public var thermalSerious: @Sendable () -> Bool
    public var onBattery: @Sendable () -> Bool
    /// Local hours in which T2/T3 may run: `from` through `to` inclusive (0–23); `from > to` wraps past midnight
    /// (22 → 6). nil = any time.
    public struct Hours: Sendable, Equatable {
        public var from: Int, to: Int
        public init(from: Int, to: Int) { self.from = from; self.to = to }
    }
    public var hours: Hours?
    public var now: @Sendable () -> Date
    /// Seconds before a single file's read is abandoned and the file marked unreadable.
    public var watchdog: @Sendable (ContentTier) -> Double

    public init(
        lowPower: @escaping @Sendable () -> Bool, thermalSerious: @escaping @Sendable () -> Bool,
        onBattery: @escaping @Sendable () -> Bool, hours: Hours? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        watchdog: @escaping @Sendable (ContentTier) -> Double = { $0 == .media ? 1800 : 20 }
    ) {
        self.lowPower = lowPower
        self.thermalSerious = thermalSerious
        self.onBattery = onBattery
        self.hours = hours
        self.now = now
        self.watchdog = watchdog
    }

    /// The Mac's real power and thermal state.
    public static let system = IndexPolicy(
        lowPower: { ProcessInfo.processInfo.isLowPowerModeEnabled },
        thermalSerious: { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue },
        onBattery: { ContentIndexPipeline.isOnBattery() })

    /// Runs regardless of power state (tests, benchmarks).
    public static let always = IndexPolicy(lowPower: { false }, thermalSerious: { false }, onBattery: { false })

    /// Everything waits (name embedding, every content tier).
    public var pausesAll: Bool { lowPower() || thermalSerious() }

    /// Whether `tier` may run now. T0/T1 only stop for `pausesAll`; T2/T3 also for battery and the hours window.
    public func allows(_ tier: ContentTier) -> Bool {
        if pausesAll { return false }
        switch tier {
        case .names, .documents: return true
        case .images, .media: return !onBattery() && insideHours
        }
    }

    var insideHours: Bool {
        guard let hours else { return true }
        let h = Calendar.current.component(.hour, from: now())
        return hours.from <= hours.to ? (hours.from...hours.to).contains(h) : (h >= hours.from || h <= hours.to)
    }
}
