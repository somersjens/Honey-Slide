//
//  AppAudio.swift
//  Elephant Challenge: Math Memory
//
//  All of the app's sound in one place:
//   - looping background music while a game is being played,
//   - the correct / wrong answer sound effects, and
//   - small Apple-native tap sounds for the menus.
//
//  The start/pause card exposes music and effects as two independent controls.
//

import Foundation
import Combine
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif


final class AppAudio: NSObject, ObservableObject {
    static let shared = AppAudio()

    /// Sound effects and background music each have their own preference.
    /// Effects can stay on with the music off, which is what most players want.
    @Published private(set) var gameSoundsEnabled: Bool {
        didSet {
            guard oldValue != gameSoundsEnabled else { return }
            GameSettings.gameSoundsEnabled = gameSoundsEnabled
            if gameSoundsEnabled {
                prepare()
                activateSession()
            } else {
                stopEngine()
                deactivateSessionIfUnused()
            }
        }
    }

    /// The endless background loop, independent of the effects.
    @Published private(set) var musicEnabled: Bool {
        didSet {
            guard oldValue != musicEnabled else { return }
            GameSettings.musicEnabled = musicEnabled
            // Re-apply the session category right away: with the music off,
            // effects should mix with whatever the player is listening to
            // elsewhere rather than silencing it.
            configureSessionIfNeeded()
            if musicEnabled {
                startMusic()
            } else {
                stopMusic()
                deactivateSessionIfUnused()
            }
        }
    }

    var hasAnyAudioEnabled: Bool { gameSoundsEnabled || musicEnabled }

    // MARK: Players

    private var musicPlayer: AVAudioPlayer?

    /// Sound effects play through one long-lived `AVAudioEngine` instead of a
    /// pool of `AVAudioPlayer`s. The render graph stays up for the whole
    /// session, so firing an effect is just "schedule a preloaded PCM buffer on
    /// a node" — no per-play decode, no audio-session touch and no graph rebuild
    /// to land in the same frame as SpriteKit. Because the graph never tears
    /// down, an audio-route change can no longer stall them.
    private let engine = AVAudioEngine()
    /// One player node per effect, kept in its always-on "playing" state so a
    /// trigger is a single cheap `scheduleBuffer(.interrupts)` on the node.
    private var effectNodes: [String: AVAudioPlayerNode] = [:]
    /// Preloaded, lead-trimmed PCM buffer per effect, ready to schedule.
    private var effectBuffers: [String: AVAudioPCMBuffer] = [:]

    /// The catalog of one-shot sound effects. The per-file `volume` values were
    /// measured (each file's RMS) and chosen so every effect lands at the same
    /// loudness as the "return to menu" trophy sound (~-38 dBFS) — the level
    /// that felt right — rather than each raw file playing at its own recorded
    /// level. `key` is what the `play…` methods reference.
    private struct Effect {
        let key: String
        let file: String
        let ext: String
        let volume: Float
        /// Seconds of leading silence in the file, skipped at playback so the
        /// sound fires immediately (measured per file; no re-encoding needed).
        let lead: TimeInterval
    }
    // Most of these are shipped as uncompressed CAF/PCM, converted from the
    // originals without touching their sample rate, channels or timing — which
    // is why their `volume`/`lead` have never had to change. The three `wav`
    // files were already PCM.
    //
    // New effects are trimmed mono AAC. Every effect is decoded into a PCM
    // buffer once in `prepare()` and only ever scheduled from memory afterwards,
    // so the compact files reduce the app download without adding work to a
    // gameplay frame. Their silence is removed in the assets themselves.
    private static let effects: [Effect] = [
        Effect(key: "correct",       file: "sfx_good",           ext: "m4a", volume: 0.069, lead: 0.0),
        Effect(key: "splash",        file: "splash",             ext: "caf", volume: 0.24, lead: 0.0),
        Effect(key: "wrongAnswer",   file: "sfx_wrong",          ext: "m4a", volume: 0.10, lead: 0.0),
        Effect(key: "fireCrackle",   file: "sfx_fire_crackle",   ext: "m4a", volume: 0.30, lead: 0.0),
        Effect(key: "cannonShoot",   file: "sfx_cannon_shoot",   ext: "m4a", volume: 0.15, lead: 0.0),
        Effect(key: "turbo",         file: "sfx_turbo",          ext: "m4a", volume: 0.15, lead: 0.0),
        Effect(key: "lifePickup",    file: "sfx_life_pickup",    ext: "m4a", volume: 0.10, lead: 0.0),
        Effect(key: "endCelebration", file: "sfx_end_screen_celebration", ext: "m4a", volume: 0.20, lead: 0.0),
        // The question card turning face up.
        Effect(key: "cardReveal",    file: "sfx_card_reveal",    ext: "caf", volume: 0.19, lead: 0.010),
        // The thick double card appearing, and the doubled score landing.
        Effect(key: "doubleCard",    file: "sfx_double_card",    ext: "caf", volume: 0.18, lead: 0.0),
        Effect(key: "doubleScore",   file: "sfx_double_score",   ext: "caf", volume: 0.15, lead: 0.0),
        Effect(key: "sessionStart",  file: "sfx_session_start",  ext: "caf", volume: 0.16, lead: 0.225),
        Effect(key: "sessionComplete", file: "sfx_level_complete", ext: "caf", volume: 0.10, lead: 0.010),
        Effect(key: "highScore",     file: "sfx_high_score",     ext: "caf", volume: 0.14, lead: 0.025),
        Effect(key: "characterUnlock", file: "sfx_character_unlock", ext: "caf", volume: 0.12, lead: 0.050),
        // The card counters on the result screen and the home header.
        Effect(key: "cardCount",     file: "sfx_card_count",     ext: "caf", volume: 1.0,  lead: 0.065),
        Effect(key: "cardFlight",    file: "sfx_card_flight",    ext: "caf", volume: 0.812, lead: 0.35),
        // The header totals climbing on the menu. The sound runs for as long as
        // the counters do, where the old blip was over before they had started.
        Effect(key: "cardTotal",     file: "score_increase_main", ext: "caf", volume: 0.094, lead: 0.0),
        Effect(key: "select",        file: "sfx_select",         ext: "caf", volume: 0.17, lead: 0.0),
        Effect(key: "switchOn",      file: "sfx_switch_on",      ext: "caf", volume: 0.89, lead: 0.200),
        Effect(key: "switchOff",     file: "sfx_switch_off",     ext: "caf", volume: 1.0,  lead: 0.170),
        // Physical answer-button press — same cue as the Nuts & Numbers grab.
        Effect(key: "buttonPress",   file: "sfx_button_press",   ext: "caf", volume: 0.31, lead: 0.0)
    ]

    /// True while a level is actually being played (not the menu, the intro/
    /// pause card or the result screen). The music loops everywhere, but plays
    /// louder here.
    private(set) var isGameplayActive = false

    /// The category options actually applied to the shared session, so
    /// `configureSessionIfNeeded()` only calls `setCategory` when the desired
    /// mix behavior has actually changed.
    private var appliedCategoryOptions: AVAudioSession.CategoryOptions?
    private var sessionActive = false
    /// The music loops continuously: softly in the background on the menus and
    /// cards, a little louder during play, and briefly ducked while a sum is
    /// read so the words stay clearly audible over it. Keep these values in dB
    /// so the intended perceived loudness is explicit; AVAudioPlayer itself
    /// expects a linear gain.
    private let menuMusicVolume: Float = pow(10, -26.0 / 20.0)
    private let gameMusicVolume: Float = pow(10, -16.0 / 20.0)
    private let duckedMusicVolume: Float = pow(10, -31.0 / 20.0)

    /// The volume the music should currently sit at, given where the player is.
    private var currentMusicTarget: Float { isGameplayActive ? gameMusicVolume : menuMusicVolume }

    /// One-time, off-the-main-thread setup so nothing has to be allocated,
    /// decoded or session-activated during play — that first-touch work was
    /// what stuttered the game the first time a sound played.
    private var preparationStarted = false
    private var audioResourcesReady = false
    /// The music asset is loaded on its own schedule — only once the music is
    /// actually switched on (see `loadMusicPlayerIfNeeded`).
    private var musicLoadStarted = false
    private var wantsMusicPlayback = false
    /// Audio output waits very briefly after activating the hardware session.
    /// Starting the engine and MP3 decoder in the same instant as that hardware
    /// transition is what can produce a one-off crack on a cold app launch.
    private var sessionOutputReady = false
    private var musicOutputReady = false
    private var sessionStartupToken = 0
    private let sessionSettleDelay: TimeInterval = 0.15
    private let engineToMusicDelay: TimeInterval = 0.10
    /// The track is already mastered at its target level. A short ramp avoids a
    /// click while still making a cold launch audible promptly; the previous
    /// two-second fade made successfully prepared music feel late.
    private let coldMusicFadeDuration: TimeInterval = 0.65
    private let prepareQueue = DispatchQueue(label: "com.elephantchallenge.audio.prepare", qos: .userInitiated)


    private override init() {
        self.gameSoundsEnabled = GameSettings.gameSoundsEnabled
        self.musicEnabled = GameSettings.musicEnabled
        super.init()
        registerForInterruptions()
        // A silent app must never take the output away from another app. The
        // category itself changes nothing until something activates the session,
        // but having a mixing one in place means an implicit activation — by us
        // or by any framework that touches audio — can no longer land on the
        // process default (`.soloAmbient`), which pauses other apps' music.
        if !hasAnyAudioEnabled { configureSessionIfNeeded() }
    }

    func toggleGameSounds() {
        gameSoundsEnabled.toggle()
    }

    func toggleMusic() {
        musicEnabled.toggle()
    }

    // MARK: - Preparation (called once, up front)

    /// Loads every player and resolves installed voices on a background queue.
    /// Cheap to call repeatedly; only the first call works.
    /// The heavy, blocking bits — file decode, `prepareToPlay`, session
    /// activation — happen here, at a calm moment, not mid-game.
    func prepare() {
        // With every sound switch off, stay out of the audio system entirely.
        // Preparation is not just decoding: `AVAudioPlayer.prepareToPlay()`
        // acquires the audio hardware, which implicitly activates the shared
        // session — under the process default category (`.soloAmbient`) that
        // silences whatever the player has running in another app. On a cold
        // launch this ran from the home screen's `onAppear` before any category
        // of ours was applied, which is exactly the interruption being fixed.
        // `preparationStarted` is deliberately left false, so turning a switch
        // back on still prepares everything.
        guard hasAnyAudioEnabled else { return }
        guard !preparationStarted else { return }
        preparationStarted = true
        // Put our own category in place before the first player exists, so an
        // implicit activation can never land on the solo default.
        configureSessionIfNeeded()
        // The music file is loaded separately, and only when the music is
        // actually switched on (see the method).
        loadMusicPlayerIfNeeded()
        prepareQueue.async { [weak self] in
            guard let self else { return }
            // Decode + lead-trim every effect into a ready-to-schedule PCM buffer
            // here, off the main thread, so play time does no file work at all.
            var buffers: [String: AVAudioPCMBuffer] = [:]
            for effect in Self.effects {
                buffers[effect.key] = Self.makeBuffer(named: effect.file, ext: effect.ext,
                                                      trimLeading: effect.lead)
            }
            DispatchQueue.main.async {
                self.installEffectBuffersInBatches(buffers)
            }
        }
    }

    /// Attaches nodes in small main-run-loop batches. AVAudioEngine graph
    /// mutation has to stay serialized, but attaching all effects in one pass
    /// produced a visible cold-launch frame spike on slower devices even though
    /// the file decoding itself was already off-main.
    private func installEffectBuffersInBatches(_ buffers: [String: AVAudioPCMBuffer],
                                               startingAt start: Int = 0) {
        let batchSize = 5
        let end = min(start + batchSize, Self.effects.count)
        for effect in Self.effects[start..<end] where effectBuffers[effect.key] == nil {
            guard let buffer = buffers[effect.key] else { continue }
            effectBuffers[effect.key] = buffer
            let node = AVAudioPlayerNode()
            node.volume = effect.volume
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            effectNodes[effect.key] = node
        }

        if end < Self.effects.count {
            // Yield a render opportunity before touching the next part of the
            // graph; the decoded buffers stay retained by this short-lived job.
            DispatchQueue.main.async { [weak self] in
                self?.installEffectBuffersInBatches(buffers, startingAt: end)
            }
            return
        }

        audioResourcesReady = true
        // The session can go active before this background decode finishes — the
        // tutorial starts gameplay immediately, with no start card, so
        // `activateSession()` runs while `effectNodes` is still empty and
        // `startEngineIfNeeded()` skips (nothing to play). Once activated,
        // `activateSession()` short-circuits and never retries, so the engine
        // would stay down and every effect would be silent. Now that the nodes
        // exist, bring the engine up here.
        if sessionOutputReady { startEngineIfNeeded() }
        // Only touch the audio session when sound is on, so a muted app never
        // interrupts the user's own audio.
        if hasAnyAudioEnabled {
            activateSession()
            startMusicIfReady()
        }
    }

    /// Loads the looping music asset, once, and only while the music is on.
    ///
    /// This is kept out of `prepare()` because building the player is the one
    /// step that reaches the audio hardware by itself: `prepareToPlay()`
    /// implicitly activates the shared session. With the music switched off
    /// there is nothing to play, so the file is never opened and the session is
    /// never touched on its behalf — another app's music keeps running.
    /// Switching the music back on comes through `startMusic()`, which calls
    /// this; the load then happens there instead.
    private func loadMusicPlayerIfNeeded() {
        guard musicEnabled, !musicLoadStarted else { return }
        musicLoadStarted = true
        // The category (solo, since the music is on) before the hardware.
        configureSessionIfNeeded()
        prepareQueue.async { [weak self] in
            // AVAudioPlayer's endless loop keeps this single compressed music
            // asset in memory without repeatedly loading or creating players.
            let music = Self.makePlayer(named: "background_music", ext: "mp3",
                                        loops: -1, volume: 0)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.musicPlayer == nil { self.musicPlayer = music }
                // Music readiness is independent of the effects catalog. The
                // old path waited for all 22 effects to decode and attach before
                // it even activated output, although AVAudioPlayer does not use
                // the effects engine at all.
                self.activateSession()
                self.startMusicIfReady()
            }
        }
    }

    /// Builds a fully prepared player. Runs the decode/`prepareToPlay` cost on
    /// whatever (background) queue calls it.
    private static func makePlayer(named name: String, ext: String = "m4a",
                                   loops: Int, volume: Float) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.numberOfLoops = loops
        player.volume = volume
        player.prepareToPlay()
        return player
    }

    /// Decodes a sound file into a PCM buffer, dropping `trimLeading` seconds of
    /// leading silence so a scheduled buffer sounds immediately. (The old players
    /// did this by seeking on every play; baking it into the buffer once makes
    /// each trigger free.) Runs on whatever background queue calls it.
    private static func makeBuffer(named name: String, ext: String,
                                   trimLeading: TimeInterval) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let skip = AVAudioFramePosition((trimLeading * format.sampleRate).rounded())
        let start = min(max(0, skip), file.length)
        file.framePosition = start
        let frames = AVAudioFrameCount(file.length - start)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil else { return nil }
        return buffer
    }

    /// Starts the effects engine (once) and puts every effect node into its
    /// always-on "playing" state, so a later trigger is a single scheduleBuffer
    /// with nothing to spin up. Requires the session active; a no-op when sound
    /// is off, the engine is already running, or the nodes aren't attached yet.
    private func startEngineIfNeeded() {
        guard gameSoundsEnabled, sessionOutputReady,
              !engine.isRunning, !effectNodes.isEmpty else { return }
        engine.prepare()
        guard (try? engine.start()) != nil else { return }
        for node in effectNodes.values { node.play() }
    }

    /// Stops the effect nodes and the engine (used when going silent or
    /// backgrounding); the attached graph is kept for a later restart.
    private func stopEngine() {
        guard engine.isRunning else { return }
        for node in effectNodes.values { node.stop() }
        engine.stop()
    }

    // MARK: - Audio session

    /// While the game's own background music is off, effects should not stop
    /// music the player has running in another app; while the
    /// game's music is on, it takes over the same way it always has.
    private var desiredCategoryOptions: AVAudioSession.CategoryOptions {
        musicEnabled ? [] : [.mixWithOthers]
    }

    private func configureSessionIfNeeded() {
        let options = desiredCategoryOptions
        guard appliedCategoryOptions != options else { return }
        let session = AVAudioSession.sharedInstance()
        // `.playback` keeps the game audible even with the ring/silent switch
        // set to silent — expected for a game the child is actively playing,
        // and the single in-app switch is the real mute control. `.mixWithOthers`
        // is added only when the game's own music is off, so another app's
        // music keeps playing underneath the game's effects.
        try? session.setCategory(.playback, mode: .default, options: options)
        appliedCategoryOptions = options
    }

    private func activateSession() {
        guard hasAnyAudioEnabled else { return }
        // The looping music has its own prepared AVAudioPlayer and does not need
        // the effects graph. Allow it to activate as soon as that player exists;
        // effects still start once their buffers and nodes have been installed.
        let hasMusicOutput = musicEnabled && musicPlayer != nil
        guard audioResourcesReady || hasMusicOutput else {
            prepare()
            return
        }
        guard !sessionActive else {
            if sessionOutputReady {
                startEngineIfNeeded()
                startMusicIfReady()
            }
            return
        }
        configureSessionIfNeeded()
        try? AVAudioSession.sharedInstance().setActive(true)
        sessionActive = true
        sessionOutputReady = false
        musicOutputReady = false
        sessionStartupToken += 1
        let token = sessionStartupToken
        DispatchQueue.main.asyncAfter(deadline: .now() + sessionSettleDelay) { [weak self] in
            guard let self, token == self.sessionStartupToken,
                  self.sessionActive, self.hasAnyAudioEnabled else { return }
            self.sessionOutputReady = true
            self.startEngineIfNeeded()
            // Only stagger music when the effects engine actually started in
            // this window. On a cold launch music normally becomes ready first;
            // waiting behind a graph that does not exist added pure latency.
            let musicDelay = self.engine.isRunning ? self.engineToMusicDelay : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + musicDelay) {
                guard token == self.sessionStartupToken,
                      self.sessionActive, self.hasAnyAudioEnabled else { return }
                self.musicOutputReady = true
                self.startMusicIfReady()
            }
        }
    }

    private func deactivateSession() {
        guard sessionActive else { return }
        sessionStartupToken += 1
        sessionOutputReady = false
        musicOutputReady = false
        stopEngine()
        // Let any paused apps (music, podcasts) resume once we go quiet.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    private func deactivateSessionIfUnused() {
        guard !hasAnyAudioEnabled else { return }
        deactivateSession()
    }

    // MARK: - Gameplay lifecycle

    /// Called by the game view as the play field becomes (in)active. The music
    /// keeps looping either way; this only raises it for play and lowers it
    /// back to the soft menu level afterwards.
    func setGameplayActive(_ active: Bool) {
        isGameplayActive = active
        if active {
            if musicEnabled {
                startMusic()
                setMusicVolume(gameMusicVolume)
            }
        } else {
            setMusicVolume(menuMusicVolume) // keep the loop, just soften it
        }
    }

    // MARK: - Background music

    /// Starts (or resumes) the endless background loop at the volume that suits
    /// the current screen. Safe to call repeatedly.
    func startMusic() {
        guard musicEnabled else { return }
        wantsMusicPlayback = true
        prepare()
        // The music file is only opened from here on, so switching the music on
        // after a silent launch still loads it.
        loadMusicPlayerIfNeeded()
        activateSession()
        startMusicIfReady()
    }

    /// Starts only after background decoding and the short session-settle
    /// window. There is intentionally no synchronous cold-load fallback here.
    private func startMusicIfReady() {
        guard musicEnabled, wantsMusicPlayback,
              musicOutputReady else { return }
        guard let player = musicPlayer else { return }
        if !player.isPlaying {
            player.volume = 0
            player.play()
            player.setVolume(currentMusicTarget, fadeDuration: coldMusicFadeDuration)
        } else {
            setMusicVolume(currentMusicTarget)
        }
    }

    private func setMusicVolume(_ volume: Float, fade: TimeInterval = 0.7) {
        musicPlayer?.setVolume(volume, fadeDuration: fade)
    }

    /// Fades the music out and stops it — used only when sound is switched off
    /// (or paused for backgrounding, via `pause`).
    private func stopMusic() {
        wantsMusicPlayback = false
        guard let player = musicPlayer, player.isPlaying else {
            musicPlayer?.stop()
            deactivateSessionIfUnused()
            return
        }
        player.setVolume(0, fadeDuration: 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.musicEnabled else { return }
            self.musicPlayer?.stop()
            self.musicPlayer?.currentTime = 0
            self.deactivateSessionIfUnused()
        }
    }

    // MARK: - Sound effects

    // Answers.
    func playCorrect() {
        stopEffect("wrongAnswer")
        playEffect("correct")
    }
    func playSplash()           { playEffect("splash") }          // entering the water
    func playWrongAnswer() {
        // Verdicts are mutually exclusive. In particular, a stale tail from a
        // preceding correct answer must never colour a wrong hoop passage.
        stopEffect("correct")
        playEffect("wrongAnswer")
    }
    func playFireCrackle()      { playEffect("fireCrackle") }     // the cannon fuse burns
    func stopFireCrackle()      { stopEffect("fireCrackle") }
    func playCannonShoot()      { playEffect("cannonShoot") }     // the cannon fires
    func playTurbo()            { playEffect("turbo") }           // the player accelerates
    func playLifePickup()       { playEffect("lifePickup") }      // a life is picked up
    func playEndCelebration()   { playEffect("endCelebration") }  // result hoops rise
    func playCardReveal()       { playEffect("cardReveal") }       // the question becomes visible
    func playDoubleCardAppear() { playEffect("doubleCard") }       // the thick special card
    func playDoubleScore()      { playEffect("doubleScore") }      // a double card paid out
    func playSessionStart()     { playEffect("sessionStart") }
    func playSessionComplete()  { playEffect("sessionComplete") }
    func playHighScore()        { playEffect("highScore") }        // new personal best
    func playCharacterUnlock()  { playEffect("characterUnlock") }
    func playCardCount()        { playEffect("cardCount") }        // cards counting up
    func playCardFlight()       { playEffect("cardFlight") }       // cards flying to the total
    func playCardTotal()        { playEffect("cardTotal") }        // grand total ticks up

    func playMenuTap()          { playEffect("select") }
    func playSwitch(on: Bool)   { playEffect(on ? "switchOn" : "switchOff") }
    func playButtonPress()      { playEffect("buttonPress") }     // arcade answer cap presses in

    private func playEffect(_ key: String) {
        guard gameSoundsEnabled else { return }
        prepare()
        activateSession()
        // Preloaded by `prepare()`. If a sound is somehow needed before that
        // finished (rare — play happens well after launch) it's simply skipped;
        // no synchronous file work is ever done on this hot path.
        guard sessionOutputReady,
              let node = effectNodes[key], let buffer = effectBuffers[key] else { return }
        // The node is already running (see `startEngineIfNeeded`); `.interrupts`
        // restarts it from the top with nothing to allocate — the whole trigger
        // is one buffer schedule on the audio render thread, invisible to the
        // frame. The lead trim and volume are already baked in at load time.
        if !node.isPlaying { node.play() }
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// Ends a timed effect early when its matching visual is shortened (for
    /// example the fuse under Reduce Motion). The node remains ready to reuse.
    private func stopEffect(_ key: String) {
        guard let node = effectNodes[key], node.isPlaying else { return }
        node.stop()
        if engine.isRunning { node.play() }
    }

    // MARK: - Interruptions & backgrounding

    private func registerForInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        // A route change (headphones plugged/unplugged, etc.) stops the engine;
        // this brings it back so effects keep working afterwards.
        center.addObserver(self, selector: #selector(handleEngineConfigurationChange),
                           name: .AVAudioEngineConfigurationChange, object: engine)
#if canImport(UIKit)
        center.addObserver(self, selector: #selector(appWillResignActive),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
#endif
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            musicPlayer?.pause()
            // The system deactivates our session and stops the engine; mirror
            // that so `ended` can cleanly reactivate and bring the effects back.
            sessionStartupToken += 1
            sessionOutputReady = false
            musicOutputReady = false
            sessionActive = false
            stopEngine()
        case .ended:
            if let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                prepare()
                activateSession()
                startMusic()
            }
        @unknown default:
            break
        }
    }

    /// The route/config changed and stopped the engine; restart it in place.
    @objc private func handleEngineConfigurationChange() {
        DispatchQueue.main.async { [weak self] in self?.startEngineIfNeeded() }
    }

    @objc private func appWillResignActive() {
        musicPlayer?.pause()
        sessionStartupToken += 1
        sessionOutputReady = false
        musicOutputReady = false
        sessionActive = false
        stopEngine()
    }

    @objc private func appDidBecomeActive() {
        // Restore the shared output. Music and effects remain independently
        // governed by their own switches.
        prepare()
        activateSession()
        startMusic()
        startEngineIfNeeded()
    }
}
