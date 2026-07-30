import CoreGraphics

struct OrbMaterialFrameKey: Hashable, Sendable {
    let phase: String
    let pointSizeHundredths: Int
    let backingScaleHundredths: Int
    let darkAppearance: Bool
    let increasedContrast: Bool
    let frameCount: Int
    let renderVersion: Int
}

/// Process-local banks of fully composited orb frames. Banks are generated in
/// yielded MainActor slices: a cold phase displays one complete fallback frame
/// immediately, then installs its compositor track without blocking a turn.
@MainActor
final class OrbMaterialFrameStore {
    static let shared = OrbMaterialFrameStore()

    typealias FrameBuilder = @MainActor (Int) -> CGImage?

    private var banks: [OrbMaterialFrameKey: [CGImage]] = [:]
    private var accessOrder: [OrbMaterialFrameKey] = []
    private var inFlight: [
        OrbMaterialFrameKey: Task<[CGImage]?, Never>
    ] = [:]
    private let maximumBankCount = 4

    private init() {}

    func cachedFrames(
        for key: OrbMaterialFrameKey
    ) -> [CGImage]? {
        guard let cached = banks[key] else { return nil }
        markRecentlyUsed(key)
        return cached
    }

    func frames(
        for key: OrbMaterialFrameKey,
        frameCount: Int,
        buildFrame: @escaping FrameBuilder
    ) async -> [CGImage]? {
        if let cached = banks[key] {
            markRecentlyUsed(key)
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task: Task<[CGImage]?, Never> = Task { @MainActor in
            var rendered: [CGImage] = []
            rendered.reserveCapacity(frameCount)

            for index in 0..<frameCount {
                guard let frame = buildFrame(index) else {
                    return nil
                }
                rendered.append(frame)

                // Each ImageRenderer pass is small, but yielding after every
                // pass keeps input, speech, and HUD updates responsive.
                await Task.yield()
            }
            return rendered
        }
        inFlight[key] = task

        let rendered = await task.value
        inFlight[key] = nil
        guard let rendered, rendered.count == frameCount else {
            return nil
        }
        banks[key] = rendered
        markRecentlyUsed(key)
        evictLeastRecentlyUsedBanks()
        return rendered
    }

    var cachedBankCountForTesting: Int {
        banks.count
    }

    private func markRecentlyUsed(_ key: OrbMaterialFrameKey) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    private func evictLeastRecentlyUsedBanks() {
        while banks.count > maximumBankCount,
              let leastRecent = accessOrder.first
        {
            accessOrder.removeFirst()
            banks[leastRecent] = nil
        }
    }
}
