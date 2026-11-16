import CAudioRender
import CoreAudio
import XCTest

/// Exercises the real-time render function with hand-built buffer lists.
final class RenderTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let rampSeconds = 0.010
    private var rampFrames: Int { Int(sampleRate * rampSeconds) }

    // MARK: Buffer helpers

    /// A buffer list whose buffers are described as (channels, samples).
    private final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>?] = []

        init(_ buffers: [(channels: Int, samples: [Float]?)]) {
            list = AudioBufferList.allocate(maximumBuffers: buffers.count)
            for (index, buffer) in buffers.enumerated() {
                guard let samples = buffer.samples else {
                    // A stream the HAL was told is unused arrives with no data.
                    list[index] = AudioBuffer(mNumberChannels: UInt32(buffer.channels), mDataByteSize: 0, mData: nil)
                    storage.append(nil)
                    continue
                }
                let memory = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
                memory.initialize(from: samples, count: samples.count)
                storage.append(memory)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(buffer.channels),
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(memory)
                )
            }
        }

        deinit {
            storage.forEach { $0?.deallocate() }
            free(list.unsafeMutablePointer)
        }

        func samples(_ buffer: Int) -> [Float] {
            let count = Int(list[buffer].mDataByteSize) / MemoryLayout<Float>.size
            guard let memory = storage[buffer] else { return [] }
            return Array(UnsafeBufferPointer(start: memory, count: count))
        }
    }

    private func makeState(
        gain: Float = 1, tapBuffers: UInt32 = 1, left: UInt32 = 0, right: UInt32 = 1
    ) -> OpaquePointer {
        let state = nm_tap_state_create(gain, sampleRate, rampSeconds, tapBuffers, left, right)!
        addTeardownBlock { nm_tap_state_destroy(state) }
        return state
    }

    private func render(_ state: OpaquePointer, _ input: Buffers?, _ output: Buffers) {
        nm_tap_render(state, input.map { UnsafePointer($0.list.unsafeMutablePointer) }, output.list.unsafeMutablePointer)
    }

    /// Interleaved stereo ramp: L = 0.1, 0.2, ... and R = -L.
    private func stereoSignal(frames: Int) -> [Float] {
        (0..<frames).flatMap { frame -> [Float] in
            let value = Float(frame + 1) / Float(frames + 1)
            return [value, -value]
        }
    }

    // MARK: Gain

    func testUnityGainIsBitExact() {
        let signal = stereoSignal(frames: 64)
        let state = makeState(gain: 1)
        let output = Buffers([(2, [Float](repeating: 9, count: 128))])
        render(state, Buffers([(2, signal)]), output)
        XCTAssertEqual(output.samples(0), signal)
    }

    func testConstantGainScalesEverySample() {
        let signal = stereoSignal(frames: 64)
        let state = makeState(gain: 0.25)
        let output = Buffers([(2, [Float](repeating: 9, count: 128))])
        render(state, Buffers([(2, signal)]), output)
        XCTAssertEqual(output.samples(0), signal.map { $0 * 0.25 })
    }

    func testGainChangeRampsLinearlyOverTenMilliseconds() {
        let frames = rampFrames + 100
        let state = makeState(gain: 1)
        nm_tap_state_set_gain(state, 0)

        let output = Buffers([(2, [Float](repeating: 9, count: frames * 2))])
        render(state, Buffers([(2, [Float](repeating: 1, count: frames * 2))]), output)
        // The input is all ones, so the left channel is the gain envelope.
        let envelope = stride(from: 0, to: frames * 2, by: 2).map { output.samples(0)[$0] }

        let step = 1 / Float(rampFrames)
        XCTAssertEqual(envelope[0], 1 - step, accuracy: 1e-5, "ramp starts on the first frame")
        XCTAssertEqual(envelope[rampFrames / 2 - 1], 0.5, accuracy: 1e-3)
        XCTAssertEqual(envelope[rampFrames - 1], 0, "ramp lands exactly on the target")
        XCTAssertTrue(envelope[rampFrames...].allSatisfy { $0 == 0 })
        for index in 1..<rampFrames {
            let delta = envelope[index - 1] - envelope[index]
            XCTAssertEqual(delta, step, accuracy: 1e-5, "no step larger than the ramp slope (zipper noise)")
        }
    }

    func testRampContinuesAcrossCallbacks() {
        let state = makeState(gain: 0)
        nm_tap_state_set_gain(state, 1)
        var envelope: [Float] = []
        for _ in 0..<4 {
            let output = Buffers([(1, [Float](repeating: 0, count: 256))])
            render(state, Buffers([(1, [Float](repeating: 1, count: 256))]), output)
            envelope += output.samples(0)
        }
        XCTAssertEqual(envelope[rampFrames - 1], 1)
        XCTAssertEqual(envelope.last, 1)
        XCTAssertTrue(zip(envelope, envelope.dropFirst()).allSatisfy { $0 <= $1 }, "monotonic across buffer boundaries")
    }

    func testRetargetingMidRampStartsFromCurrentLevel() {
        let state = makeState(gain: 1)
        nm_tap_state_set_gain(state, 0)
        let half = rampFrames / 2
        let first = Buffers([(1, [Float](repeating: 0, count: half))])
        render(state, Buffers([(1, [Float](repeating: 1, count: half))]), first)
        let reached = first.samples(0).last!
        XCTAssertEqual(reached, 0.5, accuracy: 1e-3)

        nm_tap_state_set_gain(state, 1)
        let second = Buffers([(1, [Float](repeating: 0, count: rampFrames))])
        render(state, Buffers([(1, [Float](repeating: 1, count: rampFrames))]), second)
        XCTAssertGreaterThan(second.samples(0)[0], reached, "no jump back to the old target")
        XCTAssertLessThan(second.samples(0)[0] - reached, 0.01)
        XCTAssertEqual(second.samples(0).last, 1)
    }

    func testGainIsClamped() {
        let state = makeState(gain: 1)
        nm_tap_state_set_gain(state, 2)
        XCTAssertEqual(nm_tap_state_target_gain(state), 1)
        nm_tap_state_set_gain(state, -1)
        XCTAssertEqual(nm_tap_state_target_gain(state), 0)
        nm_tap_state_set_gain(state, .nan)
        XCTAssertEqual(nm_tap_state_target_gain(state), 1, "a bad value must not silence or blast the app")
    }

    // MARK: Buffer layouts

    func testReadsOnlyTheTrailingTapBuffer() {
        // An aggregate on a duplex device lists the microphone stream first.
        let microphone = [Float](repeating: 0.9, count: 64)
        let tap = stereoSignal(frames: 32)
        let state = makeState(gain: 1, tapBuffers: 1)
        let output = Buffers([(2, [Float](repeating: 9, count: 64))])
        render(state, Buffers([(2, microphone), (2, tap)]), output)
        XCTAssertEqual(output.samples(0), tap)
    }

    func testUnusedHardwareInputBufferIsNull() {
        let tap = stereoSignal(frames: 32)
        let state = makeState(gain: 1, tapBuffers: 1)
        let output = Buffers([(2, [Float](repeating: 9, count: 64))])
        render(state, Buffers([(2, nil), (2, tap)]), output)
        XCTAssertEqual(output.samples(0), tap)
    }

    func testPlanarInputToInterleavedOutput() {
        let left: [Float] = [0.1, 0.2, 0.3, 0.4]
        let right: [Float] = [-0.1, -0.2, -0.3, -0.4]
        let state = makeState(gain: 1, tapBuffers: 2)
        let output = Buffers([(2, [Float](repeating: 9, count: 8))])
        render(state, Buffers([(1, left), (1, right)]), output)
        XCTAssertEqual(output.samples(0), [0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4])
    }

    func testInterleavedInputToPlanarOutput() {
        let state = makeState(gain: 0.5)
        let output = Buffers([(1, [Float](repeating: 9, count: 4)), (1, [Float](repeating: 9, count: 4))])
        render(state, Buffers([(2, [0.2, -0.2, 0.4, -0.4, 0.6, -0.6, 0.8, -0.8])]), output)
        XCTAssertEqual(output.samples(0), [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(output.samples(1), [-0.1, -0.2, -0.3, -0.4])
    }

    func testMonoTapFeedsBothStereoChannels() {
        let state = makeState(gain: 1)
        let output = Buffers([(2, [Float](repeating: 9, count: 6))])
        render(state, Buffers([(1, [0.1, 0.2, 0.3])]), output)
        XCTAssertEqual(output.samples(0), [0.1, 0.1, 0.2, 0.2, 0.3, 0.3])
    }

    func testStereoTapUsesPreferredChannelsOnMultichannelDevice() {
        // A four-channel interface that wants stereo on channels 3 and 4.
        let state = makeState(gain: 1, left: 2, right: 3)
        let output = Buffers([(4, [Float](repeating: 9, count: 8))])
        render(state, Buffers([(2, [0.1, -0.1, 0.2, -0.2])]), output)
        XCTAssertEqual(output.samples(0), [0, 0, 0.1, -0.1, 0, 0, 0.2, -0.2])
    }

    func testStereoTapFoldsToMonoDevice() {
        let state = makeState(gain: 1)
        let output = Buffers([(1, [Float](repeating: 9, count: 2))])
        render(state, Buffers([(2, [0.2, 0.4, 1.0, -1.0])]), output)
        XCTAssertEqual(output.samples(0)[0], 0.3, accuracy: 1e-6)
        XCTAssertEqual(output.samples(0)[1], 0)
    }

    func testMatchingMultichannelLayoutsMapOneToOne() {
        let signal: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
        let state = makeState(gain: 1)
        let output = Buffers([(4, [Float](repeating: 9, count: 8))])
        render(state, Buffers([(4, signal)]), output)
        XCTAssertEqual(output.samples(0), signal)
    }

    // MARK: Safety

    func testMissingInputRendersSilenceNotStaleMemory() {
        let state = makeState(gain: 1)
        let output = Buffers([(2, [Float](repeating: 9, count: 16))])
        render(state, nil, output)
        XCTAssertTrue(output.samples(0).allSatisfy { $0 == 0 })
    }

    func testShortInputLeavesRemainderSilent() {
        let state = makeState(gain: 1)
        let output = Buffers([(2, [Float](repeating: 9, count: 8))])
        render(state, Buffers([(2, [0.5, 0.5, 0.5, 0.5])]), output)
        XCTAssertEqual(output.samples(0), [0.5, 0.5, 0.5, 0.5, 0, 0, 0, 0])
    }

    // MARK: Telemetry

    func testCallbackCounterAdvancesEveryCycle() {
        let state = makeState()
        XCTAssertEqual(nm_tap_state_callbacks(state), 0)
        for _ in 0..<3 {
            render(state, Buffers([(2, stereoSignal(frames: 8))]), Buffers([(2, [Float](repeating: 0, count: 16))]))
        }
        XCTAssertEqual(nm_tap_state_callbacks(state), 3)
    }

    func testAudibleFramesAreMeasuredBeforeGain() {
        // A muted app must still register as delivering audio; otherwise
        // muting would look like a missing permission.
        let state = makeState(gain: 0)
        render(state, Buffers([(2, stereoSignal(frames: 8))]), Buffers([(2, [Float](repeating: 0, count: 16))]))
        XCTAssertEqual(nm_tap_state_audible_frames(state), 8)

        render(state, Buffers([(2, [Float](repeating: 0, count: 16))]), Buffers([(2, [Float](repeating: 0, count: 16))]))
        XCTAssertEqual(nm_tap_state_audible_frames(state), 8, "digital silence does not count")
    }

    func testStreamUsageIsANoOpWhenNothingNeedsSwitchingOff() {
        // No extra input streams means no HAL call at all, so even a bogus
        // device and callback must report success.
        let callback: AudioDeviceIOProcID = nm_tap_ioproc
        XCTAssertEqual(nm_use_only_trailing_input_streams(0, callback, 0, 1), noErr)
        XCTAssertEqual(nm_use_only_trailing_input_streams(0, callback, 1, 1), noErr)
        XCTAssertEqual(nm_use_only_trailing_input_streams(0, callback, 1, 3), noErr)
    }

    func testStreamUsageReportsFailureOnAMissingDevice() {
        let callback: AudioDeviceIOProcID = nm_tap_ioproc
        XCTAssertNotEqual(nm_use_only_trailing_input_streams(0, callback, 3, 1), noErr)
    }

    func testIOProcEntryPointRenders() {
        let state = makeState(gain: 0.5)
        let input = Buffers([(2, [0.4, 0.4])])
        let output = Buffers([(2, [9, 9])])
        var time = AudioTimeStamp()
        let status = nm_tap_ioproc(
            0, &time, UnsafePointer(input.list.unsafeMutablePointer), &time,
            output.list.unsafeMutablePointer, &time, UnsafeMutableRawPointer(state)
        )
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(output.samples(0), [0.2, 0.2])
    }
}
