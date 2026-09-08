import CoreGraphics
import Foundation

enum PointerMotionProfile: String {
    case fast
    case precise
}

enum PointerMotionKind {
    case move
    case click
    case doubleClick
}

struct PointerMotionRequest {
    let start: CGPoint
    let end: CGPoint
    let profile: PointerMotionProfile
    let kind: PointerMotionKind
    let seed: UInt64?
}

struct PointerMotionSample {
    let point: CGPoint
    let delayMicros: UInt32
}

struct PointerMotionPlan {
    let samples: [PointerMotionSample]
    let interClickDelayMicros: UInt32?

    var totalDurationMicros: UInt64 {
        samples.reduce(into: UInt64(0)) { partial, sample in
            partial += UInt64(sample.delayMicros)
        }
    }
}

struct PointerMotionRNG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed != 0 ? seed : 0x9e3779b97f4a7c15
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(nextUInt64() >> 11) / Double(1 << 53)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextDouble()
    }

    mutating func chance(_ probability: Double) -> Bool {
        nextDouble() < probability
    }
}

private struct PointerMotionConfig {
    let planDelayMs: ClosedRange<Double>
    let baseDurationMs: ClosedRange<Double>
    let distanceFactorMs: Double
    let stepIntervalMs: ClosedRange<Double>
    let driftFactor: Double
    let driftMax: Double
    let overshootChance: Double
    let overshootPx: ClosedRange<Double>
    let settleRadiusPx: Double
    let settleSteps: Int
    let doubleClickDelayMs: ClosedRange<Double>

    static func forProfile(_ profile: PointerMotionProfile) -> PointerMotionConfig {
        switch profile {
        case .fast:
            return PointerMotionConfig(
                planDelayMs: 8...22,
                baseDurationMs: 120...170,
                distanceFactorMs: 0.48,
                stepIntervalMs: 7...13,
                driftFactor: 0.045,
                driftMax: 10,
                overshootChance: 0.16,
                overshootPx: 1.5...4.5,
                settleRadiusPx: 1.4,
                settleSteps: 2,
                doubleClickDelayMs: 72...122
            )
        case .precise:
            return PointerMotionConfig(
                planDelayMs: 14...32,
                baseDurationMs: 175...235,
                distanceFactorMs: 0.72,
                stepIntervalMs: 9...15,
                driftFactor: 0.03,
                driftMax: 7,
                overshootChance: 0.08,
                overshootPx: 1.0...2.6,
                settleRadiusPx: 0.85,
                settleSteps: 3,
                doubleClickDelayMs: 95...160
            )
        }
    }
}

enum PointerMotionEngine {
    static func buildPlan(_ request: PointerMotionRequest) -> PointerMotionPlan {
        var rng = PointerMotionRNG(seed: request.seed ?? runtimeSeed())
        let config = PointerMotionConfig.forProfile(request.profile)
        let distance = hypot(request.end.x - request.start.x, request.end.y - request.start.y)

        if distance < 0.5 {
            let delay = micros(rng.uniform(config.planDelayMs))
            return PointerMotionPlan(
                samples: [PointerMotionSample(point: request.end, delayMicros: delay)],
                interClickDelayMicros: request.kind == .doubleClick ? micros(rng.uniform(config.doubleClickDelayMs)) : nil
            )
        }

        let direction = normalize(request.end - request.start)
        let perpendicular = CGPoint(x: -direction.y, y: direction.x)
        let driftAmplitude = min(max(distance * config.driftFactor, 0.8), config.driftMax)
        let movementDurationMs = clamp(
            rng.uniform(config.baseDurationMs) + distance * config.distanceFactorMs,
            lower: config.baseDurationMs.lowerBound,
            upper: config.baseDurationMs.upperBound + distance * 0.9
        )

        var samples: [PointerMotionSample] = []
        samples.append(PointerMotionSample(point: request.start, delayMicros: micros(rng.uniform(config.planDelayMs))))

        let shouldOvershoot = request.kind != .move && distance > 36 && rng.chance(config.overshootChance)
        let primaryTarget: CGPoint
        if shouldOvershoot {
            let amount = min(rng.uniform(config.overshootPx), max(1.0, distance * 0.12))
            let lateral = rng.uniform(-driftAmplitude * 0.18...driftAmplitude * 0.18)
            primaryTarget = request.end + direction * amount + perpendicular * lateral
        } else {
            primaryTarget = request.end
        }

        samples += segmentSamples(
            from: request.start,
            to: primaryTarget,
            profile: request.profile,
            durationMs: movementDurationMs,
            driftAmplitude: driftAmplitude,
            rng: &rng
        )

        if shouldOvershoot {
            let correctionDurationMs = request.profile == .fast ? rng.uniform(36...68) : rng.uniform(48...92)
            samples += segmentSamples(
                from: primaryTarget,
                to: request.end,
                profile: request.profile,
                durationMs: correctionDurationMs,
                driftAmplitude: driftAmplitude * 0.18,
                rng: &rng
            )
        }

        let settleBase = config.settleRadiusPx * min(1.0, distance / 120.0)
        if settleBase > 0.2 {
            for index in 0..<config.settleSteps {
                let factor = Double(config.settleSteps - index) / Double(config.settleSteps)
                let radius = settleBase * factor
                let angle = rng.uniform(0...(2 * Double.pi))
                let settlePoint = CGPoint(
                    x: request.end.x + cos(angle) * radius,
                    y: request.end.y + sin(angle) * radius
                )
                samples.append(
                    PointerMotionSample(
                        point: settlePoint,
                        delayMicros: micros(rng.uniform(request.profile == .fast ? 6...14 : 9...18))
                    )
                )
            }
        }

        samples.append(
            PointerMotionSample(
                point: request.end,
                delayMicros: micros(rng.uniform(request.profile == .fast ? 7...16 : 10...20))
            )
        )

        return PointerMotionPlan(
            samples: compress(samples),
            interClickDelayMicros: request.kind == .doubleClick ? micros(rng.uniform(config.doubleClickDelayMs)) : nil
        )
    }

    private static func segmentSamples(
        from start: CGPoint,
        to end: CGPoint,
        profile: PointerMotionProfile,
        durationMs: Double,
        driftAmplitude: Double,
        rng: inout PointerMotionRNG
    ) -> [PointerMotionSample] {
        let distance = hypot(end.x - start.x, end.y - start.y)
        if distance < 0.25 {
            return []
        }

        let direction = normalize(end - start)
        let perpendicular = CGPoint(x: -direction.y, y: direction.x)
        let intervalRange: ClosedRange<Double> = profile == .fast ? 7...13 : 9...15
        let averageInterval = rng.uniform(intervalRange)
        let stepCount = max(6, min(96, Int((durationMs / averageInterval).rounded())))

        let controlA = rng.uniform(-0.85...0.85)
        let controlB = rng.uniform(-0.5...0.5)
        let wavePhase = rng.uniform(0...(2 * Double.pi))
        let waveWeight = rng.uniform(0.22...0.55)
        var samples: [PointerMotionSample] = []

        for step in 1...stepCount {
            let t = Double(step) / Double(stepCount)
            let base = minimumJerk(start: start, end: end, t: t)
            let envelope = pow(sin(Double.pi * t), profile == .fast ? 0.95 : 1.25)
            let blended = ((1.0 - t) * controlA + t * controlB)
            let sinusoid = sin(Double.pi * t + wavePhase) * waveWeight
            let lateral = driftAmplitude * envelope * (blended + sinusoid)
            let point = base + perpendicular * lateral
            let delay = micros(jitteredInterval(baseMs: durationMs / Double(stepCount), rng: &rng, profile: profile, progress: t))
            samples.append(PointerMotionSample(point: point, delayMicros: delay))
        }

        return samples
    }

    private static func jitteredInterval(
        baseMs: Double,
        rng: inout PointerMotionRNG,
        profile: PointerMotionProfile,
        progress: Double
    ) -> Double {
        let jitter = profile == .fast ? rng.uniform(0.88...1.17) : rng.uniform(0.9...1.14)
        let endDensity = progress > 0.78 ? rng.uniform(0.85...0.98) : 1.0
        return max(4.0, baseMs * jitter * endDensity)
    }

    private static func minimumJerk(start: CGPoint, end: CGPoint, t: Double) -> CGPoint {
        let s = 10 * pow(t, 3) - 15 * pow(t, 4) + 6 * pow(t, 5)
        return CGPoint(
            x: start.x + (end.x - start.x) * s,
            y: start.y + (end.y - start.y) * s
        )
    }

    private static func compress(_ samples: [PointerMotionSample]) -> [PointerMotionSample] {
        guard !samples.isEmpty else { return [] }
        var result: [PointerMotionSample] = []
        var previous: CGPoint?
        for (index, sample) in samples.enumerated() {
            // The final sample is the requested endpoint, not disposable jitter.
            if index != samples.count - 1,
               let previous, hypot(previous.x - sample.point.x, previous.y - sample.point.y) < 0.2 {
                if !result.isEmpty {
                    let mergedDelay = min(UInt32.max, result[result.count - 1].delayMicros &+ sample.delayMicros)
                    result[result.count - 1] = PointerMotionSample(point: result[result.count - 1].point, delayMicros: mergedDelay)
                }
                continue
            }
            result.append(sample)
            previous = sample.point
        }
        return result
    }

    private static func normalize(_ vector: CGPoint) -> CGPoint {
        let length = hypot(vector.x, vector.y)
        guard length > 0 else { return .zero }
        return CGPoint(x: vector.x / length, y: vector.y / length)
    }

    private static func micros(_ milliseconds: Double) -> UInt32 {
        UInt32(max(0.0, (milliseconds * 1_000.0).rounded()))
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private static func runtimeSeed() -> UInt64 {
        let time = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        return time ^ UInt64(bitPattern: Int64(ProcessInfo.processInfo.systemUptime * 10_000))
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

private func * (lhs: CGPoint, rhs: Double) -> CGPoint {
    CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
}
