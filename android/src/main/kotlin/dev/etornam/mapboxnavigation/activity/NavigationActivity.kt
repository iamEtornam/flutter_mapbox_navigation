package dev.etornam.mapboxnavigation.activity

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Bundle
import org.json.JSONObject
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import dev.etornam.mapboxnavigation.FlutterMapboxNavigationPlugin
import dev.etornam.mapboxnavigation.databinding.NavigationActivityBinding
import dev.etornam.mapboxnavigation.models.MapBoxEvents
import dev.etornam.mapboxnavigation.models.MapBoxRouteProgressEvent
import dev.etornam.mapboxnavigation.models.Waypoint
import dev.etornam.mapboxnavigation.models.WaypointSet
import dev.etornam.mapboxnavigation.utilities.NavigationUi
import dev.etornam.mapboxnavigation.utilities.PluginUtilities
import dev.etornam.mapboxnavigation.utilities.PluginUtilities.Companion.sendEvent
import com.google.gson.Gson
import com.mapbox.common.MapboxOptions
import com.mapbox.common.location.Location
import com.mapbox.api.directions.v5.models.RouteOptions
import com.mapbox.geojson.Point
import com.mapbox.maps.plugin.gestures.gestures
import com.mapbox.navigation.ui.maps.NavigationStyles
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
import com.mapbox.navigation.utils.internal.ifNonNull

@OptIn(ExperimentalPreviewMapboxNavigationAPI::class)
class NavigationActivity : AppCompatActivity() {
    private var finishBroadcastReceiver: BroadcastReceiver? = null
    private var addWayPointsBroadcastReceiver: BroadcastReceiver? = null
    private var points: MutableList<Waypoint> = mutableListOf()
    private var waypointSet: WaypointSet = WaypointSet()
    private var lastLocation: Location? = null
    private var isNavigationInProgress = false

    private lateinit var binding: NavigationActivityBinding
    private lateinit var navigationUi: NavigationUi
    private val replayRouteMapper = ReplayRouteMapper()
    private val addedWaypoints = WaypointSet()

    @SuppressLint("MissingPermission")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setTheme(androidx.appcompat.R.style.Theme_AppCompat_NoActionBar)
        binding = NavigationActivityBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Navigation SDK v3 reads the token from MapboxOptions / resources.
        MapboxOptions.accessToken =
            PluginUtilities.getResourceFromContext(this.applicationContext, "mapbox_access_token")

        MapboxNavigationApp
            .setup(NavigationOptions.Builder(this.applicationContext).build())
            .attach(this)

        val styleUrlDay = FlutterMapboxNavigationPlugin.mapStyleUrlDay ?: NavigationStyles.NAVIGATION_DAY_STYLE
        navigationUi = NavigationUi(
            context = this,
            binding = binding,
            language = FlutterMapboxNavigationPlugin.navigationLanguage,
            onStopClicked = {
                tryCancelNavigation()
                finish()
            }
        )
        navigationUi.initialize(styleUrlDay)

        MapboxNavigationApp.current()?.apply {
            registerLocationObserver(locationObserver)
            registerRouteProgressObserver(routeProgressObserver)
            registerRoutesObserver(routesObserver)
            registerArrivalObserver(arrivalObserver)
            registerVoiceInstructionsObserver(voiceInstructionObserver)
            registerOffRouteObserver(offRouteObserver)
        }

        if (FlutterMapboxNavigationPlugin.longPressDestinationEnabled) {
            binding.mapView.gestures.addOnMapLongClickListener { point ->
                onMapLongClick(point)
                true
            }
        }
        if (FlutterMapboxNavigationPlugin.enableOnMapTapCallback) {
            binding.mapView.gestures.addOnMapClickListener { point ->
                val waypoint = mapOf(
                    "latitude" to point.latitude().toString(),
                    "longitude" to point.longitude().toString()
                )
                sendEvent(MapBoxEvents.ON_MAP_TAP, JSONObject(waypoint).toString())
                false
            }
        }

        finishBroadcastReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                finish()
            }
        }

        addWayPointsBroadcastReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val stops = intent.getSerializableExtra("waypoints") as? MutableList<Waypoint>
                val nextIndex = 1
                if (stops != null) {
                    if (points.count() >= nextIndex)
                        points.addAll(nextIndex, stops)
                    else
                        points.addAll(stops)
                    waypointSet = WaypointSet()
                    points.map { waypointSet.add(it) }
                    requestRoutes(waypointSet)
                }
            }
        }

        // These receivers handle app-internal broadcasts only. targetSdk 34 requires an
        // explicit export flag; ContextCompat handles the flag across API levels.
        ContextCompat.registerReceiver(
            this, finishBroadcastReceiver, IntentFilter(NavigationLauncher.KEY_STOP_NAVIGATION),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        ContextCompat.registerReceiver(
            this, addWayPointsBroadcastReceiver, IntentFilter(NavigationLauncher.KEY_ADD_WAYPOINTS),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )

        if (FlutterMapboxNavigationPlugin.enableFreeDriveMode) {
            startTripSession()
            return
        }

        val p = intent.getSerializableExtra("waypoints") as? MutableList<Waypoint>
        if (p != null) points = p
        points.map { waypointSet.add(it) }
        requestRoutes(waypointSet)
    }

    override fun onDestroy() {
        super.onDestroy()
        MapboxNavigationApp.current()?.apply {
            unregisterLocationObserver(locationObserver)
            unregisterRouteProgressObserver(routeProgressObserver)
            unregisterRoutesObserver(routesObserver)
            unregisterArrivalObserver(arrivalObserver)
            unregisterVoiceInstructionsObserver(voiceInstructionObserver)
            unregisterOffRouteObserver(offRouteObserver)
            mapboxReplayer.stop()
        }
        navigationUi.onDestroy()
        finishBroadcastReceiver?.let { unregisterReceiver(it) }
        addWayPointsBroadcastReceiver?.let { unregisterReceiver(it) }
    }

    private fun tryCancelNavigation() {
        if (isNavigationInProgress) {
            isNavigationInProgress = false
            MapboxNavigationApp.current()?.apply {
                mapboxReplayer.stop()
                setNavigationRoutes(listOf())
                stopTripSession()
            }
            sendEvent(MapBoxEvents.NAVIGATION_CANCELLED)
        }
    }

    @SuppressLint("MissingPermission")
    private fun startTripSession() {
        MapboxNavigationApp.current()?.startTripSession()
    }

    private fun requestRoutes(waypointSet: WaypointSet) {
        sendEvent(MapBoxEvents.ROUTE_BUILDING)
        val mapboxNavigation = MapboxNavigationApp.current() ?: return
        mapboxNavigation.requestRoutes(
            routeOptions = RouteOptions
                .builder()
                .applyDefaultNavigationOptions()
                .applyLanguageAndVoiceUnitOptions(this)
                .profile(FlutterMapboxNavigationPlugin.navigationMode)
                .coordinatesList(waypointSet.coordinatesList())
                .waypointIndicesList(waypointSet.waypointsIndices())
                .waypointNamesList(waypointSet.waypointsNames())
                .language(FlutterMapboxNavigationPlugin.navigationLanguage)
                .alternatives(FlutterMapboxNavigationPlugin.showAlternateRoutes)
                .voiceUnits(FlutterMapboxNavigationPlugin.navigationVoiceUnits)
                .bannerInstructions(FlutterMapboxNavigationPlugin.bannerInstructionsEnabled)
                .voiceInstructions(FlutterMapboxNavigationPlugin.voiceInstructionsEnabled)
                .steps(true)
                .build(),
            callback = object : NavigationRouterCallback {
                override fun onCanceled(routeOptions: RouteOptions, routerOrigin: String) {
                    sendEvent(MapBoxEvents.ROUTE_BUILD_CANCELLED)
                }

                override fun onFailure(reasons: List<RouterFailure>, routeOptions: RouteOptions) {
                    sendEvent(MapBoxEvents.ROUTE_BUILD_FAILED)
                }

                override fun onRoutesReady(routes: List<NavigationRoute>, routerOrigin: String) {
                    if (routes.isEmpty()) {
                        sendEvent(MapBoxEvents.ROUTE_BUILD_NO_ROUTES_FOUND)
                        return
                    }
                    sendEvent(
                        MapBoxEvents.ROUTE_BUILT,
                        Gson().toJson(routes.map { it.directionsRoute.toJson() })
                    )
                    setRouteAndStartNavigation(routes)
                }
            }
        )
    }

    @SuppressLint("MissingPermission")
    private fun setRouteAndStartNavigation(routes: List<NavigationRoute>) {
        val mapboxNavigation = MapboxNavigationApp.current() ?: return
        if (FlutterMapboxNavigationPlugin.simulateRoute) {
            mapboxNavigation.startReplayTripSession()
            mapboxNavigation.setNavigationRoutes(routes)
            startReplay(routes.first())
        } else {
            mapboxNavigation.startTripSession()
            mapboxNavigation.setNavigationRoutes(routes)
        }
        isNavigationInProgress = true
        navigationUi.showGuidanceUi()
        sendEvent(MapBoxEvents.NAVIGATION_RUNNING)
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
        mapboxNavigation.registerRouteProgressObserver(replayProgressObserver)
    }

    private fun onMapLongClick(point: Point) {
        ifNonNull(lastLocation) {
            val set = WaypointSet()
            set.add(Waypoint(Point.fromLngLat(it.longitude, it.latitude)))
            set.add(Waypoint(point))
            requestRoutes(set)
        }
    }

    private val replayProgressObserver by lazy {
        ReplayProgressObserver(MapboxNavigationApp.current()!!.mapboxReplayer)
    }

    private val routeProgressObserver = RouteProgressObserver { routeProgress ->
        navigationUi.onRouteProgress(routeProgress)
        val progressEvent = MapBoxRouteProgressEvent(routeProgress)
        FlutterMapboxNavigationPlugin.distanceRemaining = routeProgress.distanceRemaining
        FlutterMapboxNavigationPlugin.durationRemaining = routeProgress.durationRemaining
        sendEvent(progressEvent)
    }

    private val arrivalObserver: ArrivalObserver = object : ArrivalObserver {
        override fun onFinalDestinationArrival(routeProgress: RouteProgress) {
            isNavigationInProgress = false
            sendEvent(MapBoxEvents.ON_ARRIVAL)
        }

        override fun onNextRouteLegStart(routeLegProgress: RouteLegProgress) {}

        override fun onWaypointArrival(routeProgress: RouteProgress) {}
    }

    private val locationObserver = object : LocationObserver {
        override fun onNewLocationMatcherResult(locationMatcherResult: LocationMatcherResult) {
            lastLocation = locationMatcherResult.enhancedLocation
            navigationUi.onLocationMatcherResult(locationMatcherResult)
        }

        override fun onNewRawLocation(rawLocation: Location) {
            // no impl
        }
    }

    private val voiceInstructionObserver = VoiceInstructionsObserver { voiceInstructions ->
        if (FlutterMapboxNavigationPlugin.voiceInstructionsEnabled) {
            navigationUi.playVoiceInstruction(voiceInstructions)
        }
        sendEvent(MapBoxEvents.SPEECH_ANNOUNCEMENT, voiceInstructions.announcement().toString())
    }

    private val offRouteObserver = OffRouteObserver { offRoute ->
        if (offRoute) {
            sendEvent(MapBoxEvents.USER_OFF_ROUTE)
        }
    }

    private val routesObserver = RoutesObserver { routeUpdateResult ->
        navigationUi.onRoutesChanged(routeUpdateResult.navigationRoutes)
        if (routeUpdateResult.navigationRoutes.isNotEmpty()) {
            sendEvent(MapBoxEvents.REROUTE_ALONG)
        }
    }
}
