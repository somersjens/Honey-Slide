//
//  PracticeMode.swift
//  Number Reef
//
//  The three order buttons that sit under the topic circles: Order · Random ·
//  Mixed. They do not change *what* you practise — the topic and the level do
//  that — they change the *order and spread* of the sums you get.
//
//  Ported from Jumping Fox by way of MenuKit. Two things are deliberate:
//
//  · The raw values are the stored values ("standard"/"random"/"mix"), and one
//    mode carries an empty `idSuffix` so existing scoreboards keep their keys.
//    In Jumping Fox that was `.order`; here it is `.mixed`, because until now
//    Number Reef only ever generated the Mixed route — every best score on
//    disk was earned playing it, and it must stay attached to it.
//  · Fractions and Percentages do not sort their sub-levels by order at all;
//    the same three buttons change *what kind of sum* you get. They therefore
//    carry their own labels, their own pop-out heading and their own texts
//    (`ModeLabelOverride`), while Mixed keeps the shared label everywhere.
//

import Foundation

// MARK: - Per-topic label overrides

/// Alternative labels and pop-out copy for a topic whose three buttons mean
/// something other than "order". `mixedTitleKey` / `mixedInfoKey` stay nil for
/// both current topics: Mixed keeps its shared label and its shared text.
public struct ModeLabelOverride: Sendable {
    public let orderTitleKey: String
    public let randomTitleKey: String
    public var mixedTitleKey: String?

    public let infoHeaderKey: String
    public let orderInfoKey: String
    public let randomInfoKey: String
    public var mixedInfoKey: String?
}

// MARK: - The three modes

public enum PracticeMode: String, CaseIterable, Identifiable, Codable, Sendable {
    /// The calm, predictable climbing route.
    case order = "standard"
    /// This level's own number only, shuffled.
    case random = "random"
    /// This number *or a lower one*, all jumbled, leaning on the harder end.
    case mixed = "mix"

    public var id: String { rawValue }

    /// Appended to a level id so every mode keeps its own score. Empty for
    /// `.mixed` on purpose — see the file header.
    public var idSuffix: String {
        switch self {
        case .order:  return ".order"
        case .random: return ".random"
        case .mixed:  return ""
        }
    }

    /// The mode a player who has never made a choice lands on: the route the
    /// game generated before the three buttons existed.
    public static let fallback = PracticeMode.mixed

    /// Shared button label.
    public var titleKey: String {
        switch self {
        case .order:  return "mode.order"
        case .random: return "mode.random"
        case .mixed:  return "mode.mixed"
        }
    }

    /// Shared pop-out body, under the `info.mode.header` ("Order") heading.
    public var infoKey: String {
        switch self {
        case .order:  return "info.mode.order"
        case .random: return "info.mode.random"
        case .mixed:  return "info.mode.mixed"
        }
    }

    /// The glyph used on the welcome screen, where the same choice is asked in
    /// children's language.
    public var symbolName: String {
        switch self {
        case .order:  return "leaf.fill"
        case .random: return "shuffle"
        case .mixed:  return "bolt.fill"
        }
    }

    // MARK: Per-topic variants

    public func titleKey(for topic: MathTopic) -> String {
        guard let override = topic.modeOverride else { return titleKey }
        switch self {
        case .order:  return override.orderTitleKey
        case .random: return override.randomTitleKey
        case .mixed:  return override.mixedTitleKey ?? titleKey
        }
    }

    /// Heading above the pop-out text ("Order" / "Parts" / "Type").
    public func infoHeaderKey(for topic: MathTopic) -> String {
        topic.modeOverride?.infoHeaderKey ?? "info.mode.header"
    }

    public func infoKey(for topic: MathTopic) -> String {
        guard let override = topic.modeOverride else { return infoKey }
        switch self {
        case .order:  return override.orderInfoKey
        case .random: return override.randomInfoKey
        case .mixed:  return override.mixedInfoKey ?? infoKey
        }
    }

    public static func from(rawValue: String?) -> PracticeMode {
        guard let rawValue, let mode = PracticeMode(rawValue: rawValue) else { return fallback }
        return mode
    }
}
