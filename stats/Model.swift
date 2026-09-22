import Foundation
import Combine

final class Model: ObservableObject {
    static let historyLength = 60

    /// Always-current readings for the menu bar. The @Published copies below feed the
    /// dropdown and are only updated while it is open, so SwiftUI stays idle otherwise.
    private(set) var latestCPU = CPUSample()
    private(set) var latestMemory = MemorySample()
    private(set) var latestBattery = BatterySample()
    private var latestCPUHistory: [Double] = []
    private var latestMemoryHistory: [Double] = []
    private var isVisible = false
    private var tickCount = 0

    @Published var cpu = CPUSample()
    @Published var memory = MemorySample()
    @Published var battery = BatterySample()
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var loads: [Double] = []
    @Published var topByCPU: [TopProcess] = []
    @Published var topByMemory: [TopProcess] = []

    @Published var showCPU: Bool { didSet { defaults.set(showCPU, forKey: "showCPU"); onDisplayChange?() } }
    @Published var showMemory: Bool { didSet { defaults.set(showMemory, forKey: "showMemory"); onDisplayChange?() } }
    @Published var showBattery: Bool { didSet { defaults.set(showBattery, forKey: "showBattery"); onDisplayChange?() } }

    /// Called after every sample and whenever the menu bar selection changes.
    var onDisplayChange: (() -> Void)?
    /// Called when the dropdown's content may have changed height (tab switch, process list loaded).
    var onLayoutChange: (() -> Void)?

    let cpuReader = CPUReader()
    private let memoryReader = MemoryReader()
    private let batteryReader = BatteryReader()
    private let processQueue = DispatchQueue(label: "sysmeter.processes", qos: .utility)
    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var processTimer: Timer?

    init() {
        defaults.register(defaults: ["showCPU": true, "showMemory": true, "showBattery": true])
        showCPU = defaults.bool(forKey: "showCPU")
        showMemory = defaults.bool(forKey: "showMemory")
        showBattery = defaults.bool(forKey: "showBattery")
    }

    func start() {
        _ = cpuReader.sample()   // prime the tick counters
        tick()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        latestCPU = cpuReader.sample()
        latestMemory = memoryReader.sample()
        // Battery changes slowly and its registry read is the costliest; every 10 s unless the dropdown is open.
        if isVisible || tickCount % 5 == 0 { latestBattery = batteryReader.sample() }
        tickCount += 1
        latestCPUHistory = Array((latestCPUHistory + [latestCPU.total]).suffix(Model.historyLength))
        latestMemoryHistory = Array((latestMemoryHistory + [latestMemory.usage]).suffix(Model.historyLength))
        if isVisible { publish() }
        onDisplayChange?()
    }

    private func publish() {
        cpu = latestCPU
        memory = latestMemory
        battery = latestBattery
        loads = loadAverages()
        cpuHistory = latestCPUHistory
        memoryHistory = latestMemoryHistory
    }

    /// Process lists are only refreshed while the popover is open.
    func setPopoverVisible(_ visible: Bool) {
        isVisible = visible
        processTimer?.invalidate()
        processTimer = nil
        guard visible else { return }
        publish()
        refreshProcesses()
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refreshProcesses() }
        RunLoop.main.add(t, forMode: .common)
        processTimer = t
    }

    private func refreshProcesses() {
        processQueue.async { [weak self] in
            let all = ProcessReader.snapshot()
            let byCPU = Array(all.sorted { $0.cpu > $1.cpu }.prefix(5))
            let byMemory = Array(all.sorted { $0.memory > $1.memory }.prefix(5))
            DispatchQueue.main.async {
                self?.topByCPU = byCPU
                self?.topByMemory = byMemory
                self?.onLayoutChange?()
            }
        }
    }
}
