import ServiceManagement

/// Controls whether Notchmix starts automatically at login.
public enum LoginItem {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Declined or unavailable when running unbundled (e.g. unit tests).
        }
        return isEnabled
    }
}
