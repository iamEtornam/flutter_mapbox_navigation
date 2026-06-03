# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`flutter_mapbox_navigation` is a Flutter **plugin package** that adds turn-by-turn navigation to Flutter apps via the Mapbox Navigation SDK. It is published to pub.dev; the `example/` app is the integration harness. Only **Android** and **iOS** are active platforms — the `linux/`, `macos/`, `windows/`, and web (`flutter_mapbox_navigation_web.dart`) scaffolds are present but commented out in `pubspec.yaml` and not wired up.

## Commands

Run plugin-level analysis/tests from the repo root; run/build the app from `example/`.

```bash
flutter pub get                      # repo root — fetch plugin deps
flutter analyze                      # lint (very_good_analysis + flutter_lints)
flutter test                         # run all Dart tests
flutter test test/flutter_mapbox_navigation_method_channel_test.dart   # single test file
flutter test --plain-name "getPlatformVersion"                        # single test by name

cd example && flutter pub get
cd example && flutter run            # run example app on a connected device/simulator
cd example && flutter build apk      # / flutter build ios
```

### Required Mapbox secrets (builds fail without them)

- **Android**: `android/build.gradle` throws a `GradleException` at configure time if `MAPBOX_DOWNLOADS_TOKEN` (a secret token with `downloads:read` scope) is missing. Set it in `~/.gradle/gradle.properties` or as an env var. The runtime/public token goes in `android/app/src/main/res/values/mapbox_access_token.xml` in the consuming app.
- **iOS**: the same `downloads:read` token goes in `~/.netrc` (CocoaPods reads it to fetch Mapbox binaries). The public token goes in the app's Info.plist as `MBXAccessToken`.

Consuming-app setup (FlutterFragmentActivity requirement, manifest permissions, kotlin-bom, etc.) lives in `README.md` — consult it before debugging integration failures.

## Architecture

The plugin exposes **two parallel navigation surfaces**, each with its own Dart entry point and its own native channels:

### 1. Full-screen navigation — `MapBoxNavigation.instance` (singleton)

Launches the Mapbox UI in a native Activity (Android) / ViewController (iOS) on top of the Flutter app. Follows the standard federated-plugin pattern:

- `lib/src/flutter_mapbox_navigation.dart` — public singleton API (`startNavigation`, `startFreeDrive`, `finishNavigation`, `addWayPoints`, `registerRouteEventListener`, distance/duration getters). Holds the `_defaultOptions` used when a call omits options.
- `lib/src/flutter_mapbox_navigation_platform_interface.dart` — abstract `PlatformInterface` (uses `plugin_platform_interface` token verification). All methods throw `UnimplementedError` by default.
- `lib/src/flutter_mapbox_navigation_method_channel.dart` — the only concrete platform impl. Talks over the **fixed-name** channels `flutter_mapbox_navigation` (methods) and `flutter_mapbox_navigation/events` (route event stream).

### 2. Embedded navigation view — `MapBoxNavigationView` widget

A platform view embedded in the widget tree (Android Hybrid Composition via `PlatformViewLink`/`initExpensiveAndroidView`; iOS `UiKitView`). Bypasses the platform-interface entirely:

- `lib/src/embedded/view.dart` — `StatelessWidget` registered as platform view type `FlutterMapboxNavigationView`. On creation it hands back a controller via the `onCreated` callback.
- `lib/src/embedded/controller.dart` — `MapBoxNavigationViewController`, one per embedded view instance. Channels are **id-scoped**: `flutter_mapbox_navigation/$id` and `flutter_mapbox_navigation/$id/events`, where `$id` is the platform view id. Methods include `buildRoute`, `clearRoute`, `startNavigation`, `startFreeDrive`, `finishNavigation`.

When adding a capability, decide which surface it belongs to — the two do **not** share channels or code paths, so a feature often needs implementing in both (singleton + embedded) plus both native sides.

### Event flow (native → Dart)

Native sends route events as **JSON strings** over the event channel. Both `_parseRouteEvent` implementations (method-channel and embedded controller) decode the JSON, then branch on `RouteProgressEvent.isProgressEvent`: if true it's wrapped as a `MapBoxEvent.progress_change`, otherwise parsed as a generic `RouteEvent` (route building, navigation lifecycle, arrival, etc.). Event/enum definitions live in `lib/src/models/`. Keep the JSON key names in the native serializers in lockstep with the Dart `fromJson`/`toMap` methods — there is no shared schema, so a renamed key silently breaks parsing.

### Models

`lib/src/models/models.dart` is the barrel export. `options.dart` (`MapBoxOptions.toMap()`) is the canonical config payload sent to native for every navigation/build call and as `creationParams` for the embedded view. `way_point.dart` waypoints are serialized to maps with capitalized keys (`Order`, `Name`, `Latitude`, `Longitude`, `IsSilent`) and passed as an index-keyed map (`{0: {...}, 1: {...}}`) — match this shape on the native side.

### Native layout

- **Android** (`android/src/main/kotlin/dev/etornam/mapboxnavigation/`): `FlutterMapboxNavigationPlugin.kt` is the registrar/`MethodCallHandler` for the singleton API and holds global config in a `companion object`. `TurnByTurn.kt` backs the embedded view's id-scoped channels. `activity/NavigationActivity.kt` + `NavigationLauncher.java` drive full-screen nav; `factory/EmbeddedNavigationViewFactory.kt` + `models/views/EmbeddedNavigationMapView.kt` back the embedded view. **Navigation SDK v3** (`com.mapbox.navigationcore:android` `3.23.1`, Maps SDK v11) — the Drop-In `NavigationView` was removed, so the turn-by-turn UI is assembled from components in `utilities/NavigationUi.kt` (route line, arrow, camera, maneuver, trip progress, voice) and rendered via observers. Access token is read from `MapboxOptions`/`R.string.mapbox_access_token` (not `NavigationOptions.Builder`). Kotlin `1.9.24`, AGP `8.6`, Gradle `8.7`, JDK 17, compile/target SDK 34, minSdk 21, NDK 23. The example's Android project uses the declarative Flutter Gradle plugins DSL (`settings.gradle` `plugins {}` block).
- **iOS** (`ios/flutter_mapbox_navigation/Sources/flutter_mapbox_navigation/`): distributed as a **Swift Package** (`ios/flutter_mapbox_navigation/Package.swift`) because Mapbox Navigation SDK v3 is SPM-only — consuming apps must run `flutter config --enable-swift-package-manager`; the `.podspec` is a vestigial shell. `FlutterMapboxNavigationPlugin.swift` registers channels; the bulk of logic is in its superclass `NavigationFactory.swift`. `EmbeddedNavigationView.swift` + `NavigationViewFactory.swift` back the embedded view. **Navigation SDK v3** (`MapboxNavigationCore` + `MapboxNavigationUIKit` `~> 3.24` from `mapbox-navigation-ios`, `MapboxMaps` v11 from `mapbox-maps-ios`), iOS min `14.0`. A single shared `MapboxNavigationProvider` is held in `NavigationProvider.swift` (v3 forbids multiple instances); routing uses `routingProvider().calculateRoutes` → `NavigationRoutes`, progress comes from the `navigation().routeProgress` Combine publisher. The classes are `@MainActor`-isolated (v3 APIs require it), and `Typealiases.swift` disambiguates names re-exported by both `MapboxDirections` and `MapboxNavigationCore`.

## Conventions

- Lint config is `very_good_analysis` (strict) layered via `analysis_options.yaml`; `flutter analyze` should stay clean. Public Dart members carry `///` doc comments — keep that up.
- Argument validation on the Dart side uses `assert` (waypoint count ≥ 2, iOS drivingWithTraffic ≤ 3 stops, non-null waypoint fields). These only fire in debug builds.
- Bump `version` in **both** `pubspec.yaml` and `ios/flutter_mapbox_navigation.podspec` together, and add a `CHANGELOG.md` entry (entries reference the merged PR number).
