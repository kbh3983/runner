import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../data/models/gps_point.dart';
import '../theme/app_theme.dart';

/// 경로 세그먼트 (페이스별 색상 지정)
class ColoredSegment {
  final List<LatLng> points;
  final Color color;
  final double? paceSec;

  const ColoredSegment({
    required this.points,
    required this.color,
    this.paceSec,
  });
}

/// 러닝 경로 스무딩(지터 제거/직선 보정) 및 페이스별 색상 계산 유틸
class RouteSmoother {
  RouteSmoother._();

  // ------------------------------------------------------------ 페이스 컬러 맵핑

  /// 페이스(sec/km)에 대응하는 색상 반환.
  /// - 느림 (8:00+): 웜 오렌지/앰버 계열
  /// - 보통 (6:00~7:00): 형광 옐로우 / 라임
  /// - 빠름 (4:30~5:30): 밝고 선명한 네온 그린
  /// - 매우 빠름 (4:00 이하): 강렬하고 짙은 네온 에메랄드/시안
  static Color paceColor(
    double paceSec, {
    double minPace = 240, // 4:00 /km (빠름)
    double maxPace = 480, // 8:00 /km (느림)
  }) {
    if (paceSec <= 0) return AppColors.neon;

    // t: 0.0 (매우 느림) ~ 1.0 (매우 빠름)
    final t = ((maxPace - paceSec) / (maxPace - minPace)).clamp(0.0, 1.0);

    // 5단계 컬러 램프 (사진의 히트맵 팔레트)
    // 0.0: 오렌지 (#FF9800)
    // 0.3: 골드 옐로우 (#FFD600)
    // 0.6: 형광 라임 (#CCFF00)
    // 0.85: 비비드 네온 그린 (#00E676)
    // 1.0: 딥 네온 에메랄드 (#00B0FF or #00E5FF)
    if (t < 0.3) {
      final subT = t / 0.3;
      return Color.lerp(
        const Color(0xFFFF9100), // 오렌지
        const Color(0xFFFFD600), // 옐로우
        subT,
      )!;
    } else if (t < 0.6) {
      final subT = (t - 0.3) / 0.3;
      return Color.lerp(
        const Color(0xFFFFD600), // 옐로우
        AppColors.neon,          // 형광 라임 (0xFFCCFF00)
        subT,
      )!;
    } else if (t < 0.85) {
      final subT = (t - 0.6) / 0.25;
      return Color.lerp(
        AppColors.neon,          // 형광 라임
        const Color(0xFF00E676), // 비비드 그린
        subT,
      )!;
    } else {
      final subT = (t - 0.85) / 0.15;
      return Color.lerp(
        const Color(0xFF00E676), // 비비드 그린
        const Color(0xFF00E5FF), // 딥 네온 시안/에메랄드
        subT,
      )!;
    }
  }

  // ------------------------------------------------------------ GPS 노이즈/지터 스무딩

  /// 3점 가중 이동 평균(Weighted Moving Average: 0.2, 0.6, 0.2)으로
  /// GPS 좌우 흔들림(jitter)을 완화하여 직선 구간을 곧게 펴줍니다.
  static List<LatLng> smoothPoints(List<LatLng> points, {int passes = 1}) {
    if (points.length < 3) return List.of(points);

    var current = List.of(points);
    for (var pass = 0; pass < passes; pass++) {
      final smoothed = <LatLng>[current.first];
      for (var i = 1; i < current.length - 1; i++) {
        final prev = current[i - 1];
        final curr = current[i];
        final next = current[i + 1];

        final lat = prev.latitude * 0.2 + curr.latitude * 0.6 + next.latitude * 0.2;
        final lng = prev.longitude * 0.2 + curr.longitude * 0.6 + next.longitude * 0.2;
        smoothed.add(LatLng(lat, lng));
      }
      smoothed.add(current.last);
      current = smoothed;
    }
    return current;
  }

  /// Chaikin 코너 커팅 알고리즘:
  /// 각 선분의 25%와 75% 지점을 이어 뾰족하고 거친 코너를 자연스럽고 매끄럽게 곡선화합니다.
  static List<LatLng> chaikinSmooth(List<LatLng> points) {
    if (points.length < 3) return List.of(points);

    final result = <LatLng>[points.first];
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];

      // Q = 0.75 * P0 + 0.25 * P1
      final qLat = 0.75 * p0.latitude + 0.25 * p1.latitude;
      final qLng = 0.75 * p0.longitude + 0.25 * p1.longitude;

      // R = 0.25 * P0 + 0.75 * P1
      final rLat = 0.25 * p0.latitude + 0.75 * p1.latitude;
      final rLng = 0.25 * p0.longitude + 0.75 * p1.longitude;

      result.add(LatLng(qLat, qLng));
      result.add(LatLng(rLat, rLng));
    }
    result.add(points.last);
    return result;
  }

  // ------------------------------------------------------------ 페이스별 세그먼트 생성

  /// GpsPoint 리스트로부터 페이스별 멀티컬러 세그먼트를 생성합니다.
  /// 인접 포인트의 페이스 색상이 유사하면 하나로 묶어(chunking) Google Maps 렌더링 성능을 극대화합니다.
  static List<ColoredSegment> buildFromGpsPoints(
    List<GpsPoint> points, {
    bool smooth = true,
  }) {
    if (points.isEmpty) return const [];
    if (points.length < 2) {
      return [
        ColoredSegment(
          points: [points.first.latLng],
          color: AppColors.neon,
          paceSec: points.first.pace,
        ),
      ];
    }

    // 1) 전체 페이스의 최소/최대값 파악 (유효한 페이스만)
    final validPaces = points
        .map((p) => p.pace)
        .whereType<double>()
        .where((p) => p >= 120 && p <= 720) // 2:00 ~ 12:00
        .toList();

    double minP = 240; // 4:00 기본
    double maxP = 480; // 8:00 기본
    if (validPaces.length >= 5) {
      validPaces.sort();
      // 상하위 5% 이상치 제외
      final lowIdx = (validPaces.length * 0.05).floor();
      final highIdx = (validPaces.length * 0.95).floor();
      minP = validPaces[lowIdx];
      maxP = validPaces[highIdx];
      if (maxP - minP < 60) maxP = minP + 60; // 최소 1분 차이 확보
    }

    // 2) 세그먼트별 그룹화 (일시정지 구간 구분)
    final segmentsByPause = <int, List<GpsPoint>>{};
    for (final p in points) {
      segmentsByPause.putIfAbsent(p.segment, () => []).add(p);
    }

    final result = <ColoredSegment>[];

    for (final segPoints in segmentsByPause.values) {
      if (segPoints.length < 2) continue;

      // 스무딩 처리 (선택적)
      final rawCoords = segPoints.map((p) => p.latLng).toList();
      final smoothedCoords = smooth ? smoothPoints(rawCoords, passes: 2) : rawCoords;

      // 각 포인트 페이스 색상 인덱스 (0 ~ 7 등급)
      const numBuckets = 8;
      int getBucket(double? pace) {
        if (pace == null || pace <= 0) return numBuckets ~/ 2;
        final t = ((maxP - pace) / (maxP - minP)).clamp(0.0, 1.0);
        return (t * (numBuckets - 1)).round();
      }

      var currentBucket = getBucket(segPoints.first.pace);
      var currentChunk = <LatLng>[smoothedCoords.first];
      var paceSum = segPoints.first.pace ?? 360.0;
      var paceCount = 1;

      for (var i = 1; i < segPoints.length; i++) {
        final b = getBucket(segPoints[i].pace);
        final coord = smoothedCoords[i];

        if (b != currentBucket && currentChunk.length >= 2) {
          // 이전 청크 마무리 (선 끊김 방지를 위해 현재 좌표를 이전 청크 끝에도 포함)
          currentChunk.add(coord);
          final avgPace = paceSum / paceCount;
          result.add(ColoredSegment(
            points: List.of(currentChunk),
            color: paceColor(avgPace, minPace: minP, maxPace: maxP),
            paceSec: avgPace,
          ));

          // 새 청크 시작
          currentChunk = [coord];
          currentBucket = b;
          paceSum = segPoints[i].pace ?? 360.0;
          paceCount = 1;
        } else {
          currentChunk.add(coord);
          if (segPoints[i].pace != null) {
            paceSum += segPoints[i].pace!;
            paceCount++;
          }
        }
      }

      if (currentChunk.length >= 2) {
        final avgPace = paceSum / paceCount;
        result.add(ColoredSegment(
          points: currentChunk,
          color: paceColor(avgPace, minPace: minP, maxPace: maxP),
          paceSec: avgPace,
        ));
      }
    }

    return result;
  }

  /// 단순 좌표 리스트(GpsPoint가 없을 때)에서도 지터 스무딩 후 단일/그라데이션 세그먼트로 변환
  static List<List<LatLng>> smoothCoordinateSegments(
    List<List<LatLng>> rawSegments, {
    bool applyChaikin = false,
  }) {
    final result = <List<LatLng>>[];
    for (final seg in rawSegments) {
      if (seg.length < 3) {
        result.add(List.of(seg));
        continue;
      }
      var smoothed = smoothPoints(seg, passes: 2);
      if (applyChaikin && smoothed.length < 500) {
        smoothed = chaikinSmooth(smoothed);
      }
      result.add(smoothed);
    }
    return result;
  }
}
