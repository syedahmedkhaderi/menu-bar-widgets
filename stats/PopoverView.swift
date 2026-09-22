import SwiftUI

struct PopoverView: View {
    enum Tab: String, CaseIterable { case cpu = "CPU", memory = "Memory", battery = "Battery" }

    @ObservedObject var model: Model
    @AppStorage("selectedTab") private var tab: Tab = .cpu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases.filter { $0 != .battery || model.battery.present }, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: tab) { model.onLayoutChange?() }

            switch tab {
            case .cpu: cpuSection
            case .memory: memorySection
            case .battery: if model.battery.present { batterySection } else { cpuSection }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: CPU

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("CPU", systemImage: "cpu", value: percent(model.cpu.total))
            Sparkline(values: model.cpuHistory, color: .blue)
                .frame(height: 30)
            HStack {
                stat("User", percent(model.cpu.user))
                stat("System", percent(model.cpu.system))
                stat("Idle", percent(max(0, 1 - model.cpu.total)))
            }
            CoreBars(values: model.cpu.perCore, kinds: model.cpuReader.coreKinds)
                .frame(height: 24)
            HStack {
                if let e = model.cpu.efficiencyAvg { stat("Efficiency cores", percent(e)) }
                if let p = model.cpu.performanceAvg { stat("\(model.cpuReader.performanceName) cores", percent(p)) }
            }
            HStack {
                if model.loads.count == 3 {
                    stat("Load avg", model.loads.map { String(format: "%.2f", $0) }.joined(separator: " "))
                }
                if let boot = bootTime() { stat("Uptime", uptime(since: boot)) }
            }
            processList(model.topByCPU) { String(format: "%.1f%%", $0.cpu) }
        }
    }

    // MARK: Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Memory", systemImage: "memorychip",
                   value: "\(bytes(model.memory.used)) / \(bytes(model.memory.total))")
            Sparkline(values: model.memoryHistory, color: .purple)
                .frame(height: 30)
            HStack {
                stat("App", bytes(model.memory.app))
                stat("Wired", bytes(model.memory.wired))
                stat("Compressed", bytes(model.memory.compressed))
            }
            HStack {
                stat("Cached", bytes(model.memory.cached))
                stat("Swap", "\(bytes(model.memory.swapUsed)) / \(bytes(model.memory.swapTotal))")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Pressure").font(.caption2).foregroundStyle(.secondary)
                    Text(model.memory.pressure.rawValue)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(pressureColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            processList(model.topByMemory) { bytes($0.memory) }
        }
    }

    private var pressureColor: Color {
        switch model.memory.pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    // MARK: Battery

    private var batterySection: some View {
        let b = model.battery
        return VStack(alignment: .leading, spacing: 8) {
            header("Battery", systemImage: batterySymbol(b), value: percent(b.level))
            ProgressView(value: b.level)
                .tint(b.level < 0.2 && !b.onAC ? .red : .green)
            HStack {
                stat("Status", b.statusText)
                stat(b.isCharging ? "Until full" : "Remaining",
                     b.minutesRemaining.map { String(format: "%d:%02d", $0 / 60, $0 % 60) } ?? (b.isCharged || (b.onAC && !b.isCharging) ? "—" : "Calculating"))
            }
            HStack {
                stat("Health", b.health.map { "\($0)%" } ?? "—")
                stat("Cycles", b.cycles.map(String.init) ?? "—")
                stat("Temp", b.temperature.map { String(format: "%.1f °C", $0) } ?? "—")
            }
            HStack {
                stat(b.power.map { $0 < 0 ? "Draw" : "Charge rate" } ?? "Power",
                     b.power.map { String(format: "%.1f W", abs($0)) } ?? "—")
                stat("Voltage", b.voltage.map { String(format: "%.2f V", $0) } ?? "—")
                stat("Adapter", b.adapterWatts.map { "\($0) W" } ?? "—")
            }
            HStack {
                stat("Capacity", b.maxCapacity.map { "\($0) mAh" } ?? "—")
                stat("Design", b.designCapacity.map { "\($0) mAh" } ?? "—")
                Spacer().frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Menu bar:").font(.caption).foregroundStyle(.secondary)
            Toggle("CPU", isOn: $model.showCPU)
            Toggle("RAM", isOn: $model.showMemory)
            Toggle("Battery", isOn: $model.showBattery)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.bordered)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    // MARK: Helpers

    private func header(_ title: String, systemImage: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage).font(.headline)
            Spacer()
            Text(value).font(.headline.monospacedDigit())
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func processList(_ processes: [TopProcess], value: @escaping (TopProcess) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Top processes").font(.caption2).foregroundStyle(.secondary)
            if processes.isEmpty {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(processes) { p in
                HStack {
                    Text(p.name).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text(value(p)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Components


struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let step = geo.size.width / CGFloat(max(Model.historyLength - 1, 1))
            let offset = CGFloat(Model.historyLength - values.count) * step
            let points = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step, y: geo.size.height * (1 - CGFloat(min(max(v, 0), 1))))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08))
                if points.count > 1 {
                    Path { p in
                        p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        points.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.25))
                    Path { p in p.addLines(points) }
                        .stroke(color, lineWidth: 1.5)
                }
            }
        }
    }
}

struct CoreBars: View {
    let values: [Double]
    let kinds: [CoreKind]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.12))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: i))
                            .frame(height: max(1, geo.size.height * CGFloat(v)))
                    }
                }
            }
        }
        .help("Per-core usage — teal: efficiency cores, orange: performance cores")
    }

    private func color(for index: Int) -> Color {
        guard index < kinds.count else { return .blue }
        switch kinds[index] {
        case .efficiency: return .teal
        case .performance: return .orange
        case .unknown: return .blue
        }
    }
}

// MARK: - Formatting

func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

func bytes(_ v: Double) -> String {
    let gb = v / 1_073_741_824
    return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", v / 1_048_576)
}

func uptime(since boot: Date) -> String {
    let s = Int(Date().timeIntervalSince(boot))
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    return d > 0 ? "\(d)d \(h)h" : "\(h)h \(m)m"
}

func batterySymbol(_ b: BatterySample) -> String {
    if b.isCharging { return "battery.100percent.bolt" }
    switch b.level {
    case ..<0.13: return "battery.0percent"
    case ..<0.38: return "battery.25percent"
    case ..<0.63: return "battery.50percent"
    case ..<0.88: return "battery.75percent"
    default: return "battery.100percent"
    }
}
