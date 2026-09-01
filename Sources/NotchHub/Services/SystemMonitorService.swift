import Combine
import Darwin
import Foundation

/// Live system health: CPU load, memory pressure, and disk usage — all via
/// public Mach / BSD APIs (no private frameworks, no permissions).
///
/// Mirrors MacNotch's `SystemMonitorService`. CPU is computed as a delta of
/// cumulative host CPU ticks between samples (an instantaneous read is
/// meaningless); memory uses `host_statistics64` vm counters; disk uses the
/// resource-values API on the home volume.
final class SystemMonitorService: ObservableObject {

    /// 0…1 fraction of CPU in use across all cores.
    @Published private(set) var cpuUsage: Double = 0
    /// 0…1 fraction of physical RAM in use ("used" = active + wired + compressed).
    @Published private(set) var memoryUsage: Double = 0
    /// 0…1 fraction of the boot volume consumed.
    @Published private(set) var diskUsage: Double = 0

    @Published private(set) var memoryUsedGB: Double = 0
    @Published private(set) var memoryTotalGB: Double = 0
    @Published private(set) var diskFreeGB: Double = 0

    private var timer: Timer?
    private var previousCPUTicks: host_cpu_load_info?
    private let totalRAM = Double(ProcessInfo.processInfo.physicalMemory)
    /// Guards against overlapping off-main disk reads.
    private var diskInFlight = false
    /// Counts samples so the disk read can run on a slower cadence than the
    /// cheap CPU and memory reads.
    private var sampleCount = 0

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        cpuUsage = readCPU() ?? cpuUsage
        readMemory()
        sampleDiskIfDue()
    }

    /// The CPU and memory reads are cheap Mach calls and stay on the main thread,
    /// but the disk read touches the filesystem — it used to hitch the main
    /// thread every 2s, including as the notch opened. Disk usage changes
    /// slowly, so read it off the main thread and only every ~10s (every fifth
    /// 2s sample). Published values are still assigned on the main thread.
    private func sampleDiskIfDue() {
        defer { sampleCount += 1 }
        guard sampleCount % 5 == 0, !diskInFlight else { return }
        diskInFlight = true
        DispatchQueue.global(qos: .utility).async {
            let capacity = Self.homeVolumeCapacity()
            DispatchQueue.main.async { [weak self] in
                self?.applyDiskCapacity(capacity)
            }
        }
    }

    private func applyDiskCapacity(_ capacity: (total: Double, free: Double)?) {
        diskInFlight = false
        guard let capacity,
              let metrics = Self.diskMetrics(total: capacity.total, free: capacity.free)
        else { return }
        diskUsage = metrics.usage
        diskFreeGB = metrics.freeGB
    }

    // MARK: - CPU

    /// Ticks elapsed between two samples of a Mach CPU counter.
    ///
    /// `cpu_ticks` entries are `natural_t` (UInt32) and wrap roughly every
    /// 20–60 days of uptime depending on core count. Plain `-` would trap on
    /// that wrap and kill the app; wrapping subtraction yields the correct
    /// delta, because far fewer than 2^32 ticks elapse between two samples
    /// taken two seconds apart.
    static func tickDelta(_ current: natural_t, _ previous: natural_t) -> Double {
        Double(current &- previous)
    }

    /// Runs `body` with a host port and releases the send right afterwards.
    ///
    /// `mach_host_self()` returns a *new* send right on every call — unlike
    /// `mach_task_self()` — so a long-running sampler that never deallocates
    /// leaks kernel resources for the life of the process.
    private static func withHostPort<T>(_ body: (mach_port_t) -> T) -> T {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        return body(host)
    }

    private func readCPU() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = Self.withHostPort { host in
            withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
                }
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        defer { previousCPUTicks = info }
        guard let prev = previousCPUTicks else { return nil }

        let user = Self.tickDelta(info.cpu_ticks.0, prev.cpu_ticks.0)
        let system = Self.tickDelta(info.cpu_ticks.1, prev.cpu_ticks.1)
        let idle = Self.tickDelta(info.cpu_ticks.2, prev.cpu_ticks.2)
        let nice = Self.tickDelta(info.cpu_ticks.3, prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return (user + system + nice) / total
    }

    // MARK: - Memory

    private func readMemory() {
        guard let used = Self.usedMemoryBytes() else { return }
        memoryUsedGB = Double(used) / 1_073_741_824
        memoryTotalGB = totalRAM / 1_073_741_824
        memoryUsage = totalRAM > 0 ? min(Double(used) / totalRAM, 1) : 0
    }

    /// Raw `vm_statistics64` sample, shared by the monitor and the RAM cleaner.
    static func vmSnapshot() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withHostPort { host in
            withUnsafeMutablePointer(to: &stats) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    host_statistics64(host, HOST_VM_INFO64, $0, &count)
                }
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// Bytes in use = active + wired + compressed.
    static func usedMemoryBytes() -> UInt64? {
        guard let snapshot = vmSnapshot() else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(snapshot.active_count) + UInt64(snapshot.wire_count)
            + UInt64(snapshot.compressor_page_count)) * pageSize
    }

    // MARK: - Disk

    /// Total and available capacity of the home volume, in bytes.
    ///
    /// `nonisolated static` so the filesystem read runs on a background queue
    /// (see `sampleDiskIfDue`) and returns a `Sendable` value.
    static func homeVolumeCapacity() -> (total: Double, free: Double)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]) else { return nil }

        let total = Double(values.volumeTotalCapacity ?? 0)
        let free = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
        return (total, free)
    }

    /// Used fraction and free gigabytes from a raw capacity sample. Pure, so the
    /// arithmetic — including the divide-by-zero guard — is unit-tested directly.
    static func diskMetrics(total: Double, free: Double) -> (usage: Double, freeGB: Double)? {
        guard total > 0 else { return nil }
        // Clamp to 0...1: `volumeAvailableCapacityForImportantUsage` counts
        // purgeable space, so it can exceed raw free space (a negative "used")
        // or be negative under pressure, and a bar wants a real fraction.
        let usage = min(max((total - free) / total, 0), 1)
        let freeGB = free / 1_073_741_824
        return (usage, freeGB)
    }
}
