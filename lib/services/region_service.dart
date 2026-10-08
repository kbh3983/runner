import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../data/local/local_db.dart';
import '../data/models/run_record.dart';
import 'weather_service.dart';

/// GPS 좌표 → 한국어 지역명(역지오코딩) 변환 및 러닝 기록 지역 저장 서비스
class RegionService {
  RegionService._();
  static final RegionService instance = RegionService._();

  final Map<String, String> _cache = {};
  bool _backfilling = false;

  /// 날씨 서비스에서 이미 가져온 현재 지역명이 있다면 최우선 재사용 (네트워크 호출 0회)
  String? get cachedWeatherRegion {
    final reg = WeatherService.instance.state.value.info?.region;
    if (reg != null && reg.isNotEmpty) return reg;
    return null;
  }

  /// 좌표(lat, lng)로부터 "서울시 마포구", "성남시 분당구" 형태의 지역명 반환
  Future<String?> getRegion(double lat, double lng) async {
    // 소수점 2자리(약 1km 그리드) 기준 캐시 키
    final key = '${lat.toStringAsFixed(2)},${lng.toStringAsFixed(2)}';
    if (_cache.containsKey(key)) return _cache[key];

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat': '$lat',
        'lon': '$lng',
        'format': 'jsonv2',
        'zoom': '14',
        'accept-language': 'ko',
      });
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'RunTogetherApp/1.0');
      final res = await req.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final a = j['address'] as Map<String, dynamic>?;
      if (a == null) return null;

      // 시/도/군
      final city = a['city'] ?? a['town'] ?? a['county'] ?? a['province'] ?? a['state'];
      // 구/군/동/읍/면
      final district = a['suburb'] ??
          a['city_district'] ??
          a['quarter'] ??
          a['neighbourhood'] ??
          a['borough'] ??
          a['village'];

      final parts = <String>[
        if (city != null) '$city',
        if (district != null && district != city) '$district',
      ];

      if (parts.isNotEmpty) {
        final regionStr = parts.join(' ');
        _cache[key] = regionStr;
        return regionStr;
      }
    } catch (e) {
      debugPrint('RegionService reverse geocode error: $e');
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// 특정 러닝의 좌표를 찾아 지역명을 채우고 DB에 갱신
  Future<String?> resolveAndSaveRegion(RunRecord run, {LatLng? fallbackPos}) async {
    if (run.region != null && run.region!.isNotEmpty) return run.region;

    // 현재 러닝 완료 직후이고 날씨 캐시 지역이 있다면 최우선 즉시 저장 (네트워크 0회)
    if (fallbackPos != null && cachedWeatherRegion != null) {
      run.region = cachedWeatherRegion;
      await LocalDb.instance.upsertRun(run, notify: true);
      return run.region;
    }

    double? lat = fallbackPos?.latitude;
    double? lng = fallbackPos?.longitude;

    if (lat == null || lng == null) {
      final pts = await LocalDb.instance.getPoints(run.id);
      if (pts.isNotEmpty) {
        lat = pts.first.lat;
        lng = pts.first.lng;
      } else if (run.remotePath != null && run.remotePath!.points.isNotEmpty) {
        lat = run.remotePath!.points.first.latitude;
        lng = run.remotePath!.points.first.longitude;
      }
    }

    if (lat == null || lng == null) return null;

    final reg = await getRegion(lat, lng);
    if (reg != null && reg.isNotEmpty) {
      run.region = reg;
      await LocalDb.instance.upsertRun(run, notify: true);
      return reg;
    }
    return null;
  }

  /// 과거 러닝 기록 중 region이 없는 기록들을 백그라운드에서 순차적으로 채움
  Future<void> backfillMissingRegions() async {
    if (_backfilling) return;
    _backfilling = true;
    try {
      final runs = await LocalDb.instance.getAllRuns();
      final targets = runs.where((r) => r.region == null || r.region!.isEmpty).toList();
      for (final r in targets) {
        await resolveAndSaveRegion(r);
        // 과도한 API 호출 방지를 위한 미세 지연
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      debugPrint('Region backfill error: $e');
    } finally {
      _backfilling = false;
    }
  }
}
