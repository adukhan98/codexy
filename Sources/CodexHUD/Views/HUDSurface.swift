import SwiftUI

struct HUDGlassSurface<Content: View>: View {
    let phase: HUDPhase
    let cornerRadius: CGFloat
    let interactive: Bool
    let systemEffectsEnabled: Bool
    let reduceTransparencyOverride: Bool?
    let increasedContrastOverride: Bool?
    @ViewBuilder let content: () -> Content

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(
        phase: HUDPhase,
        cornerRadius: CGFloat,
        interactive: Bool,
        systemEffectsEnabled: Bool,
        reduceTransparencyOverride: Bool? = nil,
        increasedContrastOverride: Bool? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.phase = phase
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        self.systemEffectsEnabled = systemEffectsEnabled
        self.reduceTransparencyOverride = reduceTransparencyOverride
        self.increasedContrastOverride = increasedContrastOverride
        self.content = content
    }

    private var effectiveReduceTransparency: Bool {
        reduceTransparencyOverride ?? reduceTransparency
    }

    private var effectiveIncreasedContrast: Bool {
        increasedContrastOverride
            ?? (colorSchemeContrast == .increased)
    }

    private var surfaceShape: AnyShape {
        if phase.isExpanded {
            return AnyShape(
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
        }
        return AnyShape(Capsule(style: .circular))
    }

    var body: some View {
        glassContent
            .overlay {
                surfaceShape
                    .stroke(
                        HUDVisualStyle.surfaceStroke(
                            colorScheme: colorScheme,
                            increasedContrast: effectiveIncreasedContrast
                        ),
                        lineWidth: effectiveIncreasedContrast ? 1.5 : 0.75
                    )
                    .overlay {
                        surfaceShape
                            .stroke(
                                HUDVisualStyle.innerStroke(
                                    colorScheme: colorScheme
                                ),
                                lineWidth: 0.5
                            )
                            .padding(1)
                    }
                    .padding(1)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: HUDVisualStyle.shadowColor(colorScheme: colorScheme),
                radius: phase.isExpanded ? 22 : 13,
                y: phase.isExpanded ? 10 : 6
            )
    }

    @ViewBuilder
    private var glassContent: some View {
        if #available(macOS 26.0, *),
           !effectiveReduceTransparency,
           systemEffectsEnabled
        {
            GlassEffectContainer(spacing: 10) {
                content()
                    .glassEffect(
                        .regular
                            .tint(HUDVisualStyle.glassTint(for: phase))
                            .interactive(interactive),
                        in: surfaceShape
                    )
                    .glassEffectID("codex-hud-surface", in: glassNamespace)
            }
        } else {
            content()
                .background {
                    surfaceShape
                        .fill(
                            HUDVisualStyle.surfaceFill(
                                colorScheme: colorScheme,
                                reduceTransparency:
                                    effectiveReduceTransparency
                                    || !systemEffectsEnabled
                            )
                        )
                        .overlay {
                            if !effectiveReduceTransparency,
                               systemEffectsEnabled
                            {
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(
                                            colorScheme == .dark ? 0.08 : 0.30
                                        ),
                                        HUDVisualStyle
                                            .glassTint(for: phase)
                                            .opacity(0.50),
                                        Color.clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                .clipShape(
                                    surfaceShape
                                )
                            }
                        }
                }
        }
    }
}

struct HUDToggleSurface<Content: View>: View {
    let action: () -> Void
    let accessibilityLabel: String
    let accessibilityHint: String
    let animationsEnabled: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @GestureState private var isPressed = false

    var body: some View {
        content()
            .scaleEffect(
                animationsEnabled && !reduceMotion
                    ? (isPressed ? 0.972 : (isHovered ? 1.018 : 1))
                    : 1
            )
            .brightness(isHovered ? 0.025 : 0)
            .opacity(isPressed ? 0.92 : 1)
            .animation(
                animationsEnabled && !reduceMotion
                    ? .spring(response: 0.18, dampingFraction: 0.76)
                    : nil,
                value: isHovered
            )
            .animation(
                animationsEnabled && !reduceMotion
                    ? .spring(response: 0.14, dampingFraction: 0.74)
                    : nil,
                value: isPressed
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressed) { _, pressed, _ in
                        pressed = true
                    }
            )
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction(.default, action)
        .accessibilityAction(
            named: Text("Toggle Voice Console"),
            action
        )
    }
}

struct HUDActionButton: View {
    let title: String
    let isPrimary: Bool
    let tint: Color
    let systemEffectsEnabled: Bool
    let keyboardFocusEnabled: Bool
    let action: () -> Void
    @ScaledMetric(relativeTo: .caption) private var fallbackFontSize = 11.5
    @ScaledMetric(relativeTo: .body) private var fallbackHeight = 27.0
    @ScaledMetric(relativeTo: .body) private var fallbackHorizontalPadding = 12.0

    var body: some View {
        if !systemEffectsEnabled {
            Button(action: action) {
                Text(title)
                    .font(
                        .system(
                            size: min(fallbackFontSize, 14.5),
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(
                        isPrimary
                            ? Color.black.opacity(0.88)
                            : Color.primary
                    )
                    .lineLimit(1)
                    .padding(
                        .horizontal,
                        min(fallbackHorizontalPadding, 14)
                    )
                    .frame(height: min(fallbackHeight, 32))
                    .background {
                        RoundedRectangle(
                            cornerRadius: 12,
                            style: .continuous
                        )
                            .fill(
                                isPrimary
                                    ? AnyShapeStyle(tint.opacity(0.92))
                                    : AnyShapeStyle(Color.primary.opacity(0.08))
                            )
                    }
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 12,
                            style: .continuous
                        )
                            .strokeBorder(
                                isPrimary
                                    ? Color.white.opacity(0.24)
                                    : Color.primary.opacity(0.14),
                                lineWidth: 0.75
                            )
                    }
            }
            .buttonStyle(.plain)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .focusable(keyboardFocusEnabled)
        } else if #available(macOS 26.0, *) {
            if isPrimary {
                Button(action: action) {
                    Text(title)
                        .foregroundStyle(Color.black.opacity(0.88))
                }
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                    .tint(tint)
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .focusable(keyboardFocusEnabled)
            } else {
                Button(title, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .focusable(keyboardFocusEnabled)
            }
        } else {
            if isPrimary {
                Button(action: action) {
                    Text(title)
                        .foregroundStyle(Color.black.opacity(0.88))
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(tint)
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .focusable(keyboardFocusEnabled)
            } else {
                Button(title, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .lineLimit(1)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .focusable(keyboardFocusEnabled)
            }
        }
    }
}
