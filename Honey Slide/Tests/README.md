Run the Foundation-only Honey Slide gameplay checks without touching player save data:

```sh
swiftc -module-cache-path /tmp/honey-swift-cache Core/*.swift Tests/HoneySlideChecks.swift -o /tmp/honey-slide-checks
/tmp/honey-slide-checks
```

The harness runs the actual course simulation and question engine. It covers
sixty correct moving checkpoints plus mistakes across six math topics, immutable
row positions and option order, shutters opening at the preceding collision,
constant travel at irregular frame rates, and new rows beyond the draw distance.

Full sessions cover each 20/30/40/50-question board, all-correct, all-wrong and
mixed runs, +1/−1 scoring with a zero floor, duplicate contact protection, and
saving/resuming a zero-score run. Archived bonus parameters cannot alter points.
Projection checks cover ten minutes of bends, tap-to-lane inversion at multiple
depths, a stable final approach, larger spaced pots, and honey filling the view.
Physical-divider checks start from ten positions, capture the nearest channel,
reject late attempts to steer through a wall, settle into that pot, and restore
free steering afterward. Phone/tablet viewport checks verify that pots preserve
the same width-to-height ratio.

Course checks cover sixteen generated runs: broad left/right arcs, successive
turns in the same direction, straight intervals, varied angles and curve lengths.
There is no forced alternating pattern. The run seed determines the whole course.
Extending a course preserves existing geometry. An unattended rider keeps a
straight world trajectory until the turning course brings it into an outside
rail. The wall redirects travel along its tangent while pushing against the
tube. An opposite corner releases that contact, and the same straight heading
takes the rider away from the rail; a mild curve may leave it in the middle,
while a stronger curve reaches the opposite rail. Touch release restores straight travel;
touch and keyboard input can leave the rail. A ten-second slow frame produces
the same position and heading as 1,200 fast frames. Pausing freezes both.
Phone/tablet checks align rail contact with the actual tube footprint and keep
the rider visible. The camera, rider, water,
pots, walls and inverse touch projection all use that run's course.
Eighty unattended checkpoint passages across eight seeds additionally verify
that real divider capture allows both outer lanes and intermediate positions
without input or pulling the idle rider toward its pot's center. Curves span
600–850 world units with a cosine heading transition and varied turn angles.
Fixed-width
checks cover eight seeds over ten minutes; straight rails must project as straight
lines, and all three actual answers remain visible before channel capture.

Camera-passage checks follow the same row geometry through the old −80 cutoff
and the camera near plane. They verify outward-only lane spacing, continuous
pot scale at contact, preserved option identities, and full silhouettes outside
every phone/tablet viewport before cleanup. Uncollected pots clear the view within
one second through camera travel; the collected/knocked pot owns its separate
contact animation. Fixed
30-unit divider blocks retain their world endpoints at every viewing distance.

Impact checks verify exactly one effect per contact, preservation of the old
answer after row promotion, +1 Honey only after the collecting pot reaches the
counter, a red penalty even at a zero score, pause behavior and effect cleanup.
Collection-motion checks verify the exact contact/HUD endpoints, continuous
motion and shrinking across all three lanes on phone/tablet, clearance from the
question sign, a single apex above the counter followed by a downward landing,
and zero endpoint velocity. The uninterrupted opaque pot flight takes 0.65
seconds. Contact pots are smaller than the bear and keep their original aspect
ratio. The penalty overlays the score digit for 1.15 seconds before the updated
score appears; no extra HUD space is reserved for it.
One hundred checkpoint landings verify straight channel geometry through
approach and passage, plus continuous position, heading and turn rate where
those landings meet bends. Straight sections retain the heading of their turn.

For repeatable visual QA, a Debug build accepts
`--honey-visual-check=correct:0.35` or `--honey-visual-check=wrong:0.30`.
Open a level to freeze the real renderer at that many seconds after impact.
This preview does not answer a question or change the player's saved score.
Launch without the argument to play normally. Release builds omit this helper.

Build the main application:

```sh
xcodebuild -project '../Honey Slide.xcodeproj' -scheme 'Honey Slide' -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/honey-slide-debug-final CODE_SIGNING_ALLOWED=NO build
```

The archived `honey-slide` copy sits beside the app sources, outside the synchronized group. That group excludes this standalone test harness. The application supports
landscape iPhone/iPad on iOS 17 or later.

The projection-cache regression check compares 1.3 million coordinates across
eight course seeds and ten minutes against the exact projection, including the
horizon and near-plane fallback. It requires less than half a logical pixel of
error; the measured maximum is 0.096 pixel. Answer geometry and physics stay exact.

## Renderer performance

Run the actual SwiftUI renderer on the Mac, with no player save data:

```sh
python3 Tools/honey_performance.py --output /tmp/honey-performance --samples 60
```

The runner compiles with `-O`, warms the caches, then measures approach,
correct-hit, wrong-hit and bend scenes at phone/tablet dimensions. It produces
PNG previews and `renderer.json` containing median/p95 preparation times,
per-section times and command counts. These CPU/offscreen measurements are
**not device FPS**; rendering and presentation can finish later on GPU threads.
Run comparisons consecutively on an idle host, without concurrent builds.
The bend, curve-exit and reversal previews leave the rider unattended to show
straight travel, rail contact and detachment. Continuing-arc and long-straight
scenes inspect the irregular course rhythm. Reports include the contact side,
position and world heading for each viewport.

`--source-dir` accepts a saved renderer/rules/simulation snapshot for a baseline.
`--compile-only` leaves the executable for Time Profiler. For a live simulator
workload, supply a built simulator application's asset catalog:

```sh
python3 Tools/honey_performance.py --simulator-app --output /tmp/honey-live \
  --assets '/tmp/honey-slide-perf-debug/Build/Products/Debug-iphonesimulator/Honey Slide.app'
xcrun simctl install DEVICE_UUID /tmp/honey-live/HoneyPerformance.app
xcrun simctl launch --terminate-running-process DEVICE_UUID local.honey.performance
xcrun simctl get_app_container DEVICE_UUID local.honey.performance data
```

Add `--idle-course` when building the isolated simulator app to inspect a full
unattended run through the varied curves. Omit it to check deliberate steering.
Both modes use the production renderer and simulation without player save data.

The separate test app runs 32 seconds, including steering, correct/incorrect
collisions and shutters, then writes `Library/Caches/HoneyPerformance.json`
inside its own returned data container. Its delivered-update frequency and
long frame gaps measure scheduling; they do not measure presented GPU frames.
The real game and its saves remain untouched. Use a physical iPhone/iPad with
Instruments Game Performance/Animation Hitches to verify presented FPS and GPU
time. Animation Hitches is not supported by the simulator used here.
