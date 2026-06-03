import Foundation
import MapboxNavigationCore

/// Shared holder for the single ``MapboxNavigationProvider`` instance.
///
/// Navigation SDK v3 requires exactly one provider to be alive for the lifetime
/// of the SDK — creating multiple concurrent instances triggers a runtime error.
/// Both the full-screen flow (the plugin) and every embedded view extend
/// `NavigationFactory`, so the provider must be shared here rather than created
/// per-instance.
///
/// `CoreConfig.locationSource` (live vs. simulated) is fixed when the provider is
/// created. Because the provider is created lazily on first use and then reused,
/// the `simulateRoute` flag is honored from the **first** navigation of the app
/// session; later changes to it within the same session have no effect.
@MainActor
final class NavigationProviderHolder {
    static let shared = NavigationProviderHolder()

    private var _provider: MapboxNavigationProvider?
    private var _simulates = false

    private init() {}

    /// Returns the shared provider, creating it on first use with the given
    /// simulation preference.
    func provider(simulate: Bool) -> MapboxNavigationProvider {
        if let provider = _provider {
            return provider
        }
        let config = CoreConfig(
            locationSource: simulate ? .simulation(initialLocation: nil) : .live
        )
        let provider = MapboxNavigationProvider(coreConfig: config)
        _provider = provider
        _simulates = simulate
        return provider
    }

    /// The provider if it has already been created, otherwise `nil`.
    var providerIfCreated: MapboxNavigationProvider? { _provider }

    /// Whether the active provider was configured for simulated locations.
    var simulates: Bool { _simulates }
}
