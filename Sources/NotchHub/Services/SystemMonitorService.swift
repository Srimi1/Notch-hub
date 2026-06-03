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
        readDisk()
    }

    // MARK: - CPU

    private func readCPU() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        defer { previousCPUTicks = info }
        guard let prev = previousCPUTicks else { return nil }

        let user = Double(info.cpu_ticks.0 - prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 - prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 - prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 - prev.cpu_ticks.3)
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
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// Bytes in use = active + wired + compressed.
    static func usedMemoryBytes() -> UInt64? {
        guard let s = vmSnapshot() else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(s.active_count) + UInt64(s.wire_count) + UInt64(s.compressor_page_count)) * pageSize
    }

    /// App memory = active + wired — the working set of running apps (the part
    /// `purge` deliberately leaves untouched).
    static func appBytes() -> UInt64? {
        guard let s = vmSnapshot() else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(s.active_count) + UInt64(s.wire_count)) * pageSize
    }

    /// Cached / reclaimable file-backed memory = inactive + speculative +
    /// purgeable — the pages `purge` actually flushes back to free.
    static func cachedBytes() -> UInt64? {
        guard let s = vmSnapshot() else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        return (UInt64(s.inactive_count) + UInt64(s.speculative_count) + UInt64(s.purgeable_count)) * pageSize
    }

    /// Footprint of the memory compressor — pages occupied by compressed data.
    /// This counts as "used" memory in Activity Monitor.
    static func compressedBytes() -> UInt64? {
        guard let s = vmSnapshot() else { return nil }
        return UInt64(s.compressor_page_count) * UInt64(vm_kernel_page_size)
    }

    /// Swap currently in use, via BSD `sysctl vm.swapusage` → xsw_usage.xsu_used.
    static func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let ok = sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0
        return ok ? usage.xsu_used : nil
    }

    // MARK: - Disk

    private func readDisk() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]) else { return }

        let total = Double(values.volumeTotalCapacity ?? 0)
        let free = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
        guard total > 0 else { return }
        diskFreeGB = free / 1_073_741_824
        diskUsage = min((total - free) / total, 1)
    }
}
