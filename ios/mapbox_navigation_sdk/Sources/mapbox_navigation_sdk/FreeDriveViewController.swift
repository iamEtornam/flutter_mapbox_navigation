//
//  FreeDriveViewController.swift
//  flutter_mapbox_navigation
//
//  Created by Emmanuel Oche on 5/25/23.
//

import UIKit
import Combine
import MapboxMaps
import MapboxNavigationCore
import MapboxNavigationUIKit

public class FreeDriveViewController : UIViewController {

    private let provider: MapboxNavigationProvider
    private let mapStyleUrlDay: String?
    private let zoom: Double
    private var navigationMapView: NavigationMapView!

    init(provider: MapboxNavigationProvider, mapStyleUrlDay: String?, zoom: Double) {
        self.provider = provider
        self.mapStyleUrlDay = mapStyleUrlDay
        self.zoom = zoom
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        setupNavigationMapView()

        // Free-drive (passive navigation): generate route progress without a set destination.
        provider.mapboxNavigation.tripSession().startFreeDrive()
    }

    private func setupNavigationMapView() {
        let navigation = provider.mapboxNavigation.navigation()
        navigationMapView = NavigationMapView(
            location: navigation.locationMatching.map(\.enhancedLocation).eraseToAnyPublisher(),
            routeProgress: navigation.routeProgress.map(\.?.routeProgress).eraseToAnyPublisher(),
            predictiveCacheManager: provider.predictiveCacheManager
        )
        navigationMapView.frame = view.bounds
        navigationMapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let styleUrl = mapStyleUrlDay ?? "mapbox://styles/mapbox/navigation-day-v1"
        if let uri = StyleURI(rawValue: styleUrl) {
            navigationMapView.mapView.mapboxMap.loadStyle(uri)
        }

        view.addSubview(navigationMapView)
    }
}
