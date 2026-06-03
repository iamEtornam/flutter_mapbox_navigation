import 'dart:convert';
import 'dart:io';

import 'package:mapbox_navigation_plus/mapbox_navigation_plus.dart';

/// Represents an event sent by the navigation service
class RouteEvent {
  /// Constructor
  RouteEvent({
    this.eventType,
    this.data,
  });

  /// Creates [RouteEvent] object from json
  RouteEvent.fromJson(Map<String, dynamic> json) {
    // Match the event name without throwing on unknown values (eventType
    // stays null for unsupported events).
    for (final value in MapBoxEvent.values) {
      if (value.toString().split('.').last == json['eventType']) {
        eventType = value;
        break;
      }
    }

    final dataJson = json['data'];
    if (eventType == MapBoxEvent.progress_change) {
      data = RouteProgressEvent.fromJson(dataJson as Map<String, dynamic>);
    } else if (eventType == MapBoxEvent.navigation_finished &&
        (dataJson as String).isNotEmpty) {
      data =
          MapBoxFeedback.fromJson(jsonDecode(dataJson) as Map<String, dynamic>);
    } else if (eventType == MapBoxEvent.on_map_tap) {
      final json =
          Platform.isAndroid ? dataJson : jsonDecode(dataJson as String);
      data = WayPoint.fromJson(json as Map<String, dynamic>);
    } else {
      data = jsonEncode(dataJson);
    }
  }

  /// Route event type
  MapBoxEvent? eventType;

  /// optional data related to route event
  dynamic data;
}
