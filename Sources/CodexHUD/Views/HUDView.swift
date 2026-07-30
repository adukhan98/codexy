import SwiftUI

private enum HUDActionFocus: Hashable {
    case primary
    case secondary
}

private struct HUDOrb: View {
    let phase: HUDPhase
    let fallbackAudioLevel: Double
    let liveAudioLevel: OrbAudioLevelState?
    let animationsEnabled: Bool
    let size: CGFloat
    let increasedContrastOverride: Bool?
    let productionMotionTimeOverride: TimeInterval?

    @ViewBuilder
    var body: some View {
        if let liveAudioLevel {
            LiveHUDOrb(
                phase: phase,
                audioLevel: liveAudioLevel,
                animationsEnabled: animationsEnabled,
                size: size,
                increasedContrastOverride: increasedContrastOverride,
                productionMotionTimeOverride:
                    productionMotionTimeOverride
            )
        } else {
            OrbView(
                phase: phase,
                audioLevel: fallbackAudioLevel,
                animationsEnabled: animationsEnabled,
                size: size,
                increasedContrastOverride: increasedContrastOverride,
                productionMotionTimeOverride:
                    productionMotionTimeOverride
            )
        }
    }
}

private struct LiveHUDOrb: View {
    let phase: HUDPhase
    @Bindable var audioLevel: OrbAudioLevelState
    let animationsEnabled: Bool
    let size: CGFloat
    let increasedContrastOverride: Bool?
    let productionMotionTimeOverride: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let level = animationsEnabled
            && !reduceMotion
            && (phase == .listening || phase == .speaking)
            ? audioLevel.level
            : 0
        OrbView(
            phase: phase,
            audioLevel: level,
            animationsEnabled: animationsEnabled,
            size: size,
            increasedContrastOverride: increasedContrastOverride,
            productionMotionTimeOverride: productionMotionTimeOverride
        )
    }
}

struct HUDView: View {
    let phase: HUDPhase
    let content: HUDContent
    let audioLevel: Double
    let liveAudioLevel: OrbAudioLevelState?
    let animationsEnabled: Bool
    let onToggleSession: () -> Void
    let onPrimaryAction: () -> Void
    let onSecondaryAction: () -> Void
    let keyboardFocusRequest: Int
    let onExitKeyboardFocus: () -> Void
    let reduceTransparencyOverride: Bool?
    let increasedContrastOverride: Bool?
    let keyboardFocusEnabled: Bool
    let productionMotionTimeOverride: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @Namespace private var orbGeometry
    @FocusState private var focusedAction: HUDActionFocus?
    @ScaledMetric(relativeTo: .caption2) private var compactIconSize = 8.0
    @ScaledMetric(relativeTo: .caption2) private var compactTitleSize = 10.5
    @ScaledMetric(relativeTo: .caption2) private var eyebrowSize = 9.5
    @ScaledMetric(relativeTo: .headline) private var expandedTitleSize = 15.0
    @ScaledMetric(relativeTo: .caption) private var detailSize = 11.5
    @ScaledMetric(relativeTo: .caption) private var footerSize = 10.5
    @ScaledMetric(relativeTo: .caption2) private var footerIconSize = 9.0
    @ScaledMetric(relativeTo: .body) private var expandedStatusIconSize = 13.0

    init(
        phase: HUDPhase,
        content: HUDContent,
        audioLevel: Double,
        liveAudioLevel: OrbAudioLevelState? = nil,
        animationsEnabled: Bool = true,
        onToggleSession: @escaping () -> Void,
        onPrimaryAction: @escaping () -> Void = {},
        onSecondaryAction: @escaping () -> Void = {},
        keyboardFocusRequest: Int = 0,
        onExitKeyboardFocus: @escaping () -> Void = {},
        reduceTransparencyOverride: Bool? = nil,
        increasedContrastOverride: Bool? = nil,
        keyboardFocusEnabled: Bool = true,
        productionMotionTimeOverride: TimeInterval? = nil
    ) {
        self.phase = phase
        self.content = content
        self.audioLevel = max(0, min(audioLevel, 1))
        self.liveAudioLevel = liveAudioLevel
        self.animationsEnabled = animationsEnabled
        self.onToggleSession = onToggleSession
        self.onPrimaryAction = onPrimaryAction
        self.onSecondaryAction = onSecondaryAction
        self.keyboardFocusRequest = keyboardFocusRequest
        self.onExitKeyboardFocus = onExitKeyboardFocus
        self.reduceTransparencyOverride = reduceTransparencyOverride
        self.increasedContrastOverride = increasedContrastOverride
        self.keyboardFocusEnabled = keyboardFocusEnabled
        self.productionMotionTimeOverride = productionMotionTimeOverride
    }

    private var phaseAnimation: Animation? {
        guard animationsEnabled, !reduceMotion else {
            return nil
        }

        return .spring(
            response: DesignMetrics.animationResponse,
            dampingFraction: DesignMetrics.animationDamping,
            blendDuration: 0.06
        )
    }

    private var actionSystemEffectsEnabled: Bool {
        animationsEnabled
            && !(reduceTransparencyOverride ?? reduceTransparency)
    }

    private var surfaceSystemEffectsEnabled: Bool {
        guard animationsEnabled else { return false }
        switch phase {
        case .connecting, .listening, .thinking, .speaking:
            // Liquid Glass installs its own display-link updates. The active
            // orb already animates in Core Animation, so the custom material
            // preserves the approved appearance without a second render loop.
            return false
        case .dormant, .approval, .result, .recoverableError:
            return true
        }
    }

    var body: some View {
        Group {
            if phase.isExpanded {
                expandedCard
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    )
            } else {
                compactControl
                    .transition(
                        .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                    )
            }
        }
        .frame(
            width: phase.hudVisualSize.width,
            height: phase.hudVisualSize.height,
            alignment: .top
        )
        .padding(.horizontal, DesignMetrics.shadowHorizontalPadding)
        .padding(.top, phase.hudShadowTopPadding)
        .padding(.bottom, phase.hudShadowBottomPadding)
        .frame(
            width: phase.hudWindowSize.width,
            height: phase.hudWindowSize.height,
            alignment: .top
        )
        .animation(phaseAnimation, value: phase)
        .transaction { transaction in
            if !animationsEnabled || reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .onChange(of: keyboardFocusRequest) {
            guard phase.isExpanded else { return }
            focusedAction = secondaryActionTitle == nil
                ? .primary
                : .secondary
        }
        .onChange(of: phase) {
            if !phase.isExpanded {
                focusedAction = nil
            }
        }
        .onExitCommand {
            focusedAction = nil
            onExitKeyboardFocus()
        }
    }

    private var compactControl: some View {
        let cornerRadius = phase == .dormant
            ? HUDVisualStyle.compactCornerRadius
            : HUDVisualStyle.activeCornerRadius

        return HUDToggleSurface(
            action: onToggleSession,
            accessibilityLabel: HUDVisualStyle.accessibilityDescription(for: phase),
            accessibilityHint: compactControlAccessibilityHint,
            animationsEnabled: animationsEnabled
        ) {
            HUDGlassSurface(
                phase: phase,
                cornerRadius: cornerRadius,
                interactive: true,
                systemEffectsEnabled: surfaceSystemEffectsEnabled,
                reduceTransparencyOverride: reduceTransparencyOverride,
                increasedContrastOverride: increasedContrastOverride
            ) {
                compactContent
                    .frame(
                        width: phase.hudVisualSize.width,
                        height: phase.hudVisualSize.height
                    )
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: cornerRadius,
                            style: .continuous
                        )
                    )
            }
        }
    }

    @ViewBuilder
    private var compactContent: some View {
        if phase == .dormant {
            ZStack {
                orb(size: 24)

                Image(systemName: "mic.slash.fill")
                    .font(
                        .system(
                            size: min(compactIconSize, 9),
                            weight: .black
                        )
                    )
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .shadow(color: Color.black.opacity(0.72), radius: 1, y: 0.5)
                    .accessibilityHidden(true)
            }
            .matchedGeometryEffect(id: "voice-orb", in: orbGeometry)
        } else {
            HStack(spacing: 5) {
                orb(size: 24)
                .matchedGeometryEffect(id: "voice-orb", in: orbGeometry)

                HStack(spacing: 3) {
                    Image(systemName: HUDVisualStyle.microphoneSymbol(for: phase))
                        .font(.system(size: compactIconSize, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(
                            HUDVisualStyle.microphoneAccent(for: phase)
                        )
                        .accessibilityHidden(true)

                    Text(HUDVisualStyle.statusTitle(for: phase))
                        .font(
                            .system(
                                size: compactTitleSize,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 7)
        }
    }

    private var expandedCard: some View {
        HUDGlassSurface(
            phase: phase,
            cornerRadius: HUDVisualStyle.expandedCornerRadius,
            interactive: true,
            systemEffectsEnabled: surfaceSystemEffectsEnabled,
            reduceTransparencyOverride: reduceTransparencyOverride,
            increasedContrastOverride: increasedContrastOverride
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    orb(size: 38)
                    .matchedGeometryEffect(id: "voice-orb", in: orbGeometry)
                    .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 4) {
                        if let eyebrow = content.eyebrow, !eyebrow.isEmpty {
                            Text(eyebrow.uppercased())
                                .font(
                                    .system(
                                        size: eyebrowSize,
                                        weight: .bold,
                                        design: .rounded
                                    )
                                )
                                .tracking(0.8)
                                .foregroundStyle(HUDVisualStyle.accent(for: phase))
                                .lineLimit(1)
                        }

                        Text(content.title)
                            .font(
                                .system(
                                    size: expandedTitleSize,
                                    weight: .semibold,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        expandedDetail
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: HUDVisualStyle.statusSymbol(for: phase))
                        .font(
                            .system(
                                size: expandedStatusIconSize,
                                weight: .semibold
                            )
                        )
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(HUDVisualStyle.accent(for: phase))
                        .accessibilityHidden(true)
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(
                            systemName: HUDVisualStyle
                                .microphoneSymbol(for: phase)
                        )
                        .font(.system(size: footerIconSize, weight: .bold))
                        .foregroundStyle(
                            HUDVisualStyle.microphoneAccent(for: phase)
                        )

                        Text(HUDVisualStyle.footerStatus(for: phase))
                            .font(
                                .system(
                                    size: footerSize,
                                    weight: .medium,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        HUDVisualStyle.footerAccessibilityDescription(
                            for: phase
                        )
                    )

                    Spacer(minLength: 8)

                    if let secondaryActionTitle {
                        HUDActionButton(
                            title: secondaryActionTitle,
                            isPrimary: false,
                            tint: HUDVisualStyle.accent(for: phase),
                            systemEffectsEnabled: actionSystemEffectsEnabled,
                            keyboardFocusEnabled: keyboardFocusEnabled,
                            action: onSecondaryAction
                        )
                        .focused($focusedAction, equals: .secondary)
                    }

                    if let primaryActionTitle {
                        HUDActionButton(
                            title: primaryActionTitle,
                            isPrimary: true,
                            tint: HUDVisualStyle.accent(for: phase),
                            systemEffectsEnabled: actionSystemEffectsEnabled,
                            keyboardFocusEnabled: keyboardFocusEnabled,
                            action: onPrimaryAction
                        )
                        .focused($focusedAction, equals: .primary)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(
                width: phase.hudVisualSize.width,
                height: phase.hudVisualSize.height,
                alignment: .topLeading
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: HUDVisualStyle.expandedCornerRadius,
                    style: .continuous
                )
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex voice HUD")
    }

    private func orb(size: CGFloat) -> some View {
        HUDOrb(
            phase: phase,
            fallbackAudioLevel: audioLevel,
            liveAudioLevel: liveAudioLevel,
            animationsEnabled: animationsEnabled,
            size: size,
            increasedContrastOverride: increasedContrastOverride,
            productionMotionTimeOverride: productionMotionTimeOverride
        )
    }

    @ViewBuilder
    private var expandedDetail: some View {
        if let detail = content.detail, !detail.isEmpty {
            if showsOverflowCue(for: detail) {
                HStack(alignment: .top, spacing: 7) {
                    ScrollView(.vertical) {
                        detailText(detail)
                            .padding(.bottom, 12)
                    }
                    .scrollIndicators(.visible)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.76),
                                .init(
                                    color: .white.opacity(0.72),
                                    location: 0.90
                                ),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }

                    Divider()
                        .frame(height: max(detailViewportHeight - 6, 42))
                        .opacity(0.52)

                    VStack(spacing: 2) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))

                        Text("Scroll")
                            .font(
                                .system(
                                    size: 8,
                                    weight: .bold,
                                    design: .rounded
                                )
                            )
                            .tracking(0)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(.secondary)
                    .frame(
                        width: 36,
                        height: max(detailViewportHeight - 6, 42)
                    )
                    .accessibilityHidden(true)
                }
                .frame(height: detailViewportHeight, alignment: .top)
                .layoutPriority(2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Action details. \(detail)")
                .accessibilityHint(
                    "Scroll to review the complete context before choosing an action."
                )
            } else {
                detailText(detail)
                    .frame(height: detailViewportHeight, alignment: .top)
                    .clipped()
                    .layoutPriority(2)
                    .accessibilityLabel("Action details. \(detail)")
            }
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(
                .system(
                    size: min(detailSize, 15),
                    weight: .regular,
                    design: phase == .approval ? .monospaced : .default
                )
            )
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func showsOverflowCue(for detail: String) -> Bool {
        detail.count > 150
            || detail.filter { $0.isNewline }.count > 1
    }

    private var detailViewportHeight: CGFloat {
        phase == .approval ? 120 : 48
    }

    private var primaryActionTitle: String? {
        content.primaryActionTitle ?? HUDVisualStyle.defaultPrimaryAction(for: phase)
    }

    private var secondaryActionTitle: String? {
        content.secondaryActionTitle ?? HUDVisualStyle.defaultSecondaryAction(for: phase)
    }

    private var compactControlAccessibilityHint: String {
        switch phase {
        case .dormant:
            "Starts the Voice Console session."
        case .connecting, .listening, .thinking, .speaking:
            "Stops the Voice Console session."
        case .approval, .result, .recoverableError:
            ""
        }
    }
}
