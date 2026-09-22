import AppKit

/// One external monitor we can drive over DDC.
final class ExternalDisplay {
    let displayID: CGDirectDisplayID
    let name: String
    fileprivate let ddc: DDC
    fileprivate(set) var maxValue = 100
    /// Last known raw brightness (0...maxValue); nil until the first successful read.
    fileprivate(set) var current: Int?

    fileprivate var pending: Int?
    fileprivate var writing = false

    init(displayID: CGDirectDisplayID, name: String, ddc: DDC) {
        self.displayID = displayID
        self.name = name
        self.ddc = ddc
    }

    /// Brightness as 0...1, if known.
    var level: Double? { current.map { Double($0) / Double(max(maxValue, 1)) } }
}

/// Finds external monitors, pairs them with DDC services, and serializes all I2C traffic
/// on a background queue (DDC calls sleep, so they must never run on the main thread).
final class DisplayManager {
    private(set) var displays: [ExternalDisplay] = []
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "brightness.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var reconfigureWork: DispatchWorkItem?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard let context, !flags.contains(.beginConfigurationFlag) else { return }
            let manager = Unmanaged<DisplayManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { manager.scheduleRefresh() }
        }, context)
        refresh()
    }

    /// Displays change in bursts (connect, wake, resolution change); wait for them to settle.
    private func scheduleRefresh() {
        reconfigureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        reconfigureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Rebuilds the display list (old IOAVService handles go stale after a reconnect) and reads brightness.
    func refresh() {
        let external = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            guard let id = screen.displayID, CGDisplayIsBuiltin(id) == 0 else { return nil }
            return (id, screen.localizedName)
        }.sorted { $0.0 < $1.0 }

        queue.async { [weak self] in
            guard let self else { return }
            // With several monitors the pairing is by order; exact for the common single-monitor case.
            let services = DDC.externalServices()
            let found = zip(external, services).map { ExternalDisplay(displayID: $0.0.0, name: $0.0.1, ddc: DDC(service: $0.1)) }
            for display in found {
                if let value = display.ddc.read(DDC.vcpBrightness), value.max > 0 {
                    display.maxValue = value.max
                    display.current = value.current
                }
            }
            DispatchQueue.main.async {
                self.displays = found
                self.onChange?()
            }
        }
    }

    func display(for id: CGDirectDisplayID) -> ExternalDisplay? {
        displays.first { $0.displayID == id }
    }

    /// Sets brightness (0...1). Rapid calls coalesce: only the newest value is written.
    func setLevel(_ level: Double, for display: ExternalDisplay) {
        let raw = Int((min(max(level, 0), 1) * Double(display.maxValue)).rounded())
        lock.lock()
        display.current = raw
        display.pending = raw
        let startWorker = !display.writing
        display.writing = true
        lock.unlock()
        guard startWorker else { return }

        queue.async { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock()
                guard let value = display.pending else {
                    display.writing = false
                    self.lock.unlock()
                    return
                }
                display.pending = nil
                self.lock.unlock()
                display.ddc.write(DDC.vcpBrightness, value)
            }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The screen currently under the mouse pointer.
    static var underPointer: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) }
    }
}
