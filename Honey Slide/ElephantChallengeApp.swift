//
//  ElephantChallengeApp.swift
//  Elephant Challenge: Math Memory
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// The complete app is played in landscape, on iPhone and on iPad. Keeping the
/// runtime mask aligned with the generated Info.plist prevents sheets and
/// full-screen covers from briefly rotating through portrait during presentation.
/// iPadOS 26 and later can still open a scene in portrait when windowing ignores
/// the property list, so every scene is asked to return to landscape as well.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?)
    -> UIInterfaceOrientationMask {
        .landscape
    }
}

enum LandscapeLock {
    static func enforce() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let orientation = scene.effectiveGeometry.interfaceOrientation
            guard !orientation.isLandscape else { continue }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

/// A zero-size controller consulted while the scene is on screen. Its mask
/// matches the app delegate, and appearing is what re-requests landscape if
/// iPad presented the window in portrait.
private struct LandscapeLockInstaller: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LandscapeLockController {
        LandscapeLockController()
    }

    func updateUIViewController(_ controller: LandscapeLockController, context: Context) {
        controller.lockIfNeeded()
    }
}

private final class LandscapeLockController: UIViewController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersInterfaceOrientationLocked: Bool { true }
    override var shouldAutorotate: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lockIfNeeded()
    }

    func lockIfNeeded() {
        LandscapeLock.enforce()
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
#endif

@main
struct ElephantChallengeApp: App {
#if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
#endif
    @AppStorage(GameSettings.onboardingCompleteKey) private var onboardingComplete = false
    @State private var showsOnboardingReplay = false
    @StateObject private var language = LanguageManager.shared
    @StateObject private var promotedPurchase = PromotedPurchaseCoordinator.shared
    @StateObject private var tutorial = TutorialCenter.shared

    init() {
        // The deterministic App Store trailer exporter is development tooling.
        // It deliberately bypasses persistence, StoreKit, notifications and
        // onboarding so an export cannot mutate a real player's state.
        if TrailerRuntime.isExporting { return }

        // Bring stored progress up to the current version before anything can
        // read it: data written by Jumping Fox must never reach the new game.
        Progress.store.migrateIfNeeded()
        // Decimal answers are printed with the separator of the language the
        // player is reading — a comma in Dutch, a point in English — rather
        // than the device's. The in-app language switch must win here too.
        DecimalAnswer.separatorProvider = {
            LanguageManager.shared.locale.decimalSeparator ?? "."
        }
        // Capture the first launch date independently of when the player first
        // finishes a game; later review phases use age since installation.
        _ = ReviewRequestCoordinator.shared
        PromotedPurchaseCoordinator.shared.startListening()
        // Bring iCloud sync online at launch, not just once the home screen
        // appears — on a fresh reinstall the app opens on onboarding, which
        // never touches ProgressSync, and the saved name would stay missing.
        _ = ProgressSync.shared
        // Install the notification delegate and rebuild the reminder schedule
        // for players who granted permission in an earlier session.
        NotificationManager.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if TrailerRuntime.isExporting {
                    TrailerExportHost()
                } else {
                    ZStack {
                        if onboardingComplete && !showsOnboardingReplay {
                            HomeView {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    showsOnboardingReplay = true
                                }
                            }
                                // Both screens fade through each other rather than one
                                // replacing the other, so the hand-over reads as a
                                // single settling motion instead of a cut.
                                .transition(.opacity.combined(with: .scale(scale: 1.015)))
                        }
                        // Stays on top for the whole hand-over to the tutorial: the menu
                        // is built and settles behind it, and the guided level rises
                        // over the very screen the last answer was given on. Without
                        // this the menu would cross-fade in and straight back out, which
                        // reads as a screen flashing past on the way to the game.
                        if !onboardingComplete || showsOnboardingReplay
                            || tutorial.isHandingOverFromWelcome {
                            OnboardingView {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    showsOnboardingReplay = false
                                }
                            }
                                .transition(.opacity.combined(with: .scale(scale: 0.99)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.42), value: onboardingComplete)
                    .animation(.easeInOut(duration: 0.42), value: showsOnboardingReplay)
                    // Re-renders every `Text` (and formats numbers) when the language
                    // changes; combined with the bundle redirection this makes the
                    // switch instant, no restart required.
                    .environment(\.locale, language.locale)
                    .environment(\.layoutDirection, language.effective.layoutDirection)
                    // Palettes and copy are authored for light surfaces. Without this,
                    // Dark Mode turns system fills black and inverts `.primary` /
                    // `.secondary` labels against those same light colours.
                    .preferredColorScheme(.light)
#if canImport(UIKit)
                    .background {
                        LandscapeLockInstaller()
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .onAppear { LandscapeLock.enforce() }
                    .onReceive(NotificationCenter.default.publisher(
                        for: UIDevice.orientationDidChangeNotification
                    )) { _ in
                        LandscapeLock.enforce()
                    }
#endif
                    .sheet(isPresented: Binding(
                        get: { promotedPurchase.isAwaitingParentApproval },
                        set: { isPresented in
                            if !isPresented { promotedPurchase.cancelDeferredPurchase() }
                        }
                    ),
                           onDismiss: { promotedPurchase.cancelDeferredPurchase() }) {
                        let character = CharacterCatalog.current(isPremium: PremiumStore.shared.isPremium)
                        ParentApprovalGate(
                            accent: character.color,
                            deepColor: character.deepColor,
                            onApproved: { promotedPurchase.approveDeferredPurchase() }
                        )
                        .gameEnvironment()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                    }
                }
            }
        }
    }
}

/// Shared layout helper, used to give iPad more breathing room without
/// changing the visual hierarchy.
enum AppLayout {
    static var isPad: Bool {
#if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }


    /// Shared landscape canvas widths. iPad uses the extra room without
    /// stretching controls into long, hard-to-scan rows.
    static var landscapeContentWidth: CGFloat { isPad ? 1180 : 980 }
    static var landscapeGutter: CGFloat { isPad ? 28 : 16 }
}
