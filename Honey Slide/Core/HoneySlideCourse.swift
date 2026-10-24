import Foundation

/// A run owns one generated course. Turns change the travel heading, rather
/// than shifting flat checkpoint anchors sideways along a repeating sine.
struct HoneySlideCourse {
    struct Sample {
        let x: Double
        let slope: Double
        let turnRate: Double
    }

    struct Bend {
        let start: Double
        let length: Double
        let startX: Double
        let startSlope: Double
        let endSlope: Double
        var end: Double { start + length }
        var direction: Double { endSlope == startSlope ? 0 : endSlope > startSlope ? 1 : -1 }
    }

    // Exact geometry helpers have a reproducible default for previews/checks.
    // Live games always pass the course belonging to their simulation.
    static let preview = HoneySlideCourse(seed: 42, initialSegments: 128)
    let seed: UInt64
    private(set) var bends: [Bend] = []
    private var generator: SeededGenerator
    private var nextDirection: Double
    private var nextX = 0.0
    private var nextSlope = 0.0
    private var finishStraight: (position: Double, x: Double, slope: Double)?

    init(seed: UInt64, initialSegments: Int = 16) {
        self.seed = seed
        generator = SeededGenerator(seed: seed)
        nextDirection = Bool.random(using: &generator) ? 1 : -1
        appendSegments(count: initialSegments)
    }

    mutating func extend(through position: Double) {
        let required = max(1, Int(ceil((position - HoneySlideRules.playerAhead)
            / HoneySlideRules.checkpointSpacing)) + 1)
        if required > bends.count { appendSegments(count: required - bends.count) }
    }

    mutating func straightenFinish(after position: Double) {
        guard finishStraight == nil else { return }
        let anchor = sample(at: position)
        finishStraight = (position, anchor.x, anchor.slope)
    }

    private mutating func appendSegments(count: Int) {
        for _ in 0..<count {
            let row = HoneySlideRules.playerAhead + Double(bends.count) * HoneySlideRules.checkpointSpacing
            // Keep the answer approach clear, but give the curve more of the
            // interval. Broad arcs replace the short, nearly identical corners.
            let lead = Double.random(in: 560...760, using: &generator)
            let length = min(Double.random(in: 1200...1700, using: &generator),
                             HoneySlideRules.checkpointSpacing - lead - HoneySlideRules.straightHalfLength)
            let tail = HoneySlideRules.checkpointSpacing - lead - length
            let heading = atan(nextSlope)
            let headingLimit = 55.0 * .pi / 180
            let endSlope: Double
            if bends.isEmpty {
                endSlope = nextDirection * tan(Double.random(in: 22...32, using: &generator) * .pi / 180)
            } else if Int.random(in: 0..<100, using: &generator) < 16 {
                // A whole interval may continue straight, so even the spacing
                // between visible turns has no fixed left-right rhythm.
                endSlope = nextSlope
            } else {
                if Bool.random(using: &generator) { nextDirection *= -1 }
                let room = headingLimit - nextDirection * heading
                if room < 22 * .pi / 180 { nextDirection *= -1 }
                let available = headingLimit - nextDirection * heading
                // A hairpin folds the two banks over each other. Past that
                // line the camera then rocks back and forth.
                let curvatureCap = max(420, length) * 0.00042
                let angle = min(available, min(curvatureCap, Double.random(in: 18...36, using: &generator) * .pi / 180))
                endSlope = tan(heading + nextDirection * angle)
            }
            bends.append(Bend(start: row + lead, length: length, startX: nextX,
                              startSlope: nextSlope, endSlope: endSlope))
            nextX += nextSlope * HoneySlideRules.checkpointSpacing
                + (endSlope - nextSlope) * (length / 2 + tail)
            nextSlope = endSlope
        }
    }

    func sample(at position: Double) -> Sample {
        if let finish = finishStraight, position >= finish.position {
            return Sample(x: finish.x + finish.slope * (position - finish.position), slope: finish.slope, turnRate: 0)
        }
        let cell = Int(floor((position - HoneySlideRules.playerAhead) / HoneySlideRules.checkpointSpacing))
        guard cell >= 0 else { return Sample(x: 0, slope: 0, turnRate: 0) }
        guard cell < bends.count else {
            let end = HoneySlideRules.playerAhead + Double(bends.count) * HoneySlideRules.checkpointSpacing
            return Sample(x: nextX + nextSlope * (position - end), slope: nextSlope, turnRate: 0)
        }
        let bend = bends[cell]
        let row = HoneySlideRules.playerAhead + Double(cell) * HoneySlideRules.checkpointSpacing
        let t = max(0, min(1, (position - bend.start) / bend.length))
        let delta = bend.endSlope - bend.startSlope
        let eased = (1 - cos(.pi * t)) / 2
        // A broad cosine arc distributes turning over the complete curve.
        // Its matching integral keeps position and heading continuous at entry
        // and exit, without the concentrated kink of the former short corners.
        let integral = (t - sin(.pi * t) / .pi) / 2
        let x = bend.startX + bend.startSlope * (position - row)
            + delta * (bend.length * integral + max(0, position - bend.end))
        let slope = bend.startSlope + delta * eased
        let derivative = t > 0 && t < 1 ? delta * .pi * sin(.pi * t) / (2 * bend.length) : 0
        return Sample(x: x, slope: slope,
                      turnRate: derivative * HoneySlideRules.forwardSpeed / (1 + slope * slope))
    }

}
