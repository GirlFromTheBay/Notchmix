import AudioToolbox
import CoreAudio
import Foundation

/// Thin, typed access to Core Audio HAL properties.
///
/// Every call here can block on `coreaudiod`, so the engine only uses them
/// from its own serial queue, never from the main thread or the audio thread.
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func hasProperty(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = Self.address(selector, scope)
        return AudioObjectHasProperty(self, &address)
    }

    func isSettable(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = Self.address(selector, scope)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(self, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// Reads a fixed-size plain value (`UInt32`, `Float32`, `Float64`,
    /// `pid_t`, `AudioStreamBasicDescription`, ...).
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type = T.self
    ) -> T? {
        var address = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        // Zero first so a short read can never expose uninitialised memory.
        UnsafeMutableRawPointer(value).initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type = T.self
    ) -> [T] {
        var address = Self.address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer) == noErr else { return [] }
        // The list can shrink between the two calls; trust the second size.
        let actual = Swift.min(count, Int(size) / MemoryLayout<T>.stride)
        return Array(UnsafeBufferPointer(start: buffer, count: actual))
    }

    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Reads a property whose value is a CFArray of CFStrings.
    func readStringArray(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [String] {
        var address = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        var value: Unmanaged<CFArray>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return [] }
        return (value.takeRetainedValue() as? [String]) ?? []
    }

    @discardableResult
    func write<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        value: T
    ) -> Bool {
        var address = Self.address(selector, scope)
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafePointer(to: value) { pointer in
            AudioObjectSetPropertyData(self, &address, 0, nil, size, pointer) == noErr
        }
    }

    /// Total channel count across every stream in `scope`.
    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        readArray(kAudioDevicePropertyStreams, scope: scope, of: AudioStreamID.self).count
    }
}

/// A HAL property listener that removes itself when released.
///
/// Callbacks are delivered on the queue passed at creation, which for the
/// engine is always its own serial queue.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init?(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) {
        self.object = object
        self.address = AudioObjectID.address(selector, scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else {
            return nil
        }
    }

    deinit {
        // The object may already be gone (process exited, device unplugged);
        // that failure is expected and harmless.
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
