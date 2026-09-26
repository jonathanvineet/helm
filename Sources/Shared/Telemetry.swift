import Foundation
import Darwin
import IOKit.ps

/// Real machine state that drives the engine and systems displays.
struct TelemetrySnapshot {
    var cpu = 0.0
    var mem = 0.0
    var memUsedGB = 0.0
    var memTotalGB = 0.0
    var battery: Double?
    var charging = false
    var onAC = true
    var rxRate = 0.0
    var txRate = 0.0
    var load1 = 0.0
    var cores = ProcessInfo.processInfo.activeProcessorCount
    var thermal: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = 0
    var diskFreeGB = 0.0
    var host = "MAC"
}

final class TelemetrySampler {
    private var lastTicks: [UInt64]?
    private var lastNet: (rx: UInt64, tx: UInt64, at: TimeInterval)?
    private var snapshot = TelemetrySnapshot()
    private var sampleCount = 0

    init() {
        snapshot.host = (Host.current().localizedName ?? "MAC").uppercased()
    }

    func sample() -> TelemetrySnapshot {
        var s = snapshot

        if let ticks = Self.cpuTicks() {
            if let last = lastTicks {
                let d = zip(ticks, last).map { Double($0 &- $1) }
                let total = d.reduce(0, +)
                if total > 0 { s.cpu = (d[0] + d[1] + d[3]) / total }
            }
            lastTicks = ticks
        }

        if let (used, total) = Self.memory() {
            s.memUsedGB = used / 1_073_741_824
            s.memTotalGB = total / 1_073_741_824
            s.mem = total > 0 ? used / total : 0
        }

        let now = ProcessInfo.processInfo.systemUptime
        let (rx, tx) = Self.netBytes()
        if let last = lastNet, now > last.at {
            let dt = now - last.at
            s.rxRate = rx >= last.rx ? Double(rx - last.rx) / dt : 0
            s.txRate = tx >= last.tx ? Double(tx - last.tx) / dt : 0
        }
        lastNet = (rx, tx, now)

        let power = Self.power()
        s.battery = power.level
        s.charging = power.charging
        s.onAC = power.onAC

        var loads = [0.0, 0.0, 0.0]
        if getloadavg(&loads, 3) > 0 { s.load1 = loads[0] }
        s.thermal = ProcessInfo.processInfo.thermalState
        s.uptime = now

        if sampleCount % 15 == 0,
           let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage {
            s.diskFreeGB = Double(free) / 1_000_000_000
        }
        sampleCount += 1

        snapshot = s
        return s
    }

    /// user, system, idle, nice ticks summed over all cores.
    private static func cpuTicks() -> [UInt64]? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)]
    }

    /// Same notion of "used" as Activity Monitor: app + wired + compressed.
    private static func memory() -> (Double, Double)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let page = Double(sysconf(_SC_PAGESIZE))
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        return (used, Double(ProcessInfo.processInfo.physicalMemory))
    }

    private static func netBytes() -> (UInt64, UInt64) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data else { continue }
            if String(cString: ifa.ifa_name).hasPrefix("lo") { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(d.ifi_ibytes)
            tx += UInt64(d.ifi_obytes)
        }
        return (rx, tx)
    }

    private static func power() -> (level: Double?, charging: Bool, onAC: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false, true)
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Double ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Double ?? 100
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (max > 0 ? current / max : nil, charging, onAC)
        }
        return (nil, false, true)
    }
}

@MainActor
final class Telemetry: ObservableObject {
    @Published private(set) var snapshot = TelemetrySnapshot()
    private let sampler = TelemetrySampler()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        snapshot = sampler.sample()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snapshot = self.sampler.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
