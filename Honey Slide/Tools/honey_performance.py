#!/usr/bin/env python3
"""Measure the actual SwiftUI renderer without opening or changing a save.

ImageRenderer timings are CPU/offscreen timings on the Mac, NOT device FPS.
The same renderer, core simulation and artwork are compiled with -O. Keep the
host idle and use identical samples/scale for before/after comparisons.
"""
import argparse
import json
import pathlib
import re
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source-dir", type=pathlib.Path, default=ROOT)
parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("/tmp/honey-performance"))
parser.add_argument("--samples", type=int, default=24)
parser.add_argument("--scenario-prefix", help="Render only scenes with this prefix, e.g. finish-")
parser.add_argument("--compile-only", action="store_true", help="Leave the compiled runner for Instruments")
parser.add_argument("--simulator-app", action="store_true", help="Build an isolated 32-second iOS simulator workload")
parser.add_argument("--assets", type=pathlib.Path, help="Existing simulator app containing Assets.car")
parser.add_argument("--idle-course", action="store_true", help="Leave the isolated simulator rider unattended to inspect straight travel and rail sliding")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
source = (args.source_dir / "HoneySlidePlayfield.swift").read_text()
source = source[source.index("private struct HoneySlideWorld:"):]
# Offscreen rendering must be synchronous to measure a complete draw.
source = source.replace("rendersAsynchronously: true", "rendersAsynchronously: false")
for section in ["drawWorld", "drawLandscape", "drawSlide", "drawChurningHoney", "drawRailHoney", "drawDepthObjects", "drawRailBlock", "drawCheckpoints", "dividerWall", "barrel"]:
    marker = "private func " + section + "("
    if marker not in source:
        continue
    pos = source.index("{", source.index(marker)) + 1
    source = source[:pos] + f'\n        let benchmarkStart = RenderBenchmark.now\n        defer {{ RenderBenchmark.record("{section}", since: benchmarkStart) }}\n' + source[pos:]
marker = "private func point(_ depth:"
if marker in source:
    pos = source.index("{", source.index(marker)) + 1
    source = source[:pos] + '\n        RenderBenchmark.count("trackPoint")\n        return ' + source[pos:].lstrip()
source = re.sub(r"^(\s*)(\w+)\.(fill|stroke|draw)\(",
    lambda m: m[1] + f'RenderBenchmark.count("canvas_{m[3]}")\n' + m[1] + m[2] + "." + m[3] + "(", source, flags=re.M)

prefix = '''import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
func L(key: String) -> String { key == "honey.pause" ? "Pauze" : "Antwoord" }
func L(_ key: String.LocalizationValue) -> String { String(localized: key) }
enum Currency { static let name = "Honey" }
struct CurrencyIcon: View {
    let size: CGFloat
    var body: some View { Image(systemName: "drop.fill").resizable().scaledToFit().frame(width: size, height: size) }
}
final class RenderBenchmark {
    static var totals: [String: Double] = [:]
    static var counts: [String: Int] = [:]
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    static func record(_ key: String, since start: Double) { totals[key, default: 0] += (now - start) * 1000 }
    static func count(_ key: String) { counts[key, default: 0] += 1 }
    static func reset() { totals.removeAll(keepingCapacity: true); counts.removeAll(keepingCapacity: true) }
}
'''
# Historical renderer snapshots used the shared currency pot inside the HUD.
# Keep that artwork in baseline runs; the current HUD owns its pot directly.
if "CurrencyIcon(size: 71 * scale)" in source:
    prefix = prefix.replace('Image(systemName: "drop.fill").resizable().scaledToFit()', 'HoneyPotIllustration()')
driver = r'''
private struct BenchmarkScene: View {
    let simulation: HoneySlideSimulation
    let phone: Bool
    let bear: NSImage
    var prompt = "8 + 5 = ?"
    var score = 4
    var missedChallenge = "8 + 5 = 13"
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 1600, proxy.size.height / 900)
            let player = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth, lateral: simulation.lateral, distance: simulation.elapsed)
            ZStack {
                HoneySlideWorld(simulation: simulation)
                HoneyTubeWater(simulation: simulation, foreground: false)
                Image(nsImage: bear).resizable().scaledToFit()
                    .frame(width: min(proxy.size.width * 0.285, proxy.size.height * 0.43))
                    .rotationEffect(.degrees(simulation.tubeHeading))
                    .offset(y: sin(simulation.elapsed * 6.5) * 4 * scale)
                    .position(x: player.x / 1600 * proxy.size.width, y: proxy.size.height * 0.735)
                HoneyTubeWater(simulation: simulation, foreground: true)
                VStack {
                    HoneyHUD(scale: scale, width: proxy.size.width, prompt: prompt,
                        score: score, canPause: true, penaltyProgress: simulation.penaltyProgress,
                        showsFeedback: simulation.feedbackRemaining > 0 && !simulation.lastWasCorrect,
                        missedChallenge: missedChallenge, onPause: {}).equatable()
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.leading, (phone ? 59 : 0) + max(16, 58 * scale))
                .padding(.trailing, (phone ? 59 : 0) + max(16, 58 * scale))
                .padding(.top, max(10, 32 * scale))
                .padding(.bottom, max(phone ? 21 : 0, 34 * scale))
            }
            .overlayPreferenceValue(HoneyScoreAnchor.self) { anchor in
                if let anchor { HoneyCollectionFlight(simulation: simulation, target: proxy[anchor]) }
            }
        }
    }
}
@main struct RendererPerformance {
    @MainActor static func main() throws {
        let output = CommandLine.arguments[1]
        let samples = Int(CommandLine.arguments[2])!
        let bear = NSImage(contentsOfFile: CommandLine.arguments[3])!
        var report: [[String: Any]] = []
        var scenarios = [("approach", 5.5, true), ("correct", 6.7, true), ("wrong", 6.7, false),
            ("divider-left", 6.2, true), ("divider-middle", 6.2, true),
            ("divider-right", 6.2, true), ("divider-tail", 6.83, true)]
        for (index, bend) in HoneySlideCourse.preview.bends.prefix(2).enumerated() {
            let time = (bend.start + bend.length * 0.80 - HoneySlideRules.playerAhead) / HoneySlideRules.forwardSpeed
            scenarios.append((bend.direction < 0 ? "bend-left" : "bend-right", time, true))
            let railTime = (HoneySlideCourse.preview.bends[index + 1].start - HoneySlideRules.playerAhead)
                / HoneySlideRules.forwardSpeed - 0.20
            scenarios.append((bend.direction < 0 ? "exit-left" : "exit-right", railTime, true))
            if index == 1 {
                for fraction in [0.15, 0.50, 0.95] {
                    let reversalTime = (bend.start + bend.length * fraction - HoneySlideRules.playerAhead)
                        / HoneySlideRules.forwardSpeed
                    scenarios.append(("reversal-\(Int(fraction * 100))", reversalTime, true))
                }
            }
        }
        if let index = HoneySlideCourse.preview.bends.indices.dropFirst().first(where: {
            let bends = HoneySlideCourse.preview.bends
            return bends[$0].direction != 0 && bends[$0].direction == bends[$0 - 1].direction
        }) {
            let bend = HoneySlideCourse.preview.bends[index]
            scenarios.append(("continuing-arc", (bend.start + bend.length * 0.6 - HoneySlideRules.playerAhead)
                / HoneySlideRules.forwardSpeed, true))
        }
        if let bend = HoneySlideCourse.preview.bends.first(where: { $0.direction == 0 }) {
            scenarios.append(("long-straight", (bend.start + bend.length * 0.5 - HoneySlideRules.playerAhead)
                / HoneySlideRules.forwardSpeed, true))
        }
        for (scenario, time, correct) in scenarios {
            for phone in [true, false] {
                let size = phone ? CGSize(width: 852, height: 393) : CGSize(width: 1194, height: 834)
                let engine = MemoryGame(level: MathLevel(topic: .addition, index: 6), seed: 79)
                _ = engine.start(); _ = engine.turnCardsOver(); _ = engine.beginAnswering()
                var initial = HoneySlideSimulation(courseSeed: 42)
                initial.configureViewport(size)
                initial.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
                while initial.elapsed < time {
                    if scenario.hasPrefix("divider-") {
                        let lane = scenario == "divider-left" ? -0.66 : scenario == "divider-right" ? 0.66 : 0
                        let beginsLateSteering = scenario == "divider-tail" ? 6.65 : 5.9
                        initial.steer(to: initial.elapsed < beginsLateSteering ? lane : lane > 0 ? -0.78 : 0.78)
                    }
                    if ["approach", "correct", "wrong"].contains(scenario), let row = initial.activeCheckpoint,
                       let index = row.options.firstIndex(where: { $0.isCorrect == correct }) {
                        initial.steer(to: Double(index - 1) * HoneySlideRules.laneSpacing)
                    }
                    initial.advance(seconds: 1.0 / 120)
                    if let round = engine.round, let hit = initial.crossing(roundID: round.id) {
                        initial.markSelected(checkpointID: hit.checkpointID, index: hit.index, correct: hit.option.isCorrect)
                        _ = engine.select(optionID: hit.option.id); _ = engine.finishResolving(); engine.advance()
                        _ = engine.turnCardsOver(); _ = engine.beginAnswering()
                        initial.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
                    }
                }
                var sim = initial
                let prompt = engine.round?.question.prompt ?? "…"
                let score = max(0, engine.cards - sim.pendingHoney)
                let renderer = ImageRenderer(content: BenchmarkScene(simulation: sim, phone: phone, bear: bear,
                    prompt: prompt, score: score).frame(width: size.width, height: size.height))
                renderer.scale = 2
                var frameTimes: [Double] = []
                var sections: [String: [Double]] = [:]
                var countTotals: [String: Int] = [:]
                for frame in -4..<samples {
                    sim.advance(seconds: 1.0 / 60)
                    RenderBenchmark.reset()
                    let start = RenderBenchmark.now
                    let cg: CGImage = autoreleasepool {
                        renderer.content = BenchmarkScene(simulation: sim, phone: phone, bear: bear,
                            prompt: prompt, score: score).frame(width: size.width, height: size.height)
                        return renderer.cgImage!
                    }
                    let total = (RenderBenchmark.now - start) * 1000
                    if frame >= 0 {
                        frameTimes.append(total)
                        for (key, value) in RenderBenchmark.totals { sections[key, default: []].append(value) }
                        for (key, value) in RenderBenchmark.counts { countTotals[key, default: 0] += value }
                    }
                    if frame == 0 {
                        let file = "\(output)/\(phone ? "phone" : "pad")-\(scenario).png"
                        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: file) as CFURL, UTType.png.identifier as CFString, 1, nil)!
                        CGImageDestinationAddImage(dest, cg, nil); _ = CGImageDestinationFinalize(dest)
                    }
                }
                func stats(_ values: [Double]) -> [String: Double] {
                    let sorted = values.sorted()
                    return ["mean_ms": sorted.reduce(0, +) / Double(sorted.count), "median_ms": sorted[sorted.count / 2], "p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], "max_ms": sorted.last!]
                }
                let result: [String: Any] = ["scenario": scenario, "viewport": phone ? "phone" : "pad", "samples": samples,
                    "lateral": sim.lateral, "rail_contact": sim.railContact, "travel_slope": sim.travelSlope,
                    "offscreen": stats(frameTimes), "sections": sections.mapValues(stats), "counts_per_frame": countTotals.mapValues { Double($0) / Double(samples) }]
                report.append(result)
                print("\(phone ? "phone" : "pad") \(scenario): \(stats(frameTimes)) sections \(sections.mapValues { $0.reduce(0,+) / Double($0.count) })")
                fflush(stdout)
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: "\(output)/renderer.json"))
    }
}
'''
if "HoneyRaceArtwork" in source:
    driver = driver.replace("divider-", "steering-")
    # The standalone runner has no compiled string catalog.
    prefix = prefix.replace('func L(key: String) -> String { key == "honey.pause" ? "Pauze" : "Antwoord" }',
        'func L(key: String) -> String { ["honey.pause": "Pauze", "honey.race.moment.normal": "Kies je route", "honey.race.moment.narrow": "Smalle doorgang", "honey.race.moment.moving": "Bewegende vaten", "honey.race.moment.swapping": "Vaten wisselen", "honey.race.moment.quick": "Snelle beslissing", "honey.race.moment.risk": "Risico: boost vóór het antwoord"][key] ?? "Antwoord" }')

    driver = driver.replace('("approach", 5.5, true), ("correct", 6.7, true), ("wrong", 6.7, false)',
        '("approach", 6.2, true), ("correct", 7.5, true), ("wrong", 7.5, false)')
    driver = driver.replace('        for (scenario, time, correct) in scenarios {',
        '        scenarios += HoneyAnswerMoment.allCases.map { ("race-" + $0.rawValue, 4.5, true) }\n        for (scenario, time, correct) in scenarios {')
    driver = driver.replace('                while initial.elapsed < time {', r'''                if scenario.hasPrefix("race-") {
                    let moment = String(scenario.dropFirst(5))
                    for seed in 0..<200 {
                        var candidate = HoneySlideSimulation(courseSeed: UInt64(seed))
                        candidate.configureViewport(size)
                        candidate.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true,
                            completed: 20, streak: 8)
                        if candidate.activeCheckpoint?.moment.rawValue == moment { initial = candidate; break }
                    }
                }
                while initial.elapsed < time {''')
    driver = driver.replace('initial.steer(to: Double(index - 1) * HoneySlideRules.laneSpacing)',
        'initial.steer(to: row.lateralPosition(at: index, elapsed: initial.elapsed))')
    driver = driver.replace('hit.option.isCorrect', 'hit.isCorrect')
    driver = driver.replace('_ = engine.select(optionID: hit.option.id);',
        '_ = hit.option.map { engine.select(optionID: $0.id, usesBonusFish: false) } ?? engine.missAnswer();')
    driver = driver.replace('initial.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)',
        'initial.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: engine.completedQuestions, streak: engine.correctStreak, mistakes: engine.mistakeStreak)')
    driver = driver.replace('        scenarios += HoneyAnswerMoment.allCases.map { ("race-" + $0.rawValue, 4.5, true) }',
        '        scenarios += HoneyAnswerMoment.allCases.map { ("race-" + $0.rawValue, 4.5, true) }\n        scenarios += (2...5).map { ("width-" + String($0), 0.0, true) }\n        scenarios += ["jump", "landing", "whirlpool", "blocked-log", "log-pass"].map { ("effect-" + $0, 0.0, true) }')
    driver = driver.replace('if scenario.hasPrefix("race-") {', 'if scenario.hasPrefix("race-") || scenario.hasPrefix("width-") {')
    driver = driver.replace('if candidate.activeCheckpoint?.moment.rawValue == moment { initial = candidate; break }',
        'if scenario.hasPrefix("width-") ? candidate.activeCheckpoint?.options.count == Int(scenario.dropFirst(6)) : candidate.activeCheckpoint?.moment.rawValue == moment { initial = candidate; break }')
    driver = driver.replace('                while initial.elapsed < time {',
        '                while (scenario.hasPrefix("width-") ? initial.distance + HoneySlideRules.playerAhead < initial.activeCheckpoint!.worldPosition - 1050 : initial.elapsed < time) {\n                    if scenario.hasPrefix("width-") { initial.steer(to: 0) }')
    driver = driver.replace('                while (scenario.hasPrefix("width-")', r'''                if scenario.hasPrefix("effect-") {
                    let kind: HoneyTrackItemKind = ["effect-jump", "effect-landing"].contains(scenario) ? .ramp : scenario == "effect-whirlpool" ? .whirlpool : .log
                    var found = false
                    for seed in 0..<100 where !found {
                        var candidate = HoneySlideSimulation(courseSeed: UInt64(seed))
                        candidate.configureViewport(size)
                        candidate.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: 8)
                        guard let item = candidate.items.first(where: { $0.checkpointID == 0 && $0.kind == kind }) else { continue }
                        for _ in 0..<2000 {
                            candidate.steer(to: item.lateral)
                            if kind != .log, let log = candidate.items.filter({ $0.kind == .log && $0.worldPosition - candidate.distance - HoneySlideRules.playerAhead > -200 && $0.worldPosition - candidate.distance - HoneySlideRules.playerAhead < 800 }).min(by: { $0.worldPosition < $1.worldPosition }), abs(candidate.lateral - log.lateral) < 0.6 || candidate.blockedLogID != nil {
                                candidate.steer(to: log.lateral >= 0 ? -candidate.railLimit : candidate.railLimit)
                            }
                            candidate.advance(seconds: 1.0 / 120)
                            let contacted = kind == .log ? candidate.blockedLogID == item.id : candidate.items.first(where: { $0.id == item.id })?.contactedAt != nil
                            if contacted {
                                if kind == .ramp, let jump = candidate.jump {
                                    let target = scenario == "effect-landing" ? jump.landingPosition + 5 : jump.peakPosition - 25
                                    while candidate.distance + HoneySlideRules.playerAhead < target { candidate.advance(seconds: 1.0 / 120) }
                                }
                                if scenario == "effect-log-pass" {
                                    let depth = HoneySlideRules.depth(ahead: item.worldPosition - candidate.distance)
                                    let position = HoneySlideRules.ridingPoint(depth: depth, lateral: item.lateral,
                                        distance: candidate.travelTime, course: candidate.course, cameraZoom: candidate.cameraZoom)
                                    let origin = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth, lateral: 0,
                                        distance: candidate.travelTime, course: candidate.course, cameraZoom: candidate.cameraZoom).x
                                    let side = item.lateral >= 0 ? -1.0 : 1.0
                                    let edge = position.x + (side < 0 ? HoneyLogGeometry.backCenter - HoneyLogGeometry.backRadius
                                        : HoneyLogGeometry.frontCenter + HoneyLogGeometry.frontRadius) * depth / HoneySlideRules.playerDepth * candidate.cameraZoom
                                    let width = HoneySlideRules.ridingHalfWidth(depth: HoneySlideRules.playerDepth) * candidate.cameraZoom
                                    candidate.steer(to: (edge - origin - candidate.logFootprint.center.x + side * (sqrt(candidate.logFootprint.xx) + 4)) / width)
                                    for _ in 0..<240 {
                                        candidate.advance(seconds: 1.0 / 120)
                                        if candidate.blockedLogID == nil { break }
                                    }
                                    precondition(candidate.blockedLogID == nil, "Log pass remained blocked")
                                }
                                initial = candidate; found = true; break
                            }
                            if candidate.distance + HoneySlideRules.playerAhead > item.worldPosition + 100 { break }
                        }
                    }
                    precondition(found, "No effect preview for \(scenario)")
                }
                while (scenario.hasPrefix("width-")''')
    driver = driver.replace('@main struct RendererPerformance {', r'''
private struct RaceArtworkSheet: View {
    private func label(_ kind: HoneyTrackItemKind) -> String {
        switch kind {
        case .boost: return "Boost"
        case .whirlpool: return "Draaikolk"
        case .ramp: return "Springplank"
        case .hive: return "Bijenkorf"
        case .log: return "Boomstam"
        }
    }
    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 14) {
                HoneyPotIllustration().frame(width: 44, height: 48)
                Text("Honey Slide · baanobjecten")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                Spacer()
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(250), spacing: 16), count: 5), spacing: 20) {
                ForEach(HoneyTrackItemKind.allCases, id: \.self) { kind in
                    VStack(spacing: 0) {
                        Canvas { context, size in
                            var c = context
                            c.translateBy(x: size.width / 2, y: size.height - 50)
                            let scale = kind == .whirlpool ? 0.37 : 0.64
                            c.scaleBy(x: scale, y: scale)
                            HoneyRaceArtwork.draw(kind, in: &c)
                        }
                        .frame(width: 250, height: 285)
                        Text(label(kind))
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .padding(.bottom, 18)
                    }
                    .background(Color(red: 1, green: 0.97, blue: 0.85), in: RoundedRectangle(cornerRadius: 24))
                }
            }
        }
        .foregroundStyle(Color(red: 0.29, green: 0.12, blue: 0.025))
        .padding(32)
        .frame(width: 1400, height: 470)
        .background(Color(red: 0.96, green: 0.89, blue: 0.70))
    }
}
@main struct RendererPerformance {''')
    driver = driver.replace('        var report: [[String: Any]] = []', r'''
        let gallery = ImageRenderer(content: RaceArtworkSheet())
        gallery.scale = 1
        if let cg = gallery.cgImage {
            let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(output)/race-artwork.png") as CFURL,
                UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cg, nil); _ = CGImageDestinationFinalize(dest)
        }
        var report: [[String: Any]] = []''')
    driver = driver.replace('                    initial.advance(seconds: 1.0 / 120)', r'''                    if let log = initial.items.filter({ $0.kind == .log && $0.worldPosition - initial.distance - HoneySlideRules.playerAhead > -200 && $0.worldPosition - initial.distance - HoneySlideRules.playerAhead < 800 }).min(by: { $0.worldPosition < $1.worldPosition }), abs(initial.lateral - log.lateral) < 0.6 || initial.blockedLogID != nil {
                        initial.steer(to: log.lateral >= 0 ? -initial.railLimit : initial.railLimit)
                    }
                    initial.advance(seconds: 1.0 / 120)''')
if "let questionNumber: Int" in source:
    driver = driver.replace("score: score,", "score: score, questionNumber: 5, totalQuestions: 20,", 1)
if "simulation.isFinishComplete" in source:
    driver = driver.replace('    var missedChallenge =', '    var questionNumber = 5\n    var totalQuestions = 20\n    var missedChallenge =', 1)
    driver = driver.replace('questionNumber: 5, totalQuestions: 20', 'questionNumber: questionNumber, totalQuestions: totalQuestions')
    driver = driver.replace('canPause: true', 'canPause: !simulation.hasFinishStarted')
    driver = driver.replace('onPause: {}).equatable()', 'onPause: {}).equatable().opacity(simulation.hasFinishLaunched ? max(0, 1 - simulation.finishFlightProgress * 6) : 1)')
    driver = driver.replace('        for (scenario, time, correct) in scenarios {',
        '        scenarios += ["approach", "funnel", "launch", "out"].map { ("finish-" + $0, 0.0, true) }\n        scenarios += ["second", "resumed"].map { ("run-" + $0, 0.0, true) }\n        for (scenario, time, correct) in scenarios {')
    driver = driver.replace('                while (scenario.hasPrefix("width-")', r'''                if scenario.hasPrefix("finish-") {
                    while engine.completedQuestions < engine.maximumRounds - 1 {
                        _ = engine.select(optionID: engine.round!.correctOption!.id)
                        _ = engine.finishResolving(); engine.advance()
                        _ = engine.turnCardsOver(); _ = engine.beginAnswering()
                    }
                    for seed in 0..<150 {
                        var candidate = HoneySlideSimulation(courseSeed: UInt64(seed))
                        candidate.configureViewport(size)
                        candidate.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true,
                            completed: engine.completedQuestions, streak: 8, totalQuestions: engine.maximumRounds)
                        if candidate.activeCheckpoint?.options.count == 5,
                           !candidate.items.contains(where: { $0.kind == .ramp && $0.id != candidate.finish?.rampID }) {
                            initial = candidate; break
                        }
                    }
                    let row = initial.activeCheckpoint!
                    var frames = 0
                    while scenario == "finish-approach" ? row.worldPosition - initial.distance - HoneySlideRules.playerAhead > 700 : initial.crossing(roundID: engine.round!.id) == nil {
                        let index = row.options.firstIndex(where: { $0.isCorrect })!
                        initial.steer(to: row.lateralPosition(at: index, elapsed: initial.elapsed))
                        if let log = initial.items.filter({ $0.kind == .log && $0.worldPosition - initial.distance - HoneySlideRules.playerAhead > -200 && $0.worldPosition - initial.distance - HoneySlideRules.playerAhead < 800 }).min(by: { $0.worldPosition < $1.worldPosition }), abs(initial.lateral - log.lateral) < 0.6 || initial.blockedLogID != nil {
                            initial.steer(to: log.lateral >= 0 ? -initial.railLimit : initial.railLimit)
                        }
                        initial.advance(seconds: 1.0 / 120)
                        frames += 1; precondition(frames < 3000)
                    }
                    if scenario != "finish-approach", let hit = initial.crossing(roundID: engine.round!.id) {
                        _ = hit.option.map { engine.select(optionID: $0.id) } ?? engine.missAnswer()
                        _ = engine.finishResolving(); engine.advance()
                        initial.markSelected(checkpointID: hit.checkpointID, index: hit.index, correct: hit.isCorrect)
                        if scenario == "finish-funnel" {
                            while initial.distance + HoneySlideRules.playerAhead < row.worldPosition + HoneySlideRules.finishFunnelLength * 0.6 { initial.advance(seconds: 1.0 / 120) }
                        } else {
                            while !initial.hasFinishLaunched { initial.advance(seconds: 1.0 / 120) }
                            initial.advance(seconds: scenario == "finish-launch" ? 0.015 : HoneySlideRules.finishFlightDuration)
                        }
                    }
                }
                if scenario.hasPrefix("run-") {
                    for _ in 0..<(scenario == "run-second" ? 1 : 5) {
                        _ = engine.select(optionID: engine.round!.correctOption!.id)
                        _ = engine.finishResolving(); engine.advance()
                        _ = engine.turnCardsOver(); _ = engine.beginAnswering()
                    }
                    initial = HoneySlideSimulation(courseSeed: 17)
                    initial.configureViewport(size)
                    initial.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true,
                        completed: engine.completedQuestions, streak: engine.correctStreak)
                }
                while (scenario.hasPrefix("width-")''')
    driver = driver.replace('let prompt = engine.round?.question.prompt ?? "…"',
        'let prompt = sim.hasFinishStarted ? "Finish!" : engine.round?.question.prompt ?? "…"\n                let questionNumber = scenario.hasPrefix("finish-") ? engine.maximumRounds : scenario.hasPrefix("run-") ? engine.round!.number : 5\n                let totalQuestions = scenario.hasPrefix("finish-") || scenario.hasPrefix("run-") ? engine.maximumRounds : 20')
    driver = driver.replace('prompt: prompt, score: score)', 'prompt: prompt, score: score, questionNumber: questionNumber, totalQuestions: totalQuestions)')
if "private var scorePotScale: CGFloat" in source:
    driver = driver.replace("(phone ? 59 : 0) + max(16, 58 * scale)", "max(phone ? 59 : 0, max(12, 22 * scale))")
if "private var scorePanelWidth: CGFloat" in source:
    driver = driver.replace("max(phone ? 59 : 0, max(12, 22 * scale))", "(phone ? 59 : 0) + max(12, 22 * scale)")
    driver = driver.replace("width: proxy.size.width, prompt: prompt",
                            "width: proxy.size.width - 2 * ((phone ? 59 : 0) + max(12, 22 * scale)), prompt: prompt")
if "let rider: Image?" in source:
    start = driver.index("                HoneySlideWorld(simulation: simulation)")
    end = driver.index("                VStack {", start)
    driver = driver[:start] + "                HoneySlideWorld(simulation: simulation, rider: Image(nsImage: bear))\n" + driver[end:]
    driver = driver.replace("            let player = HoneySlideRules.ridingPoint(depth: HoneySlideRules.playerDepth, lateral: simulation.lateral, distance: simulation.elapsed)\n", "")
    driver = driver.replace("penaltyProgress: simulation.penaltyProgress,", "penaltyProgress: simulation.penaltyProgress.map { _ in 0 },")
if "private struct HoneyHUDAnchors" in source:
    driver = driver.replace("if let anchor { HoneyCollectionFlight(simulation: simulation, target: proxy[anchor]) }",
        "if let score = anchor.score, simulation.hasVisibleImpact { HoneyCollectionFlight(simulation: simulation, target: proxy[score], penaltyTarget: anchor.penalty.map { proxy[$0] }) }")
if "let collectionTarget: CGRect?" in source:
    driver = driver.replace("HoneySlideWorld(simulation: simulation, rider: Image(nsImage: bear))", "Color.clear")
    driver = driver.replace("            .overlayPreferenceValue(HoneyScoreAnchor.self)", '''            .backgroundPreferenceValue(HoneyScoreAnchor.self) { anchor in
                GeometryReader { background in
                    HoneySlideWorld(simulation: simulation, rider: Image(nsImage: bear),
                        collectionTarget: anchor.score.map { background[$0] })
                }
            }
            .overlayPreferenceValue(HoneyScoreAnchor.self)''')
    driver = driver.replace("if let score = anchor.score, simulation.hasVisibleImpact { HoneyCollectionFlight(simulation: simulation, target: proxy[score], penaltyTarget: anchor.penalty.map { proxy[$0] }) }",
        "if let penalty = anchor.penalty, simulation.penaltyProgress != nil { HoneyPenaltyFlash(simulation: simulation, target: proxy[penalty]) }")
if "private struct HoneyImpactEffects:" in source:
    driver = driver.replace("if let penalty = anchor.penalty, simulation.penaltyProgress != nil { HoneyPenaltyFlash(simulation: simulation, target: proxy[penalty]) }",
        "HoneyImpactEffects(simulation: simulation, rider: Image(nsImage: bear), reduceMotion: false, target: anchor.score.map { proxy[$0] }, penaltyTarget: anchor.penalty.map { proxy[$0] })")
if "let penaltyProgress: Double?" not in source:
    driver = driver.replace("penaltyProgress: simulation.penaltyProgress.map { _ in 0 },", "")
    driver = driver.replace("penaltyProgress: simulation.penaltyProgress,", "")
    driver = driver.replace(", penaltyTarget: anchor.penalty.map { proxy[$0] }", "")
if args.simulator_app:
    if not args.assets:
        parser.error("--simulator-app requires --assets /path/to/built.app")
    # Use exactly the production asynchronous renderer. This host has its own
    # bundle/container and pure engine: it cannot read or write player progress.
    source = source.replace("rendersAsynchronously: false", "rendersAsynchronously: true")
    prefix = prefix[:prefix.index("final class RenderBenchmark")] + r'''
final class RenderBenchmark {
    static let lock = NSLock()
    static var totals: [String: Double] = [:]
    static var samples: [String: [Double]] = [:]
    static var now: Double { ProcessInfo.processInfo.systemUptime }
    static func record(_ key: String, since start: Double) {
        let duration = (now - start) * 1000
        lock.lock(); defer { lock.unlock() }
        samples[key, default: []].append(duration)
    }
    static func count(_ key: String) {} // No per-vertex profiling overhead.
}
'''
    prefix = prefix.replace("import AppKit", "import UIKit\nimport Combine")
    driver = driver[:driver.index("@main struct RendererPerformance")]
    driver = driver.replace("NSImage", "UIImage").replace("Image(nsImage: bear)", "Image(uiImage: bear)")
    driver += r'''
final class CadenceStatistics {
    var intervals: [Double] = []
    func write() {
        func stats(_ values: [Double]) -> [String: Double] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return [:] }
            return ["mean_ms": sorted.reduce(0,+) / Double(sorted.count), "p95_ms": sorted[min(sorted.count-1, Int(Double(sorted.count)*0.95))], "max_ms": sorted.last!]
        }
        RenderBenchmark.lock.lock()
        let rendering = RenderBenchmark.samples.mapValues(stats)
        RenderBenchmark.lock.unlock()
        let seconds = intervals.reduce(0,+) / 1000
        let result: [String: Any] = ["delivered_updates_per_second": Double(intervals.count)/seconds,
            "updates": intervals.count, "duration": seconds, "update_interval": stats(intervals),
            "update_gaps_over_25ms": intervals.filter { $0 > 25 }.count,
            "encoding": rendering]
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HoneyPerformance.json")
        try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("PERFORMANCE: \(url.path)")
    }
}
struct PerformanceHost: View {
    @State private var sim = HoneySlideSimulation(courseSeed: 42)
    @State private var previous: Double?
    @State private var finished = false
    @State private var missed = ""
    let engine = MemoryGame(level: MathLevel(topic: .addition, index: 6), seed: 79)
    let cadence = CadenceStatistics()
    let bear = UIImage(named: "1_bear")!
    let idleCourse = IDLE_COURSE
    // CLOCK_DECLARATION
    var body: some View {
        BenchmarkScene(simulation: sim, phone: UIDevice.current.userInterfaceIdiom == .phone, bear: bear,
            prompt: engine.round?.question.prompt ?? "…", score: max(0, engine.cards - sim.pendingHoney), missedChallenge: missed)
            .ignoresSafeArea()
            .onAppear {
                sim.configureViewport(UIScreen.main.bounds.size)
                _ = engine.start(); _ = engine.turnCardsOver(); _ = engine.beginAnswering()
                sim.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
            }
            // CLOCK_CALLBACK
    }
    private func advance(_ timestamp: Double) {
        guard !finished else { return }
        guard let last = previous else { previous = timestamp; return }
        let dt = max(0, timestamp - last)
        previous = timestamp
        if sim.elapsed > 2 { cadence.intervals.append(dt * 1000) }
        if !idleCourse, let row = sim.activeCheckpoint,
           let lane = row.options.firstIndex(where: { $0.isCorrect == (engine.completedQuestions % 3 != 1) }) {
            sim.steer(to: Double(lane - 1) * HoneySlideRules.laneSpacing)
        }
        sim.advance(seconds: dt)
        if let round = engine.round, let hit = sim.crossing(roundID: round.id) {
            if !hit.option.isCorrect, let correct = round.correctOption {
                missed = round.question.prompt.replacingOccurrences(of: "?", with: correct.text)
            }
            sim.markSelected(checkpointID: hit.checkpointID, index: hit.index, correct: hit.option.isCorrect)
            _ = engine.select(optionID: hit.option.id); _ = engine.finishResolving(); engine.advance()
            _ = engine.turnCardsOver(); _ = engine.beginAnswering()
            sim.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)
        }
        if sim.elapsed >= 32 { finished = true; cadence.write() }
    }
}
class PerformanceDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { .landscape }
}
@main struct HoneyPerformanceApp: App {
    @UIApplicationDelegateAdaptor(PerformanceDelegate.self) var delegate
    var body: some Scene { WindowGroup { PerformanceHost() } }
}
'''
    driver = driver.replace("IDLE_COURSE", "true" if args.idle_course else "false")
    if "private struct HoneyDisplayClock:" in source:
        driver = driver.replace("// CLOCK_DECLARATION", "")
        driver = driver.replace("// CLOCK_CALLBACK", ".background(HoneyDisplayClock(running: !finished) { advance($0) })")
    else:
        driver = driver.replace("// CLOCK_DECLARATION", "private let clock = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()")
        driver = driver.replace("// CLOCK_CALLBACK", ".onReceive(clock) { _ in advance(ProcessInfo.processInfo.systemUptime) }")
if "HoneyRaceArtwork" in source and args.simulator_app:
    driver = driver.replace('hit.option.isCorrect', 'hit.isCorrect')
    driver = driver.replace('_ = engine.select(optionID: hit.option.id);',
        '_ = hit.option.map { engine.select(optionID: $0.id, usesBonusFish: false) } ?? engine.missAnswer();')
    driver = driver.replace('sim.steer(to: Double(lane - 1) * HoneySlideRules.laneSpacing)',
        'sim.steer(to: row.lateralPosition(at: lane, elapsed: sim.elapsed))')
    driver = driver.replace('sim.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true)',
        'sim.synchronize(rounds: engine.visibleRounds, stage: 1, acceptingInput: true, completed: engine.completedQuestions, streak: engine.correctStreak, mistakes: engine.mistakeStreak)')
    driver = driver.replace('        sim.advance(seconds: dt)', r'''        if !idleCourse, let log = sim.items.filter({ $0.kind == .log && $0.worldPosition - sim.distance - HoneySlideRules.playerAhead > -200 && $0.worldPosition - sim.distance - HoneySlideRules.playerAhead < 800 }).min(by: { $0.worldPosition < $1.worldPosition }), abs(sim.lateral - log.lateral) < 0.6 || sim.blockedLogID != nil {
            sim.steer(to: log.lateral >= 0 ? -sim.railLimit : sim.railLimit)
        }
        sim.advance(seconds: dt)''')
if args.scenario_prefix:
    driver = driver.replace('for (scenario, time, correct) in scenarios {',
        'for (scenario, time, correct) in scenarios.filter({ $0.0.hasPrefix(' + json.dumps(args.scenario_prefix, ensure_ascii=False) + ') }) {')
with tempfile.TemporaryDirectory(prefix="honey-benchmark-") as temporary:
    tmp = pathlib.Path(temporary)
    generated = tmp / "RendererBenchmark.swift"
    generated.write_text(prefix + source + driver)
    core = sorted((ROOT / "Core").glob("*.swift"))
    if args.source_dir != ROOT:
        core = [args.source_dir / f.name if (args.source_dir / f.name).exists() else f for f in core]
    # Count expensive projections separately from the renderer's table lookups.
    rules = next(f for f in core if f.name == "HoneySlideRules.swift")
    rule_source = rules.read_text()
    for function in ["trackPoint", "course"]:
        if "static func " + function + "(" not in rule_source:
            continue
        start = rule_source.index("{", rule_source.index("static func " + function + "(")) + 1
        rule_source = rule_source[:start] + f'\n        RenderBenchmark.count("exact_{function}")\n' + rule_source[start:]
    instrumented_rules = tmp / "HoneySlideRules.swift"
    instrumented_rules.write_text(rule_source)
    core = [instrumented_rules if f.name == rules.name else f for f in core]
    if args.simulator_app:
        app = args.output / "HoneyPerformance.app"
        app.mkdir(exist_ok=True)
        binary = app / "HoneyPerformance"
        sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
        subprocess.run(["swiftc", "-O", "-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk,
            "-module-cache-path", "/tmp/honey-ios-benchmark-cache", *map(str, core), str(generated), "-o", str(binary)], check=True)
        shutil.copy2(args.assets / "Assets.car", app / "Assets.car")
        info = {"CFBundleIdentifier": "local.honey.performance", "CFBundleExecutable": "HoneyPerformance",
            "CFBundleName": "Honey Performance", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0", "LSRequiresIPhoneOS": True,
            "UIDeviceFamily": [1, 2], "UISupportedInterfaceOrientations": ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
            "UIStatusBarHidden": True, "UILaunchScreen": {}}
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        print(app)
    else:
        binary = args.output / "honey-renderer-performance"
        subprocess.run(["swiftc", "-O", "-module-cache-path", "/tmp/honey-swift-cache", *map(str, core), str(generated), "-o", str(binary)], check=True)
    if not args.compile_only and not args.simulator_app:
        subprocess.run([str(binary), str(args.output), str(args.samples), str(ROOT / "Assets.xcassets/1_bear.imageset/1_main_honey.png")], check=True)
