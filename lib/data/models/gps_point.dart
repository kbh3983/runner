import 'package:google_maps_flutter/google_maps_flutter.dart';

/// GPS 원본 포인트 (Local DB 전용, 서버로 그대로 올리지 않음)
class GpsPoint {
  final String runId;
  final int seq;
  final double lat;
  final double lng;
  final int ts; // epoch ms
  final double? speed; // m/s
  final double? altitude;
  final double? accuracy;
  final double distance; // 누적 거리 (m)
  final double? pace; // 현재 페이스 sec/km
  final int segment; // 일시정지마다 +1
  final int elapsedMs; // 이동시간

  const GpsPoint({
    required this.runId,
    required this.seq,
    required this.lat,
    required this.lng,
    required this.ts,
    this.speed,
    this.altitude,
    this.accuracy,
    required this.distance,
    this.pace,
    required this.segment,
    required this.elapsedMs,
  });

  LatLng get latLng => LatLng(lat, lng);

  Map<String, Object?> toRow() => {
        'run_id': runId,
        'seq': seq,
        'lat': lat,
        'lng': lng,
        'ts': ts,
        'speed': speed,
        'altitude': altitude,
        'accuracy': accuracy,
        'distance': distance,
        'pace': pace,
        'segment': segment,
        'elapsed_ms': elapsedMs,
      };

  factory GpsPoint.fromRow(Map<String, Object?> r) => GpsPoint(
        runId: r['run_id'] as String,
        seq: r['seq'] as int,
        lat: (r['lat'] as num).toDouble(),
        lng: (r['lng'] as num).toDouble(),
        ts: r['ts'] as int,
        speed: (r['speed'] as num?)?.toDouble(),
        altitude: (r['altitude'] as num?)?.toDouble(),
        accuracy: (r['accuracy'] as num?)?.toDouble(),
        distance: (r['distance'] as num).toDouble(),
        pace: (r['pace'] as num?)?.toDouble(),
        segment: r['segment'] as int,
        elapsedMs: r['elapsed_ms'] as int,
      );
}

class RunPhoto {
  final String id;
  final String runId;
  final String relPath; // Documents 기준 상대경로
  final int createdAt;

  const RunPhoto({required this.id, required this.runId, required this.relPath, required this.createdAt});

  Map<String, Object?> toRow() => {'id': id, 'run_id': runId, 'rel_path': relPath, 'created_at': createdAt};

  factory RunPhoto.fromRow(Map<String, Object?> r) => RunPhoto(
        id: r['id'] as String,
        runId: r['run_id'] as String,
        relPath: r['rel_path'] as String,
        createdAt: r['created_at'] as int,
      );
}

class RunMemo {
  final String id;
  final String runId;
  final String text;
  final int createdAt;

  const RunMemo({required this.id, required this.runId, required this.text, required this.createdAt});

  Map<String, Object?> toRow() => {'id': id, 'run_id': runId, 'text': text, 'created_at': createdAt};

  Map<String, dynamic> toRemote() => {'id': id, 'text': text, 'createdAt': createdAt};

  factory RunMemo.fromRow(Map<String, Object?> r) => RunMemo(
        id: r['id'] as String,
        runId: r['run_id'] as String,
        text: r['text'] as String,
        createdAt: r['created_at'] as int,
      );
}
