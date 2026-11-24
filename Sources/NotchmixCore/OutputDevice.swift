import AudioToolbox
import CoreAudio
import Foundation

/// The system's default output device and its master volume.
struct OutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String

    static func current() -> OutputDevice? {
        guard let id: AudioObjectID = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice),
              id != .unknown,
              let uid = id.readString(kAudioDevicePropertyDeviceUID) else { return nil }
        let name = id.readString(kAudioObjectPropertyName) ?? "Output"
        return OutputDevice(id: id, uid: uid, name: name)
    }

    static func isHardwareOutputTransport(_ transport: UInt32) -> Bool {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn,
             kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeAVB,
             kAudioDeviceTransportTypeAirPlay:
            return true
        default:
            return false
        }
    }

    static func allOutputDevices() -> [OutputDevice] {
        let ids = AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        var devices = ids.compactMap { id -> OutputDevice? in
            guard id != .unknown,
                  let uid = id.readString(kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix("Notchmix-"),
                  (id.read(kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) ?? 1) != 0,
                  (id.read(kAudioDevicePropertyIsHidden, as: UInt32.self) ?? 0) == 0,
                  let transport: UInt32 = id.read(kAudioDevicePropertyTransportType),
                  isHardwareOutputTransport(transport),
                  id.channelCount(scope: kAudioObjectPropertyScopeOutput) > 0 else {
                return nil
            }
            let name = id.readString(kAudioObjectPropertyName) ?? "Output"
            return OutputDevice(id: id, uid: uid, name: name)
        }
        if let current = current(), !devices.contains(where: { $0.uid == current.uid }) {
            devices.append(current)
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    static func setDefaultOutput(uid: String) -> Bool {
        guard let device = allOutputDevices().first(where: { $0.uid == uid }) else { return false }
        let okDefault = AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, value: device.id)
        let okSystem = AudioObjectID.system.write(kAudioHardwarePropertyDefaultSystemOutputDevice, value: device.id)
        return okDefault || okSystem
    }

    var sampleRate: Double {
        id.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self) ?? 48_000
    }

    var isBluetooth: Bool {
        let transport: UInt32 = id.read(kAudioDevicePropertyTransportType) ?? 0
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// For a user-made aggregate or multi-output device: the hardware devices
    /// inside it. An aggregate cannot be nested in another aggregate, so a tap
    /// session has to be built on these instead.
    var aggregateSubDeviceUIDs: [String] {
        let transport: UInt32 = id.read(kAudioDevicePropertyTransportType) ?? 0
        guard transport == kAudioDeviceTransportTypeAggregate else { return [] }
        return id.readStringArray(kAudioAggregateDevicePropertyFullSubDeviceList)
    }

    /// Zero-based channels the device wants stereo content on.
    var preferredStereoChannels: (left: UInt32, right: UInt32) {
        let channels = id.readArray(
            kAudioDevicePropertyPreferredChannelsForStereo,
            scope: kAudioObjectPropertyScopeOutput,
            of: UInt32.self
        )
        guard channels.count == 2, channels[0] >= 1, channels[1] >= 1 else { return (0, 1) }
        return (channels[0] - 1, channels[1] - 1)
    }

    // MARK: Master volume

    private static let volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    private static let outputScope = kAudioObjectPropertyScopeOutput

    /// HDMI and some digital outputs have no software volume at all.
    var hasVolumeControl: Bool {
        id.hasProperty(Self.volumeSelector, scope: Self.outputScope)
            && id.isSettable(Self.volumeSelector, scope: Self.outputScope)
    }

    /// The same 0...1 scalar the system volume slider shows.
    var volume: Float? {
        id.read(Self.volumeSelector, scope: Self.outputScope, as: Float32.self)
    }

    func setVolume(_ volume: Float) {
        id.write(Self.volumeSelector, scope: Self.outputScope, value: Float32(min(max(volume, 0), 1)))
    }

    var isMuted: Bool {
        (id.read(kAudioDevicePropertyMute, scope: Self.outputScope, as: UInt32.self) ?? 0) != 0
    }

    func setMuted(_ muted: Bool) {
        id.write(kAudioDevicePropertyMute, scope: Self.outputScope, value: UInt32(muted ? 1 : 0))
    }

    static let volumeSelectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (volumeSelector, outputScope),
        (kAudioDevicePropertyMute, outputScope),
    ]
}
