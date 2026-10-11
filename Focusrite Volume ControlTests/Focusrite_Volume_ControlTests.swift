import XCTest
import Combine
@testable import Focusrite_Volume_Control

final class Focusrite_Volume_ControlTests: XCTestCase {
    func testEachVolumeKeyMovesExactlyOneTickAndRetraces() {
        let controller = VolumeController(backend: StubBackend())
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
        let controller = VolumeController(backend: StubBackend())
        for volume in -6...5 {
            controller.setPlaybackVolume(Double(volume))
            controller.playbackVolumeUp()
            XCTAssertEqual(controller.playbackVolume, Double(volume + 1))
        }
    }

    func testPlusSixIsFullScale() {
        let controller = VolumeController(backend: StubBackend())
        controller.setPlaybackVolume(5)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.playbackVolume, 6)
        controller.playbackVolumeUp()
        XCTAssertEqual(controller.playbackVolume, 6)
    }

    func testOptimisticValueAccumulatesWhileBackendIsBusy() {
        let controller = VolumeController(backend: StubBackend())
        controller.setPlaybackVolume(-6)
        controller.playbackVolumeUp()
        controller.playbackVolumeUp()
        controller.playbackVolumeDown()
        XCTAssertEqual(controller.playbackVolume, -5)
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
