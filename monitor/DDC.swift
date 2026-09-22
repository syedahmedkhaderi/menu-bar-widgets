import Foundation
import IOKit

/// DDC/CI over the Apple Silicon IOAVService I2C path (same approach as MonitorControl's Arm64DDC).
final class DDC {
    static let chipAddress: UInt8 = 0x37
    static let dataAddress: UInt8 = 0x51
    static let vcpBrightness: UInt8 = 0x10

    private let service: IOAVService

    init(service: IOAVService) { self.service = service }

    /// All external display services, in IORegistry order.
    static func externalServices() -> [IOAVService] {
        var result: [IOAVService] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            guard location == "External", let svc = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { continue }
            result.append(svc.takeRetainedValue())
        }
        return result
    }

    private static func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    /// Sends one DDC/CI message (opcode first, e.g. [0x01, vcp] to read) and optionally reads the reply.
    private func send(_ message: [UInt8], replyLength: Int = 0) -> [UInt8]? {
        var packet: [UInt8] = [0x80 | UInt8(message.count)] + message + [0]
        packet[packet.count - 1] = DDC.checksum((DDC.chipAddress << 1) ^ DDC.dataAddress, packet[0..<(packet.count - 1)])
        for _ in 0..<5 {
            var wrote = false
            for _ in 0..<2 {
                usleep(10_000)
                wrote = IOAVServiceWriteI2C(service, UInt32(DDC.chipAddress), UInt32(DDC.dataAddress), &packet, UInt32(packet.count)) == 0
            }
            if replyLength == 0 {
                if wrote { return [] }
            } else {
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: replyLength)
                // reply[1] holds the message length, so the checksum follows at 2 + length.
                if IOAVServiceReadI2C(service, UInt32(DDC.chipAddress), 0, &reply, UInt32(reply.count)) == 0 {
                    let end = 2 + Int(reply[1] & 0x7f)
                    if end < reply.count, DDC.checksum(0x50, reply[0..<end]) == reply[end] {
                        return reply
                    }
                }
            }
            usleep(20_000)
        }
        return nil
    }

    /// Reads a VCP feature; returns (current, max) in the monitor's raw units.
    func read(_ vcp: UInt8) -> (current: Int, max: Int)? {
        guard let r = send([0x01, vcp], replyLength: 11), r[2] == 0x02, r[3] == 0x00, r[4] == vcp else { return nil }
        return (Int(r[8]) << 8 | Int(r[9]), Int(r[6]) << 8 | Int(r[7]))
    }

    @discardableResult
    func write(_ vcp: UInt8, _ value: Int) -> Bool {
        send([0x03, vcp, UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]) != nil
    }
}

