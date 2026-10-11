import Foundation
import CoreGraphics

/// Sprite placement and collision use the same viewport dimensions. The oval
/// covers the opaque inflatable tube in 1_bear, excluding the bear's arms/head.
enum HoneyTubeGeometry {
    static let imageAspect = 1286.0 / 1223

    static func spriteWidth(in viewport: CGSize) -> Double {
        // Tablet tubes need a little clearance inside the middle channel.
        min(viewport.width * 0.27, viewport.height * 0.43)
    }

    static func bob(in viewport: CGSize, elapsed: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : sin(elapsed * 6.5) * 4 * min(viewport.width / 1600, viewport.height / 900)
    }

    static func footprint(in viewport: CGSize, elapsed: Double, heading: Double,
                          reduceMotion: Bool) -> HoneyTubeFootprint {
        let width = spriteWidth(in: viewport), height = width * imageAspect
        let angle = reduceMotion ? 0 : heading * .pi / 180
        let cosine = cos(angle), sine = sin(angle)
        let sx = 1600 / viewport.width, sy = 900 / viewport.height
        // Two physical pixels of clearance; the shape rotates around the same
        // image anchor as the renderer, rather than around its own centre.
        let rx = width * 0.46 + 2, ry = height * 0.28 + 2
        let offset = height * 0.212
        return HoneyTubeFootprint(
            center: CGPoint(x: -sine * offset * sx,
                y: (viewport.height * 0.735 + cosine * offset
                    + bob(in: viewport, elapsed: elapsed, reduceMotion: reduceMotion)) * sy),
            xx: (rx * rx * cosine * cosine + ry * ry * sine * sine) * sx * sx,
            xy: (rx * rx - ry * ry) * sine * cosine * sx * sy,
            yy: (rx * rx * sine * sine + ry * ry * cosine * cosine) * sy * sy)
    }
}

struct HoneyTubeFootprint {
    /// x is relative to the projected player centre; y is absolute canvas y.
    let center: CGPoint
    let xx: Double
    let xy: Double
    let yy: Double
    var minY: Double { center.y - sqrt(yy) }
    var maxY: Double { center.y + sqrt(yy) }

    func slice(at y: Double) -> ClosedRange<Double> {
        let dy = y - center.y
        let middle = center.x + xy / yy * dy
        let half = sqrt(max(0, (xx - xy * xy / yy) * (1 - dy * dy / yy)))
        return (middle - half)...(middle + half)
    }
}

/// The lateral interval occupied by a wall after expansion by the whole tube.
/// Its rounded ends follow the tube oval: no full-width margin switches on at
/// the player midpoint. Raised caps also participate, preventing visual overlap.
enum HoneyDividerContact {
    static func forbiddenLateral(rowPosition: Double, boundary: Double,
                                 distance: Double, footprint: HoneyTubeFootprint,
                                 course: HoneySlideCourse) -> ClosedRange<Double>? {
        let far = rowPosition + HoneySlideRules.dividerTail - distance
        let near = rowPosition - HoneySlideRules.dividerLead - distance
        guard far > HoneySlideRules.nearClipAhead else { return nil }
        let farDepth = HoneySlideRules.depth(ahead: far)
        let nearDepth = HoneySlideRules.depth(ahead: near)
        let height = HoneySlideRules.dividerHeight
        let lowY = max(footprint.minY, HoneySlideRules.groundY(depth: farDepth) - height * farDepth)
        let highY = min(footprint.maxY, HoneySlideRules.groundY(depth: nearDepth))
        guard lowY < highY else { return nil }
        let playerX = HoneySlideRules.trackPoint(depth: HoneySlideRules.playerDepth, offset: 0,
            distance: distance / HoneySlideRules.forwardSpeed, course: course).x
        let half = HoneySlideRules.dividerHalfWidth + 0.005 // honey lip/stroke
        let ridingWidth = HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth)

        func interval(_ y: Double) -> ClosedRange<Double> {
            let lowDepth = max(farDepth, HoneySlideRules.groundDepth(screenY: y))
            let highDepth = min(nearDepth, HoneySlideRules.groundDepth(screenY: y, height: height))
            func edge(_ depth: Double, _ lateral: Double) -> Double {
                HoneySlideRules.ridingPoint(depth: depth, lateral: lateral,
                    distance: distance / HoneySlideRules.forwardSpeed, course: course).x - playerX
            }
            let left = min(edge(lowDepth, boundary - half), edge(highDepth, boundary - half))
            let right = max(edge(lowDepth, boundary + half), edge(highDepth, boundary + half))
            let slice = footprint.slice(at: y)
            return ((left - slice.upperBound) / ridingWidth)...((right - slice.lowerBound) / ridingWidth)
        }
        // On the reserved straight landing these are convex support functions.
        // Include the ground's derivative transition and cap endpoint kinks.
        var splits = [lowY, highY, HoneySlideRules.groundY(depth: farDepth),
            HoneySlideRules.groundY(depth: nearDepth) - height * nearDepth,
            HoneySlideRules.groundY(depth: HoneySlideRules.playerDepth),
            HoneySlideRules.groundY(depth: HoneySlideRules.playerDepth) - height * HoneySlideRules.playerDepth]
        splits = splits.filter { $0 >= lowY && $0 <= highY }.sorted()
        var lower = Double.infinity, upper = -Double.infinity
        for (a, b) in zip(splits, splits.dropFirst()) {
            lower = min(lower, extremum(from: a, to: b) { interval($0).lowerBound })
            upper = max(upper, -extremum(from: a, to: b) { -interval($0).upperBound })
        }
        return lower...upper
    }

    private static func extremum(from a: Double, to b: Double, value: (Double) -> Double) -> Double {
        var low = a, high = b
        let ratio = (sqrt(5.0) - 1) / 2
        var c = high - ratio * (high - low), d = low + ratio * (high - low)
        var vc = value(c), vd = value(d)
        for _ in 0..<22 {
            if vc < vd {
                high = d; d = c; vd = vc
                c = high - ratio * (high - low); vc = value(c)
            } else {
                low = c; c = d; vc = vd
                d = low + ratio * (high - low); vd = value(d)
            }
        }
        return min(value(a), value(b), vc, vd)
    }
}
