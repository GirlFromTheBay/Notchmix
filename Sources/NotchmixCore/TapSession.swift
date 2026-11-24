import AudioToolbox
import CAudioRender
import CoreAudio
import Foundation

enum TapSessionError: Error, CustomStringConvertible {
    case status(OSStatus, String)
    case unsupported(String)

    var description: String {
        switch self {
        case .status(let status, let stage): return "\(stage) failed (\(status))"
        case .unsupported(let reason): return reason
        }
    }
}

/// One app's audio, rerouted through a gain stage.
///
/// A process tap with `.mutedWhenTapped` silences the app's own path to the
/// speakers and hands its audio to us instead. A private aggregate device
/// joins that tap to the real output device, and an IOProc on the aggregate
/// copies tap to output with the gain applied.
///
/// If this process dies, the HAL destroys the tap and the app is audible
/// again at full volume: failure always degrades to "no control", never to
/// silence.
///
/// Not thread-safe. The engine creates, drives and stops sessions on its
/// serial queue; only `nm_tap_state` is shared with the audio thread.
final class TapSession {
    /// Length of the linear gain ramp that prevents zipper noise.
    static let rampSeconds = 0.010

    let processObjects: [AudioObjectID]
    let outputUID: String

    /// True when every one of `objects` is already in this tap. Processes
    /// that have exited do not matter; only a new one needs a new tap.
    func covers(_ objects: [AudioObjectID]) -> Bool {
        Set(objects).isSubset(of: processObjects)
    }
    let createdAt = Date()

    private let state: OpaquePointer
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private var isStopped = false

    init(processObjects: [AudioObjectID], output: OutputDevice, gain: Float, isCustomRoute: Bool = false) throws {
        self.processObjects = processObjects
        self.outputUID = output.uid

        // Flatten a user aggregate into its hardware devices.
        let subDevices = output.aggregateSubDeviceUIDs
        let outputUIDs = subDevices.isEmpty ? [output.uid] : subDevices
        let isFlattened = !subDevices.isEmpty

        let tap = try Self.makeTap(
            processObjects: processObjects,
            // A device-specific tap keeps the device's own channel layout,
            // unless we're routing an app away from the default output.
            deviceUID: (isFlattened || isCustomRoute) ? nil : output.uid,
            device: output.id
        )
        tapID = tap.id

        var createdAggregate = AudioObjectID.unknown
        var createdProc: AudioDeviceIOProcID?
        var createdState: OpaquePointer?
        do {
            guard let format: AudioStreamBasicDescription = tap.id.read(kAudioTapPropertyFormat),
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                throw TapSessionError.unsupported("Tap format is not 32-bit float PCM")
            }

            let description = Self.aggregateDescription(
                outputUIDs: outputUIDs,
                tapUUID: tap.uuid,
                stacked: outputUIDs.count > 1,
                // Bluetooth output and its tap share one clock; compensating
                // for drift that is not there causes periodic crackle.
                tapDriftCompensation: !output.isBluetooth
            )
            try Self.check(
                AudioHardwareCreateAggregateDevice(description as CFDictionary, &createdAggregate),
                "Creating the aggregate device"
            )
            guard Self.waitUntilReady(createdAggregate) else {
                throw TapSessionError.unsupported("Aggregate device has no output streams")
            }

            // The aggregate lists the output device's own input streams (a USB
            // headset's microphone, say) ahead of the tap's stream.
            let inputStreams = createdAggregate.streamCount(scope: kAudioObjectPropertyScopeInput)
            let hardwareInputStreams = Self.hardwareInputStreamCount(deviceUIDs: outputUIDs)
            let tapStreams = max(1, inputStreams - hardwareInputStreams)

            let stereo = output.preferredStereoChannels
            let sampleRate = createdAggregate.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self)
                ?? output.sampleRate
            guard let newState = nm_tap_state_create(
                gain, sampleRate, Self.rampSeconds, UInt32(tapStreams), stereo.left, stereo.right
            ) else {
                throw TapSessionError.unsupported("Out of memory")
            }
            createdState = newState

            try Self.check(
                AudioDeviceCreateIOProcID(createdAggregate, nm_tap_ioproc, UnsafeMutableRawPointer(newState), &createdProc),
                "Creating the audio callback"
            )
            if let createdProc, inputStreams > tapStreams {
                // Read only the tap's streams, which come last. Otherwise a
                // duplex output device (a USB headset) would have its
                // microphone opened too, lighting the mic indicator for an
                // app that never listens to it. Best effort: if this fails,
                // audio still works.
                nm_use_only_trailing_input_streams(
                    createdAggregate, createdProc, UInt32(inputStreams), UInt32(tapStreams)
                )
            }
            try Self.check(AudioDeviceStart(createdAggregate, createdProc), "Starting audio")
        } catch {
            if let createdProc { AudioDeviceDestroyIOProcID(createdAggregate, createdProc) }
            if createdAggregate != .unknown { AudioHardwareDestroyAggregateDevice(createdAggregate) }
            AudioHardwareDestroyProcessTap(tap.id)
            if let createdState { nm_tap_state_destroy(createdState) }
            throw error
        }

        aggregateID = createdAggregate
        procID = createdProc
        state = createdState!
    }

    deinit {
        stop()
    }

    // MARK: Control

    var gain: Float {
        get { nm_tap_state_target_gain(state) }
        set { nm_tap_state_set_gain(state, newValue) }
    }

    /// Advances once per render cycle; a stalled count means the IOProc died.
    var callbackCount: UInt64 { nm_tap_state_callbacks(state) }

    /// Frames in which the tap carried real audio, measured before gain.
    var audibleFrames: UInt64 { nm_tap_state_audible_frames(state) }

    /// Peak input sample magnitude (0...1) from the latest render cycle.
    var peak: Float { nm_tap_state_peak(state) }

    /// Stops rendering and releases the tap, which un-mutes the app.
    func stop() {
        guard !isStopped else { return }
        isStopped = true

        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != .unknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != .unknown { AudioHardwareDestroyProcessTap(tapID) }

        // AudioDeviceStop does not return until the IO thread has left the
        // callback, but the state is tiny, so give it a generous margin
        // rather than rely on that.
        let state = state
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            nm_tap_state_destroy(state)
        }
    }

    // MARK: Construction

    private static func check(_ status: OSStatus, _ stage: String) throws {
        guard status == noErr else { throw TapSessionError.status(status, stage) }
    }

    private static func makeTap(
        processObjects: [AudioObjectID],
        deviceUID: String?,
        device: AudioObjectID
    ) throws -> (id: AudioObjectID, uuid: UUID) {
        func configure(_ description: CATapDescription) -> CATapDescription {
            description.uuid = UUID()
            description.name = "Notchmix"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            return description
        }

        // Preferred: tap the processes on the output device's first stream.
        // This keeps multichannel layouts intact and leaves audio an app sends
        // to some other device alone.
        if let deviceUID, let stream = firstOutputStreamIndex(of: device) {
            let description = configure(
                CATapDescription(processes: processObjects, deviceUID: deviceUID, stream: stream)
            )
            var id = AudioObjectID.unknown
            if AudioHardwareCreateProcessTap(description, &id) == noErr, id != .unknown {
                return (id, description.uuid)
            }
        }

        // Fallback: a stereo mixdown of everything the processes play.
        let description = configure(CATapDescription(stereoMixdownOfProcesses: processObjects))
        var id = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &id), "Creating the process tap")
        return (id, description.uuid)
    }

    /// A device tap names its stream by position in the device's full stream
    /// list, where input streams can come before output streams.
    private static func firstOutputStreamIndex(of device: AudioObjectID) -> UInt? {
        let streams = device.readArray(kAudioDevicePropertyStreams, of: AudioStreamID.self)
        for (index, stream) in streams.enumerated() {
            // kAudioStreamPropertyDirection: 0 is output, 1 is input.
            if let direction: UInt32 = stream.read(kAudioStreamPropertyDirection), direction == 0 {
                return UInt(index)
            }
        }
        return nil
    }

    private static func aggregateDescription(
        outputUIDs: [String],
        tapUUID: UUID,
        stacked: Bool,
        tapDriftCompensation: Bool
    ) -> [String: Any] {
        let clockUID = outputUIDs[0]
        return [
            kAudioAggregateDeviceNameKey: "Notchmix",
            kAudioAggregateDeviceUIDKey: "Notchmix-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceClockDeviceKey: clockUID,
            // Private: invisible to other apps and to Audio MIDI Setup, and
            // never persisted, so a crash cannot leave a device behind.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: stacked,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: outputUIDs.enumerated().map { index, uid in
                [
                    kAudioSubDeviceUIDKey: uid,
                    // The first device is the clock; the rest follow it.
                    kAudioSubDeviceDriftCompensationKey: index > 0,
                ] as [String: Any]
            },
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: tapDriftCompensation,
                ] as [String: Any],
            ],
        ]
    }

    /// A new aggregate takes a moment to publish its streams.
    private static func waitUntilReady(_ aggregate: AudioObjectID, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if aggregate.streamCount(scope: kAudioObjectPropertyScopeOutput) > 0 { return true }
            if Date() >= deadline { return false }
            usleep(20_000)
        }
    }

    private static func hardwareInputStreamCount(deviceUIDs: [String]) -> Int {
        let devices = AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self)
        return devices
            .filter { device in
                device.readString(kAudioDevicePropertyDeviceUID).map(deviceUIDs.contains) ?? false
            }
            .reduce(0) { $0 + $1.streamCount(scope: kAudioObjectPropertyScopeInput) }
    }

}
