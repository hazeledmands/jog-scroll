import Foundation
import CoreMIDI

struct MidiMessage {
    var status: UInt8
    var data1: UInt8
    var data2: UInt8
    var source: String
}

/// Listens to every MIDI source and reconnects when devices are plugged in or out.
final class MidiInput {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []
    private(set) var sourceNames: [String] = []
    private let handler: (MidiMessage) -> Void
    var onSourcesChanged: (() -> Void)?
    var verbose = true

    init(handler: @escaping (MidiMessage) -> Void) {
        self.handler = handler

        MIDIClientCreateWithBlock("jog-scroll" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectSources() }
            }
        }
        MIDIInputPortCreateWithBlock(client, "in" as CFString, &port) { [weak self] packets, srcRef in
            let source = srcRef.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            for packet in packets.unsafeSequence() {
                self?.parse(packet, source: source)
            }
        }
        connectSources()
    }

    func connectSources() {
        for src in connected { MIDIPortDisconnectSource(port, src) }
        connected.removeAll()
        sourceNames.removeAll()
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            let name = endpointName(src)
            // The connection refCon carries the source name to the read block.
            let ref = Unmanaged.passRetained(name as CFString).toOpaque()
            if MIDIPortConnectSource(port, src, ref) == noErr {
                connected.append(src)
                sourceNames.append(name)
                if verbose { log("Listening to \"\(name)\"") }
            }
        }
        if connected.isEmpty && verbose { log("No MIDI inputs found. Waiting for a device…") }
        onSourcesChanged?()
    }

    private func parse(_ packet: UnsafePointer<MIDIPacket>, source: String) {
        let length = Int(packet.pointee.length)
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!
        let bytes = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt8.self)

        var i = 0
        var running: UInt8 = 0
        while i < length {
            let b = bytes[i]
            if b >= 0xF8 { i += 1; continue }                 // realtime
            if b >= 0xF0 {                                    // sysex / system common: skip to next status
                i += 1
                while i < length && bytes[i] < 0x80 { i += 1 }
                running = 0
                continue
            }
            if b >= 0x80 { running = b; i += 1 }
            guard running != 0 else { i += 1; continue }
            let type = running & 0xF0
            let size = (type == 0xC0 || type == 0xD0) ? 1 : 2
            guard i + size <= length else { break }
            let d1 = bytes[i]
            let d2 = size == 2 ? bytes[i + 1] : 0
            i += size
            let msg = MidiMessage(status: running, data1: d1, data2: d2, source: source)
            DispatchQueue.main.async { self.handler(msg) }
        }
    }
}

/// Sends MIDI to the controller, for its lights. Finds the destination whose name contains `port` each time,
/// so it keeps working after the controller is unplugged and plugged back in. Runs on the main queue.
final class MidiOutput {
    private var client = MIDIClientRef()
    private var outPort = MIDIPortRef()

    /// The output's name, or part of it.
    var port = ""

    init() {
        MIDIClientCreateWithBlock("jog-scroll lights" as CFString, &client, nil)
        MIDIOutputPortCreate(client, "out" as CFString, &outPort)
    }

    /// Sends one message. Returns nil, or why it couldn't.
    func send(_ status: UInt8, _ data1: UInt8, _ data2: UInt8) -> String? {
        guard !port.isEmpty, let dest = (0..<MIDIGetNumberOfDestinations()).lazy.map(MIDIGetDestination)
            .first(where: { endpointName($0).lowercased().contains(self.port.lowercased()) })
        else { return "There's no MIDI output called \"\(port)\" to light the controller with" }

        var list = MIDIPacketList()
        let packet = MIDIPacketListInit(&list)
        let bytes: [UInt8] = [status, data1, data2]
        MIDIPacketListAdd(&list, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
        let err = MIDISend(outPort, dest, &list)
        return err == noErr ? nil : "Couldn't send to \"\(port)\" (error \(err))"
    }
}

func endpointName(_ ep: MIDIEndpointRef) -> String {
    var name: Unmanaged<CFString>?
    MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &name)
    return (name?.takeRetainedValue() as String?) ?? "Unknown"
}

func log(_ s: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    print("[\(ts)] \(s)")
    fflush(stdout)
}

func hex(_ m: MidiMessage) -> String {
    String(format: "%02X %02X %02X", m.status, m.data1, m.data2)
}
