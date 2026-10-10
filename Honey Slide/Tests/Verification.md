# Honey Slide verification — 2026-10-10

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
rows, rapids, rail joints, trees, cliffs and waterfalls at 220 units/second.
All checkpoint positions are fixed world positions. The final approach keeps
the center at x=800 from depth 0.55 through and after contact, preventing inward drift;
the outer lanes spread only through perspective. Replenished rows enter past
the 10,000-unit draw distance and fade in at the horizon.

The foreground projection continues below the camera instead of clamping at
depth 1.3. Its value and velocity are continuous at contact; the lower ground
opens beneath the rider so a passed row travels down out of the view. Pot scale
also has a matching derivative at contact and stays proportional to lane spacing.
Each complete silhouette is culled only outside the viewport. Simulation cleanup
occurs after the wall's far end crosses the camera near plane, replacing the
previous arbitrary −80-unit row deletion. Neither selection nor promotion changes
a pot's position. The passage harness checks all three selected lanes and four
viewport sizes; every passed pot is out of view within one second.

Contact pot scale remains 2.448, with a riding width of 740 units and positive
gaps between all three choices. Both banks have a continuous forest floor,
projected verges, rooted trees and flower bushes. Rails rise 84 logical units,
with honey tongues, spills and droplets. The supplied `1_bear` image rides in
the foreground. Pause, equation sign and score share a 120-unit HUD height;
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

Two raised divider walls span 210 world units before each answer row and
60 units behind it. Their rounded honey-coated leading noses capture the
nearest lane during the final 0.95-second approach. That channel guides the
rider to its pot; late taps, dragging and keyboard input cannot cross a wall.
The lane is picked once, independently of which answer is correct. The next
answer row remains freely steerable until its own guide entrance.

The dividers always contain nine fixed 30-unit world blocks. Their surfaces are
batched for rendering without changing their geometry or joints at proximity
thresholds. Wall endpoints and pot offsets never depend on the selected lane.

## Verified after this revision

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

## Verification limits

The artwork is a procedural cartoon interpretation of the supplied reference.
Physical-device touch feel and sustained frame rate have not been measured.
The supplied bear is one image rather than an articulated character rig.
App Store signing, purchases and distribution were not part of these checks.
