#!/usr/bin/env python3
"""Measure the actual SwiftUI renderer without opening or changing a save.

ImageRenderer timings are CPU/offscreen timings on the Mac, NOT device FPS.
The same renderer, core simulation and artwork are compiled with -O. Keep the
host idle and use identical samples/scale for before/after comparisons.
"""
import argparse
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
for section in ["drawWorld", "drawLandscape", "drawSlide", "drawChurningHoney", "drawRailHoney", "drawCheckpoints", "dividerWall", "barrel"]:
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
        var scenarios = [("approach", 5.5, true), ("correct", 6.7, true), ("wrong", 6.7, false)]
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
                let renderer = ImageRenderer(content: BenchmarkScene(simulation: sim, phone: phone, bear: bear).frame(width: size.width, height: size.height))
                renderer.scale = 2
                var frameTimes: [Double] = []
                var sections: [String: [Double]] = [:]
                var countTotals: [String: Int] = [:]
                for frame in -4..<samples {
                    sim.advance(seconds: 1.0 / 60)
                    RenderBenchmark.reset()
                    let start = RenderBenchmark.now
                    let cg: CGImage = autoreleasepool {
                        renderer.content = BenchmarkScene(simulation: sim, phone: phone, bear: bear).frame(width: size.width, height: size.height)
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
