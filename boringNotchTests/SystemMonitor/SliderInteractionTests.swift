import XCTest
@testable import Dynamic_Peninsula

final class SliderInteractionTests: XCTestCase {
    func testDragPositionMapsAndClampsToSeekRange() {
        XCTAssertEqual(SliderDragMath.value(locationX: -10, width: 100, range: 0...240), 0)
        XCTAssertEqual(SliderDragMath.value(locationX: 50, width: 100, range: 0...240), 120)
        XCTAssertEqual(SliderDragMath.value(locationX: 150, width: 100, range: 0...240), 240)
        XCTAssertEqual(SliderDragMath.value(locationX: 50, width: 0, range: 10...20), 10)
    }

    func testRepeatedDragCallbacksKeepOneBalancedInteractionSession() {
        var interaction = SliderInteractionBalance()
        XCTAssertTrue(interaction.beginIfNeeded())
        XCTAssertFalse(interaction.beginIfNeeded())
        XCTAssertTrue(interaction.isActive)
        XCTAssertTrue(interaction.endIfNeeded())
        XCTAssertFalse(interaction.endIfNeeded())
        XCTAssertFalse(interaction.isActive)
    }
}
