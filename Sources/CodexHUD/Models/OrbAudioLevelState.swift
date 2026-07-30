import Observation

/// A narrowly observed visual signal. Keeping metering outside AppModel's HUD
/// projection prevents audio-rate changes from invalidating glass, labels,
/// controls, matched geometry, and the panel layout.
@MainActor
@Observable
final class OrbAudioLevelState {
    var level: Double = 0
}
