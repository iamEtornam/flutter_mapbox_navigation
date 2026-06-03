import Flutter
import UIKit
import Combine
import CoreLocation
import MapboxMaps
import MapboxDirections
import MapboxNavigationCore
import MapboxNavigationUIKit

@MainActor
public class NavigationFactory : NSObject, FlutterStreamHandler
{
    var _navigationViewController: NavigationViewController? = nil
    var _eventSink: FlutterEventSink? = nil

    let ALLOW_ROUTE_SELECTION = false
    let IsMultipleUniqueRoutes = false
    var isEmbeddedNavigation = false

    var _distanceRemaining: Double?
    var _durationRemaining: Double?
    var _navigationMode: String?
    var _wayPointOrder = [Int:Waypoint]()
    var _wayPoints = [Waypoint]()
    var _lastKnownLocation: CLLocation?

    var _options: NavigationRouteOptions?
    var _simulateRoute = false
    var _allowsUTurnAtWayPoints: Bool?
    var _isOptimized = false
    var _language = "en"
    var _voiceUnits = "imperial"
    var _mapStyleUrlDay: String?
    var _mapStyleUrlNight: String?
    var _zoom: Double = 13.0
    var _tilt: Double = 0.0
    var _bearing: Double = 0.0
    var _animateBuildRoute = true
    var _longPressDestinationEnabled = true
    var _alternatives = true
    var _shouldReRoute = true
    var _showReportFeedbackButton = true
    var _showEndOfRouteFeedback = true
    var _enableOnMapTapCallback = false

    /// Combine subscriptions to the navigation publishers. Cleared when navigation ends.
    var cancellables = Set<AnyCancellable>()

    /// The shared provider, configured for the current simulation preference.
    var navigationProvider: MapboxNavigationProvider {
        NavigationProviderHolder.shared.provider(simulate: _simulateRoute)
    }

    /// The main facade of the Navigation SDK.
    var mapboxNavigation: MapboxNavigation {
        navigationProvider.mapboxNavigation
    }

    /// Resolves the top-most view controller to present from, in a way that works
    /// with scene-based apps (the legacy `UIApplication.shared.delegate?.window`
    /// lookup is nil on modern iOS and would crash a force-unwrap/cast).
    func topViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        let keyWindow = windows.first(where: { $0.isKeyWindow })
            ?? windows.first
            ?? UIApplication.shared.delegate?.window ?? nil
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    func addWayPoints(arguments: NSDictionary?, result: @escaping FlutterResult)
    {
        guard let locations = getLocationsFromFlutterArgument(arguments: arguments) else { return }

        var nextIndex = 1
        for loc in locations
        {
            var wayPoint = Waypoint(coordinate: CLLocationCoordinate2D(latitude: loc.latitude!, longitude: loc.longitude!), name: loc.name)
            wayPoint.separatesLegs = !loc.isSilent
            if (_wayPoints.count >= nextIndex) {
                _wayPoints.insert(wayPoint, at: nextIndex)
            }
            else {
                _wayPoints.append(wayPoint)
            }
            nextIndex += 1
        }

        startNavigationWithWayPoints(wayPoints: _wayPoints, flutterResult: result, isUpdatingWaypoints: true)
    }

    func startFreeDrive(arguments: NSDictionary?, result: @escaping FlutterResult)
    {
        parseFlutterArguments(arguments: arguments)
        let freeDriveViewController = FreeDriveViewController(provider: navigationProvider, mapStyleUrlDay: _mapStyleUrlDay, zoom: _zoom)
        guard let host = topViewController() else { result(false); return }
        host.present(freeDriveViewController, animated: true, completion: nil)
        result(true)
    }

    func startNavigation(arguments: NSDictionary?, result: @escaping FlutterResult)
    {
        _wayPoints.removeAll()
        _wayPointOrder.removeAll()

        guard let locations = getLocationsFromFlutterArgument(arguments: arguments) else { return }

        for loc in locations
        {
            var location = Waypoint(coordinate: CLLocationCoordinate2D(latitude: loc.latitude!, longitude: loc.longitude!), name: loc.name)
            location.separatesLegs = !loc.isSilent
            _wayPoints.append(location)
            _wayPointOrder[loc.order!] = location
        }

        parseFlutterArguments(arguments: arguments)

        if(_wayPoints.count > 3 && arguments?["mode"] == nil)
        {
            _navigationMode = "driving"
        }

        if(_wayPoints.count > 0)
        {
            if(IsMultipleUniqueRoutes)
            {
                startNavigationWithWayPoints(wayPoints: [_wayPoints.remove(at: 0), _wayPoints.remove(at: 0)], flutterResult: result, isUpdatingWaypoints: false)
            }
            else
            {
                startNavigationWithWayPoints(wayPoints: _wayPoints, flutterResult: result, isUpdatingWaypoints: false)
            }
        }
    }

    func startNavigationWithWayPoints(wayPoints: [Waypoint], flutterResult: @escaping FlutterResult, isUpdatingWaypoints: Bool)
    {
        setNavigationOptions(wayPoints: wayPoints)

        let provider = navigationProvider
        let navigation = provider.mapboxNavigation
        let request = navigation.routingProvider().calculateRoutes(options: _options!)

        Task { @MainActor [weak self] in
            guard let strongSelf = self else { return }
            switch await request.result {
            case .failure(let error):
                strongSelf.sendEvent(eventType: MapBoxEventType.route_build_failed)
                flutterResult("An error occured while calculating the route \(error.localizedDescription)")
            case .success(let navigationRoutes):
                if (isUpdatingWaypoints) {
                    navigation.tripSession().startActiveGuidance(with: navigationRoutes, startLegIndex: 0)
                    flutterResult("true")
                } else {
                    strongSelf.presentFullScreenNavigation(navigationRoutes: navigationRoutes, provider: provider)
                    flutterResult(true)
                }
            }
        }
    }

    func presentFullScreenNavigation(navigationRoutes: NavigationRoutes, provider: MapboxNavigationProvider)
    {
        isEmbeddedNavigation = false
        let navigationOptions = NavigationOptions(
            mapboxNavigation: provider.mapboxNavigation,
            voiceController: provider.routeVoiceController,
            eventsManager: provider.eventsManager(),
            styles: buildStyles()
        )

        let navigationViewController = NavigationViewController(
            navigationRoutes: navigationRoutes,
            navigationOptions: navigationOptions
        )
        navigationViewController.modalPresentationStyle = .fullScreen
        navigationViewController.routeLineTracksTraversal = true
        navigationViewController.delegate = self
        _navigationViewController = navigationViewController

        subscribeToNavigationProgress(provider: provider)

        guard let host = topViewController() else { return }
        host.present(navigationViewController, animated: true, completion: nil)
    }

    /// Subscribes to the route-progress publisher and forwards progress to Flutter.
    func subscribeToNavigationProgress(provider: MapboxNavigationProvider)
    {
        cancellables.removeAll()
        provider.mapboxNavigation.navigation().routeProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let strongSelf = self, let progress = state?.routeProgress else { return }
                MainActor.assumeIsolated { strongSelf.handleProgress(progress) }
            }
            .store(in: &cancellables)
    }

    func handleProgress(_ progress: RouteProgress)
    {
        _distanceRemaining = progress.distanceRemaining
        _durationRemaining = progress.durationRemaining
        sendEvent(eventType: MapBoxEventType.navigation_running)
        if(_eventSink != nil)
        {
            let jsonEncoder = JSONEncoder()
            let progressEvent = MapBoxRouteProgressEvent(progress: progress)
            if let progressEventJsonData = try? jsonEncoder.encode(progressEvent),
               let progressEventJson = String(data: progressEventJsonData, encoding: String.Encoding.ascii)
            {
                _eventSink!(progressEventJson)
            }

            if(progress.isFinalLeg && progress.currentLegProgress.userHasArrivedAtWaypoint && !_showEndOfRouteFeedback)
            {
                _eventSink = nil
            }
        }
    }

    func buildStyles() -> [Style]
    {
        let dayStyle = _mapStyleUrlDay != nil ? CustomDayStyle(url: _mapStyleUrlDay) : CustomDayStyle()
        let nightStyle = _mapStyleUrlNight != nil ? CustomNightStyle(url: _mapStyleUrlNight) : CustomNightStyle()
        return [dayStyle, nightStyle]
    }

    func setNavigationOptions(wayPoints: [Waypoint]) {
        var mode: ProfileIdentifier = .automobileAvoidingTraffic

        if (_navigationMode == "cycling")
        {
            mode = .cycling
        }
        else if(_navigationMode == "driving")
        {
            mode = .automobile
        }
        else if(_navigationMode == "walking")
        {
            mode = .walking
        }
        let options = NavigationRouteOptions(waypoints: wayPoints, profileIdentifier: mode)

        if (_allowsUTurnAtWayPoints != nil)
        {
            options.allowsUTurnAtWaypoint = _allowsUTurnAtWayPoints!
        }

        options.distanceMeasurementSystem = _voiceUnits == "imperial" ? .imperial : .metric
        options.locale = Locale(identifier: _language)
        options.includesAlternativeRoutes = _alternatives
        _options = options
    }

    func parseFlutterArguments(arguments: NSDictionary?) {
        _language = arguments?["language"] as? String ?? _language
        _voiceUnits = arguments?["units"] as? String ?? _voiceUnits
        _simulateRoute = arguments?["simulateRoute"] as? Bool ?? _simulateRoute
        _isOptimized = arguments?["isOptimized"] as? Bool ?? _isOptimized
        _allowsUTurnAtWayPoints = arguments?["allowsUTurnAtWayPoints"] as? Bool
        _navigationMode = arguments?["mode"] as? String ?? "drivingWithTraffic"
        _showReportFeedbackButton = arguments?["showReportFeedbackButton"] as? Bool ?? _showReportFeedbackButton
        _showEndOfRouteFeedback = arguments?["showEndOfRouteFeedback"] as? Bool ?? _showEndOfRouteFeedback
        _enableOnMapTapCallback = arguments?["enableOnMapTapCallback"] as? Bool ?? _enableOnMapTapCallback
        _mapStyleUrlDay = arguments?["mapStyleUrlDay"] as? String
        _mapStyleUrlNight = arguments?["mapStyleUrlNight"] as? String
        _zoom = arguments?["zoom"] as? Double ?? _zoom
        _bearing = arguments?["bearing"] as? Double ?? _bearing
        _tilt = arguments?["tilt"] as? Double ?? _tilt
        _animateBuildRoute = arguments?["animateBuildRoute"] as? Bool ?? _animateBuildRoute
        _longPressDestinationEnabled = arguments?["longPressDestinationEnabled"] as? Bool ?? _longPressDestinationEnabled
        _alternatives = arguments?["alternatives"] as? Bool ?? _alternatives
    }

    func endNavigation(result: FlutterResult?)
    {
        sendEvent(eventType: MapBoxEventType.navigation_finished)
        NavigationProviderHolder.shared.providerIfCreated?.mapboxNavigation.tripSession().setToIdle()
        cancellables.removeAll()
        if(self._navigationViewController != nil)
        {
            if(isEmbeddedNavigation)
            {
                self._navigationViewController?.view.removeFromSuperview()
                self._navigationViewController?.removeFromParent()
                self._navigationViewController = nil
            }
            else
            {
                self._navigationViewController?.dismiss(animated: true, completion: {
                    self._navigationViewController = nil
                    if(result != nil)
                    {
                        result!(true)
                    }
                })
            }
        }
    }

    func getLocationsFromFlutterArgument(arguments: NSDictionary?) -> [Location]? {
        var locations = [Location]()
        guard let oWayPoints = arguments?["wayPoints"] as? NSDictionary else {return nil}
        for item in oWayPoints as NSDictionary
        {
            let point = item.value as! NSDictionary
            guard let oName = point["Name"] as? String else {return nil }
            guard let oLatitude = point["Latitude"] as? Double else {return nil}
            guard let oLongitude = point["Longitude"] as? Double else {return nil}
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
        return locations
    }

    func getLastKnownLocation() -> Waypoint
    {
        return Waypoint(coordinate: CLLocationCoordinate2D(latitude: _lastKnownLocation!.coordinate.latitude, longitude: _lastKnownLocation!.coordinate.longitude))
    }

    func sendEvent(eventType: MapBoxEventType, data: String = "")
    {
        let routeEvent = MapBoxRouteEvent(eventType: eventType, data: data)

        let jsonEncoder = JSONEncoder()
        let jsonData = try! jsonEncoder.encode(routeEvent)
        let eventJson = String(data: jsonData, encoding: String.Encoding.utf8)
        if(_eventSink != nil){
            _eventSink!(eventJson)
        }
    }

    func downloadOfflineRoute(arguments: NSDictionary?, flutterResult: @escaping FlutterResult)
    {
        // Offline routing/tile download is not yet wired up for Navigation SDK v3.
        flutterResult(false)
    }

    func encodeRouteResponse(navigationRoutes: NavigationRoutes) -> String {
        let routes = [navigationRoutes.mainRoute.route]
        let jsonEncoder = JSONEncoder()
        if let jsonData = try? jsonEncoder.encode(routes),
           let json = String(data: jsonData, encoding: String.Encoding.utf8) {
            return json
        }
        return "{}"
    }

    //MARK: EventListener Delegates
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        _eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        _eventSink = nil
        return nil
    }
}


extension NavigationFactory : NavigationViewControllerDelegate {
    //MARK: NavigationViewController Delegates
    public func navigationViewController(_ navigationViewController: NavigationViewController, didArriveAt waypoint: Waypoint) {
        sendEvent(eventType: MapBoxEventType.on_arrival, data: "true")
    }

    public func navigationViewControllerDidDismiss(_ navigationViewController: NavigationViewController, byCanceling canceled: Bool) {
        if(canceled)
        {
            sendEvent(eventType: MapBoxEventType.navigation_cancelled)
        }
        endNavigation(result: nil)
    }
}
