package dev.etornam.mapboxnavigation

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.util.Log
import androidx.lifecycle.LifecycleOwner
import dev.etornam.mapboxnavigation.databinding.NavigationActivityBinding
import dev.etornam.mapboxnavigation.models.MapBoxEvents
import dev.etornam.mapboxnavigation.models.MapBoxRouteProgressEvent
import dev.etornam.mapboxnavigation.models.Waypoint
import dev.etornam.mapboxnavigation.models.WaypointSet
import dev.etornam.mapboxnavigation.utilities.NavigationUi
import dev.etornam.mapboxnavigation.utilities.PluginUtilities
import com.google.gson.Gson
import com.mapbox.common.MapboxOptions
import com.mapbox.common.location.Location
import com.mapbox.maps.plugin.gestures.gestures
import com.mapbox.navigation.ui.maps.NavigationStyles
import com.mapbox.api.directions.v5.DirectionsCriteria
import com.mapbox.api.directions.v5.models.RouteOptions
import com.mapbox.geojson.Point
import com.mapbox.navigation.base.ExperimentalPreviewMapboxNavigationAPI
import com.mapbox.navigation.base.extensions.applyDefaultNavigationOptions
import com.mapbox.navigation.base.extensions.applyLanguageAndVoiceUnitOptions
import com.mapbox.navigation.base.options.NavigationOptions
import com.mapbox.navigation.base.route.NavigationRoute
import com.mapbox.navigation.base.route.NavigationRouterCallback
import com.mapbox.navigation.base.route.RouterFailure
import com.mapbox.navigation.base.trip.model.RouteLegProgress
import com.mapbox.navigation.base.trip.model.RouteProgress
import com.mapbox.navigation.core.arrival.ArrivalObserver
import com.mapbox.navigation.core.directions.session.RoutesObserver
import com.mapbox.navigation.core.lifecycle.MapboxNavigationApp
import com.mapbox.navigation.core.replay.route.ReplayProgressObserver
import com.mapbox.navigation.core.replay.route.ReplayRouteMapper
import com.mapbox.navigation.core.trip.session.LocationMatcherResult
import com.mapbox.navigation.core.trip.session.LocationObserver
import com.mapbox.navigation.core.trip.session.OffRouteObserver
import com.mapbox.navigation.core.trip.session.RouteProgressObserver
import com.mapbox.navigation.core.trip.session.VoiceInstructionsObserver
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.*

@OptIn(ExperimentalPreviewMapboxNavigationAPI::class)
open class TurnByTurn(
    ctx: Context,
    act: Activity,
    bind: NavigationActivityBinding,
    accessToken: String
) : MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    Application.ActivityLifecycleCallbacks {

    open fun initFlutterChannelHandlers() {
        this.methodChannel?.setMethodCallHandler(this)
        this.eventChannel?.setStreamHandler(this)
    }

    @SuppressLint("MissingPermission")
    open fun initNavigation() {
        // Navigation SDK v3 reads the access token from MapboxOptions / resources;
        // NavigationOptions.Builder no longer accepts an access token.
        MapboxOptions.accessToken = this.token

        val navigationOptions = NavigationOptions.Builder(this.context).build()

        MapboxNavigationApp
            .setup(navigationOptions)
            .attach(this.activity as LifecycleOwner)

        // Assemble the component-based turn-by-turn UI (Drop-In is gone in v3).
        val styleUri = this.mapStyleUrlDay ?: NavigationStyles.NAVIGATION_DAY_STYLE
        this.navigationUi = NavigationUi(
            context = this.context,
            binding = this.binding,
            language = this.navigationLanguage,
            onStopClicked = { this.finishNavigation() }
        )
        this.navigationUi!!.initialize(styleUri)

        this.registerObservers()
        this.registerMapGestures()
    }

    override fun onMethodCall(methodCall: MethodCall, result: MethodChannel.Result) {
        when (methodCall.method) {
            "getPlatformVersion" -> {
                result.success("Android ${android.os.Build.VERSION.RELEASE}")
            }
            "enableOfflineRouting" -> {
                // downloadRegionForOfflineRouting(call, result)
            }
            "buildRoute" -> {
                this.buildRoute(methodCall, result)
            }
            "clearRoute" -> {
                this.clearRoute(methodCall, result)
            }
            "startFreeDrive" -> {
                FlutterMapboxNavigationPlugin.enableFreeDriveMode = true
                this.startFreeDrive()
                result.success(true)
            }
            "startNavigation" -> {
                FlutterMapboxNavigationPlugin.enableFreeDriveMode = false
                this.startNavigation(methodCall, result)
            }
            "finishNavigation" -> {
                this.finishNavigation(methodCall, result)
            }
            "getDistanceRemaining" -> {
                result.success(this.distanceRemaining)
            }
            "getDurationRemaining" -> {
                result.success(this.durationRemaining)
            }
            else -> result.notImplemented()
        }
    }

    private fun buildRoute(methodCall: MethodCall, result: MethodChannel.Result) {
        this.isNavigationCanceled = false

        val arguments = methodCall.arguments as? Map<*, *>
        if (arguments != null) this.setOptions(arguments)
        this.addedWaypoints.clear()
        val points = arguments?.get("wayPoints") as HashMap<*, *>
        for (item in points) {
            val point = item.value as HashMap<*, *>
            val latitude = point["Latitude"] as Double
            val longitude = point["Longitude"] as Double
            val isSilent = point["IsSilent"] as Boolean
            this.addedWaypoints.add(Waypoint(Point.fromLngLat(longitude, latitude), isSilent))
        }
        this.getRoute(this.context)
        result.success(true)
    }

    private fun getRoute(context: Context) {
        PluginUtilities.sendEvent(MapBoxEvents.ROUTE_BUILDING)
        val mapboxNavigation = MapboxNavigationApp.current() ?: return
        mapboxNavigation.requestRoutes(
            routeOptions = RouteOptions
                .builder()
                .applyDefaultNavigationOptions()
                .applyLanguageAndVoiceUnitOptions(context)
                .profile(navigationMode)
                .coordinatesList(this.addedWaypoints.coordinatesList())
                .waypointIndicesList(this.addedWaypoints.waypointsIndices())
                .waypointNamesList(this.addedWaypoints.waypointsNames())
                .language(navigationLanguage)
                .alternatives(alternatives)
                .steps(true)
                .voiceUnits(navigationVoiceUnits)
                .bannerInstructions(bannerInstructionsEnabled)
                .voiceInstructions(voiceInstructionsEnabled)
                .build(),
            callback = object : NavigationRouterCallback {
                override fun onRoutesReady(
                    routes: List<NavigationRoute>,
                    routerOrigin: String
                ) {
                    this@TurnByTurn.currentRoutes = routes
                    PluginUtilities.sendEvent(
                        MapBoxEvents.ROUTE_BUILT,
                        Gson().toJson(routes.map { it.directionsRoute.toJson() })
                    )
                    // Draw a route preview without starting active guidance.
                    this@TurnByTurn.navigationUi?.onRoutesChanged(routes)
                    this@TurnByTurn.navigationUi?.showRoutePreviewUi()
                }

                override fun onFailure(
                    reasons: List<RouterFailure>,
                    routeOptions: RouteOptions
                ) {
                    PluginUtilities.sendEvent(MapBoxEvents.ROUTE_BUILD_FAILED)
                }

                override fun onCanceled(
                    routeOptions: RouteOptions,
                    routerOrigin: String
                ) {
                    PluginUtilities.sendEvent(MapBoxEvents.ROUTE_BUILD_CANCELLED)
                }
            }
        )
    }

    private fun clearRoute(methodCall: MethodCall, result: MethodChannel.Result) {
        this.currentRoutes = null
        MapboxNavigationApp.current()?.setNavigationRoutes(listOf())
        this.navigationUi?.hideUi()
        PluginUtilities.sendEvent(MapBoxEvents.NAVIGATION_CANCELLED)
        result.success(true)
    }

    @SuppressLint("MissingPermission")
    private fun startFreeDrive() {
        MapboxNavigationApp.current()?.startTripSession()
    }

    private fun startNavigation(methodCall: MethodCall, result: MethodChannel.Result) {
        val arguments = methodCall.arguments as? Map<*, *>
        if (arguments != null) {
            this.setOptions(arguments)
        }

        this.startNavigation()

        if (this.currentRoutes != null) {
            result.success(true)
        } else {
            result.success(false)
        }
    }

    private fun finishNavigation(methodCall: MethodCall, result: MethodChannel.Result) {
        this.finishNavigation()

        if (this.currentRoutes != null) {
            result.success(true)
        } else {
            result.success(false)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startNavigation() {
        val routes = this.currentRoutes
        val mapboxNavigation = MapboxNavigationApp.current()
        if (routes == null || mapboxNavigation == null) {
            PluginUtilities.sendEvent(MapBoxEvents.NAVIGATION_CANCELLED)
            return
        }

        if (this.simulateRoute) {
            mapboxNavigation.startReplayTripSession()
            mapboxNavigation.setNavigationRoutes(routes)
            startReplay(routes.first())
        } else {
            mapboxNavigation.startTripSession()
            mapboxNavigation.setNavigationRoutes(routes)
        }

        this.navigationUi?.showGuidanceUi()
        PluginUtilities.sendEvent(MapBoxEvents.NAVIGATION_RUNNING)
    }

    private fun startReplay(route: NavigationRoute) {
        val mapboxNavigation = MapboxNavigationApp.current() ?: return
        val replayer = mapboxNavigation.mapboxReplayer
        replayer.stop()
        replayer.clearEvents()
        val replayData = replayRouteMapper.mapDirectionsRouteGeometry(route.directionsRoute)
        replayer.pushEvents(replayData)
        replayer.seekTo(replayData.first())
        replayer.play()
    }

    private fun finishNavigation(isOffRouted: Boolean = false) {
        val mapboxNavigation = MapboxNavigationApp.current()
        mapboxNavigation?.mapboxReplayer?.stop()
        mapboxNavigation?.setNavigationRoutes(listOf())
        mapboxNavigation?.stopTripSession()
        this.navigationUi?.hideUi()
        this.isNavigationCanceled = true
        PluginUtilities.sendEvent(MapBoxEvents.NAVIGATION_CANCELLED)
    }

    private fun setOptions(arguments: Map<*, *>) {
        val navMode = arguments["mode"] as? String
        if (navMode != null) {
            when (navMode) {
                "walking" -> this.navigationMode = DirectionsCriteria.PROFILE_WALKING
                "cycling" -> this.navigationMode = DirectionsCriteria.PROFILE_CYCLING
                "driving" -> this.navigationMode = DirectionsCriteria.PROFILE_DRIVING
            }
        }

        val simulated = arguments["simulateRoute"] as? Boolean
        if (simulated != null) {
            this.simulateRoute = simulated
        }

        val language = arguments["language"] as? String
        if (language != null) {
            this.navigationLanguage = language
        }

        val units = arguments["units"] as? String

        if (units != null) {
            if (units == "imperial") {
                this.navigationVoiceUnits = DirectionsCriteria.IMPERIAL
            } else if (units == "metric") {
                this.navigationVoiceUnits = DirectionsCriteria.METRIC
            }
        }

        this.mapStyleUrlDay = arguments["mapStyleUrlDay"] as? String
        this.mapStyleUrlNight = arguments["mapStyleUrlNight"] as? String

        this.initialLatitude = arguments["initialLatitude"] as? Double
        this.initialLongitude = arguments["initialLongitude"] as? Double

        val zm = arguments["zoom"] as? Double
        if (zm != null) {
            this.zoom = zm
        }

        val br = arguments["bearing"] as? Double
        if (br != null) {
            this.bearing = br
        }

        val tt = arguments["tilt"] as? Double
        if (tt != null) {
            this.tilt = tt
        }

        val optim = arguments["isOptimized"] as? Boolean
        if (optim != null) {
            this.isOptimized = optim
        }

        val anim = arguments["animateBuildRoute"] as? Boolean
        if (anim != null) {
            this.animateBuildRoute = anim
        }

        val altRoute = arguments["alternatives"] as? Boolean
        if (altRoute != null) {
            this.alternatives = altRoute
        }

        val voiceEnabled = arguments["voiceInstructionsEnabled"] as? Boolean
        if (voiceEnabled != null) {
            this.voiceInstructionsEnabled = voiceEnabled
        }

        val bannerEnabled = arguments["bannerInstructionsEnabled"] as? Boolean
        if (bannerEnabled != null) {
            this.bannerInstructionsEnabled = bannerEnabled
        }

        val longPress = arguments["longPressDestinationEnabled"] as? Boolean
        if (longPress != null) {
            this.longPressDestinationEnabled = longPress
        }

        val onMapTap = arguments["enableOnMapTapCallback"] as? Boolean
        if (onMapTap != null) {
            this.enableOnMapTapCallback = onMapTap
        }
    }

    @SuppressLint("MissingPermission")
    private fun registerMapGestures() {
        val mapView = this.binding.mapView
        if (this.longPressDestinationEnabled) {
            mapView.gestures.addOnMapLongClickListener { point ->
                onMapLongClick(point)
                true
            }
        }
        if (this.enableOnMapTapCallback) {
            mapView.gestures.addOnMapClickListener { point ->
                val waypoint = mapOf(
                    "latitude" to point.latitude().toString(),
                    "longitude" to point.longitude().toString()
                )
                PluginUtilities.sendEvent(
                    MapBoxEvents.ON_MAP_TAP,
                    org.json.JSONObject(waypoint).toString()
                )
                false
            }
        }
    }

    private fun onMapLongClick(point: Point) {
        val origin = this.lastLocation ?: return
        this.addedWaypoints.clear()
        this.addedWaypoints.add(Waypoint(Point.fromLngLat(origin.longitude, origin.latitude)))
        this.addedWaypoints.add(Waypoint(point))
        this.getRoute(this.context)
    }

    open fun registerObservers() {
        val mapboxNavigation = MapboxNavigationApp.current() ?: return
        mapboxNavigation.registerVoiceInstructionsObserver(this.voiceInstructionObserver)
        mapboxNavigation.registerOffRouteObserver(this.offRouteObserver)
        mapboxNavigation.registerRoutesObserver(this.routesObserver)
        mapboxNavigation.registerLocationObserver(this.locationObserver)
        mapboxNavigation.registerRouteProgressObserver(this.routeProgressObserver)
        mapboxNavigation.registerArrivalObserver(this.arrivalObserver)
        mapboxNavigation.registerRouteProgressObserver(this.replayProgressObserver)
    }

    open fun unregisterObservers() {
        val mapboxNavigation = MapboxNavigationApp.current() ?: return
        mapboxNavigation.unregisterVoiceInstructionsObserver(this.voiceInstructionObserver)
        mapboxNavigation.unregisterOffRouteObserver(this.offRouteObserver)
        mapboxNavigation.unregisterRoutesObserver(this.routesObserver)
        mapboxNavigation.unregisterLocationObserver(this.locationObserver)
        mapboxNavigation.unregisterRouteProgressObserver(this.routeProgressObserver)
        mapboxNavigation.unregisterArrivalObserver(this.arrivalObserver)
        mapboxNavigation.unregisterRouteProgressObserver(this.replayProgressObserver)
        this.navigationUi?.onDestroy()
    }

    // Flutter stream listener delegate methods
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        FlutterMapboxNavigationPlugin.eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        FlutterMapboxNavigationPlugin.eventSink = null
    }

    private val context: Context = ctx
    val activity: Activity = act
    private val token: String = accessToken
    open var methodChannel: MethodChannel? = null
    open var eventChannel: EventChannel? = null
    private var lastLocation: Location? = null

    /** Drives the component-based turn-by-turn UI. */
    private var navigationUi: NavigationUi? = null

    /** Converts a route into events that can be replayed to simulate driving. */
    private val replayRouteMapper = ReplayRouteMapper()

    /**
     * Helper class that keeps added waypoints and transforms them to the [RouteOptions] params.
     */
    private val addedWaypoints = WaypointSet()

    // Config
    private var initialLatitude: Double? = null
    private var initialLongitude: Double? = null

    private var navigationMode = DirectionsCriteria.PROFILE_DRIVING_TRAFFIC
    var simulateRoute = false
    private var mapStyleUrlDay: String? = null
    private var mapStyleUrlNight: String? = null
    private var navigationLanguage = "en"
    private var navigationVoiceUnits = DirectionsCriteria.IMPERIAL
    private var zoom = 15.0
    private var bearing = 0.0
    private var tilt = 0.0
    private var distanceRemaining: Float? = null
    private var durationRemaining: Double? = null

    private var alternatives = true

    var allowsUTurnAtWayPoints = false
    var enableRefresh = false
    private var voiceInstructionsEnabled = true
    private var bannerInstructionsEnabled = true
    private var longPressDestinationEnabled = true
    private var enableOnMapTapCallback = false
    private var animateBuildRoute = true
    private var isOptimized = false

    private var currentRoutes: List<NavigationRoute>? = null
    private var isNavigationCanceled = false

    /**
     * Bindings to the example layout.
     */
    open val binding: NavigationActivityBinding = bind

    /** Keeps the replayer fed with up-to-date progress while simulating. */
    private val replayProgressObserver by lazy {
        ReplayProgressObserver(MapboxNavigationApp.current()!!.mapboxReplayer)
    }

    /**
     * Gets notified with location updates and forwards them to the UI components.
     */
    private val locationObserver = object : LocationObserver {
        override fun onNewLocationMatcherResult(locationMatcherResult: LocationMatcherResult) {
            this@TurnByTurn.lastLocation = locationMatcherResult.enhancedLocation
            this@TurnByTurn.navigationUi?.onLocationMatcherResult(locationMatcherResult)
        }

        override fun onNewRawLocation(rawLocation: Location) {
            // no impl
        }
    }

    private val voiceInstructionObserver = VoiceInstructionsObserver { voiceInstructions ->
        if (this.voiceInstructionsEnabled) {
            this.navigationUi?.playVoiceInstruction(voiceInstructions)
        }
        PluginUtilities.sendEvent(
            MapBoxEvents.SPEECH_ANNOUNCEMENT,
            voiceInstructions.announcement().toString()
        )
    }

    private val offRouteObserver = OffRouteObserver { offRoute ->
        if (offRoute) {
            PluginUtilities.sendEvent(MapBoxEvents.USER_OFF_ROUTE)
        }
    }

    private val routesObserver = RoutesObserver { routeUpdateResult ->
        this.navigationUi?.onRoutesChanged(routeUpdateResult.navigationRoutes)
        if (routeUpdateResult.navigationRoutes.isNotEmpty()) {
            PluginUtilities.sendEvent(MapBoxEvents.REROUTE_ALONG)
        }
    }

    /**
     * Gets notified with progress along the currently active route.
     */
    private val routeProgressObserver = RouteProgressObserver { routeProgress ->
        this.navigationUi?.onRouteProgress(routeProgress)
        if (!this.isNavigationCanceled) {
            try {
                this.distanceRemaining = routeProgress.distanceRemaining
                this.durationRemaining = routeProgress.durationRemaining

                val progressEvent = MapBoxRouteProgressEvent(routeProgress)
                PluginUtilities.sendEvent(progressEvent)
            } catch (_: java.lang.Exception) {
                // ignore malformed progress
            }
        }
    }

    private val arrivalObserver: ArrivalObserver = object : ArrivalObserver {
        override fun onFinalDestinationArrival(routeProgress: RouteProgress) {
            PluginUtilities.sendEvent(MapBoxEvents.ON_ARRIVAL)
        }

        override fun onNextRouteLegStart(routeLegProgress: RouteLegProgress) {
            // not impl
        }

        override fun onWaypointArrival(routeProgress: RouteProgress) {
            // not impl
        }
    }

    override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
        Log.d("Embedded", "onActivityCreated not implemented")
    }

    override fun onActivityStarted(activity: Activity) {
        Log.d("Embedded", "onActivityStarted not implemented")
    }

    override fun onActivityResumed(activity: Activity) {
        Log.d("Embedded", "onActivityResumed not implemented")
    }

    override fun onActivityPaused(activity: Activity) {
        Log.d("Embedded", "onActivityPaused not implemented")
    }

    override fun onActivityStopped(activity: Activity) {
        Log.d("Embedded", "onActivityStopped not implemented")
    }

    override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {
        Log.d("Embedded", "onActivitySaveInstanceState not implemented")
    }

    override fun onActivityDestroyed(activity: Activity) {
        Log.d("Embedded", "onActivityDestroyed not implemented")
    }
}
