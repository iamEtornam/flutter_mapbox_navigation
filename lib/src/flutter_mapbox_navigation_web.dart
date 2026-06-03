// Web stub: web is not an actively supported platform. dart:html is used only
// here to read the platform version (package:web migration deferred).
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:html' as html show window;

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:mapbox_navigation_sdk/src/flutter_mapbox_navigation_platform_interface.dart';

/// A web implementation of the FlutterMapboxNavigationPlatform of the
/// FlutterMapboxNavigation plugin.
class FlutterMapboxNavigationWeb extends FlutterMapboxNavigationPlatform {
  /// Constructs a FlutterMapboxNavigationWeb
  FlutterMapboxNavigationWeb();

  /// Registers this class as the default platform implementation on web.
  static void registerWith(Registrar registrar) {
    FlutterMapboxNavigationPlatform.instance = FlutterMapboxNavigationWeb();
  }

  /// Returns a [String] containing the version of the platform.
  @override
  Future<String?> getPlatformVersion() async {
    final version = html.window.navigator.userAgent;
    return version;
  }
}
