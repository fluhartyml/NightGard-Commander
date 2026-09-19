//
//  JobGovernor.swift
//  NightGard Commander
//
//  Created by Michael Fluharty with Claude on 2026 Sep 19
//
//  Keeps the Mac stable while bars run — build 76. His spec, 2026-09-18:
//  "is there a govoner or regulator to keep the mac stable?" · "it needs to say system
//  unstable; paused untill system becomes stable again or similar" · "the pause warning
//  should be on each status bar and the user can override and resumw at their own rish".
//  And 2026-09-19, when the bars became one per top-level folder, all started at once:
//  "all at once but i can pause them ... and the govoner can and gives stability warnings".
//
//  WHAT COUNTS AS UNSTABLE — only things macOS reports directly, never a guess:
//   • memory pressure at warning or critical
//   • the Mac running hot (thermal state serious or critical)
//   • the battery at 10% or less and not plugged in
//   • a bar's target drive with less than 2 GB free (pauses only the bars writing there)
//  ⚠️ Claude's pick, 2026-09-19, from the candidates in the notes — his to change.
//  Not included: a network drive that stopped answering. A check on a dead share can hang,
//  and the copy itself already stops and asks when a drive goes away.
//
//  THE RULES:
//   • It pauses with the bar's own Pause — no second mechanism.
//   • ⛔ A pause HE made is never resumed by the governor.
//   • When things are stable again it resumes its own pauses ONE AT A TIME, each after
//     things have held steady for 10 seconds — his manual method on 2026-09-18: "i can
//     pause them all and let them resume one at a time".
//   • "Resume at Your Own Risk" runs a bar anyway; it is not paused again for the same
//     condition, only for a new one.
//

import Foundation
import IOKit.ps
import Observation

@MainActor
@Observable
final class JobGovernor {

    nonisolated struct Condition: Hashable, Sendable {
        let key: String
        /// Finishes the sentence "System unstable — …".
        let text: String
        /// Nil = the whole Mac. Otherwise only bars writing to this volume.
        let volume: String?
    }

    /// What is wrong right now. Empty = stable.
    private(set) var conditions: [Condition] = []
    var isUnstable: Bool { !conditions.isEmpty }
    var reasonText: String { conditions.map(\.text).joined(separator: " · ") }

    @ObservationIgnored weak var controller: FileOperationController?
    /// For the self-test only: conditions added as if macOS had reported them. Nothing in
    /// the app sets it. A policy that cannot be tested in seconds is a guess.
    @ObservationIgnored var injectedForTest: [Condition] = []

    @ObservationIgnored private var memoryLevel: DispatchSource.MemoryPressureEvent = .normal
    @ObservationIgnored private var memorySource: DispatchSourceMemoryPressure?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var diskConditions: [Condition] = []
    /// Bar target path → the volume it is on, filled in off the main thread.
    @ObservationIgnored private var targetVolumes: [String: String] = [:]
    @ObservationIgnored private var diskCheckRunning = false
    @ObservationIgnored private var lastChange = Date.distantPast
    @ObservationIgnored private var lastResume = Date.distantPast
    @ObservationIgnored private var ticks = 0

    nonisolated static let settleSeconds: TimeInterval = 10
    nonisolated static let lowDiskBytes: Int64 = 2_000_000_000
    nonisolated static let lowBatteryPercent = 10

    // MARK: - Running only while bars do

    func startIfNeeded() {
        guard timer == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let data = self.memorySource?.data else { return }
                self.memoryLevel = data
                self.tick()
            }
        }
        source.resume()
        memorySource = source
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        memorySource?.cancel()
        memorySource = nil
        memoryLevel = .normal
        diskConditions = []
        targetVolumes = [:]
        conditions = []
    }

    // MARK: - Every 3 seconds

    func tick() {
        guard let controller else { return }
        let jobs = controller.jobs
        if jobs.isEmpty { stop(); return }

        ticks += 1
        if ticks % 3 == 1 { checkDisks(jobs) }

        var now: [Condition] = []
        if memoryLevel.contains(.warning) || memoryLevel.contains(.critical) {
            now.append(Condition(key: "memory", text: "memory is running low", volume: nil))
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            now.append(Condition(key: "heat", text: "the Mac is running hot", volume: nil))
        default:
            break
        }
        if let percent = Self.batteryPercentOnBattery(), percent <= Self.lowBatteryPercent {
            now.append(Condition(key: "battery", text: "the battery is at \(percent)% and not plugged in", volume: nil))
        }
        now += diskConditions
        now += injectedForTest
        if now != conditions {
            conditions = now
            lastChange = Date()
        }

        for job in jobs where !job.control.isCancelled {
            let reasons = reasons(for: job)
            if job.governorPausedFor != nil {
                // Still unstable: keep the bar's wording current.
                if !reasons.isEmpty, reasons != job.governorPausedFor { job.governorPause(for: reasons) }
            } else if !reasons.isEmpty, !job.control.isPaused {
                job.governorPause(for: reasons)
            }
        }

        // Stable again for this bar: resume ONE, and only once things have held steady.
        let clock = Date()
        guard clock.timeIntervalSince(lastChange) >= Self.settleSeconds,
              clock.timeIntervalSince(lastResume) >= Self.settleSeconds else { return }
        if let next = jobs.first(where: { $0.governorPausedFor != nil && reasons(for: $0).isEmpty }) {
            next.governorResume()
            lastResume = clock
        }
    }

    /// The conditions that apply to this bar and that he has not already overridden.
    func reasons(for job: FileOperationJob) -> [Condition] {
        conditions.filter { c in
            guard !job.overridden.contains(c.key) else { return false }
            guard let volume = c.volume else { return true }
            guard let target = job.target?.path else { return false }
            return targetVolumes[target] == volume
        }
    }

    // MARK: - Free space, off the main thread

    private func checkDisks(_ jobs: [FileOperationJob]) {
        guard !diskCheckRunning else { return }   // a dead network share can hang a check
        let targets = Array(Set(jobs.compactMap { $0.target?.path }))
        guard !targets.isEmpty else { diskConditions = []; return }
        diskCheckRunning = true
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.measure(targets) }.value
            guard let self else { return }
            self.targetVolumes = result.volumes
            self.diskConditions = result.low
            self.diskCheckRunning = false
        }
    }

    /// Each target's volume, and the volumes under the free-space floor.
    nonisolated private static func measure(_ targets: [String]) -> (volumes: [String: String], low: [Condition]) {
        var volumes: [String: String] = [:]
        var low: [Condition] = []
        var seen = Set<String>()
        for path in targets {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeAvailableCapacityKey, .volumeNameKey]),
                  let volume = values.volume?.path else { continue }
            volumes[path] = volume
            guard seen.insert(volume).inserted, let free = values.volumeAvailableCapacity else { continue }
            if Int64(free) < lowDiskBytes {
                let name = values.volumeName ?? (volume as NSString).lastPathComponent
                let size = ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)
                low.append(Condition(key: "disk:\(volume)", text: "“\(name)” has only \(size) free", volume: volume))
            }
        }
        return (volumes, low)
    }

    // MARK: - Battery

    /// The internal battery's charge, or nil when plugged in or there is no battery.
    nonisolated static func batteryPercentOnBattery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            guard (d[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue else { return nil }
            if let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return current * 100 / max
            }
        }
        return nil
    }
}
