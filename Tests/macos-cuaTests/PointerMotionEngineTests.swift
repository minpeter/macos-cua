import CoreGraphics
import XCTest
@testable import macos_cua

final class PointerMotionEngineTests: XCTestCase {
    func testPlanIsDeterministicForSeed() {
        let request = PointerMotionRequest(
            start: CGPoint(x: 10, y: 10),
            end: CGPoint(x: 420, y: 260),
            profile: .fast,
            kind: .click,
            seed: 42
        )

        let lhs = PointerMotionEngine.buildPlan(request)
        let rhs = PointerMotionEngine.buildPlan(request)

        XCTAssertEqual(lhs.samples.count, rhs.samples.count)
        XCTAssertEqual(lhs.interClickDelayMicros, rhs.interClickDelayMicros)
        XCTAssertEqual(lhs.samples.map(\.delayMicros), rhs.samples.map(\.delayMicros))
        for (a, b) in zip(lhs.samples, rhs.samples) {
            XCTAssertEqual(a.point.x, b.point.x, accuracy: 0.0001)
            XCTAssertEqual(a.point.y, b.point.y, accuracy: 0.0001)
        }
    }

    func testFinalPointAlwaysMatchesTarget() {
        let target = CGPoint(x: 620, y: 444)
        let plan = PointerMotionEngine.buildPlan(
            PointerMotionRequest(
                start: CGPoint(x: 0, y: 0),
                end: target,
                profile: .fast,
                kind: .move,
                seed: 7
            )
        )

        guard let lastPoint = plan.samples.last?.point else {
            XCTFail("Expected at least one sampled point")
            return
        }

        XCTAssertEqual(lastPoint.x, target.x, accuracy: 0.0001)
        XCTAssertEqual(lastPoint.y, target.y, accuracy: 0.0001)
    }

    func testCompressionPreservesExactShortMoveEndpoints() {
        for profile in [PointerMotionProfile.fast, .precise] {
            for distance in [0.25, 1.0, 20.0, 40.0, 80.0] {
                for seed in UInt64(1)...16 {
                    let target = CGPoint(x: 200 + distance, y: 240)
                    let plan = PointerMotionEngine.buildPlan(PointerMotionRequest(
                        start: CGPoint(x: 200, y: 240), end: target,
                        profile: profile, kind: .move, seed: seed))
                    XCTAssertEqual(plan.samples.last?.point, target, "profile=\(profile) distance=\(distance) seed=\(seed)")
                }
            }
        }
    }

    func testIntervalsAreNotUniform() {
        let plan = PointerMotionEngine.buildPlan(
            PointerMotionRequest(
                start: CGPoint(x: 20, y: 20),
                end: CGPoint(x: 600, y: 300),
                profile: .fast,
                kind: .move,
                seed: 11
            )
        )

        let uniqueIntervals = Set(plan.samples.map(\.delayMicros))
        XCTAssertGreaterThan(uniqueIntervals.count, 3)
    }

    func testPathIsNotDegenerateStraightInterpolation() {
        let start = CGPoint(x: 50, y: 80)
        let end = CGPoint(x: 540, y: 310)
        let plan = PointerMotionEngine.buildPlan(
            PointerMotionRequest(
                start: start,
                end: end,
                profile: .fast,
                kind: .click,
                seed: 99
            )
        )

        let deviations = plan.samples.dropFirst().dropLast().map { sample -> Double in
            perpendicularDistance(from: sample.point, start: start, end: end)
        }
        XCTAssertGreaterThan(deviations.max() ?? 0, 0.8)
    }

    func testPreciseHasTighterTerminalBehaviorThanFast() {
        let fast = PointerMotionEngine.buildPlan(
            PointerMotionRequest(
                start: CGPoint(x: 100, y: 100),
                end: CGPoint(x: 700, y: 500),
                profile: .fast,
                kind: .click,
                seed: 1234
            )
        )
        let precise = PointerMotionEngine.buildPlan(
            PointerMotionRequest(
                start: CGPoint(x: 100, y: 100),
                end: CGPoint(x: 700, y: 500),
                profile: .precise,
                kind: .click,
                seed: 1234
            )
        )

        XCTAssertLessThan(terminalRadius(of: precise), terminalRadius(of: fast))
    }

    func testDoubleClickDelayFallsWithinProfileRange() {
        let fast = PointerMotionEngine.buildPlan(
            PointerMotionRequest(
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 300, y: 220),
                profile: .fast,
                kind: .doubleClick,
                seed: 555
            )
        )
        let precise = PointerMotionEngine.buildPlan(
            PointerMotionRequest(
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 300, y: 220),
                profile: .precise,
                kind: .doubleClick,
                seed: 555
            )
        )

        XCTAssertNotNil(fast.interClickDelayMicros)
        XCTAssertNotNil(precise.interClickDelayMicros)
        XCTAssertTrue((72_000...122_000).contains(Int(fast.interClickDelayMicros ?? 0)))
        XCTAssertTrue((95_000...160_000).contains(Int(precise.interClickDelayMicros ?? 0)))
    }

    private func perpendicularDistance(from point: CGPoint, start: CGPoint, end: CGPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let numerator = abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x)
        let denominator = hypot(dx, dy)
        return denominator > 0 ? numerator / denominator : 0
    }

    private func terminalRadius(of plan: PointerMotionPlan) -> Double {
        guard let target = plan.samples.last?.point else { return .infinity }
        let tail = plan.samples.suffix(4)
        return tail.map { hypot($0.point.x - target.x, $0.point.y - target.y) }.max() ?? .infinity
    }
}
