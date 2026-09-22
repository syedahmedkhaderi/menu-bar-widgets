import AppKit
import Darwin
import IOKit
import IOKit.ps

// MARK: - CPU

enum CoreKind { case efficiency, performance, unknown }

struct CPUSample {
    var total: Double = 0        // 0...1
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []
    var efficiencyAvg: Double?
    var performanceAvg: Double?
}

final class CPUReader {
    let coreKinds: [CoreKind]
    let performanceName: String   // "Performance", or "Super" on M5
    private var prevTotal: host_cpu_load_info?
    private var prevCores: [[UInt32]] = []

    init() {
        coreKinds = CPUReader.readCoreKinds()
        performanceName = sysctlString("hw.perflevel0.name") ?? "Performance"
    }

    func sample() -> CPUSample {
        var s = CPUSample()

        if let info = hostCPULoadInfo() {
            if let prev = prevTotal {
                let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
                let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
                let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
                let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
                let all = user + system + idle + nice
                if all > 0 {
                    s.user = (user + nice) / all
                    s.system = system / all
                    s.total = min(1, s.user + s.system)
                }
            }
            prevTotal = info
        }

        let cores = perCoreTicks()
        if cores.count == prevCores.count {
            for (now, prev) in zip(cores, prevCores) {
                let used = Double((now[0] &- prev[0]) &+ (now[1] &- prev[1]) &+ (now[3] &- prev[3]))
                let idle = Double(now[2] &- prev[2])
                s.perCore.append(used + idle > 0 ? min(1, used / (used + idle)) : 0)
            }
        }
        prevCores = cores

        if s.perCore.count == coreKinds.count {
            func avg(_ kind: CoreKind) -> Double? {
                let v = zip(s.perCore, coreKinds).filter { $0.1 == kind }.map { $0.0 }
                return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
            }
            s.efficiencyAvg = avg(.efficiency)
            s.performanceAvg = avg(.performance)
        }
        return s
    }

    private func hostCPULoadInfo() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// Per core: [user, system, idle, nice] tick counters.
    private func perCoreTicks() -> [[UInt32]] {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(numCPUs)).map { i in
            (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[i * Int(CPU_STATE_MAX) + $0]) }
        }
    }

    /// Core types from the device tree ("cluster-type" = "E" / "P"), indexed by logical CPU id.
    private static func readCoreKinds() -> [CoreKind] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var iterator = io_iterator_t()
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var kinds: [Int: CoreKind] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let id = IORegistryEntryCreateCFProperty(entry, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int else { continue }
            let data = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
            switch data?.first {
            case UInt8(ascii: "E"): kinds[id] = .efficiency
            case UInt8(ascii: "P"): kinds[id] = .performance
            default: kinds[id] = .unknown
            }
        }
        return (0..<kinds.count).map { kinds[$0] ?? .unknown }
    }
}

// MARK: - Memory

enum MemoryPressure: String { case normal = "Normal", warning = "Warning", critical = "Critical" }

struct MemorySample {
    var total: Double = 0
    var used: Double = 0
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var swapUsed: Double = 0
    var swapTotal: Double = 0
    var pressure: MemoryPressure = .normal
    var usage: Double { total > 0 ? used / total : 0 }
}

final class MemoryReader {
    private let total = Double(ProcessInfo.processInfo.physicalMemory)

    func sample() -> MemorySample {
        var s = MemorySample(total: total)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            let active = Double(stats.active_count) * page
            let inactive = Double(stats.inactive_count) * page
            let speculative = Double(stats.speculative_count) * page
            let wired = Double(stats.wire_count) * page
            let compressed = Double(stats.compressor_page_count) * page
            let purgeable = Double(stats.purgeable_count) * page
            let external = Double(stats.external_page_count) * page
            s.used = active + inactive + speculative + wired + compressed - purgeable - external
            s.wired = wired
            s.compressed = compressed
            s.app = max(0, s.used - wired - compressed)
            s.cached = purgeable + external
        }

        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            s.pressure = level >= 4 ? .critical : level >= 2 ? .warning : .normal
        }

        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = Double(swap.xsu_used)
            s.swapTotal = Double(swap.xsu_total)
        }
        return s
    }
}

// MARK: - Battery

struct BatterySample {
    var present = false
    var level: Double = 0            // 0...1
    var isCharging = false
    var isCharged = false
    var onAC = false
    var minutesRemaining: Int?       // to empty on battery, to full when charging
    var health: Int?
    var cycles: Int?
    var designCapacity: Int?         // mAh
    var maxCapacity: Int?            // mAh
    var temperature: Double?         // °C
    var voltage: Double?             // V
    var amperage: Double?            // A, negative = discharging
    var adapterWatts: Int?

    var power: Double? {
        guard let v = voltage, let a = amperage else { return nil }
        return v * a
    }

    var statusText: String {
        if !present { return "No battery" }
        if isCharged { return "Fully charged" }
        if isCharging { return "Charging" }
        if onAC { return "Plugged in, not charging" }
        return "On battery"
    }
}

final class BatteryReader {
    func sample() -> BatterySample {
        var s = BatterySample()

        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        if let d = descriptions.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) {
            s.present = true
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            s.level = max > 0 ? Double(current) / Double(max) : 0
            s.onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            s.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            s.isCharged = d[kIOPSIsChargedKey] as? Bool ?? false
            let minutes = (s.isCharging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int ?? -1
            s.minutesRemaining = minutes > 0 ? minutes : nil
        }

        if let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            s.adapterWatts = details[kIOPSPowerAdapterWattsKey] as? Int
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return s }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return s }

        // Values like Amperage are signed but stored as unsigned 64-bit; read the raw bit pattern.
        func int(_ key: String) -> Int? { (dict[key] as? NSNumber).map { Int($0.int64Value) } }

        s.cycles = int("CycleCount")
        s.designCapacity = int("DesignCapacity")
        s.maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        if let max = s.maxCapacity, let design = s.designCapacity, design > 0 {
            s.health = min(100, Int((Double(max) * 100 / Double(design)).rounded()))
        }
        s.temperature = int("Temperature").map { Double($0) / 100 }
        s.voltage = int("Voltage").map { Double($0) / 1000 }
        s.amperage = (int("InstantAmperage") ?? int("Amperage")).map { Double($0) / 1000 }
        return s
    }
}

// MARK: - Processes

struct TopProcess: Identifiable {
    let pid: Int
    let name: String
    let cpu: Double      // percent of one core
    let memory: Double   // bytes (resident)
    var id: Int { pid }
}

enum ProcessReader {
    /// Snapshot of all processes via /bin/ps (setuid, so it sees every user's processes).
    static func snapshot() -> [TopProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]) else { return nil }
            let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")) ?? 0
            let rssKB = Double(parts[2]) ?? 0
            var name = String(parts[3])
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)), let n = app.localizedName { name = n }
            return TopProcess(pid: pid, name: name, cpu: cpu, memory: rssKB * 1024)
        }
    }
}

// MARK: - Misc

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

func bootTime() -> Date? {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
}

func loadAverages() -> [Double] {
    var loads = [Double](repeating: 0, count: 3)
    return getloadavg(&loads, 3) == 3 ? loads : []
}
