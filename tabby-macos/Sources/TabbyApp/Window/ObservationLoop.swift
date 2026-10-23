#if canImport(AppKit)
import Foundation
import Observation

/// Bridges `@Observable` models to AppKit: `track` reads the properties a view depends on;
/// when any of them changes, `apply` runs (outside tracking, so it may freely mutate
/// models) and tracking starts again. The loop stops when its owner releases it.
@MainActor
final class ObservationLoop {
    private let track: @MainActor () -> Void
    private let apply: @MainActor () -> Void

    init(track: @escaping @MainActor () -> Void, apply: @escaping @MainActor () -> Void) {
        self.track = track
        self.apply = apply
        apply()
        observe()
    }

    private func observe() {
        withObservationTracking {
            track()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.apply()
                    self.observe()
                }
            }
        }
    }
}
#endif
