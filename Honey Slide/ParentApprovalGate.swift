//
//  ParentApprovalGate.swift
//  Jumping Fox
//
//  A lightweight, local parental gate shown before a StoreKit purchase.
//

import SwiftUI

struct ParentApprovalGate: View {
    let accent: Color
    let deepColor: Color
    let onApproved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = LanguageManager.shared
    @State private var challenge = ParentChallenge.make()
    @State private var phase: Phase = .hold
    @State private var failures = 0
    @State private var holdProgress = 0
    @State private var tapCount = 0
    @State private var heldShape: GateShape?
    @State private var activeTouchShape: GateShape?
    @State private var ignoresCompletedHoldRelease = false
    @State private var isTransitioningToTap = false
    @State private var isCompletingTap = false
    @State private var holdTask: Task<Void, Never>?
    @State private var isShowingSuccess = false
    @State private var isShieldPulsing = false

    private enum Phase { case hold, tap }

    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.28), .white, accent.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView {
                    Group {
                        // iPad presents this sheet as a centered form sheet
                        // rather than edge-to-edge, so the side-by-side split
                        // that works in an iPhone-width sheet leaves the
                        // description column too narrow and truncates its
                        // text. Stacking it above the card instead gives both
                        // the full sheet width, which there is plenty of.
                        if AppLayout.isPad {
                            VStack(spacing: 24) {
                                header
                                if failures > 0 {
                                    failureIndicator
                                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                }
                                approvalCard
                                    .frame(maxWidth: 620)
                            }
                        } else {
                            HStack(alignment: .center, spacing: 28) {
                                VStack(spacing: 18) {
                                    header
                                    if failures > 0 {
                                        failureIndicator
                                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                    }
                                }
                                .frame(width: 220)

                                approvalCard
                                    .frame(maxWidth: 620)
                            }
                        }
                    }
                    .padding(.horizontal, AppLayout.landscapeGutter * 2)
                    .padding(.vertical, AppLayout.isPad ? 36 : 20)
                    .frame(maxWidth: AppLayout.landscapeContentWidth)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            if isShowingSuccess {
                successOverlay
            }
        }
        .onDisappear { holdTask?.cancel() }
        .onAppear {
            holdProgress = challenge.holdSeconds
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
                isShieldPulsing = true
            }
        }
        .environment(\.locale, language.locale)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(deepColor)
                .scaleEffect(isShieldPulsing ? 1.06 : 0.96)
                .opacity(isShieldPulsing ? 1 : 0.84)
            Text("parentGate.title")
                .font(.system(.title2, design: .rounded, weight: .heavy))
                .foregroundStyle(deepColor)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(maxWidth: .infinity)
            Text("parentGate.subtitle")
                .font(.subheadline)
                .foregroundStyle(deepColor.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity)
        }
    }

    private var approvalCard: some View {
        VStack(spacing: 16) {
            instructionCard

            Divider()
                .overlay(accent.opacity(0.20))

            shapeBoard

            Divider()
                .overlay(accent.opacity(0.20))

            progressCard
        }
        .padding(18)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(accent.opacity(0.22), lineWidth: 1.5)
        }
    }

    private var instructionCard: some View {
        Text(instruction)
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(deepColor)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.80)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 62)
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.42), value: instruction)
    }

    private var shapeBoard: some View {
        HStack(spacing: 12) {
            ForEach(challenge.shapes, id: \.self) { shape in
                shapeButton(shape)
            }
        }
        .frame(maxWidth: .infinity, minHeight: AppLayout.isPad ? 140 : 104)
    }

    private func shapeButton(_ shape: GateShape) -> some View {
        let isHeld = heldShape == shape
        return shape.symbol
            .fill(accent)
            .frame(width: AppLayout.isPad ? 76 : 62,
                   height: AppLayout.isPad ? 76 : 62)
            .shadow(color: deepColor.opacity(isHeld ? 0.32 : 0.12), radius: isHeld ? 14 : 5, y: 4)
            .scaleEffect(isHeld ? 1.13 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.62), value: isHeld)
            .frame(width: AppLayout.isPad ? 84 : 72,
                   height: AppLayout.isPad ? 100 : 78)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in touchBegan(on: shape) }
                .onEnded { _ in touchEnded(on: shape) })
    }

    private var progressCard: some View {
        Text(progressTitle)
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(deepColor)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 1)
        .contentTransition(.numericText())
        .animation(
            .easeInOut(duration: 0.25),
            value: phase == .hold ? holdProgress : remainingTaps
        )
    }

    private var failureIndicator: some View {
        VStack(spacing: 8) {
            Text(attemptsTitle)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(deepColor.opacity(0.68))
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    Image(systemName: index < failures ? "xmark.circle.fill" : "circle")
                        .foregroundStyle(index < failures ? .red : deepColor.opacity(0.25))
                }
            }
        }
    }

    private var successOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 68))
                .foregroundStyle(.green)
                .scaleEffect(isShowingSuccess ? 1 : 0.65)
                .animation(.spring(response: 0.38, dampingFraction: 0.58), value: isShowingSuccess)
            Text("parentGate.approved")
                .font(.system(.title3, design: .rounded, weight: .heavy))
                .foregroundStyle(deepColor)
        }
        .padding(30)
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: deepColor.opacity(0.25), radius: 20, y: 10)
        .transition(.scale.combined(with: .opacity))
    }

    private var instruction: String {
        phase == .hold
            ? L("parentGate.holdInstruction \(challenge.holdShape.localizedName) \(holdProgress)")
            : L("parentGate.tapInstruction \(remainingTaps) \(challenge.tapShape.localizedName)")
    }

    private var progressTitle: String {
        phase == .hold
            ? L("parentGate.holdProgress \(holdProgress)")
            : L("parentGate.tapProgress \(remainingTaps) \(challenge.tapCount)")
    }

    private var remainingTaps: Int {
        max(0, challenge.tapCount - tapCount)
    }

    private var attemptsTitle: String {
        L("parentGate.attempts \(failures) \(3)")
    }

    private func touchBegan(on shape: GateShape) {
        guard activeTouchShape == nil,
              !isShowingSuccess,
              !isTransitioningToTap,
              !isCompletingTap else { return }
        activeTouchShape = shape
        guard phase == .hold else { return }
        guard shape == challenge.holdShape else {
            registerFailure()
            return
        }
        heldShape = shape
        holdProgress = challenge.holdSeconds
        startHoldTimer()
    }

    private func startHoldTimer() {
        let seconds = challenge.holdSeconds
        let firstTickLead = 0.5
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                let components = start.duration(to: .now).components
                let elapsed = Double(components.seconds)
                    + Double(components.attoseconds) / 1_000_000_000_000_000_000
                let remaining = max(
                    0,
                    Int(ceil(Double(seconds) - elapsed - firstTickLead))
                )
                holdProgress = remaining
                if remaining == 0 {
                    heldShape = nil
                    ignoresCompletedHoldRelease = true
                    isTransitioningToTap = true
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                    } catch {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.42)) {
                        phase = .tap
                        isTransitioningToTap = false
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func touchTapped(_ shape: GateShape) {
        guard phase == .tap, !isShowingSuccess, !isCompletingTap else { return }
        guard shape == challenge.tapShape else {
            registerFailure()
            return
        }
        tapCount += 1
        if tapCount == challenge.tapCount {
            isCompletingTap = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(320))
                guard isCompletingTap else { return }
                complete()
            }
        }
        if tapCount > challenge.tapCount { registerFailure() }
    }

    private func registerFailure() {
        holdTask?.cancel()
        heldShape = nil
        activeTouchShape = nil
        ignoresCompletedHoldRelease = false
        isTransitioningToTap = false
        isCompletingTap = false
        failures += 1
        guard failures < 3 else {
            dismiss()
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            challenge = .make()
            phase = .hold
            holdProgress = challenge.holdSeconds
            tapCount = 0
        }
    }

    private func complete() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isShowingSuccess = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            onApproved()
        }
    }
}

private extension ParentApprovalGate {
    // Taps are recognized at gesture end so a completed hold can move cleanly
    // into the second step without counting its release as a tap.
    func touchEnded(on shape: GateShape) {
        guard activeTouchShape == shape else { return }
        activeTouchShape = nil
        if ignoresCompletedHoldRelease {
            ignoresCompletedHoldRelease = false
            return
        }
        if phase == .tap {
            touchTapped(shape)
            return
        }
        guard shape == challenge.holdShape, heldShape == shape else { return }
        holdTask?.cancel()
        heldShape = nil
        registerFailure()
    }
}

private struct ParentChallenge {
    let holdShape: GateShape
    let tapShape: GateShape
    let holdSeconds: Int
    let tapCount: Int
    let shapes: [GateShape]

    static func make() -> ParentChallenge {
        let selected = Array(GateShape.allCases.shuffled().prefix(3))
        return ParentChallenge(
            holdShape: selected[0],
            tapShape: selected[1],
            holdSeconds: Int.random(in: 2...4),
            tapCount: Int.random(in: 2...4),
            shapes: selected.shuffled()
        )
    }
}

private enum GateShape: CaseIterable, Hashable {
    case circle, triangle, square, star, heart, hexagon, diamond, plus

    var localizedName: String {
        L(key: "parentGate.shape.\(key)")
    }

    private var key: String {
        switch self {
        case .circle: "circle"; case .triangle: "triangle"; case .square: "square"; case .star: "star"
        case .heart: "heart"; case .hexagon: "hexagon"; case .diamond: "diamond"; case .plus: "plus"
        }
    }

    var symbol: AnyShape {
        switch self {
        case .circle: AnyShape(Circle())
        case .triangle: AnyShape(Triangle())
        case .square: AnyShape(Rectangle())
        case .star: AnyShape(Star(corners: 5, innerRadius: 0.45))
        case .heart: AnyShape(Heart())
        case .hexagon: AnyShape(Hexagon())
        case .diamond: AnyShape(Diamond())
        case .plus: AnyShape(Plus())
        }
    }
}

private struct Triangle: Shape { func path(in rect: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: rect.midX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.closeSubpath() } } }
private struct Diamond: Shape { func path(in rect: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: rect.midX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); p.closeSubpath() } } }
private struct Hexagon: Shape { func path(in rect: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: rect.width * 0.5, y: 0)); p.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.25)); p.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.75)); p.addLine(to: CGPoint(x: rect.width * 0.5, y: rect.height)); p.addLine(to: CGPoint(x: 0, y: rect.height * 0.75)); p.addLine(to: CGPoint(x: 0, y: rect.height * 0.25)); p.closeSubpath() } } }
private struct Plus: Shape { func path(in rect: CGRect) -> Path { let w = rect.width * 0.31; return Path { p in p.addRoundedRect(in: CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: rect.height), cornerSize: CGSize(width: w / 3, height: w / 3)); p.addRoundedRect(in: CGRect(x: rect.minX, y: rect.midY - w / 2, width: rect.width, height: w), cornerSize: CGSize(width: w / 3, height: w / 3)) } } }
private struct Star: Shape { let corners: Int; let innerRadius: CGFloat; func path(in rect: CGRect) -> Path { let center = CGPoint(x: rect.midX, y: rect.midY); let outer = min(rect.width, rect.height) / 2; var p = Path(); for i in 0..<(corners * 2) { let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(corners); let radius = i.isMultiple(of: 2) ? outer : outer * innerRadius; let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius); i == 0 ? p.move(to: point) : p.addLine(to: point) }; p.closeSubpath(); return p } }
private struct Heart: Shape { func path(in rect: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: rect.midX, y: rect.maxY)); p.addCurve(to: CGPoint(x: rect.minX, y: rect.height * 0.32), control1: CGPoint(x: rect.width * 0.18, y: rect.height * 0.74), control2: CGPoint(x: rect.minX, y: rect.height * 0.55)); p.addCurve(to: CGPoint(x: rect.midX, y: rect.height * 0.18), control1: CGPoint(x: rect.minX, y: 0), control2: CGPoint(x: rect.width * 0.38, y: 0)); p.addCurve(to: CGPoint(x: rect.maxX, y: rect.height * 0.32), control1: CGPoint(x: rect.width * 0.62, y: 0), control2: CGPoint(x: rect.maxX, y: 0)); p.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control1: CGPoint(x: rect.maxX, y: rect.height * 0.55), control2: CGPoint(x: rect.width * 0.82, y: rect.height * 0.74)); p.closeSubpath(); return p } }
