import XCTest
import Combine
@testable import Focusrite_Volume_Control

final class Focusrite_Volume_ControlTests: XCTestCase {
    func testEachVolumeKeyMovesExactlyOneTickAndRetraces() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        for tick in 0..<VolumeTickScale.maximumTick {
            controller.setPlaybackVolume(VolumeTickScale.levels[tick])
            controller.playbackVolumeUp()
            XCTAssertEqual(VolumeTickScale.tick(for: controller.playbackVolume), tick + 1)
            XCTAssertEqual(controller.playbackVolume, VolumeTickScale.levels[tick + 1])
            controller.playbackVolumeDown()
            XCTAssertEqual(VolumeTickScale.tick(for: controller.playbackVolume), tick)
            XCTAssertEqual(controller.playbackVolume, VolumeTickScale.levels[tick])
        }
    }

    func testHigherTicksUseOneDbSteps() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        for volume in -6...5 {
            controller.setPlaybackVolume(Double(volume))
            controller.playbackVolumeUp()
            XCTAssertEqual(controller.playbackVolume, Double(volume + 1))
        }
    }

    func testPlusSixIsFullScale() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.setPlaybackVolume(5)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.playbackVolume, 6)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.playbackVolume, 6)
    }

    func testOptimisticValueAccumulatesWhileBackendIsBusy() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.setPlaybackVolume(-6)
        controller.playbackVolumeUp()
        controller.playbackVolumeUp()
        controller.playbackVolumeDown()
        XCTAssertEqual(controller.playbackVolume, -5)
    }

    func testPerceptualMidpointAndEndpointsWithAndWithoutGain() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = true
        for allowGain in [false, true] {
            controller.allowGain = allowGain
            XCTAssertEqual(controller.maximumVolumeTick, 16)
            XCTAssertEqual(controller.volumeForTick(0), -127)
            XCTAssertEqual(controller.volumeForTick(8), -16)
            XCTAssertEqual(controller.volumeForTick(16), allowGain ? 6 : 0)
            XCTAssertTrue(controller.volumeLevels.contains(0))
            XCTAssertEqual(Set(controller.volumeLevels).count, 17)
            XCTAssertEqual(controller.volumeLevels, controller.volumeLevels.sorted())
        }
    }

    func testPerceptualKeysSliderAndHUDStayOnTheSameTick() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        let hud = VolumeHUDViewModel()
        controller.usePerceptualVolumeCurve = true
        for allowGain in [false, true] {
            controller.allowGain = allowGain
            hud.levels = controller.volumeLevels
            for tick in 0..<16 {
                controller.setPlaybackVolume(controller.volumeForTick(tick))
                controller.playbackVolumeUp()
                hud.volumeDb = controller.playbackVolume
                hud.isMuted = controller.playbackMuted
                XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), tick + 1)
                XCTAssertEqual(hud.filledTickCount, tick + 1)
                XCTAssertEqual(controller.playbackVolume, controller.volumeForTick(tick + 1))

                controller.playbackVolumeDown()
                hud.volumeDb = controller.playbackVolume
                hud.isMuted = controller.playbackMuted
                XCTAssertEqual(hud.filledTickCount, tick)
                XCTAssertEqual(controller.playbackVolume, controller.volumeForTick(tick))
            }
        }
    }

    func testPerceptualRapidPressesAccumulateAndStopAtEndpoints() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = true
        controller.setPlaybackVolume(-16)
        controller.playbackVolumeUp()
        controller.playbackVolumeUp()
        controller.playbackVolumeDown()
        XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), 9)
        XCTAssertEqual(controller.playbackVolume, -13)

        for _ in 0..<30 { controller.playbackVolumeUp() }
        XCTAssertEqual(controller.playbackVolume, 6)
        for _ in 0..<30 { controller.playbackVolumeDown() }
        XCTAssertEqual(controller.playbackVolume, -127)
        XCTAssertTrue(controller.playbackMuted)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), 1)
        XCTAssertFalse(controller.playbackMuted)
    }

    func testChangingCurvePreservesCurrentVolumeAndMuteRestore() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.setPlaybackVolume(-12)
        controller.usePerceptualVolumeCurve = true
        XCTAssertEqual(controller.playbackVolume, -12)
        controller.mute()
        controller.usePerceptualVolumeCurve = false
        XCTAssertTrue(controller.playbackMuted)
        controller.unmute()
        XCTAssertEqual(controller.playbackVolume, -12)
        XCTAssertFalse(controller.playbackMuted)
    }

    func testPerceptualKeyMovesOneTickFromAnExternalOffGridValue() {
        let controller = VolumeController(backend: StubBackend(), preferences: nil)
        controller.usePerceptualVolumeCurve = true
        controller.setPlaybackVolume(-14)
        let initialTick = controller.volumeTick(for: controller.playbackVolume)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), initialTick + 1)
        controller.playbackVolumeDown()
        XCTAssertEqual(controller.volumeTick(for: controller.playbackVolume), initialTick)
    }

    func testPerceptualCurvePreferenceSurvivesControllerReload() {
        let domain = "FocusriteVolumeControlTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let original = VolumeController(backend: StubBackend(), preferences: preferences)
        XCTAssertFalse(original.usePerceptualVolumeCurve)
        original.usePerceptualVolumeCurve = true
        let reloaded = VolumeController(backend: StubBackend(), preferences: preferences)
        XCTAssertTrue(reloaded.usePerceptualVolumeCurve)
        reloaded.usePerceptualVolumeCurve = false
        XCTAssertFalse(VolumeController(backend: StubBackend(), preferences: preferences).usePerceptualVolumeCurve)
    }
}

private final class StubBackend: VolumeBackend {
    private let subject = CurrentValueSubject<VolumeState, Never>(VolumeState())
    var statePublisher: AnyPublisher<VolumeState, Never> { subject.eraseToAnyPublisher() }
    func connect() async -> VolumeResult { .success }
    func disconnect() {}
    func refresh() async -> VolumeResult { .success }
    func setPlaybackVolume(_ db: Double, ensureDirectMonitor: Bool) async -> VolumeResult { .success }
    func setDirectMonitorEnabled(_ enabled: Bool) async -> VolumeResult { .success }
}
