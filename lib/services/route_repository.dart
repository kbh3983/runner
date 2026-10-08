import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../core/geo.dart';
import '../core/route_smoother.dart';
import '../data/local/local_db.dart';
import '../data/models/gps_point.dart';
import '../data/models/run_record.dart';

/// 러닝 경로 및 마커 조회:
/// 로컬 GPS 원본이 있으면 그것을, 없으면(서버에서 복원된 기록) 다운샘플 경로 사용.
/// 페이스별 세그먼트 생성 및 1km, 2km 분할 지점 계산 제공.
class RouteRepository {
  RouteRepository._();

  /// 기본 단순 좌표 세그먼트 (스무딩 옵션 지원)
  static Future<List<List<LatLng>>> segmentsFor(RunRecord run, {bool smooth = true}) async {
    final pts = await pointsFor(run);
    if (pts.isNotEmpty) {
      final result = <List<LatLng>>[];
      int? seg;
      for (final p in pts) {
        if (p.segment != seg) {
          result.add([]);
          seg = p.segment;
        }
        result.last.add(p.latLng);
      }
      return smooth ? RouteSmoother.smoothCoordinateSegments(result) : result;
    }
    final raw = run.remotePath?.segments ?? [];
    return smooth ? RouteSmoother.smoothCoordinateSegments(raw) : raw;
  }

  /// 로컬 DB의 상세 GpsPoint 목록 조회
  static Future<List<GpsPoint>> pointsFor(RunRecord run) async {
    return await LocalDb.instance.getPoints(run.id);
  }

  /// 페이스별 색상이 입혀진 세그먼트 목록 조회 (히트맵 폴리라인)
  static Future<List<ColoredSegment>> coloredSegmentsFor(
    RunRecord run, {
    bool smooth = true,
  }) async {
    final pts = await pointsFor(run);
    if (pts.isNotEmpty) {
      return RouteSmoother.buildFromGpsPoints(pts, smooth: smooth);
    }

    // GpsPoint가 없는 경우(원격 다운샘플 기록 등)에는 기본 단색 세그먼트로 구성
    final segs = run.remotePath?.segments ?? [];
    final smoothed = smooth ? RouteSmoother.smoothCoordinateSegments(segs) : segs;
    final fallbackColor = RouteSmoother.paceColor(run.avgPaceSecPerKm ?? 360.0);
    return smoothed
        .map((s) => ColoredSegment(points: s, color: fallbackColor))
        .toList();
  }

  /// 1km, 2km 등 각 km 지점의 좌표(LatLng) 맵 반환 (key: km 번호)
  static Future<Map<int, LatLng>> extractKmPositions(
    RunRecord run, {
    List<GpsPoint>? cachedPoints,
  }) async {
    final result = <int, LatLng>{};

    // 1) KmSplit에 이미 좌표가 있는 경우 우선 사용
    for (final s in run.splits) {
      if (s.lat != null && s.lng != null) {
        result[s.km] = LatLng(s.lat!, s.lng!);
      }
    }

    // 모든 split에 좌표가 있다면 바로 반환
    if (result.length == run.splits.length && result.isNotEmpty) {
      return result;
    }

    // 2) GpsPoint에서 누적 거리를 기준으로 각 km 지점 보간
    final pts = cachedPoints ?? await pointsFor(run);
    if (pts.isNotEmpty) {
      final totalKm = (run.distanceM / 1000).floor();
      for (var km = 1; km <= totalKm; km++) {
        if (result.containsKey(km)) continue;
        final targetM = km * 1000.0;

        // targetM 직전 점과 직후 점 찾기
        int nextIdx = -1;
        for (var i = 0; i < pts.length; i++) {
          if (pts[i].distance >= targetM) {
            nextIdx = i;
            break;
          }
        }

        if (nextIdx > 0) {
          final p0 = pts[nextIdx - 1];
          final p1 = pts[nextIdx];
          final span = p1.distance - p0.distance;
          final frac = span > 0 ? ((targetM - p0.distance) / span).clamp(0.0, 1.0) : 0.0;
          final lat = p0.lat + (p1.lat - p0.lat) * frac;
          final lng = p0.lng + (p1.lng - p0.lng) * frac;
          result[km] = LatLng(lat, lng);
        } else if (nextIdx == 0) {
          result[km] = pts.first.latLng;
        }
      }
      return result;
    }

    // 3) remotePath에서 누적 거리 계산하여 보간 (최후의 수단)
    final segs = run.remotePath?.segments ?? [];
    if (segs.isNotEmpty) {
      final allPoints = segs.expand((s) => s).toList();
      if (allPoints.length >= 2) {
        var dist = 0.0;
        final dists = <double>[0.0];
        for (var i = 1; i < allPoints.length; i++) {
          dist += Geo.distanceLatLng(allPoints[i - 1], allPoints[i]);
          dists.add(dist);
        }

        final totalKm = (dist / 1000).floor();
        for (var km = 1; km <= totalKm; km++) {
          if (result.containsKey(km)) continue;
          final targetM = km * 1000.0;
          for (var i = 1; i < dists.length; i++) {
            if (dists[i] >= targetM) {
              final frac = (targetM - dists[i - 1]) / (dists[i] - dists[i - 1]);
              final p0 = allPoints[i - 1];
              final p1 = allPoints[i];
              final lat = p0.latitude + (p1.latitude - p0.latitude) * frac;
              final lng = p0.longitude + (p1.longitude - p0.longitude) * frac;
              result[km] = LatLng(lat, lng);
              break;
            }
          }
        }
      }
    }

    return result;
  }
}
