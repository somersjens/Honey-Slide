//
//  Localization.swift
//  Elephant Challenge: Math Memory
//
//  Runtime language switching + the little flag-and-chevron picker shown on
//  the welcome screens and the premium menu.
//
//  SwiftUI's `Text` resolves its strings from the *main bundle*, not from the
//  environment locale, so changing `\.locale` alone is not enough to swap the
//  language while the app is running. We install a tiny Bundle subclass that
//  redirects `localizedString(...)` to a chosen `.lproj`. Changing the
//  environment locale at the root then re-renders every `Text`, which now
//  reads the redirected strings — a live, no-restart language change.
//
//  English is the source language and the safety net: anything a language has
//  not translated yet — a missing key, or a language with no translations at
//  all — is answered in English rather than left as a raw identifier or handed
//  back to whatever the device happens to be set to.
//

import SwiftUI
import Combine
import ObjectiveC

// MARK: - Supported languages

/// A language the app can present, identified by its ISO code and shown in the
/// picker with a flag and its own-language name (endonym).
///
/// The roster below is the app's *offer*; the string catalog is its *coverage*.
/// The two are deliberately allowed to differ: a language is listed here as
/// soon as we intend to ship it, and anything not yet translated falls back to
/// English rather than disappearing from the picker. Translating a language
/// therefore needs no change to this file at all.
struct AppLanguage: Identifiable, Hashable, Sendable {
    /// ISO 639 code (optionally with a region, as in `pt-BR`), matching the
    /// language's `.lproj` and its column in the string catalog.
    let code: String
    /// Flag shown in the picker. Carried per language because language and
    /// country are not the same thing — nothing can derive one from the other,
    /// which is why this is the one detail a new language must spell out.
    let flag: String

    var id: String { code }

    /// Which way this language reads. SwiftUI settles the layout direction from
    /// the bundle at launch and never revisits it, so an in-app switch to
    /// Arabic or Hebrew has to say this out loud — otherwise the words change
    /// and the screen stays the wrong way round.
    var layoutDirection: LayoutDirection {
        Locale.Language(identifier: baseCode).characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    /// The language part of the code, with any region dropped: `pt` for `pt-BR`.
    var baseCode: String {
        code.split(separator: "-").first.map(String.init) ?? code
    }

    /// The language's name in its own language — the convention for a picker.
    /// Read from the system rather than kept in a table, so seventy-odd names
    /// stay correct, in their own script, with nobody maintaining them.
    var displayName: String {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forIdentifier: code)
                ?? locale.localizedString(forLanguageCode: code),
              name != code else { return code.uppercased() }
        return Self.capitalizedForPicker(name, in: locale)
    }

    /// CLDR writes each endonym the way its own language does, which for French
    /// or Polish means lowercase; a picker capitalises. Two cases must be left
    /// alone: scripts that have no capitals to speak of (Georgian's Mtavruli
    /// exists in Unicode but is not used for a name like this), and names whose
    /// small first letter is deliberate — isiZulu is not "IsiZulu".
    private static func capitalizedForPicker(_ name: String, in locale: Locale) -> String {
        guard let first = name.unicodeScalars.first,
              bicameralScripts.contains(where: { $0.contains(first.value) }),
              !name.dropFirst().contains(where: { $0.isUppercase }) else { return name }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// Latin, Greek, Cyrillic and Armenian: the scripts in this roster where a
    /// reader expects to see a capital at the front of a name.
    private static let bicameralScripts: [ClosedRange<UInt32>] = [
        0x0041...0x02AF,  // Latin and its extended blocks
        0x0370...0x03FF,  // Greek
        0x0400...0x052F,  // Cyrillic
        0x0530...0x058F   // Armenian
    ]

    /// Every language the app offers, listed by ISO code and flag. Translating
    /// one is a string-catalog job; this list only decides what the picker
    /// shows and is otherwise inert.
    private static let roster: [AppLanguage] = [
        AppLanguage(code: "af", flag: "\u{1F1FF}\u{1F1E6}"),  // Afrikaans
        AppLanguage(code: "sq", flag: "\u{1F1E6}\u{1F1F1}"),  // Albanian
        AppLanguage(code: "am", flag: "\u{1F1EA}\u{1F1F9}"),  // Amharic
        AppLanguage(code: "ar", flag: "\u{1F1F8}\u{1F1E6}"),  // Arabic
        AppLanguage(code: "hy", flag: "\u{1F1E6}\u{1F1F2}"),  // Armenian
        AppLanguage(code: "as", flag: "\u{1F1EE}\u{1F1F3}"),  // Assamese
        AppLanguage(code: "az", flag: "\u{1F1E6}\u{1F1FF}"),  // Azerbaijani
        AppLanguage(code: "eu", flag: "\u{1F1EA}\u{1F1F8}"),  // Basque
        AppLanguage(code: "be", flag: "\u{1F1E7}\u{1F1FE}"),  // Belarusian
        AppLanguage(code: "bn", flag: "\u{1F1E7}\u{1F1E9}"),  // Bengali
        AppLanguage(code: "bs", flag: "\u{1F1E7}\u{1F1E6}"),  // Bosnian
        AppLanguage(code: "bg", flag: "\u{1F1E7}\u{1F1EC}"),  // Bulgarian
        AppLanguage(code: "my", flag: "\u{1F1F2}\u{1F1F2}"),  // Burmese
        AppLanguage(code: "ca", flag: "\u{1F1EA}\u{1F1F8}"),  // Catalan
        AppLanguage(code: "zh", flag: "\u{1F1E8}\u{1F1F3}"),  // Chinese
        AppLanguage(code: "hr", flag: "\u{1F1ED}\u{1F1F7}"),  // Croatian
        AppLanguage(code: "cs", flag: "\u{1F1E8}\u{1F1FF}"),  // Czech
        AppLanguage(code: "da", flag: "\u{1F1E9}\u{1F1F0}"),  // Danish
        AppLanguage(code: "nl", flag: "\u{1F1F3}\u{1F1F1}"),  // Dutch
        AppLanguage(code: "en", flag: "\u{1F1EC}\u{1F1E7}"),  // English
        AppLanguage(code: "et", flag: "\u{1F1EA}\u{1F1EA}"),  // Estonian
        AppLanguage(code: "fo", flag: "\u{1F1EB}\u{1F1F4}"),  // Faroese
        AppLanguage(code: "fi", flag: "\u{1F1EB}\u{1F1EE}"),  // Finnish
        AppLanguage(code: "fr", flag: "\u{1F1EB}\u{1F1F7}"),  // French
        AppLanguage(code: "gl", flag: "\u{1F1EA}\u{1F1F8}"),  // Galician
        AppLanguage(code: "ka", flag: "\u{1F1EC}\u{1F1EA}"),  // Georgian
        AppLanguage(code: "de", flag: "\u{1F1E9}\u{1F1EA}"),  // German
        AppLanguage(code: "el", flag: "\u{1F1EC}\u{1F1F7}"),  // Greek
        AppLanguage(code: "gu", flag: "\u{1F1EE}\u{1F1F3}"),  // Gujarati
        AppLanguage(code: "he", flag: "\u{1F1EE}\u{1F1F1}"),  // Hebrew
        AppLanguage(code: "hi", flag: "\u{1F1EE}\u{1F1F3}"),  // Hindi
        AppLanguage(code: "hu", flag: "\u{1F1ED}\u{1F1FA}"),  // Hungarian
        AppLanguage(code: "is", flag: "\u{1F1EE}\u{1F1F8}"),  // Icelandic
        AppLanguage(code: "id", flag: "\u{1F1EE}\u{1F1E9}"),  // Indonesian
        AppLanguage(code: "ga", flag: "\u{1F1EE}\u{1F1EA}"),  // Irish
        AppLanguage(code: "it", flag: "\u{1F1EE}\u{1F1F9}"),  // Italian
        AppLanguage(code: "ja", flag: "\u{1F1EF}\u{1F1F5}"),  // Japanese
        AppLanguage(code: "kn", flag: "\u{1F1EE}\u{1F1F3}"),  // Kannada
        AppLanguage(code: "kk", flag: "\u{1F1F0}\u{1F1FF}"),  // Kazakh
        AppLanguage(code: "km", flag: "\u{1F1F0}\u{1F1ED}"),  // Khmer
        AppLanguage(code: "ko", flag: "\u{1F1F0}\u{1F1F7}"),  // Korean
        AppLanguage(code: "lo", flag: "\u{1F1F1}\u{1F1E6}"),  // Lao
        AppLanguage(code: "lv", flag: "\u{1F1F1}\u{1F1FB}"),  // Latvian
        AppLanguage(code: "lt", flag: "\u{1F1F1}\u{1F1F9}"),  // Lithuanian
        AppLanguage(code: "mk", flag: "\u{1F1F2}\u{1F1F0}"),  // Macedonian
        AppLanguage(code: "ms", flag: "\u{1F1F2}\u{1F1FE}"),  // Malay
        AppLanguage(code: "ml", flag: "\u{1F1EE}\u{1F1F3}"),  // Malayalam
        AppLanguage(code: "mr", flag: "\u{1F1EE}\u{1F1F3}"),  // Marathi
        AppLanguage(code: "mn", flag: "\u{1F1F2}\u{1F1F3}"),  // Mongolian
        AppLanguage(code: "ne", flag: "\u{1F1F3}\u{1F1F5}"),  // Nepali
        AppLanguage(code: "nb", flag: "\u{1F1F3}\u{1F1F4}"),  // Norwegian Bokmål
        AppLanguage(code: "or", flag: "\u{1F1EE}\u{1F1F3}"),  // Odia
        AppLanguage(code: "fa", flag: "\u{1F1EE}\u{1F1F7}"),  // Persian
        AppLanguage(code: "pl", flag: "\u{1F1F5}\u{1F1F1}"),  // Polish
        AppLanguage(code: "pt", flag: "\u{1F1F5}\u{1F1F9}"),  // Portuguese
        AppLanguage(code: "pa", flag: "\u{1F1EE}\u{1F1F3}"),  // Punjabi
        AppLanguage(code: "ro", flag: "\u{1F1F7}\u{1F1F4}"),  // Romanian
        AppLanguage(code: "ru", flag: "\u{1F1F7}\u{1F1FA}"),  // Russian
        AppLanguage(code: "sr", flag: "\u{1F1F7}\u{1F1F8}"),  // Serbian
        AppLanguage(code: "si", flag: "\u{1F1F1}\u{1F1F0}"),  // Sinhala
        AppLanguage(code: "sk", flag: "\u{1F1F8}\u{1F1F0}"),  // Slovak
        AppLanguage(code: "sl", flag: "\u{1F1F8}\u{1F1EE}"),  // Slovenian
        AppLanguage(code: "es", flag: "\u{1F1EA}\u{1F1F8}"),  // Spanish
        AppLanguage(code: "sw", flag: "\u{1F1F0}\u{1F1EA}"),  // Swahili
        AppLanguage(code: "sv", flag: "\u{1F1F8}\u{1F1EA}"),  // Swedish
        AppLanguage(code: "ta", flag: "\u{1F1EE}\u{1F1F3}"),  // Tamil
        AppLanguage(code: "te", flag: "\u{1F1EE}\u{1F1F3}"),  // Telugu
        AppLanguage(code: "th", flag: "\u{1F1F9}\u{1F1ED}"),  // Thai
        AppLanguage(code: "bo", flag: "\u{1F1E8}\u{1F1F3}"),  // Tibetan
        AppLanguage(code: "tr", flag: "\u{1F1F9}\u{1F1F7}"),  // Turkish
        AppLanguage(code: "uk", flag: "\u{1F1FA}\u{1F1E6}"),  // Ukrainian
        AppLanguage(code: "ur", flag: "\u{1F1F5}\u{1F1F0}"),  // Urdu
        AppLanguage(code: "ug", flag: "\u{1F1E8}\u{1F1F3}"),  // Uyghur
        AppLanguage(code: "uz", flag: "\u{1F1FA}\u{1F1FF}"),  // Uzbek
        AppLanguage(code: "vi", flag: "\u{1F1FB}\u{1F1F3}"),  // Vietnamese
        AppLanguage(code: "cy", flag: "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}"),  // Welsh
        AppLanguage(code: "zu", flag: "\u{1F1FF}\u{1F1E6}"),  // Zulu
    ]

    /// The roster, plus anything the bundle turns out to carry that is not on
    /// it — a translation can never be stranded by a forgotten line above.
    /// Ordered by endonym, which is the order the picker reads in.
    static let all: [AppLanguage] = {
        let listed = Set(roster.map(\.code))
        let extras = Bundle.main.localizations
            .filter { $0 != "Base" && !listed.contains($0) }
            // No flag to be had for an unlisted language; a globe is honest
            // where a guessed flag would not be.
            .map { AppLanguage(code: $0, flag: "\u{1F310}") }
        return (roster + extras)
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
    }()

    /// Look up a language by its code, preferring an exact match and otherwise
    /// accepting the language without its region (`nl` for a `nl-BE` device).
    static func named(_ code: String) -> AppLanguage? {
        if let exact = all.first(where: { $0.code == code }) { return exact }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return all.first { $0.baseCode == base }
    }

    /// The source language, and the fallback for every key another language has
    /// not translated yet.
    static let english = AppLanguage(code: "en", flag: "\u{1F1EC}\u{1F1E7}")
}

// MARK: - Language manager

/// Holds the user's language choice. `nil` means "follow the device", which is
/// the default at first launch; picking a flag pins the app to that language.
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()
    private static let overrideKey = "settings.languageOverride"

    @Published var override: AppLanguage? {
        didSet {
            let defaults = UserDefaults.standard
            if let override {
                defaults.set(override.code, forKey: Self.overrideKey)
            } else {
                defaults.removeObject(forKey: Self.overrideKey)
            }
            apply()
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.overrideKey) {
            override = AppLanguage.named(raw)
        }
        apply()
    }

    /// Point both string-lookup paths at the language now in force, and work
    /// out once whether that language can come up short — so the per-lookup
    /// fallback below is only paid for by a translation that is still partial.
    private func apply() {
        let target = Self.lprojBundle(for: effective.code) ?? Self.englishBundle ?? .main
        bundle = target
        mayLackTranslations = !Self.coversEverythingEnglishHas(target)
        Bundle.setLanguage(override?.code)
    }

    /// The language actually shown: the pinned choice, or the device's best
    /// match among the languages we ship. Matching goes through
    /// `AppLanguage.named`, which accepts a regional variant of a language we
    /// have, so a newly translated language is followed automatically.
    var effective: AppLanguage {
        if let override { return override }
        for code in Bundle.main.preferredLocalizations {
            if let match = AppLanguage.named(code) { return match }
        }
        return .english
    }

    /// Drives the environment locale, which both formats numbers correctly and
    /// forces every `Text` to re-render when the language changes.
    var locale: Locale { Locale(identifier: effective.code) }

    /// The `.lproj` bundle for the language currently shown, or English where
    /// that language carries no translations at all. `String(localized:)`
    /// ignores the runtime bundle redirection used for `Text`, so any string
    /// resolved in code must be pointed at this bundle explicitly (see `L`).
    private(set) var bundle: Bundle = .main

    /// True when the language on screen is missing at least one string English
    /// has, which is the normal state for a translation still in progress.
    private(set) var mayLackTranslations = false

    /// The English `.lproj`, used as the last-resort fallback for any key a
    /// language has not translated yet.
    static let englishBundle: Bundle? = lprojBundle(for: "en")

    static func lprojBundle(for code: String) -> Bundle? {
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    /// Whether a language holds every key English does. Answered by reading the
    /// two compiled tables once, rather than by guessing per lookup.
    private static func coversEverythingEnglishHas(_ bundle: Bundle) -> Bool {
        guard let english = englishBundle, bundle !== english else { return true }
        return keys(in: english).isSubset(of: keys(in: bundle))
    }

    private static func keys(in bundle: Bundle) -> Set<String> {
        var result: Set<String> = []
        // Plain strings and plural rules live in two separate compiled files;
        // a key present in either one is a key the language has.
        for type in ["strings", "stringsdict"] {
            guard let path = bundle.path(forResource: "Localizable", ofType: type),
                  let table = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            result.formUnion(table.keys)
        }
        return result
    }

    func select(_ language: AppLanguage) {
        withAnimation(.easeInOut(duration: 0.2)) { override = language }
    }
}

/// A table name no bundle can hold, used below to find out what "not found"
/// looks like for a given key.
private let absentTable = "\u{0}NoSuchTable"

/// Resolve a localized string in the language the user has chosen. Use this
/// everywhere instead of `String(localized:)`, which always follows the system
/// language regardless of the in-app switch.
func L(_ key: String.LocalizationValue) -> String {
    let manager = LanguageManager.shared
    let value = String(localized: key, bundle: manager.bundle, locale: manager.locale)
    guard manager.mayLackTranslations,
          let english = LanguageManager.englishBundle else { return value }

    // Unlike `localizedString(forKey:)`, `String(localized:)` offers no way to
    // tell a translation apart from a miss: a key it cannot find comes back as
    // the key itself with the arguments filled in. Asking a table that cannot
    // exist produces exactly that string for this key and these arguments, so
    // the two matching means the language has no entry — and English answers
    // instead. A fully translated language never reaches this line.
    let missing = String(localized: key, table: absentTable,
                         bundle: manager.bundle, locale: manager.locale)
    return value == missing
        ? String(localized: key, bundle: english, locale: manager.locale)
        : value
}

/// A count written the way the language being read groups its digits: 1.284 in
/// Dutch, 1,284 in English. Every running total goes through this — a card
/// total in the tens or hundreds of thousands is an unreadable run of digits
/// without it, and it is exactly the totals that grow that far.
@MainActor
func LNumber(_ value: Int) -> String {
    NumberFormatting.grouped(value)
}

@MainActor
private enum NumberFormatting {
    /// Built once per language rather than per frame: these are read by counters
    /// that redraw on a display link.
    private static var formatters: [String: NumberFormatter] = [:]

    static func grouped(_ value: Int) -> String {
        let locale = LanguageManager.shared.locale
        let formatter: NumberFormatter
        if let cached = formatters[locale.identifier] {
            formatter = cached
        } else {
            let made = NumberFormatter()
            made.numberStyle = .decimal
            made.locale = locale
            made.maximumFractionDigits = 0
            formatters[locale.identifier] = made
            formatter = made
        }
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// Resolve a localized string from a key that is only known at runtime (for
/// example an indexed key like `game.encouragement.3`). Routes through the same
/// bundle as `L(_:)` so the in-app language switch applies consistently instead
/// of relying on `Bundle.main`'s redirection.
func L(key: String) -> String {
    let manager = LanguageManager.shared
    let value = manager.bundle.localizedString(forKey: key, value: key, table: nil)
    // A key that resolves to itself was not found in the chosen language; fall
    // back to English so an untranslated key never surfaces as a raw identifier.
    if value == key, let english = LanguageManager.englishBundle {
        return english.localizedString(forKey: key, value: key, table: nil)
    }
    return value
}

/// Resolve a runtime key in the language on screen *only*, with no English
/// fallback. `nil` means that language has no entry for it.
///
/// This is for the one case the English fallback handles badly: a key that
/// refines a line the catalog already carries in every language. Falling back
/// to English there would swap a good translation for an English sentence, so
/// the caller wants to know it came up short and offer the broader line
/// instead. Everything else should use `L(key:)`.
func LTranslated(key: String) -> String? {
    let value = LanguageManager.shared.bundle.localizedString(forKey: key, value: key, table: nil)
    return value == key ? nil : value
}

/// Resolve a runtime key whose text varies with a count — "1 star" against
/// "3 stars". The catalog holds one plural rule per language, so the count
/// and the noun agree wherever the app is read; nothing here has to know which
/// forms a language distinguishes.
func L(key: String, count: Int) -> String {
    String(format: L(key: key), locale: LanguageManager.shared.locale, count)
}

// MARK: - Bundle redirection (the mechanism behind a live switch)

private var languageBundleKey: UInt8 = 0

/// A Bundle that, when asked for a localized string, forwards the request to a
/// specific `.lproj` bundle if one has been set.
private final class LanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let redirected = objc_getAssociatedObject(self, &languageBundleKey) as? Bundle {
            let result = redirected.localizedString(forKey: key, value: key, table: tableName)
            // Fall back to English for any key the chosen language is missing,
            // so a partial translation never leaves a raw key on screen.
            if result == key,
               let english = LanguageManager.englishBundle,
               english !== redirected {
                return english.localizedString(forKey: key, value: value, table: tableName)
            }
            return result
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// Swap `Bundle.main`'s class exactly once so it can redirect lookups.
    private static let installLanguageBundle: Void = {
        object_setClass(Bundle.main, LanguageBundle.self)
    }()

    /// Point `Bundle.main` at a language's `.lproj`. Passing `nil` restores the
    /// device's normal resolution, which is what "follow the device" means.
    ///
    /// A language that is offered but not yet translated is pinned to English
    /// rather than left to the device: someone on a Dutch phone who asks for
    /// Portuguese wants the language they picked or the source language, not a
    /// silent return to Dutch.
    static func setLanguage(_ language: String?) {
        _ = installLanguageBundle
        let target: Bundle?
        if let language {
            target = LanguageManager.lprojBundle(for: language) ?? LanguageManager.englishBundle
        } else {
            target = nil
        }
        objc_setAssociatedObject(Bundle.main, &languageBundleKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

// MARK: - Liquid glass styling with an iOS 16 fallback

private struct LiquidGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }
    }
}

extension View {
    /// Liquid-glass capsule background (with an iOS 16 material fallback),
    /// shared by the language picker and the onboarding back button so they
    /// match exactly.
    func liquidGlassCapsule() -> some View { modifier(LiquidGlassCapsule()) }
}

// MARK: - Re-applying the language environment across modal boundaries

/// Re-applies the app's locale. Modal presentations (`sheet`,
/// `fullScreenCover`) begin a fresh environment and do not inherit the values
/// set at the app root, so any full-screen surface presented that way (the game
/// and result screens) must opt back in.
private struct GameEnvironment: ViewModifier {
    @ObservedObject private var language = LanguageManager.shared
    func body(content: Content) -> some View {
        content
            .environment(\.locale, language.locale)
            .environment(\.layoutDirection, language.effective.layoutDirection)
            // Palettes and copy are authored for light surfaces. Sheets and
            // full-screen covers start a fresh environment, so Dark Mode would
            // otherwise invert system fills and labels on those screens.
            .preferredColorScheme(.light)
    }
}

extension View {
    /// Carry the chosen language's locale into a modally presented surface.
    func gameEnvironment() -> some View { modifier(GameEnvironment()) }
}

// MARK: - The picker

/// A flag with a chevron. Tap to choose a language; the current one is ticked.
struct LanguagePicker: View {
    @ObservedObject private var language = LanguageManager.shared
    @State private var showsLanguages = false

    /// Colour for the chevron so it can sit on light or dark backgrounds.
    var tint: Color = .secondary
    /// Callers can opt into the larger, touch-friendly iPad treatment while
    /// preserving the compact control on iPhone.
    var scale: CGFloat = 1

    var body: some View {
        if AppLayout.isPad {
            padPicker
        } else {
            phoneMenu
        }
    }

    /// iPhone keeps the system menu. It is already the right size for that screen.
    private var phoneMenu: some View {
        Menu {
            ForEach(AppLanguage.all) { option in
                languageButton(option)
            }
        } label: {
            pickerLabel
        }
    }

    /// The system menu stays at a phone point size on iPad, which reads small
    /// next to the enlarged Premium controls. A popover can carry the same
    /// list at the size of the other iPad pop-outs.
    private var padPicker: some View {
        Button {
            showsLanguages = true
        } label: {
            pickerLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsLanguages, arrowEdge: .top) {
            languageList
                .presentationCompactAdaptation(.popover)
        }
    }

    private var pickerLabel: some View {
        HStack(spacing: 5) {
            Text(language.effective.flag)
                .font(.system(size: 20 * scale))
            Image(systemName: "chevron.down")
                .font(.system(size: 10 * scale, weight: .bold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 8 * scale)
        .liquidGlassCapsule()
        .contentShape(Capsule())
    }

    private func languageButton(_ option: AppLanguage) -> some View {
        Button {
            language.select(option)
        } label: {
            // Flag + endonym are already runtime strings and must not
            // be treated as a localizable key, so compose them verbatim.
            let title = Text(verbatim: "\(option.flag)  \(option.displayName)")
            if language.effective == option {
                Label { title } icon: { Image(systemName: "checkmark") }
            } else {
                title
            }
        }
    }

    private var languageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(AppLanguage.all) { option in
                        let selected = language.effective == option
                        Button {
                            language.select(option)
                            showsLanguages = false
                        } label: {
                            HStack(spacing: 14) {
                                Text(verbatim: option.flag)
                                    .font(.system(size: 30))
                                Text(verbatim: option.displayName)
                                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.primary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .background(selected ? Color.primary.opacity(0.08) : .clear,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .id(option.id)
                    }
                }
                .padding(12)
            }
            .frame(width: 380, height: 520)
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo(language.effective.id, anchor: .center)
                }
            }
        }
    }
}
