import CoreGraphics

enum DesignMetrics {
    static let collapsedSize = CGSize(width: 58, height: 34)
    static let activeSize = CGSize(width: 118, height: 44)
    static let expandedSize = CGSize(width: 388, height: 164)
    static let approvalSize = CGSize(width: 420, height: 236)
    static let screenTopInset: CGFloat = 7
    static let shadowHorizontalPadding: CGFloat = 48
    static let shadowTopPadding: CGFloat = 32
    static let expandedShadowTopPadding: CGFloat = 72
    static let shadowBottomPadding: CGFloat = 56
    static let animationResponse = 0.42
    static let animationDamping = 0.82

    static func windowSize(for surfaceSize: CGSize) -> CGSize {
        let topPadding = surfaceSize.height > activeSize.height
            ? expandedShadowTopPadding
            : shadowTopPadding
        return CGSize(
            width: surfaceSize.width + shadowHorizontalPadding * 2,
            height: surfaceSize.height
                + topPadding
                + shadowBottomPadding
        )
    }
}
