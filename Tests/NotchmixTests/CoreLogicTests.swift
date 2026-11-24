import CoreServices
import XCTest
@testable import NotchmixCore
@testable import NotchmixUI

final class AppIdentityTests: XCTestCase {
    func testHelperResolvesToOutermostApp() {
        let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        XCTAssertEqual(
            ProcessInspector.outermostAppBundle(inExecutablePath: chromeHelper),
            "/Applications/Google Chrome.app"
        )
        let electronHelper = "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)"
        XCTAssertEqual(ProcessInspector.outermostAppBundle(inExecutablePath: electronHelper), "/Applications/Slack.app")
        let firefox = "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"
        XCTAssertEqual(ProcessInspector.outermostAppBundle(inExecutablePath: firefox), "/Applications/Firefox.app")
    }

    func testPlainAppAndPathsWithSpaces() {
        XCTAssertEqual(
            ProcessInspector.outermostAppBundle(inExecutablePath: "/Users/me/My Apps/Some Player.app/Contents/MacOS/Some Player"),
            "/Users/me/My Apps/Some Player.app"
        )
    }

    func testExecutablesOutsideAnyBundle() {
        XCTAssertNil(ProcessInspector.outermostAppBundle(inExecutablePath: "/usr/bin/afplay"))
        // Steam's helpers live in a folder that is not a `.app`.
        XCTAssertNil(ProcessInspector.outermostAppBundle(
            inExecutablePath: "/Users/me/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx"
        ))
        XCTAssertNil(ProcessInspector.outermostAppBundle(inExecutablePath: "/opt/application/bin/tool"))
    }

    func testInfoPlistFlagSpellings() {
        XCTAssertTrue(AppIdentityResolver.flag(true))
        XCTAssertTrue(AppIdentityResolver.flag(1))
        XCTAssertTrue(AppIdentityResolver.flag("1"))
        XCTAssertTrue(AppIdentityResolver.flag("YES"))
        XCTAssertTrue(AppIdentityResolver.flag("true"))
        XCTAssertFalse(AppIdentityResolver.flag(false))
        XCTAssertFalse(AppIdentityResolver.flag(0))
        XCTAssertFalse(AppIdentityResolver.flag("0"))
        XCTAssertFalse(AppIdentityResolver.flag(nil))
    }

    func testSystemAgentsAreHiddenButStockAppsAreNot() {
        func identity(_ path: String) -> AppIdentity { AppIdentity(id: path, name: "x", bundlePath: path) }
        XCTAssertNotNil(AppIdentityResolver.visible(identity("/Applications/Spotify.app")))
        XCTAssertNotNil(AppIdentityResolver.visible(identity("/System/Applications/Music.app")))
        XCTAssertNotNil(AppIdentityResolver.visible(
            identity("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")
        ))
        XCTAssertNotNil(AppIdentityResolver.visible(identity("/System/Library/CoreServices/Finder.app")))
        XCTAssertNil(AppIdentityResolver.visible(identity("/System/Library/CoreServices/ControlCenter.app")))
        XCTAssertNil(AppIdentityResolver.visible(identity("/System/Library/CoreServices/Siri.app")))
        XCTAssertNotNil(AppIdentityResolver.visible(AppIdentity(id: "path:/opt/bin/mpv", name: "mpv", bundlePath: nil)))
    }

    func testSystemDaemonPaths() {
        XCTAssertTrue(AppIdentityResolver.isSystemPath("/usr/libexec/audiomxd"))
        XCTAssertTrue(AppIdentityResolver.isSystemPath("/System/Library/PrivateFrameworks/X.framework/x"))
        XCTAssertFalse(AppIdentityResolver.isSystemPath("/usr/bin/afplay"))
        XCTAssertFalse(AppIdentityResolver.isSystemPath("/opt/homebrew/bin/mpv"))
    }

    func testInvisibleCharactersAreStrippedFromNames() {
        XCTAssertEqual(AppIdentityResolver.cleaned("\u{200E}WhatsApp"), "WhatsApp")
        XCTAssertEqual(AppIdentityResolver.cleaned("  Music \n"), "Music")
        XCTAssertEqual(AppIdentityResolver.cleaned("VLC media player"), "VLC media player")
    }

    func testReadsRealBundleInfo() throws {
        let info = try XCTUnwrap(AppIdentityResolver.readBundleInfo(at: "/System/Applications/Music.app"))
        XCTAssertEqual(info.identity.id, "com.apple.Music")
        XCTAssertEqual(info.identity.bundlePath, "/System/Applications/Music.app")
        XCTAssertFalse(info.identity.name.isEmpty)
        XCTAssertTrue(info.isUserFacing)
        XCTAssertNil(AppIdentityResolver.readBundleInfo(at: "/nonexistent/Nothing.app"))
    }

    func testResolvesThisProcessWithoutCrashing() {
        // The test runner is a bare tool or lives inside Xcode; either way
        // resolution must return something consistent on repeat calls.
        let resolver = AppIdentityResolver()
        let first = resolver.resolve(pid: getpid())
        XCTAssertEqual(resolver.resolve(pid: getpid()), first)
        XCTAssertNil(resolver.resolve(pid: 1), "launchd is a system daemon")
    }

    func testParentLookupUsesProcPidInfo() {
        XCTAssertEqual(ProcessInspector.parentPID(of: getpid()), getppid())
        XCTAssertNotNil(ProcessInspector.executablePath(of: getpid()))
        XCTAssertNil(ProcessInspector.executablePath(of: -5))
    }
}

final class ModelTests: XCTestCase {
    func testTaperEndpointsAndShape() {
        XCTAssertEqual(VolumeTaper.gain(forPosition: 0), 0)
        XCTAssertEqual(VolumeTaper.gain(forPosition: 1), 1)
        XCTAssertEqual(VolumeTaper.gain(forPosition: 0.5), 0.25, accuracy: 1e-6)
        XCTAssertEqual(VolumeTaper.gain(forPosition: -3), 0)
        XCTAssertEqual(VolumeTaper.gain(forPosition: 7), 1)
        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map(VolumeTaper.gain(forPosition:))
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 }, "strictly increasing")
    }

    func testDefaultSettingMeansUntapped() {
        XCTAssertTrue(AppSetting.default.isDefault)
        XCTAssertTrue(AppSetting(volume: 1, isMuted: false).isDefault)
        XCTAssertFalse(AppSetting(volume: 0.5).isDefault)
        XCTAssertFalse(AppSetting(volume: 1, isMuted: true).isDefault)
    }

    func testMuteOverridesVolume() {
        XCTAssertEqual(AppSetting(volume: 0.8, isMuted: true).gain, 0)
        XCTAssertEqual(AppSetting(volume: 0.5).gain, 0.25, accuracy: 1e-6)
        XCTAssertEqual(AppSetting(volume: 4).volume, 1, "out-of-range values are clamped")
    }

    func testSettingsRoundTripThroughJSON() throws {
        let settings = ["com.spotify.client": AppSetting(volume: 0.4, isMuted: true)]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode([String: AppSetting].self, from: data), settings)
    }
}

final class ScrollWheelTests: XCTestCase {
    private func delta(x: CGFloat = 0, y: CGFloat = 0, precise: Bool, inverted: Bool) -> Double {
        ScrollWheelMonitor.sliderDelta(deltaX: x, deltaY: y, isPrecise: precise, isInverted: inverted)
    }

    func testWheelAwayFromUserRaisesVolumeEitherScrollSetting() {
        // Traditional scrolling: wheel up reports a positive delta.
        XCTAssertGreaterThan(delta(y: 1, precise: false, inverted: false), 0)
        // Natural scrolling: the same physical motion reports a negative one.
        XCTAssertGreaterThan(delta(y: -1, precise: false, inverted: true), 0)
        XCTAssertLessThan(delta(y: -1, precise: false, inverted: false), 0)
    }

    func testSwipeRightRaisesVolume() {
        XCTAssertGreaterThan(delta(x: 10, precise: true, inverted: true), 0)
        XCTAssertGreaterThan(delta(x: -10, precise: true, inverted: false), 0)
    }

    func testDominantAxisWins() {
        XCTAssertGreaterThan(delta(x: -1, y: 20, precise: true, inverted: false), 0)
    }

    func testOneEventCannotSlamTheSlider() {
        XCTAssertEqual(delta(y: 5000, precise: true, inverted: false), 0.2)
        XCTAssertEqual(delta(y: -5000, precise: false, inverted: false), -0.2)
        XCTAssertEqual(delta(precise: true, inverted: false), 0)
    }
}

@MainActor
final class MixerModelTests: XCTestCase {
    private func makeModel(settings: [String: AppSetting] = [:]) -> MixerModel {
        MixerModel(
            preview: MixerSnapshot(
                apps: [MixerApp(id: "a", name: "A", bundlePath: nil, isPlaying: true)],
                output: OutputState(name: "Speakers", volume: 0.5, isMuted: false, hasVolumeControl: true)
            ),
            settings: settings
        )
    }

    func testMovingTheSliderUnmutes() {
        let model = makeModel(settings: ["a": AppSetting(volume: 0.5, isMuted: true)])
        model.setVolume(0.3, for: "a")
        XCTAssertEqual(model.setting(for: "a"), AppSetting(volume: 0.3, isMuted: false))
    }

    func testMuteKeepsTheLevelForUnmute() {
        let model = makeModel(settings: ["a": AppSetting(volume: 0.6)])
        model.toggleMute(for: "a")
        XCTAssertEqual(model.setting(for: "a"), AppSetting(volume: 0.6, isMuted: true))
        model.toggleMute(for: "a")
        XCTAssertEqual(model.setting(for: "a"), AppSetting(volume: 0.6, isMuted: false))
    }

    func testReturningToFullVolumeForgetsTheApp() {
        let model = makeModel(settings: ["a": AppSetting(volume: 0.6)])
        model.setVolume(1, for: "a")
        XCTAssertNil(model.settings["a"], "default settings are not stored")
        XCTAssertTrue(model.setting(for: "a").isDefault)
    }

    func testScrollAdjustsOnlyTheHoveredSlider() {
        let model = makeModel(settings: ["a": AppSetting(volume: 0.5)])
        XCTAssertFalse(model.scrollHoveredSlider(by: 0.1), "nothing hovered: the event passes through")

        model.hover(.app("a"), true)
        XCTAssertTrue(model.scrollHoveredSlider(by: 0.1))
        XCTAssertEqual(model.setting(for: "a").volume, 0.6, accuracy: 1e-9)

        model.hover(.master, true)
        model.hover(.app("a"), false)
        XCTAssertTrue(model.scrollHoveredSlider(by: -0.2))
        XCTAssertEqual(model.masterVolume, 0.3, accuracy: 1e-6)
        XCTAssertEqual(model.setting(for: "a").volume, 0.6, accuracy: 1e-9)
    }

    func testScrollingUpFromMuteStartsFromSilence() {
        let model = makeModel(settings: ["a": AppSetting(volume: 0.8, isMuted: true)])
        model.hover(.app("a"), true)
        _ = model.scrollHoveredSlider(by: 0.1)
        XCTAssertEqual(model.setting(for: "a"), AppSetting(volume: 0.1, isMuted: false))
    }

    func testMasterVolumeIsClampedAndUnmutes() {
        let model = makeModel()
        model.toggleMasterMute()
        XCTAssertTrue(model.isMasterMuted)
        model.setMasterVolume(1.7)
        XCTAssertEqual(model.masterVolume, 1)
        XCTAssertFalse(model.isMasterMuted)
    }
}

final class SiteNameTests: XCTestCase {
    func testCommonSites() {
        XCTAssertEqual(SiteName.short(for: "https://www.youtube.com/watch?v=abc"), "youtube")
        XCTAssertEqual(SiteName.short(for: "https://app.roll20.net/editor/"), "roll20")
        XCTAssertEqual(SiteName.short(for: "https://music.youtube.com/"), "youtube")
        XCTAssertEqual(SiteName.short(for: "https://open.spotify.com/track/1"), "spotify")
        XCTAssertEqual(SiteName.short(for: "https://twitch.tv/somebody"), "twitch")
        XCTAssertEqual(SiteName.short(for: "HTTPS://WWW.Netflix.COM/browse"), "netflix")
    }

    func testCountrySuffixes() {
        XCTAssertEqual(SiteName.short(for: "https://www.bbc.co.uk/sounds"), "bbc")
        XCTAssertEqual(SiteName.short(for: "https://iview.abc.net.au/"), "abc")
        XCTAssertEqual(SiteName.short(for: "https://www.ardmediathek.de/live"), "ardmediathek")
        // A two-letter domain that is the site itself, not a suffix.
        XCTAssertEqual(SiteName.short(for: "https://youtu.be/abc"), "youtu")
    }

    func testHostsWithoutARegistrableName() {
        XCTAssertEqual(SiteName.short(for: "http://localhost:8080/player"), "localhost")
        XCTAssertEqual(SiteName.short(for: "http://192.168.1.20/stream"), "192.168.1.20")
    }

    func testNonWebLocations() {
        XCTAssertNil(SiteName.short(for: "file:///Users/me/song.html"))
        XCTAssertNil(SiteName.short(for: "about:blank"))
        XCTAssertNil(SiteName.short(for: ""))
        XCTAssertNil(SiteName.short(for: "favorites://"))
    }
}

final class BrowserSitesTests: XCTestCase {
    func testRecognisesOnlyWebContentPlaybackAssertions() {
        // Shapes taken from a live system.
        let webContent = "xpcservice<com.apple.WebKit.WebContent([app<application.com.apple.Safari.1.2(501)>:1281])(501)>{vt hash: 0}[uuid:153F14AA]{definition:com.apple.WebKit.WebContent[standard][client]}:26356616-1281-146216:WebKit Media Playback"
        let gpu = "xpcservice<com.apple.WebKit.GPU([app<application.com.apple.Safari.1.2(501)>:1281])(501)>{vt hash: 0}[uuid:690BC51B]{definition:com.apple.WebKit.GPU[standard][client]}:1498616-1281-145420:WebKit Media Playback"
        let browser = "app<application.com.apple.Safari.1.2(501)>616-1281-145419:WebKit Media Playback"

        XCTAssertTrue(BrowserSites.isWebContentPlayback(assertionName: webContent))
        XCTAssertFalse(BrowserSites.isWebContentPlayback(assertionName: gpu), "the shared audio process names no tab")
        XCTAssertFalse(BrowserSites.isWebContentPlayback(assertionName: browser))
        XCTAssertFalse(BrowserSites.isWebContentPlayback(assertionName: "com.apple.WebCore: HTMLMediaElement playback"))
    }

    func testOnlyPlayingTabsAreNamedOnceEachInTabOrder() {
        let tabs = [
            BrowserSites.Tab(pid: 10, url: "https://www.wikipedia.org/"),
            BrowserSites.Tab(pid: 11, url: "https://app.roll20.net/editor/"),
            BrowserSites.Tab(pid: 12, url: "https://www.youtube.com/watch?v=1"),
            BrowserSites.Tab(pid: 13, url: "https://www.youtube.com/watch?v=2"),
            BrowserSites.Tab(pid: 14, url: "about:blank"),
        ]
        XCTAssertEqual(BrowserSites.siteNames(of: tabs, playing: [11, 12, 13, 14, 99]), ["roll20", "youtube"])
        XCTAssertEqual(BrowserSites.siteNames(of: tabs, playing: []), [])
        XCTAssertEqual(BrowserSites.siteNames(of: [], playing: [11]), [])
    }

    func testAssertionQueryRunsWithoutPermission() {
        // Whatever is playing on the test machine, the query must not crash
        // and must return plausible pids.
        XCTAssertTrue(BrowserSites.playingWebContentPIDs().allSatisfy { $0 > 0 })
    }
}

final class AppleEventsTests: XCTestCase {
    func testFourCharacterCodes() {
        XCTAssertEqual(AppleEvents.code("core"), 0x636F_7265)
        XCTAssertEqual(AppleEvents.code("all "), 0x616C_6C20)
        XCTAssertEqual(AppleEvents.code("----"), AEKeyword(keyDirectObject))
        XCTAssertEqual(AppleEvents.code("obj "), typeObjectSpecifier)
        XCTAssertEqual(AppleEvents.code("list"), typeAEList)
    }

    func testSpecifierForPropertyOfEveryTabOfEveryWindow() throws {
        let everyTab = AppleEvents.every("bTab", of: AppleEvents.every("cwin", of: .null()))
        let specifier = AppleEvents.property("pURL", of: everyTab)

        // property pURL of ...
        XCTAssertEqual(specifier.descriptorType, typeObjectSpecifier)
        XCTAssertEqual(specifier.forKeyword(AppleEvents.code("want"))?.typeCodeValue, AppleEvents.code("prop"))
        XCTAssertEqual(specifier.forKeyword(AppleEvents.code("form"))?.enumCodeValue, AppleEvents.code("prop"))
        XCTAssertEqual(specifier.forKeyword(AppleEvents.code("seld"))?.typeCodeValue, AppleEvents.code("pURL"))

        // ... every tab of ...
        let tabs = try XCTUnwrap(specifier.forKeyword(AppleEvents.code("from")))
        XCTAssertEqual(tabs.descriptorType, typeObjectSpecifier)
        XCTAssertEqual(tabs.forKeyword(AppleEvents.code("want"))?.typeCodeValue, AppleEvents.code("bTab"))
        XCTAssertEqual(tabs.forKeyword(AppleEvents.code("form"))?.enumCodeValue, AppleEvents.code("indx"))
        XCTAssertEqual(tabs.forKeyword(AppleEvents.code("seld"))?.descriptorType, typeAbsoluteOrdinal)

        // ... every window of the application.
        let windows = try XCTUnwrap(tabs.forKeyword(AppleEvents.code("from")))
        XCTAssertEqual(windows.forKeyword(AppleEvents.code("want"))?.typeCodeValue, AppleEvents.code("cwin"))
        XCTAssertEqual(windows.forKeyword(AppleEvents.code("from"))?.descriptorType, typeNull)
    }

    func testRepliesFlattenToLeaves() {
        // Safari answers "every tab of every window" with a list per window.
        let windowOne = NSAppleEventDescriptor.list()
        windowOne.insert(NSAppleEventDescriptor(string: "https://a.example/"), at: 1)
        windowOne.insert(NSAppleEventDescriptor(string: "https://b.example/"), at: 2)
        let windowTwo = NSAppleEventDescriptor.list()
        windowTwo.insert(NSAppleEventDescriptor(int32: 4242), at: 1)
        let reply = NSAppleEventDescriptor.list()
        reply.insert(windowOne, at: 1)
        reply.insert(NSAppleEventDescriptor.list(), at: 2)
        reply.insert(windowTwo, at: 3)

        let leaves = AppleEvents.leaves(of: reply)
        XCTAssertEqual(leaves.count, 3)
        XCTAssertEqual(leaves[0].stringValue, "https://a.example/")
        XCTAssertEqual(leaves[2].int32Value, 4242)
        XCTAssertEqual(AppleEvents.leaves(of: nil).count, 0)
        XCTAssertEqual(AppleEvents.leaves(of: NSAppleEventDescriptor(string: "one")).count, 1)
    }

    func testNeverAddressesAnAppThatIsNotRunning() {
        // Sending to a bundle identifier would launch the app.
        XCTAssertEqual(AppleEvents.permission(for: "invalid.bundle.that.does.not.exist", askUser: true), .targetNotRunning)
    }
}

final class SpotifyRemoteTests: XCTestCase {
    func testCommandCodesMatchSpotifysScriptingDictionary() {
        XCTAssertEqual(SpotifyRemote.Command.previous.eventID, "Prev")
        XCTAssertEqual(SpotifyRemote.Command.playPause.eventID, "PlPs")
        XCTAssertEqual(SpotifyRemote.Command.next.eventID, "Next")
    }

    func testReadsPlayerStateFromSpotifysNotification() {
        func note(_ info: [AnyHashable: Any]?) -> Notification {
            Notification(name: SpotifyRemote.stateNotification, object: nil, userInfo: info)
        }
        XCTAssertEqual(SpotifyRemote.isPlaying(in: note(["Player State": "Playing"])), true)
        XCTAssertEqual(SpotifyRemote.isPlaying(in: note(["Player State": "Paused"])), false)
        XCTAssertEqual(SpotifyRemote.isPlaying(in: note(["Player State": "Stopped"])), false)
        XCTAssertNil(SpotifyRemote.isPlaying(in: note(nil)))
    }
}

final class SystemSoundsTests: XCTestCase {
    func testAlertVolumeBackupSurvivesAndClears() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NotchmixTests.\(UUID().uuidString)"))
        let backup = SystemSounds.AlertVolumeBackup(defaults: defaults)
        XCTAssertNil(backup.value)
        backup.value = 0.4
        // A new instance (the next launch) still sees the user's volume.
        XCTAssertEqual(SystemSounds.AlertVolumeBackup(defaults: defaults).value, 0.4)
        backup.value = nil
        XCTAssertNil(SystemSounds.AlertVolumeBackup(defaults: defaults).value)
    }

    func testClassifiesSystemSoundProcessesByBundleIDAndPath() {
        XCTAssertTrue(SystemSounds.isAlertDaemon(bundleID: "com.apple.systemsoundserverd", executablePath: nil))
        XCTAssertTrue(SystemSounds.isAlertDaemon(bundleID: nil, executablePath: "/usr/sbin/systemsoundserverd"))
        XCTAssertFalse(SystemSounds.isNotificationProcess(bundleID: "com.apple.systemsoundserverd", executablePath: nil))

        XCTAssertTrue(SystemSounds.isNotificationProcess(bundleID: "com.apple.notificationcenterui", executablePath: nil))
        XCTAssertTrue(SystemSounds.isNotificationProcess(bundleID: "com.apple.UserNotificationCenter", executablePath: nil))
        XCTAssertTrue(SystemSounds.isNotificationProcess(bundleID: "com.apple.usernoted", executablePath: nil))
        XCTAssertTrue(SystemSounds.isNotificationProcess(
            bundleID: nil,
            executablePath: "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter"
        ))
        XCTAssertTrue(SystemSounds.isNotificationProcess(bundleID: nil, executablePath: "/usr/sbin/usernoted"))

        XCTAssertTrue(SystemSounds.isSystemSoundProcess(bundleID: "com.apple.systemsoundserverd", executablePath: nil))
        XCTAssertTrue(SystemSounds.isSystemSoundProcess(bundleID: "com.apple.notificationcenterui", executablePath: nil))

        XCTAssertFalse(SystemSounds.isSystemSoundProcess(bundleID: "com.spotify.client", executablePath: "/Applications/Spotify.app/Contents/MacOS/Spotify"))
        XCTAssertFalse(SystemSounds.isSystemSoundProcess(bundleID: "com.apple.Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"))
        XCTAssertFalse(SystemSounds.isSystemSoundProcess(bundleID: "com.apple.controlcenter", executablePath: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"))
        XCTAssertFalse(SystemSounds.isSystemSoundProcess(bundleID: nil, executablePath: "/usr/libexec/audiomxd"))
    }

    func testAlertVolumeCurveEndpointsAndRoundTrip() {
        XCTAssertEqual(SystemSounds.rawAlertVolume(forPosition: 0), 0)
        XCTAssertEqual(SystemSounds.rawAlertVolume(forPosition: -0.5), 0)
        XCTAssertEqual(SystemSounds.rawAlertVolume(forPosition: 1), 1)
        XCTAssertEqual(SystemSounds.rawAlertVolume(forPosition: 2), 1)
        XCTAssertEqual(SystemSounds.rawAlertVolume(forPosition: .nan), 1)

        for position in stride(from: 0.1, through: 0.9, by: 0.1) {
            let raw = SystemSounds.rawAlertVolume(forPosition: position)
            XCTAssertGreaterThan(raw, 0)
            XCTAssertLessThan(raw, 1)
            XCTAssertEqual(SystemSounds.position(forRawAlertVolume: raw), position, accuracy: 1e-5)
        }
        XCTAssertEqual(SystemSounds.position(forRawAlertVolume: 0), 0)
        XCTAssertEqual(SystemSounds.position(forRawAlertVolume: .nan), 0)
    }

    func testCatalogExcludesSystemSoundsFromUserAppsAndCollectsObjects() {
        let catalog = AudioProcessCatalog()
        let alertProc = AudioProcess(objectID: 101, pid: 1001, bundleID: "com.apple.systemsoundserverd", isRunningOutput: true)
        let notifProc = AudioProcess(objectID: 102, pid: 1002, bundleID: "com.apple.notificationcenterui", isRunningOutput: false)
        let processes = [alertProc, notifProc]

        XCTAssertTrue(catalog.groups(from: processes).isEmpty)
        XCTAssertEqual(catalog.systemSoundObjects(from: processes, includeAlertDaemon: false), [102])
        XCTAssertEqual(catalog.systemSoundObjects(from: processes, includeAlertDaemon: true), [101, 102])
    }

    @MainActor
    func testMixerModelControlsAndIconForSystemSounds() {
        let model = MixerModel(
            preview: MixerSnapshot(
                apps: [],
                output: OutputState(name: "Speakers", volume: 0.8, isMuted: false, hasVolumeControl: true)
            ),
            settings: [:]
        )

        model.toggleMute(for: SystemSounds.id)
        XCTAssertEqual(model.setting(for: SystemSounds.id), AppSetting(volume: 1, isMuted: true))

        model.hover(.app(SystemSounds.id), true)
        XCTAssertTrue(model.scrollHoveredSlider(by: 0.25))
        XCTAssertEqual(model.setting(for: SystemSounds.id), AppSetting(volume: 0.25, isMuted: false))

        let icon = model.icon(for: .systemSounds)
        XCTAssertGreaterThan(icon.size.width, 0)
        XCTAssertGreaterThan(icon.size.height, 0)
    }
}

final class EnhancedMixerFeaturesTests: XCTestCase {
    func testCustomOutputDeviceMakesSettingNonDefaultAndRoundTrips() throws {
        let routed = AppSetting(volume: 1, isMuted: false, outputDeviceUID: "usb-dac")
        XCTAssertFalse(routed.isDefault)
        let data = try JSONEncoder().encode(routed)
        XCTAssertEqual(try JSONDecoder().decode(AppSetting.self, from: data), routed)

        let cleared = AppSetting(volume: 1, isMuted: false, outputDeviceUID: nil)
        XCTAssertTrue(cleared.isDefault)
    }

    @MainActor
    func testPerAppOutputRoutingClearsBackToDefault() {
        let model = MixerModel(
            preview: MixerSnapshot(
                apps: [MixerApp(id: "a", name: "App A", bundlePath: nil, isPlaying: true)],
                output: OutputState(name: "Speakers", volume: 0.8, isMuted: false, hasVolumeControl: true),
                devices: [
                    OutputDeviceInfo(id: "speakers", name: "Speakers", isDefault: true),
                    OutputDeviceInfo(id: "headphones", name: "Headphones", isDefault: false),
                ]
            ),
            settings: [:]
        )

        model.setOutputDevice("headphones", for: "a")
        XCTAssertEqual(model.setting(for: "a").outputDeviceUID, "headphones")
        XCTAssertEqual(model.routedDeviceName(for: "a"), "Headphones")

        // Choosing the current default output clears the override so the app
        // can be released back to bit-perfect default playback.
        model.setOutputDevice("speakers", for: "a")
        XCTAssertNil(model.setting(for: "a").outputDeviceUID)
        XCTAssertNil(model.routedDeviceName(for: "a"))
        XCTAssertTrue(model.setting(for: "a").isDefault)
    }

    func testMediaPlayerSelectionPrefersPlayingApp() {
        XCTAssertNil(MediaPlayer.activePlayer(
            spotifyRunning: false, spotifyPlaying: false, musicRunning: false, musicPlaying: false
        ))
        XCTAssertEqual(MediaPlayer.activePlayer(
            spotifyRunning: true, spotifyPlaying: false, musicRunning: true, musicPlaying: true
        ), .appleMusic)
        XCTAssertEqual(MediaPlayer.activePlayer(
            spotifyRunning: true, spotifyPlaying: true, musicRunning: true, musicPlaying: false
        ), .spotify)
        XCTAssertEqual(MediaPlayer.activePlayer(
            spotifyRunning: true, spotifyPlaying: true, musicRunning: true, musicPlaying: true, preferred: .appleMusic
        ), .appleMusic)
    }

    func testBrowserSitesSupportsChromiumAndOperaBrowsers() {
        XCTAssertTrue(BrowserSites.supportedBundleIDs.contains("com.apple.Safari"))
        XCTAssertTrue(BrowserSites.chromiumBundleIDs.contains("com.google.Chrome"))
        XCTAssertTrue(BrowserSites.chromiumBundleIDs.contains("com.brave.Browser"))
        XCTAssertTrue(BrowserSites.chromiumBundleIDs.contains("company.thebrowser.Browser"))
        XCTAssertTrue(BrowserSites.chromiumBundleIDs.contains("com.microsoft.edgemac"))
        XCTAssertTrue(BrowserSites.chromiumBundleIDs.contains("com.operasoftware.OperaGX"))
    }
}
