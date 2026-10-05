import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// 위치/경로 관련 순수 함수.
class Geo {
  Geo._();

  static const _earthRadius = 6371000.0;

  static double distance(double lat1, double lng1, double lat2, double lng2) {
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * _earthRadius * math.asin(math.min(1, math.sqrt(a)));
  }

  static double distanceLatLng(LatLng a, LatLng b) =>
      distance(a.latitude, a.longitude, b.latitude, b.longitude);

  static double _rad(double d) => d * math.pi / 180;

  static LatLngBounds? bounds(Iterable<LatLng> points) {
    double? minLat, maxLat, minLng, maxLng;
    for (final p in points) {
      minLat = minLat == null ? p.latitude : math.min(minLat, p.latitude);
      maxLat = maxLat == null ? p.latitude : math.max(maxLat, p.latitude);
      minLng = minLng == null ? p.longitude : math.min(minLng, p.longitude);
      maxLng = maxLng == null ? p.longitude : math.max(maxLng, p.longitude);
    }
    if (minLat == null) return null;
    // 한 점뿐이면 약간 넓혀준다.
    if ((maxLat! - minLat).abs() < 0.0005 && (maxLng! - minLng!).abs() < 0.0005) {
      minLat -= 0.001;
      maxLat += 0.001;
      minLng -= 0.001;
      maxLng += 0.001;
    }
    return LatLngBounds(
      southwest: LatLng(minLat, minLng!),
      northeast: LatLng(maxLat, maxLng!),
    );
  }

  // ---------------- Google encoded polyline ----------------

  static String encodePolyline(List<LatLng> points) {
    final sb = StringBuffer();
    var lastLat = 0, lastLng = 0;
    for (final p in points) {
      final lat = (p.latitude * 1e5).round();
      final lng = (p.longitude * 1e5).round();
      _encodeValue(lat - lastLat, sb);
      _encodeValue(lng - lastLng, sb);
      lastLat = lat;
      lastLng = lng;
    }
    return sb.toString();
  }

  static void _encodeValue(int v, StringBuffer sb) {
    var value = v < 0 ? ~(v << 1) : (v << 1);
    while (value >= 0x20) {
      sb.writeCharCode((0x20 | (value & 0x1f)) + 63);
      value >>= 5;
    }
    sb.writeCharCode(value + 63);
  }

  static List<LatLng> decodePolyline(String encoded) {
    final points = <LatLng>[];
    var index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      lat += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20 && index < encoded.length);
      lng += (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }

  /// 구간 리스트를 [breaks] 인덱스 기준으로 나눈다.
  static List<List<LatLng>> splitByBreaks(List<LatLng> points, List<int> breaks) {
    if (points.isEmpty) return [];
    final sorted = [...breaks]..sort();
    final result = <List<LatLng>>[];
    var start = 0;
    for (final b in sorted) {
      if (b <= start || b >= points.length) continue;
      result.add(points.sublist(start, b));
      start = b;
    }
    result.add(points.sublist(start));
    return result.where((s) => s.isNotEmpty).toList();
  }
}
