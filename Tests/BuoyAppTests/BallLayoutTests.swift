import XCTest
@testable import BuoyApp

/// Pure layout math for the independent balls + position-storage contract.
final class BallLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: Default vertical stack

    func test_defaultOrigins_countMatches() {
        let origins = BallLayout.defaultOrigins(count: 3, in: screen, ballSize: 88,
                                                spacing: 6, margin: 16)
        XCTAssertEqual(origins.count, 3)
    }

    func test_defaultOrigins_emptyForZeroCount() {
        let origins = BallLayout.defaultOrigins(count: 0, in: screen, ballSize: 88,
                                                spacing: 6, margin: 16)
        XCTAssertTrue(origins.isEmpty)
    }

    func test_defaultOrigin_topRightAnchored() {
        // First ball sits at the top-right, offset by margin and the menu-bar inset.
        let origin = BallLayout.defaultOrigin(index: 0, in: screen, ballSize: 88,
                                               spacing: 6, margin: 16)
        XCTAssertEqual(origin.x, screen.maxX - 88 - 16, accuracy: 0.001)
        XCTAssertEqual(origin.y, screen.maxY - 88 - 16 - BallLayout.menuBarInset, accuracy: 0.001)
    }

    func test_defaultOrigins_descendByStride() {
        let o0 = BallLayout.defaultOrigin(index: 0, in: screen, ballSize: 88, spacing: 6, margin: 16)
        let o1 = BallLayout.defaultOrigin(index: 1, in: screen, ballSize: 88, spacing: 6, margin: 16)
        let o2 = BallLayout.defaultOrigin(index: 2, in: screen, ballSize: 88, spacing: 6, margin: 16)
        XCTAssertEqual(o0.x, o1.x)                        // same column
        XCTAssertEqual(o1.y, o0.y - (88 + 6), accuracy: 0.001) // each step drops by ballSize + spacing
        XCTAssertEqual(o2.y, o0.y - 2 * (88 + 6), accuracy: 0.001)
    }

    // MARK: Clamp

    func test_clamped_pullsOffscreenOriginInside() {
        let origin = CGPoint(x: screen.maxX + 500, y: screen.maxY + 500)
        let clamped = BallLayout.clamped(origin, ballSize: 88, in: screen, margin: 16)
        XCTAssertEqual(clamped.x, screen.maxX - 88 - 16, accuracy: 0.001)
        XCTAssertEqual(clamped.y, screen.maxY - 88 - 16, accuracy: 0.001)
    }

    func test_clamped_leavesValidOriginUntouched() {
        let origin = CGPoint(x: 200, y: 200)
        let clamped = BallLayout.clamped(origin, ballSize: 88, in: screen, margin: 16)
        XCTAssertEqual(clamped.x, 200, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 200, accuracy: 0.001)
    }

    // MARK: Position storage round-trip

    func test_positionStorage_roundTrip() {
        let storage = InMemoryBallPositionStorage()
        XCTAssertNil(storage.loadOrigin(for: "volcano"))
        storage.saveOrigin(CGPoint(x: 100, y: 200), for: "volcano")
        let loaded = storage.loadOrigin(for: "volcano")
        XCTAssertEqual(Double(loaded?.x ?? 0), 100, accuracy: 0.001)
        XCTAssertEqual(Double(loaded?.y ?? 0), 200, accuracy: 0.001)
    }

    func test_positionStorage_isolatesPerProvider() {
        let storage = InMemoryBallPositionStorage()
        storage.saveOrigin(CGPoint(x: 1, y: 2), for: "volcano")
        storage.saveOrigin(CGPoint(x: 3, y: 4), for: "deepseek")
        XCTAssertEqual(Double(storage.loadOrigin(for: "volcano")?.x ?? 0), 1, accuracy: 0.001)
        XCTAssertEqual(Double(storage.loadOrigin(for: "deepseek")?.x ?? 0), 3, accuracy: 0.001)
    }

    // MARK: Non-overlapping default slot

    private func slot(_ index: Int, count: Int) -> CGPoint {
        BallLayout.defaultOrigins(count: count, in: screen, ballSize: 88, spacing: 6, margin: 16)[index]
    }

    private func assertEqualPoint(_ a: CGPoint, _ b: CGPoint,
                                  file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, file: file, line: line)
    }

    func test_firstNonOverlapping_returnsFirstSlotWhenNothingOccupied() {
        let origin = BallLayout.firstNonOverlappingDefault(count: 2, in: screen, ballSize: 88,
                                                           spacing: 6, margin: 16, avoiding: [])
        assertEqualPoint(origin, slot(0, count: 2))
    }

    func test_firstNonOverlapping_skipsKeptBallSlot() {
        // Two balls were at slots 0 and 1; the first was removed, leaving the second at slot 1.
        // A newly added ball (count still 2) must take slot 0, NOT stack on slot 1.
        let occupied = [slot(1, count: 2)]
        let origin = BallLayout.firstNonOverlappingDefault(count: 2, in: screen, ballSize: 88,
                                                           spacing: 6, margin: 16, avoiding: occupied)
        assertEqualPoint(origin, slot(0, count: 2))
    }

    func test_firstNonOverlapping_picksNextFreeSlot() {
        // Slot 0 is taken; the new ball should take slot 1.
        let occupied = [slot(0, count: 2)]
        let origin = BallLayout.firstNonOverlappingDefault(count: 2, in: screen, ballSize: 88,
                                                           spacing: 6, margin: 16, avoiding: occupied)
        assertEqualPoint(origin, slot(1, count: 2))
    }

    func test_firstNonOverlapping_fallsBackToLastWhenAllOverlap() {
        // Both slots occupied -> fall back to the last default origin rather than .zero.
        let occupied = [slot(0, count: 2), slot(1, count: 2)]
        let origin = BallLayout.firstNonOverlappingDefault(count: 2, in: screen, ballSize: 88,
                                                           spacing: 6, margin: 16, avoiding: occupied)
        assertEqualPoint(origin, slot(1, count: 2))
    }
}

/// In-memory BallPositionStorage for tests (isolates UserDefaults).
private final class InMemoryBallPositionStorage: BallPositionStorage {
    private var origins: [String: CGPoint] = [:]
    func loadOrigin(for id: String) -> CGPoint? { origins[id] }
    func saveOrigin(_ origin: CGPoint, for id: String) { origins[id] = origin }
}
