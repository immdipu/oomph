import CoreAudio
import Observation

/// The Mac's audio outputs and the one macOS plays through, from Core Audio. eqtune follows
/// the default output by itself; Oomph watches it to switch presets per device.
@MainActor @Observable
final class AudioOutputs {
    struct Device: Identifiable, Hashable, Sendable {
        /// Core Audio's UID, which stays the same across reconnects and restarts.
        let id: String
        let name: String
        let symbol: String
    }

    private(set) var devices: [Device] = []
    private(set) var current: Device?
    /// Called when macOS switches to another output (not for the first one seen).
    var onChange: ((Device) -> Void)?

    init() {
        reload()
        // ponytail: listeners live as long as the app, so they're never removed.
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    private func reload() {
        let previous = current
        devices = Self.deviceIDs().filter(Self.hasOutput).compactMap(Self.device)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        current = Self.defaultOutputID().flatMap(Self.device)
        if let current, let previous, current.id != previous.id { onChange?(current) }
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func deviceIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func defaultOutputID() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func device(_ id: AudioObjectID) -> Device? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID),
              let name = string(id, kAudioObjectPropertyName) else { return nil }
        var address = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        let headphones = name.localizedCaseInsensitiveContains("headphone")
        let symbol = switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            name.localizedCaseInsensitiveContains("airpods") ? "airpods" : "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeUSB: headphones ? "headphones" : "hifispeaker"
        default: headphones ? "headphones" : "speaker.wave.2"
        }
        return Device(id: uid, name: name, symbol: symbol)
    }

    /// A CFString property; Core Audio hands it over retained.
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
