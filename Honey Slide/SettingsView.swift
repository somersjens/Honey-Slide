//
//  SettingsView.swift
//  Elephant Challenge: Math Memory
//
//  Settings sheet: sound, play goals, character selector and Premium status.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(GameSettings.characterKey) private var characterID = CharacterCatalog.freeCharacterID
    @AppStorage(GameSettings.gameSoundsEnabledKey) private var gameSounds = true
    @AppStorage(GameSettings.musicEnabledKey) private var music = true
    @ObservedObject private var premium = PremiumStore.shared
    @ObservedObject private var tracker = PlaytimeTracker.shared
    @ObservedObject private var language = LanguageManager.shared
    @State private var showPremium = false

    private var character: AnimalCharacter { CharacterCatalog.current(isPremium: premium.isPremium) }
    private var isPad: Bool { AppLayout.isPad }

    private let characterColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: isPad ? 24 : 16),
                    GridItem(.flexible(), spacing: isPad ? 24 : 16)
                ], alignment: .leading, spacing: isPad ? 24 : 16) {
                    VStack(spacing: isPad ? 24 : 16) {
                        soundCard
                        premiumCard
                    }
                    VStack(spacing: isPad ? 24 : 16) {
                        goalsCard
                        characterCard
                    }
                }
                .padding(AppLayout.landscapeGutter)
                .frame(maxWidth: AppLayout.landscapeContentWidth)
                .frame(maxWidth: .infinity)
            }
            .background(character.skyColor.ignoresSafeArea())
            .navigationTitle("settings.title")
#if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showPremium) {
            PremiumView()
                .premiumSheetPresentation()
        }
    }

    // MARK: Sound

    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.sound")
                .font(.headline)

            Toggle(isOn: Binding(
                get: { gameSounds },
                set: { newValue in
                    AppAudio.shared.toggleGameSounds()
                    AppAudio.shared.playSwitch(on: newValue)
                }
            )) {
                Label("settings.soundEffects", systemImage: "speaker.wave.2.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(character.color)

            Toggle(isOn: Binding(
                get: { music },
                set: { _ in AppAudio.shared.toggleMusic() }
            )) {
                Label("settings.music", systemImage: "music.note")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(character.color)

            Text("settings.soundInfo")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Play goals

    private var dailyGoal: Binding<Int> {
        Binding(get: { tracker.dailyGoalMinutes }, set: { tracker.setDailyGoal($0) })
    }

    private var goalsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("settings.playGoals")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("settings.dailyGoal")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach([5, 10, 15, 20], id: \.self) { minutes in
                        Button {
                            tracker.setDailyGoal(minutes)
                        } label: {
                            Text(verbatim: "\(minutes)")
                                .font(.subheadline.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(
                                    tracker.dailyGoalMinutes == minutes
                                        ? AnyShapeStyle(character.color)
                                        : AnyShapeStyle(.white),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .foregroundStyle(tracker.dailyGoalMinutes == minutes ? .white : character.deepColor)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(character.color.opacity(0.4), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                Stepper("settings.customMinutes \(tracker.dailyGoalMinutes)", value: dailyGoal, in: 1...120)
                    .font(.subheadline)
            }

            Text("settings.goalInfo")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Character selector

    private var characterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("settings.character")
                    .font(.headline)
                if !premium.isPremium {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: characterColumns, spacing: 12) {
                ForEach(CharacterCatalog.all) { animal in
                    characterButton(for: animal)
                }
            }

            Text("settings.characterInfo")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
    }

    private func characterButton(for animal: AnimalCharacter) -> some View {
        let isSelected = characterID == animal.id
        let isLocked = !CharacterUnlockStore.canUse(
            characterID: animal.id,
            isPremium: premium.isPremium
        )
        return Button {
            if isLocked {
                showPremium = true
            } else {
                characterID = animal.id
            }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(animal.color.opacity(0.22))
                        .frame(width: 52, height: 52)
                    CharacterPortrait(character: animal,
                                      side: 46,
                                      magnification: 1,
                                      usesThumbnail: true)
                        .opacity(isLocked ? 0.5 : 1)
                    if isLocked {
                        Image(systemName: "lock.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .background(.white, in: Circle())
                    }
                }
                .overlay(
                    Circle().stroke(isSelected ? animal.color : .clear, lineWidth: 3)
                )
                Text(animal.localizedName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                if isLocked, let cards = CharacterUnlockStore.requirement(for: animal.id) {
                    Text(verbatim: LNumber(cards))
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Premium

    @ViewBuilder
    private var premiumCard: some View {
        if premium.isPremium {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(.yellow)
                Text("settings.premiumUnlocked")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        } else {
            VStack(spacing: 10) {
                Button {
                    showPremium = true
                } label: {
                    Label("premium.unlock", systemImage: "crown.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(colors: [character.color, character.deepColor],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button("premium.restore") {
                    Task { await premium.restorePurchases() }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

#Preview {
    SettingsView()
}
