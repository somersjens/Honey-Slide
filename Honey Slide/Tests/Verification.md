# Honey Slide verification — 2026-10-14

The current obstacle racer uses 2–5 full-size answer pots and physical track
widths of 80%, 100%, 132% and 164% respectively. Width transitions blend over
950 world units. Four and five answers are wider than the original road; the
camera pulls back to frame them. Bank projection, rail clearance, tube contact
and inverse touch selection share the same world profile and camera transform.

All six upcoming rows and their props are prepared ahead of time. Question
promotion preserves their identities, positions and layouts. Future pots keep
their original closed shutters; labels open for the current question. New
objects enter beyond the draw distance. Stationary rows have one solid divider
between each pair of pots and persistent answered tails. The walls are 36%
thinner and start only 180 world units before the answer, allowing later lane
switches. Moving rows have three pots on a four-option-wide road, no dividers,
and a continuous shared bounce that reverses at the banks.

The HUD retains the original signs and Honey total. The separate race score,
multiplier, stars, bonus honey pickups and track rocks are removed. Correct
answers earn one Honey. Warm wood, amber glaze, leaves, shading and contact
shadows tie the five remaining props into the original forest scene.

Logs are permanent solid obstacles: forward travel stays exactly at the contact
distance until the rider steers just past the painted bark. Contact follows the
rendered silhouette and visible front hull, excluding the empty space around
the bear's shoulders. The clearance is half a pixel. The complete log silhouette
is clamped inside the banks at its world position. Whirlpools have animated
spiral flow and slow the rider for exactly two seconds. The funnels are 50%
larger and rotate faster, fading into the honey surface. Ramps sit 430 world
units before stationary rows in line with a divider. The distance-based jump
peaks just before the pots, clears the entire answer row with a 48% viewport
lift, and lands 180 world units after it, regardless of speed modifiers. A
grounded shadow and gently following camera keep the flight readable below
the HUD. Obstacles and modifiers start at question two, with saved question
numbers ensuring they are also present immediately when a level resumes.

Verified with the Foundation harness: 80 seeded runways, 250 questions across
six math topics, all five prop types and six answer moments, stable future rows,
every stationary passage in 2–5 answer rows on phone/tablet, three-pot bouncing
rows, solid log stops and escape, exact effect timers, full answer-row jumps,
short landings and HUD clearance, early/resumed props, Honey-only rewards, older saves, long frames,
width transitions, touch inversion and projection. The Debug iOS Simulator
build passes. Production-renderer previews cover phone/tablet layouts for
every answer count, moving rows, future pots, jump apex/landing, whirlpool
contact, blocked logs and question-two/resumed layouts, plus an artwork sheet.
These are offscreen checks, not device FPS.

The finish sequence also passes for every final answer count on phone/tablet.
It is prepared ahead of time, narrows smoothly into one passage, keeps a straight
terminal road, centers the rider, launches within 1.05 seconds of the final
answer, and sends it completely offscreen during the 0.6875-second flight before
reporting completion. The flight is 20% slower than the previous version.
Scoring remains unchanged during the exit. An airborne final answer lands
before the terminal ramp, then launches with a native honey burst and jets.
Pause freezes the sequence, long frames complete it once, and a fresh run has
no old finish state. Native renderer previews cover approach, funnel, launch
and complete exit; the finite honey surface and banks end at the springboard,
whose full deck follows exactly the same projected edges as the banks.

The notes below document earlier versions and are not the current scoring or
answer-layout specification.

# Historical verification — 2026-10-11

## Current gameplay

Each board contains a fixed 20, 30, 40 or 50 questions. Each collision consumes
one question, regardless of correctness. Correct answers earn one point;
wrong answers subtract one point, with a minimum of zero. No deadline, stage
clock, timed reward or wrong-answer retry controls the active game. The final
result reports net points and counts of correct/incorrect answers.

The next row exists on the course before it becomes active. Every pot uses
the same warm wood gradient, honey cap and front guides at every distance.
Future numbers are concealed by wooden shutters. Contact with the preceding
row starts the next shutters' upward motion under the honey lip (0.42 s).
Promoting a row preserves its position, options and shutter state.

Tapping the track steers toward the touched lane, using the inverse of the
barrel projection; this also works for a lane in the distance. Dragging uses
the same direct position target. Keyboard steering and accessible
answer controls continue to use the simulation. Pause freezes the world.
Attempted questions remain resumable even when the score is zero.

## Course and composition

One monotonic movement clock projects the continuous honey course, answer
rows, rapids, rail joints, trees, cliffs and waterfalls at 440 units/second.
All checkpoint positions are fixed world positions. The final approach keeps
the center at x=800 along each checkpoint's straight landing; the outer lanes
spread through perspective. Elsewhere the foreground retains the actual bend.
Replenished rows enter past
the 10,000-unit draw distance and fade in at the horizon.

Each new playfield generates its own seeded course. Rounded arcs vary in angle
and length, can continue in the same direction, and sometimes give way to a longer
straight. Turns are not forced to alternate left/right. The heading stays within
55 degrees either side to keep the course readable without imposing a zigzag.
Turns change heading continuously; the camera follows that heading instead of
flattening the foreground or moving sine-wave anchors sideways. Course extension
retains all previously generated geometry. Pausing keeps the same course.
Curved sections now span 1,200–1,700 world units. A cosine transition spreads the
change of heading over the full arc rather than concentrating a short corner.
The answer approaches and foreground passage remain clear. Road width
is constant in world coordinates. Direct perspective replaces per-point horizontal
compression and the distance-dependent width funnel. Straight verges and their
raised rails consequently project as straight lines up to the rider.
At the horizon, the last visible section continues along its own tangent rather
than closing across the view toward a forced center point.

An unattended rider keeps its world heading and travels straight. The turning
course moves underneath that trajectory until the tube contacts an outside rail.
Contact aligns travel with the rail only while the wall pushes against the tube.
When the next corner turns away, the rider detaches, keeps its existing heading,
and crosses away from the rail. Mild curves can leave it near the middle, while
stronger curves reach the other outside rail. There is no automatic steering target
or pull toward the middle. A released touch finishes its requested movement,
then restores straight travel. The rider's lean reflects deliberate steering
and a small rail-contact lean, with smoothing and a 16-degree limit. Physics
integrates the complete frame interval, including wall contact and channel capture.
Foreground rails account for the actual tube footprint at each viewport size,
so the visible tube reaches the rail while remaining on screen.

The foreground projection continues below the camera instead of clamping at
depth 1.3. Its value and velocity are continuous at contact; the lower ground
opens beneath the rider so a passed row travels down out of the view. Pot scale
also has a matching derivative at contact and stays proportional to lane spacing.
Each complete silhouette is culled only outside the viewport. Simulation cleanup
occurs after the wall's far end crosses the camera near plane, replacing the
previous arbitrary −80-unit row deletion. Neither selection nor promotion changes
a pot's position. The passage harness checks all three selected lanes and four
viewport sizes; every passed pot is out of view within one second.

Contact pot scale remains 1.88, with a riding width of 740 units and positive
gaps between all three choices. Both banks have a continuous forest floor,
projected verges, rooted trees and flower bushes. Rails rise 84 logical units,
with projected top surfaces, amber lips and small clinging drips. The supplied
`1_bear` image rides in the foreground. Pause, equation sign and score share a 120-unit HUD height;
all three panels share cream, honey and wood colors. No question ordinal,
countdown or lower-corner arrows appear in the active HUD. Wrong-answer
feedback and the pause card show only the solved question, without a point
penalty prefix.

The side panels have independent safe-area insets plus extra edge spacing.
All three panels have capsule-shaped sides. Only the equation panel carries a
continuous glossy honey lip and drips; pause and score use clean cream faces.
The pots have a recessed, reflective honey pool, a raised wooden rim, organic
drip shapes, leaves and flowers.

Long curved highlights and moving rapids give the honey surface depth. Water
around the tube uses the supplied bear sprite's actual footprint, with a broad
turbulent wake behind it and a low moving honey crest over its waterline. Spray
and bubbles fade smoothly through their trajectories on phone and tablet.

The Canvas renders asynchronously from an immutable simulation snapshot.
Cached plant symbols and separate equatable HUD, control and accessibility
views keep input and scoring responsive while the world moves. Upright pots
cancel the course canvas's aspect-ratio scaling, so iPhone and iPad render
the same proportions. Double-density cached pot base/crown symbols preserve
the glossy honey rim, irregular drips, leaves and flowers while the numbers
and sliding shutter remain dynamic.

Two raised divider walls span 420 world units before each answer row and
120 units behind it, retaining the earlier time spent alongside the walls at
440 units/second. Each contains eighteen fixed 30-unit blocks. Their surfaces
remain interleaved with banks and outside rails in world-depth order.

The full inflatable tube oval, including its rotation and bob, is tested against
the projected sides, noses, tails and raised caps. Collision starts with its
front and ends when its rear clears the complete obstacle. Answered rows remain
solid throughout passage. The actual first front contact determines the channel;
using the sprite-anchor midpoint could otherwise snap a rider across a narrow
projected nose. The channel is independent of the correct answer.

Steering toward a wall is constrained by the available clearance without
replacing the player's requested target. Steering away works immediately, and
the same request resumes once the complete tube clears the wall. Free steering
is available before and after that overlap. Physics integrates at 120 Hz, even
for long frames, and resolves the final drawn lean as well as lateral movement.
Tablet sprite width is capped at 27% rather than 28.5% of the viewport, giving
the tube room to fit in the middle channel. A lean is reduced if the channel
cannot contain it. Drawing, collision and water effects share sprite geometry.

## Verified after this revision

- Generated-course, straight-travel and rail-contact checks across sixteen seeds: passed.
- Different course shapes, continuing turns, straight intervals and unchanged geometry
  after course extension; unchanged world heading before contact, staying on the
  first rail until the corner reverses, detachment with unchanged world heading,
  movement away from the first rail, touch release, touch/key steering away from
  the rail, pause and identical movement over one ten-second frame versus 1,200
  small frames. Phone/tablet contact also matches the visible tube footprint.
- Projection cache across eight seeds and ten minutes: maximum error 0.096 logical
  pixel; all pot, divider, scoring, shutter and session regression checks passed.
- Production-renderer previews inspected for broad arcs, continuing turns, longer
  straights and three reversal phases on phone and tablet; final Release simulator
  build passed.
- Fixed world width and straight projected verges across eight seeds and ten
  minutes; all three real answer silhouettes visible before capture across sixteen seeds.
- Eighty unattended checkpoint passages across eight seeds reached both outer
  lanes without forcing an alternating sequence, including through the physical
  guides. A separate iPadOS 27 simulator app
  completed a 32-second unattended course with the production renderer and engine.
  Its own container keeps test answers separate from the player's saved progress.
## Earlier builds, save and interaction checks

- Debug iOS Simulator build: passed.
- Release iOS Simulator build: passed.
- Release generic iOS device build, signing disabled: passed.
- Foundation gameplay harness: passed.
- Sixty correct moving checkpoints plus wrong answers across addition,
  subtraction, tables, fractions, percentages and mixed questions.
- Fixed question counts in all-correct, all-wrong and mixed full sessions,
  one score per contact, +1/−1 rules, zero floor and save/resume at zero.
- Preview identity/position preservation and collision-timed shutter opening.
- Physical channel capture from ten starting positions, no jump at entry,
  resistance to late steering across walls and free steering after contact.
- Undistorted pot width/height across four phone/tablet viewport sizes.
- Selected-row passage through the previous deletion distance, no inward motion,
  continuous scaling, complete offscreen silhouettes before removal and stable
  divider block endpoints. Inverse touch projection also covers the near ground.
- Constant speed at irregular frame times, projection/inverse-touch geometry,
  spaced answer lanes and a stable final approach over ten minutes of bends.
- iPad A16/iPadOS 27 simulator: resumed an older 10-point run, tested direct
  coordinate tapping on the course, paused/resumed, and reached the result
  after exactly 20 questions: 16 correct, 4 wrong, 12 points.
- iPhone 17/iOS 26.5 simulator: a wrong first answer kept points at zero and
  advanced to question 2; exiting to the menu and returning preserved that
  zero-score progress. Reviewed the landscape HUD and open/closed pot artwork.
- Main target excludes the archived asset catalog, avoiding duplicate colors.

## Latest visual and interaction check

The camera revision was inspected in the Release iPhone 17 simulator. The three
rounded HUD panels share a palette, side panels have more clearance and no
drips, while the central panel has a continuous honey rim. New pot crowns and
the tube's layered wake/waterline were inspected during play. A passed selected
row continued below the viewport and the next row remained on the course.
The subsequent near-ground adjustment additionally shortens foreground passage;
the harness verifies that complete pots leave the view within one second.
Simulator automation on moving virtual answer controls can wait for UI stability;
these waits are not a measurement of physical-device rendering or input latency.

The final near-ground projection and additional turbulent water crests were
subsequently installed and inspected on both iPhone 17 and iPad A16. The iPad
check followed an answer contact into the next question: the passed row cleared
the foreground while the already-placed next row approached along the course.
Both final simulator sessions were left paused. Debug simulator, Release
simulator and Release generic-device builds all passed after the last source edit.

The latest Release iPhone simulator build was inspected near the divider
entrance: pot silhouettes and numbers remain upright, the raised walls lead
to the answer gaps, future shutters stay closed, and the HUD uses the same
palette across pause, equation and score. Question ordinals and corner arrows
are absent. Wrong answers showed only solved sums both in play and on pause.
Caching the additional artwork reduced an observed active-game accessibility
read from about 12 seconds to 0.6 seconds; this is an interaction check rather
than a physical-device frame-rate measurement.

The final iPad build was also inspected at the guide entrance with large pots:
all three HUD panels match, pot proportions are preserved, and the raised
walls flank the rider. Continuing through the selected center channel scored
the correct answer and advanced the score from 5 to 6. The pause card retained
only the previously solved question, without a penalty prefix.

## Bank and rail revision — 2026-10-11

Trees, flower gardens, sandstone outcrops, outside rail blocks, divider blocks
and answer pots now share a far-to-near world-depth draw order. Nearby canopies
can cover a distant bend; nearby walls still cover plants behind them. The honey
surface stays continuous underneath. New cached forest artwork adds branching
trunks, layered leafy canopies, ferns, daisies, moss and occasional stepped rock
formations. Broad honey falls are integrated into the outcrops; the former
isolated cylindrical honey props are removed.

Outside rails now have projected inner/outer faces, a top surface, stable
72-unit joints, subtle wood grain and restrained honey drips. The nine fixed
30-unit divider blocks use the same palette and shading, with rounded coated
noses. Collision geometry and checkpoint positions are unchanged.

The horizon is raised from y=155 to y=108. Compensating the ground slope keeps
the rider waterline fixed, and inverse touch projection uses the same horizon.
The Foundation harness passed, including ten-minute projection, straight rails,
touch inversion, divider capture, camera passage and collection motion. The
projection cache's maximum error was 0.0952 logical pixel. The full Debug iOS
Simulator build passed. Production-renderer previews were inspected on phone
and tablet for approach, impact, both bend directions, reversal and long straight
scenes. CPU/offscreen profiling covered twelve scenes at each size; it does not
measure physical-device FPS.

## Full divider contact and doubled speed — 2026-10-11

The Foundation harness passed with assertions enabled (`-O -assert-config Debug`):

- 440 world units/second and twenty exact contacts at 6.6-second intervals,
  without accumulated timing drift. Checkpoint spacing is 2,904 units.
- Full oval clearance sampled across 121 scanlines during approach and passage,
  including twenty edge-position entries on phone/tablet and all three channels
  across four viewport sizes with and without Reduce Motion.
- Answered divider tails remain solid; free movement resumes on the first step
  after complete clearance. Resize during tail contact also preserves clearance.
- Drag, tap and held-key requests cannot cross walls. Long-frame contact matches
  the same interval in ninety fine steps, including the final drawn angle.
- Existing generated turns, idle travel, outer rails, scoring, fixed sessions,
  pot passage, collection and projection regressions passed. Maximum projection
  cache error was 0.04121 logical pixel.

Course leads, bends and reserved straights double with world speed; scenery
spacing, lane width and perspective remain fixed so optical flow increases.
Extra honey flow doubles to 116 units/second. Shutters, collection, input response
and feedback retain their real-time durations. Linear pot scaling preserves
contact size 1.88 and approximately the previous initial active pot width:
37.23 logical pixels rather than 16.39 under the old scale at the new distance.

The final Debug iOS Simulator build passed. Production-renderer previews covered
sixteen scenes at both phone and tablet sizes, including each channel under late
cross-wall steering and an answered tail. Approach, selected passage, all three
wall-contact scenes and tail clearance were visually inspected. These are
CPU/offscreen checks rather than physical-device frame-rate measurements.

## Verification limits

The artwork is a procedural cartoon interpretation of the supplied reference.
Physical-device touch feel and sustained frame rate have not been measured.
The supplied bear is one image rather than an articulated character rig.
App Store signing, purchases and distribution were not part of these checks.
