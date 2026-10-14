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
                          reduceMotion: Bool, cameraZoom: Double = 1, logContact: Bool = false) -> HoneyTubeFootprint {
        let originalWidth = spriteWidth(in: viewport), originalHeight = originalWidth * imageAspect
        let width = originalWidth * cameraZoom, height = width * imageAspect
        let angle = reduceMotion ? 0 : heading * .pi / 180
        let cosine = cos(angle), sine = sin(angle)
        let sx = 1600 / viewport.width, sy = 900 / viewport.height
        // Two physical pixels of clearance; the shape rotates around the same
        // image anchor as the renderer, rather than around its own centre.
        // Logs touch the visible inflatable hull, whose front edge begins
        // around 58% of the bear image. The taller wall ellipse includes the
        // space around the shoulders and caused a visible gap against logs.
        let clearance = logContact ? 0.5 : 2
        let rx = width * (logContact ? 0.45 : 0.46) + clearance
        let ry = height * (logContact ? 0.21 : 0.28) + clearance
        let offset = height * (logContact ? 0.29 : 0.212)
        return HoneyTubeFootprint(
            center: CGPoint(x: -sine * offset * sx,
                y: (viewport.height * 0.735 + (originalHeight - height) * 0.212 + cosine * offset
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
                                 course: HoneySlideCourse, cameraZoom: Double = 1,
                                 tail: Double = HoneySlideRules.dividerTail) -> ClosedRange<Double>? {
        let far = rowPosition + tail - distance
        let near = rowPosition - HoneySlideRules.dividerLead - distance
        guard far > HoneySlideRules.nearClipAhead else { return nil }
        let farDepth = HoneySlideRules.depth(ahead: far)
        let nearDepth = HoneySlideRules.depth(ahead: near)
        let height = HoneySlideRules.dividerHeight * cameraZoom
        let lowY = max(footprint.minY, HoneySlideRules.groundY(depth: farDepth) - height * farDepth)
        let highY = min(footprint.maxY, HoneySlideRules.groundY(depth: nearDepth))
        guard lowY < highY else { return nil }
        let playerX = HoneySlideRules.trackPoint(depth: HoneySlideRules.playerDepth, offset: 0,
            distance: distance / HoneySlideRules.forwardSpeed, course: course, cameraZoom: cameraZoom).x
        let half = HoneySlideRules.dividerHalfWidth + 0.005 // honey lip/stroke
        let ridingWidth = HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth) * cameraZoom

        func interval(_ y: Double) -> ClosedRange<Double> {
            let lowDepth = max(farDepth, HoneySlideRules.groundDepth(screenY: y))
            let highDepth = min(nearDepth, HoneySlideRules.groundDepth(screenY: y, height: height))
            func edge(_ depth: Double, _ lateral: Double) -> Double {
                HoneySlideRules.ridingPoint(depth: depth, lateral: lateral,
                    distance: distance / HoneySlideRules.forwardSpeed, course: course, cameraZoom: cameraZoom).x - playerX
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

/// Shared with the opaque bark silhouette and its visible cut end. Coordinates
/// are local artwork pixels, before the world's billboard projection.
enum HoneyLogGeometry {
    static let backCenter = -142.0
    static let frontCenter = 139.0
    static let backRadius = 30.0
    static let frontRadius = 41.0
    static let centerY = -54.5
    static let halfHeight = 62.5
    static let minY = centerY - halfHeight
    static let maxY = centerY + halfHeight

    static func span(at y: Double) -> ClosedRange<Double> {
        let fraction = (y - centerY) / halfHeight
        let radius = sqrt(max(0, 1 - fraction * fraction))
        return (backCenter - backRadius * radius)...(frontCenter + frontRadius * radius)
    }
}

/// Contact follows the rendered log silhouette, rather than an enlarged world
/// cuboid. Contact uses the visible front hull with half a pixel of clearance.
enum HoneyLogContact {
    static func forbidden(_ item: HoneyTrackItem, distance: Double, footprint: HoneyTubeFootprint,
                          course: HoneySlideCourse, cameraZoom: Double, viewport: CGSize) -> ClosedRange<Double>? {
        let ahead = item.worldPosition - distance
        guard ahead > HoneySlideRules.nearClipAhead else { return nil }
        let depth = HoneySlideRules.depth(ahead: ahead)
        let scaleX = depth / HoneySlideRules.playerDepth * cameraZoom
        let scaleY = scaleX * HoneySlideRules.billboardVerticalScale(viewport: viewport)
        let position = HoneySlideRules.ridingPoint(depth: depth, lateral: item.lateral,
            distance: distance / HoneySlideRules.forwardSpeed, course: course, cameraZoom: cameraZoom)
        let low = max(footprint.minY, position.y + HoneyLogGeometry.minY * scaleY)
        let high = min(footprint.maxY, position.y + HoneyLogGeometry.maxY * scaleY)
        guard low < high else { return nil }
        let width = HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth) * cameraZoom
        let origin = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth, lateral: 0,
            distance: distance / HoneySlideRules.forwardSpeed, course: course, cameraZoom: cameraZoom).x
        var lower = Double.infinity, upper = -Double.infinity
        for sample in 0...32 {
            let y = low + (high - low) * Double(sample) / 32
            let span = HoneyLogGeometry.span(at: (y - position.y) / scaleY)
            let slice = footprint.slice(at: y)
            lower = min(lower, (position.x + span.lowerBound * scaleX - origin - slice.upperBound) / width)
            upper = max(upper, (position.x + span.upperBound * scaleX - origin - slice.lowerBound) / width)
        }
        return lower...upper
    }
}
