import AppKit
import CoreServices

/// The few Apple Events the app sends, built by hand from four-character
/// codes so nothing has to be compiled or run on the main thread.
///
/// Every call can block: on the target app, and the first time on the
/// system's "wants to control" prompt. Call from a background queue.
enum AppleEvents {
    enum Permission: Equatable {
        case granted
        case denied
        /// Never asked; sending an event shows the consent prompt.
        case undetermined
        case targetNotRunning
    }

    static func code(_ string: String) -> FourCharCode {
        string.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Whether this app may send events to `bundleID`.
    ///
    /// - Parameter askUser: Show the consent prompt if the user has not
    ///   decided yet, and wait for the answer.
    static func permission(for bundleID: String, askUser: Bool) -> Permission {
        // Addressing an app that is not running would launch it.
        guard isRunning(bundleID) else { return .targetNotRunning }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return .denied }
        switch AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUser) {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
        case OSStatus(procNotFound): return .targetNotRunning
        default: return .denied
        }
    }

    // MARK: Object specifiers

    /// `every <element> of <container>`.
    static func every(_ elementClass: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        var all = code("all ")
        let ordinal = NSAppleEventDescriptor(
            descriptorType: code("abso"), bytes: &all, length: MemoryLayout<FourCharCode>.size
        ) ?? .null()
        return specifier(wanting: elementClass, from: container, form: "indx", selecting: ordinal)
    }

    /// `<property> of <container>`.
    static func property(_ propertyCode: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(
            wanting: "prop", from: container, form: "prop",
            selecting: NSAppleEventDescriptor(typeCode: code(propertyCode))
        )
    }

    private static func specifier(
        wanting desiredClass: String,
        from container: NSAppleEventDescriptor,
        form: String,
        selecting keyData: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(desiredClass)), forKeyword: code("want"))
        record.setDescriptor(container, forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(keyData, forKeyword: code("seld"))
        return record.coerce(toDescriptorType: code("obj ")) ?? record
    }

    // MARK: Sending

    /// Sends `get <specifier>` and returns the reply's value.
    static func get(
        _ specifier: NSAppleEventDescriptor, from bundleID: String, timeout: TimeInterval
    ) throws -> NSAppleEventDescriptor? {
        let event = makeEvent(class: "core", id: "getd", to: bundleID)
        event.setParam(specifier, forKeyword: code("----"))
        let reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        return reply.paramDescriptor(forKeyword: code("----"))
    }

    /// Sends a command that takes no parameters.
    static func send(class eventClass: String, id eventID: String, to bundleID: String, timeout: TimeInterval) throws {
        let event = makeEvent(class: eventClass, id: eventID, to: bundleID)
        _ = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
    }

    private static func makeEvent(class eventClass: String, id eventID: String, to bundleID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: code(eventClass),
            eventID: code(eventID),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: bundleID),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    /// Flattens a reply that is a list, or a list of lists, into its leaves.
    static func leaves(of descriptor: NSAppleEventDescriptor?) -> [NSAppleEventDescriptor] {
        guard let descriptor else { return [] }
        guard descriptor.descriptorType == code("list") else { return [descriptor] }
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).flatMap { leaves(of: descriptor.atIndex($0)) }
    }
}
