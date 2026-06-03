import Flutter
import UIKit
import Combine
import CoreLocation
import MapboxMaps
import MapboxDirections
import MapboxNavigationCore
import MapboxNavigationUIKit

public class FlutterMapboxNavigationView : NavigationFactory, FlutterPlatformView
{
    let frame: CGRect
    let viewId: Int64

    let messenger: FlutterBinaryMessenger
    let channel: FlutterMethodChannel
    let eventChannel: FlutterEventChannel

    var navigationMapView: NavigationMapView!
    var arguments: NSDictionary?

    var navigationRoutes: NavigationRoutes?

    var _mapInitialized = false;
    var locationManager = CLLocationManager()

    init(messenger: FlutterBinaryMessenger, frame: CGRect, viewId: Int64, args: Any?)
    {
        self.frame = frame
        self.viewId = viewId
        self.arguments = args as! NSDictionary?

        self.messenger = messenger
        self.channel = FlutterMethodChannel(name: "flutter_mapbox_navigation/\(viewId)", binaryMessenger: messenger)
        self.eventChannel = FlutterEventChannel(name: "flutter_mapbox_navigation/\(viewId)/events", binaryMessenger: messenger)

        super.init()

        self.eventChannel.setStreamHandler(self)

        self.channel.setMethodCallHandler { [weak self](call, result) in

            guard let strongSelf = self else { return }

            let arguments = call.arguments as? NSDictionary

            if(call.method == "getPlatformVersion")
            {
                result("iOS " + UIDevice.current.systemVersion)
            }
            else if(call.method == "buildRoute")
            {
                strongSelf.buildRoute(arguments: arguments, flutterResult: result)
            }
            else if(call.method == "clearRoute")
            {
                strongSelf.clearRoute(arguments: arguments, result: result)
            }
            else if(call.method == "getDistanceRemaining")
            {
                result(strongSelf._distanceRemaining)
            }
            else if(call.method == "getDurationRemaining")
            {
                result(strongSelf._durationRemaining)
            }
            else if(call.method == "finishNavigation")
            {
                strongSelf.endNavigation(result: result)
            }
            else if(call.method == "startFreeDrive")
            {
                strongSelf.startEmbeddedFreeDrive(arguments: arguments, result: result)
            }
            else if(call.method == "startNavigation")
            {
                strongSelf.startEmbeddedNavigation(arguments: arguments, result: result)
            }
            else
            {
                result("method is not implemented");
            }

        }
    }

    public func view() -> UIView
    {
        if(_mapInitialized)
        {
            return navigationMapView
        }

        setupMapView()

        return navigationMapView
    }


    private func setupMapView()
    {
        if(self.arguments != nil)
        {
            parseFlutterArguments(arguments: arguments)
        }

        // Building the map view requires the shared provider (created here on first use).
        let navigation = navigationProvider.mapboxNavigation.navigation()
        navigationMapView = NavigationMapView(
            location: navigation.locationMatching.map(\.enhancedLocation).eraseToAnyPublisher(),
            routeProgress: navigation.routeProgress.map(\.?.routeProgress).eraseToAnyPublisher(),
            predictiveCacheManager: navigationProvider.predictiveCacheManager
        )
        navigationMapView.frame = frame
        navigationMapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        navigationMapView.delegate = self

        let styleUrl = _mapStyleUrlDay ?? "mapbox://styles/mapbox/navigation-day-v1"
        if let uri = StyleURI(rawValue: styleUrl) {
            navigationMapView.mapView.mapboxMap.loadStyle(uri)
        }

        locationManager.requestWhenInUseAuthorization()

        if _longPressDestinationEnabled
        {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            gesture.delegate = self
            navigationMapView?.addGestureRecognizer(gesture)
        }

        if _enableOnMapTapCallback {
            let onTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            onTapGesture.numberOfTapsRequired = 1
            onTapGesture.delegate = self
            navigationMapView?.addGestureRecognizer(onTapGesture)
        }

        _mapInitialized = true
    }

    func clearRoute(arguments: NSDictionary?, result: @escaping FlutterResult)
    {
        if navigationRoutes == nil
        {
            return
        }
        mapboxNavigation.tripSession().setToIdle()
        navigationMapView.removeRoutes()
        navigationRoutes = nil
        cancellables.removeAll()
        sendEvent(eventType: MapBoxEventType.navigation_cancelled)
        result(true)
    }

    func buildRoute(arguments: NSDictionary?, flutterResult: @escaping FlutterResult)
    {
        _wayPoints.removeAll()
        isEmbeddedNavigation = true
        sendEvent(eventType: MapBoxEventType.route_building)

        guard let oWayPoints = arguments?["wayPoints"] as? NSDictionary else {return}

        var locations = [Location]()

        for item in oWayPoints as NSDictionary
        {
            let point = item.value as! NSDictionary
            guard let oName = point["Name"] as? String else {return}
            guard let oLatitude = point["Latitude"] as? Double else {return}
            guard let oLongitude = point["Longitude"] as? Double else {return}
            let oIsSilent = point["IsSilent"] as? Bool ?? false
            let order = point["Order"] as? Int
            let location = Location(name: oName, latitude: oLatitude, longitude: oLongitude, order: order,isSilent: oIsSilent)
            locations.append(location)
        }

        if(!_isOptimized)
        {
            //waypoints must be in the right order
            locations.sort(by: {$0.order ?? 0 < $1.order ?? 0})
        }

        for loc in locations
        {
            var location = Waypoint(coordinate: CLLocationCoordinate2D(latitude: loc.latitude!, longitude: loc.longitude!),
                                    coordinateAccuracy: -1, name: loc.name)
            location.separatesLegs = !loc.isSilent
            _wayPoints.append(location)
        }

        parseFlutterArguments(arguments: arguments)

        if(_wayPoints.count > 3 && arguments?["mode"] == nil)
        {
            _navigationMode = "driving"
        }

        setNavigationOptions(wayPoints: _wayPoints)

        let request = mapboxNavigation.routingProvider().calculateRoutes(options: _options!)

        Task { @MainActor [weak self] in
            guard let strongSelf = self else { return }
            switch await request.result {
            case .failure(let error):
                print(error.localizedDescription)
                strongSelf.sendEvent(eventType: MapBoxEventType.route_build_failed)
                flutterResult(false)
            case .success(let navigationRoutes):
                strongSelf.navigationRoutes = navigationRoutes
                strongSelf.sendEvent(eventType: MapBoxEventType.route_built, data: strongSelf.encodeRouteResponse(navigationRoutes: navigationRoutes))
                strongSelf.navigationMapView?.showcase(navigationRoutes)
                flutterResult(true)
            }
        }
    }

    func startEmbeddedFreeDrive(arguments: NSDictionary?, result: @escaping FlutterResult) {
        mapboxNavigation.tripSession().startFreeDrive()
        result(true)
    }

    func startEmbeddedNavigation(arguments: NSDictionary?, result: @escaping FlutterResult) {
        guard let navigationRoutes = self.navigationRoutes else { return }

        let provider = navigationProvider
        let navigationOptions = NavigationOptions(
            mapboxNavigation: provider.mapboxNavigation,
            voiceController: provider.routeVoiceController,
            eventsManager: provider.eventsManager(),
            styles: buildStyles()
        )

        // Remove previous navigation view and controller if any
        if(_navigationViewController?.view != nil){
            _navigationViewController!.view.removeFromSuperview()
            _navigationViewController?.removeFromParent()
        }

        let navigationViewController = NavigationViewController(
            navigationRoutes: navigationRoutes,
            navigationOptions: navigationOptions
        )
        navigationViewController.delegate = self
        _navigationViewController = navigationViewController
        isEmbeddedNavigation = true

        subscribeToNavigationProgress(provider: provider)

        guard let host = topViewController() else { result(false); return }
        host.addChild(navigationViewController)

        self.navigationMapView.addSubview(navigationViewController.view)
        navigationViewController.view.translatesAutoresizingMaskIntoConstraints = false
        constraintsWithPaddingBetween(holderView: self.navigationMapView, topView: navigationViewController.view, padding: 0.0)
        navigationViewController.didMove(toParent: host)
        result(true)
    }

    func constraintsWithPaddingBetween(holderView: UIView, topView: UIView, padding: CGFloat) {
        guard holderView.subviews.contains(topView) else {
            return
        }
        topView.translatesAutoresizingMaskIntoConstraints = false
        let pinTop = NSLayoutConstraint(item: topView, attribute: .top, relatedBy: .equal,
                                        toItem: holderView, attribute: .top, multiplier: 1.0, constant: padding)
        let pinBottom = NSLayoutConstraint(item: topView, attribute: .bottom, relatedBy: .equal,
                                           toItem: holderView, attribute: .bottom, multiplier: 1.0, constant: padding)
        let pinLeft = NSLayoutConstraint(item: topView, attribute: .left, relatedBy: .equal,
                                         toItem: holderView, attribute: .left, multiplier: 1.0, constant: padding)
        let pinRight = NSLayoutConstraint(item: topView, attribute: .right, relatedBy: .equal,
                                          toItem: holderView, attribute: .right, multiplier: 1.0, constant: padding)
        holderView.addConstraints([pinTop, pinBottom, pinLeft, pinRight])
    }
}

extension FlutterMapboxNavigationView : NavigationMapViewDelegate {

    public func navigationMapView(_ navigationMapView: NavigationMapView, userDidLongTap mapPoint: MapPoint) {
        if _longPressDestinationEnabled {
            requestRoute(destination: mapPoint.coordinate)
        }
    }

    public func navigationMapView(_ navigationMapView: NavigationMapView, userDidTap mapPoint: MapPoint) {
        if _enableOnMapTapCallback {
            emitMapTap(coordinate: mapPoint.coordinate)
        }
    }

    public func navigationMapView(_ navigationMapView: NavigationMapView, didSelect alternativeRoute: AlternativeRoute) {
        Task { @MainActor [weak self] in
            guard let strongSelf = self,
                  let selected = await strongSelf.navigationRoutes?.selecting(alternativeRoute: alternativeRoute) else { return }
            strongSelf.navigationRoutes = selected
            strongSelf.navigationMapView?.showcase(selected)
        }
    }
}

extension FlutterMapboxNavigationView : UIGestureRecognizerDelegate {

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let location = navigationMapView.mapView.mapboxMap.coordinate(for: gesture.location(in: navigationMapView.mapView))
        requestRoute(destination: location)
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else {return}
        let location = navigationMapView.mapView.mapboxMap.coordinate(for: gesture.location(in: navigationMapView.mapView))
        emitMapTap(coordinate: location)
    }

    private func emitMapTap(coordinate: CLLocationCoordinate2D) {
        let waypoint: Encodable = [
            "latitude" : coordinate.latitude,
            "longitude" : coordinate.longitude,
        ]
        do {
            let encodedData = try JSONEncoder().encode(waypoint)
            let jsonString = String(data: encodedData, encoding: .utf8)

            if (jsonString?.isEmpty ?? true) {
                return
            }

            sendEvent(eventType: .on_map_tap, data: jsonString!)
        } catch {
            return
        }
    }

    func requestRoute(destination: CLLocationCoordinate2D) {
        isEmbeddedNavigation = true
        sendEvent(eventType: MapBoxEventType.route_building)

        guard let userLocation = navigationMapView.mapView.location.latestLocation else { return }
        let location = CLLocation(latitude: userLocation.coordinate.latitude,
                                  longitude: userLocation.coordinate.longitude)
        let userWaypoint = Waypoint(location: location, name: "Current Location")
        let destinationWaypoint = Waypoint(coordinate: destination)

        let routeOptions = NavigationRouteOptions(waypoints: [userWaypoint, destinationWaypoint])

        let request = mapboxNavigation.routingProvider().calculateRoutes(options: routeOptions)

        Task { @MainActor [weak self] in
            guard let strongSelf = self else { return }
            switch await request.result {
            case .failure(let error):
                print(error.localizedDescription)
                strongSelf.sendEvent(eventType: MapBoxEventType.route_build_failed)
            case .success(let navigationRoutes):
                strongSelf.navigationRoutes = navigationRoutes
                strongSelf._options = routeOptions
                strongSelf.sendEvent(eventType: MapBoxEventType.route_built, data: strongSelf.encodeRouteResponse(navigationRoutes: navigationRoutes))
                strongSelf.navigationMapView?.showcase(navigationRoutes)
            }
        }
    }

}
