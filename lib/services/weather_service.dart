import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// 미세먼지 등급 (한국 환경부 기준)
enum DustGrade { good, normal, bad, veryBad }

extension DustGradeX on DustGrade {
  String get label => switch (this) {
    DustGrade.good => '좋음',
    DustGrade.normal => '보통',
    DustGrade.bad => '나쁨',
    DustGrade.veryBad => '매우 나쁨',
  };

  static DustGrade pm10(double v) {
    if (v <= 30) return DustGrade.good;
    if (v <= 80) return DustGrade.normal;
    if (v <= 150) return DustGrade.bad;
    return DustGrade.veryBad;
  }

  static DustGrade pm25(double v) {
    if (v <= 15) return DustGrade.good;
    if (v <= 35) return DustGrade.normal;
    if (v <= 75) return DustGrade.bad;
    return DustGrade.veryBad;
  }
}

class WeatherInfo {
  const WeatherInfo({
    required this.region,
    required this.tempC,
    required this.feelsLikeC,
    required this.humidity,
    required this.windMps,
    required this.weatherCode,
    required this.rainProbability,
    required this.pm10,
    required this.pm25,
    required this.fetchedAt,
  });

  final String? region;
  final double tempC;
  final double feelsLikeC;
  final int humidity;
  final double windMps;
  final int weatherCode;
  final int? rainProbability;
  final double? pm10;
  final double? pm25;
  final DateTime fetchedAt;

  DustGrade? get pm10Grade => pm10 == null ? null : DustGradeX.pm10(pm10!);
  DustGrade? get pm25Grade => pm25 == null ? null : DustGradeX.pm25(pm25!);

  /// 둘 중 더 나쁜 미세먼지 등급
  DustGrade? get worstDust {
    final a = pm10Grade, b = pm25Grade;
    if (a == null) return b;
    if (b == null) return a;
    return a.index >= b.index ? a : b;
  }

  /// WMO weather code → (이모지, 설명)
  (String, String) get condition {
    final c = weatherCode;
    if (c == 0) return ('☀️', '맑음');
    if (c == 1) return ('🌤️', '대체로 맑음');
    if (c == 2) return ('⛅', '구름 조금');
    if (c == 3) return ('☁️', '흐림');
    if (c == 45 || c == 48) return ('🌫️', '안개');
    if (c >= 51 && c <= 57) return ('🌦️', '이슬비');
    if (c >= 61 && c <= 67) return ('🌧️', '비');
    if (c >= 71 && c <= 77) return ('🌨️', '눈');
    if (c >= 80 && c <= 82) return ('🌦️', '소나기');
    if (c == 85 || c == 86) return ('🌨️', '눈 소나기');
    if (c >= 95) return ('⛈️', '뇌우');
    return ('🌡️', '-');
  }

  bool get isRaining =>
      (weatherCode >= 51 && weatherCode <= 67) ||
      (weatherCode >= 80 && weatherCode <= 82) ||
      weatherCode >= 95;
  bool get isSnowing =>
      (weatherCode >= 71 && weatherCode <= 77) ||
      weatherCode == 85 ||
      weatherCode == 86;

  /// 러닝 참고 한 줄 조언
  String get advice {
    final dust = worstDust;
    if (dust == DustGrade.veryBad) return '미세먼지가 매우 나빠요. 실내 러닝(러닝머신)을 추천해요';
    if (dust == DustGrade.bad) return '미세먼지가 나빠요. 마스크 착용이나 실내 러닝을 고려해보세요';
    if (weatherCode >= 95) return '뇌우가 예상돼요. 오늘은 쉬어가는 걸 추천해요';
    if (isRaining || isSnowing) return '노면이 미끄러울 수 있어요. 조심해서 달리세요';
    if (feelsLikeC >= 30) return '많이 더워요. 수분 보충하고 무리하지 마세요';
    if (feelsLikeC <= -5) return '매우 추워요. 충분히 워밍업하고 따뜻하게 입으세요';
    if (feelsLikeC <= 5) return '쌀쌀해요. 가벼운 워밍업 후 출발하세요';
    if ((rainProbability ?? 0) >= 60) return '비 소식이 있어요. 우산 대신 가벼운 방수 재킷을 챙기세요';
    return '달리기 좋은 날씨예요. 즐거운 러닝 되세요!';
  }
}

enum WeatherStatus { idle, loading, ready, noPermission, error }

class WeatherState {
  const WeatherState(this.status, {this.info, this.message});
  final WeatherStatus status;
  final WeatherInfo? info;
  final String? message;
}

/// 현재 위치의 날씨/미세먼지 (Open-Meteo, API 키 불필요)
class WeatherService {
  WeatherService._();
  static final WeatherService instance = WeatherService._();

  static const _cacheTtl = Duration(minutes: 20);

  final ValueNotifier<WeatherState> state = ValueNotifier(
    const WeatherState(WeatherStatus.idle),
  );
  bool _loading = false;

  Future<void> refresh({bool force = false}) async {
    if (_loading) return;
    final cur = state.value;
    if (!force &&
        cur.status == WeatherStatus.ready &&
        cur.info != null &&
        DateTime.now().difference(cur.info!.fetchedAt) < _cacheTtl) {
      return;
    }
    _loading = true;
    // 기존 데이터가 있으면 깜빡임 없이 유지
    if (cur.info == null)
      state.value = const WeatherState(WeatherStatus.loading);
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        state.value = const WeatherState(
          WeatherStatus.noPermission,
          message: '위치 권한을 허용하면 날씨를 알려드려요',
        );
        return;
      }
      final pos = await _position();
      if (pos == null) {
        state.value = const WeatherState(
          WeatherStatus.error,
          message: '현재 위치를 찾지 못했어요',
        );
        return;
      }
      final results = await Future.wait([
        _getJson(
          Uri.https('api.open-meteo.com', '/v1/forecast', {
            'latitude': '${pos.latitude}',
            'longitude': '${pos.longitude}',
            'current':
                'temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m',
            'daily': 'precipitation_probability_max',
            'wind_speed_unit': 'ms',
            'forecast_days': '1',
            'timezone': 'auto',
          }),
        ),
        _getJson(
          Uri.https('air-quality-api.open-meteo.com', '/v1/air-quality', {
            'latitude': '${pos.latitude}',
            'longitude': '${pos.longitude}',
            'current': 'pm10,pm2_5',
            'timezone': 'auto',
          }),
        ).catchError((_) => <String, dynamic>{}),
        _region(pos.latitude, pos.longitude).catchError((_) => null),
      ]);
      final w = results[0] as Map<String, dynamic>;
      final aq = results[1] as Map<String, dynamic>;
      final region = results[2] as String?;
      final cw = w['current'] as Map<String, dynamic>;
      final caq = aq['current'] as Map<String, dynamic>?;
      final daily = w['daily'] as Map<String, dynamic>?;
      final rain =
          (daily?['precipitation_probability_max'] as List?)?.firstOrNull;

      state.value = WeatherState(
        WeatherStatus.ready,
        info: WeatherInfo(
          region: region,
          tempC: (cw['temperature_2m'] as num).toDouble(),
          feelsLikeC: (cw['apparent_temperature'] as num).toDouble(),
          humidity: (cw['relative_humidity_2m'] as num).round(),
          windMps: (cw['wind_speed_10m'] as num).toDouble(),
          weatherCode: (cw['weather_code'] as num).toInt(),
          rainProbability: (rain as num?)?.round(),
          pm10: (caq?['pm10'] as num?)?.toDouble(),
          pm25: (caq?['pm2_5'] as num?)?.toDouble(),
          fetchedAt: DateTime.now(),
        ),
      );
    } catch (e) {
      debugPrint('weather error: $e');
      // 이전 데이터가 있으면 유지
      if (state.value.info == null) {
        state.value = const WeatherState(
          WeatherStatus.error,
          message: '날씨 정보를 불러오지 못했어요',
        );
      }
    } finally {
      _loading = false;
    }
  }

  Future<Position?> _position() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return last;
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
        ),
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _getJson(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'RunTogetherApp/1.0');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200)
        throw HttpException('HTTP ${res.statusCode}', uri: uri);
      final body = await res.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  /// 좌표 → 동네 이름 (OpenStreetMap Nominatim)
  Future<String?> _region(double lat, double lng) async {
    final j = await _getJson(
      Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat': '$lat',
        'lon': '$lng',
        'format': 'jsonv2',
        'zoom': '14',
        'accept-language': 'ko',
      }),
    );
    final a = j['address'] as Map<String, dynamic>?;
    if (a == null) return null;
    final city =
        a['city'] ?? a['town'] ?? a['county'] ?? a['province'] ?? a['state'];
    final dong =
        a['suburb'] ??
        a['quarter'] ??
        a['neighbourhood'] ??
        a['village'] ??
        a['city_district'];
    final parts = <String>[
      if (city != null) '$city',
      if (dong != null && dong != city) '$dong',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }
}
