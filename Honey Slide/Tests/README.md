# Honey Slide checks

Run the real gameplay simulation and question engine without touching player saves:

```sh
swiftc -module-cache-path /tmp/honey-swift-cache Core/*.swift Tests/HoneySlideChecks.swift -o /tmp/honey-slide-checks
/tmp/honey-slide-checks
```

The obstacle racer checks cover:

- 80 deterministic runways: 2–5 unique answers, random correct-answer positions, all six answer moments and all five track item types.
- World-space widening/narrowing for 2–5 answers; four/five exceed the original width. Full-size pots, camera framing, rail limits and inverse touch projection match on phone/tablet.
- Future rows and props retain their identities, positions and layout during promotion and difficulty changes. Newly appended objects enter beyond the draw distance.
- Three moving pots bounce between the banks of a four-option-wide road without dividers. Moving artwork stays inside the road; props start at question two, survive resume preparation, and fit within the banks at their own world positions.
- 250 questions across six math topics, actual airborne misses, stable question promotion, and one Honey per correct answer.
- Permanent log blocking on phone/tablet, exact stationary distance during contact, and resuming travel just beside the visible bark without an invisible margin.
- Three-second boosts, exactly two-second whirlpools, and jumps that lift the whole tube above all stationary answer pots and land just after the row. Ramps are 430 world units before the pots and align with a divider. Pause and timer expiration are covered.
- Every passage in stationary 2–5 answer rows on phone/tablet: late steering cannot cross a divider, and answered divider tails remain solid until cleared. A lane switch 450 world units before the answer remains possible.
- Saved difficulty streaks, Honey-only rewards and loading older saves with obsolete score fields.
- Equivalent travel and collision outcomes for a long frame and 1,200 short frames.
- Finish from every final answer count on phone/tablet: stable advance planning, narrowing to one passage, a straight terminal road, guided centering, launch within 1.05 seconds of the last answer, a 0.6875-second flight with a completely offscreen bear before results, landing an airborne final answer before the terminal ramp, frozen pause, long-frame completion and fresh restart state.
- Existing question-count boards (20/30/40/50), monotonic Honey rewards, course generation, straight unattended travel, rail contact, steering, collection motion and projection accuracy.

The existing Honey total is the only reward. Track stars, rocks, bonus honey pickups, the separate race score and multiplier are removed.

Build the application:

```sh
xcodebuild -project '../Honey Slide.xcodeproj' -scheme 'Honey Slide' -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/honey-obstacle-debug CODE_SIGNING_ALLOWED=NO build
```

For visual QA, the Debug app accepts `--honey-visual-check=correct:0.35` or `--honey-visual-check=wrong:0.30`. Opening a level freezes the renderer after an impact without selecting an answer or modifying saved progress.

Render the production SwiftUI scene at phone/tablet sizes:

```sh
python3 Tools/honey_performance.py --output /tmp/honey-race-preview --samples 24
```

The runner includes all six race moments, every answer count, jump apex/landing, whirlpool contact, a blocked log, close passage beside its bark, question-two/resumed props, finish approach/funnel/launch/exit scenes and an artwork sheet. Use `--scenario-prefix finish-` for only the finish scenes. It emits phone/tablet PNGs plus CPU/offscreen preparation measurements. These measurements are not presented device FPS. Use a physical iPhone/iPad with Instruments to measure GPU presentation and animation hitches.
