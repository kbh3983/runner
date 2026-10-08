import 'dart:convert';

import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../core/geo.dart';

enum RunMode { solo, group, treadmill }

enum GoalType { none, distance, time }

GoalType goalTypeFrom(String? s) => GoalType.values.firstWhere(
      (e) => e.name == s,
      orElse: () => GoalType.none,
    );

/// km 지점 통과 기록
class KmSplit {
  final int km;
  final int movingMs; // 이동시간 기준 통과 시점
  final int? raceMs; // 단체 러닝 공통 출발 시각 기준 통과 시점
  final double paceSec; // 이 1km 구간 페이스 (sec/km)
  final double? lat;
  final double? lng;

  const KmSplit({
    required this.km,
    required this.movingMs,
    this.raceMs,
    required this.paceSec,
    this.lat,
    this.lng,
  });

  Map<String, dynamic> toMap() => {
        'km': km,
        'movingMs': movingMs,
        'raceMs': raceMs,
        'paceSec': paceSec,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
      };

  factory KmSplit.fromMap(Map m) => KmSplit(
        km: (m['km'] as num).toInt(),
        movingMs: (m['movingMs'] as num).toInt(),
        raceMs: (m['raceMs'] as num?)?.toInt(),
        paceSec: (m['paceSec'] as num).toDouble(),
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
      );
}

/// 시간별 페이스 계산용 샘플
class TimelineSample {
  final int t; // 이동시간 (s)
  final double d; // 누적거리 (m)
  final int? r; // race 경과 (s)

  const TimelineSample({required this.t, required this.d, this.r});

  Map<String, dynamic> toMap() => {'t': t, 'd': double.parse(d.toStringAsFixed(1)), 'r': r};

  factory TimelineSample.fromMap(Map m) => TimelineSample(
        t: (m['t'] as num).toInt(),
        d: (m['d'] as num).toDouble(),
        r: (m['r'] as num?)?.toInt(),
      );
}

class Participant {
  final String uid;
  final String name;
  final int colorIndex;

  const Participant({required this.uid, required this.name, required this.colorIndex});

  Map<String, dynamic> toMap() => {'uid': uid, 'name': name, 'colorIndex': colorIndex};

  factory Participant.fromMap(Map m) => Participant(
        uid: m['uid'] as String,
        name: (m['name'] as String?) ?? 'Runner',
        colorIndex: (m['colorIndex'] as num?)?.toInt() ?? 0,
      );
}

/// 서버에서 내려받은(복원된) 경로
class RemotePath {
  final List<LatLng> points;
  final List<int> breaks;

  const RemotePath(this.points, this.breaks);

  List<List<LatLng>> get segments => Geo.splitByBreaks(points, breaks);

  String toJson() => jsonEncode({'p': Geo.encodePolyline(points), 'b': breaks});

  static RemotePath? fromJson(String? s) {
    if (s == null || s.isEmpty) return null;
    final m = jsonDecode(s) as Map;
    return RemotePath(
      Geo.decodePolyline(m['p'] as String),
      ((m['b'] as List?) ?? []).map((e) => (e as num).toInt()).toList(),
    );
  }
}

enum RunStatus { active, paused, finished }

enum SyncStatus { pending, memoPending, synced }

/// 한 번의 러닝 기록 (Local DB 원본)
class RunRecord {
  final String id;
  final String ownerId;
  String ownerName;
  final RunMode mode;
  final String? partyKey;
  final String? partyId;
  final GoalType goalType;
  final double? goalValue; // distance → m, time → s
  final bool loyalty;
  RunStatus status;
  final int startedAt;
  int? endedAt;
  final int? raceStartAt;
  int durationMs;
  double distanceM;
  double? avgPaceSecPerKm;
  double? maxSpeedMps;
  double? elevationGainM;
  final int? colorIndex;
  List<KmSplit> splits;
  List<TimelineSample> timeline;
  String? thumbnailPath; // Documents 기준 상대경로
  SyncStatus syncStatus;
  List<Participant> participants;
  RemotePath? remotePath;
  String? region;
  int updatedAt;

  RunRecord({
    required this.id,
    required this.ownerId,
    required this.ownerName,
    required this.mode,
    this.partyKey,
    this.partyId,
    this.goalType = GoalType.none,
    this.goalValue,
    this.loyalty = false,
    this.status = RunStatus.active,
    required this.startedAt,
    this.endedAt,
    this.raceStartAt,
    this.durationMs = 0,
    this.distanceM = 0,
    this.avgPaceSecPerKm,
    this.maxSpeedMps,
    this.elevationGainM,
    this.colorIndex,
    List<KmSplit>? splits,
    List<TimelineSample>? timeline,
    this.thumbnailPath,
    this.syncStatus = SyncStatus.pending,
    List<Participant>? participants,
    this.remotePath,
    this.region,
    int? updatedAt,
  })  : splits = splits ?? [],
        timeline = timeline ?? [],
        participants = participants ?? [],
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  bool get isGroup => mode == RunMode.group;

  Map<String, Object?> toRow() => {
        'id': id,
        'owner_id': ownerId,
        'owner_name': ownerName,
        'mode': mode.name,
        'party_key': partyKey,
        'party_id': partyId,
        'goal_type': goalType.name,
        'goal_value': goalValue,
        'loyalty': loyalty ? 1 : 0,
        'status': status.name,
        'started_at': startedAt,
        'ended_at': endedAt,
        'race_start_at': raceStartAt,
        'duration_ms': durationMs,
        'distance_m': distanceM,
        'avg_pace': avgPaceSecPerKm,
        'max_speed': maxSpeedMps,
        'elevation_gain': elevationGainM,
        'color_index': colorIndex,
        'splits_json': jsonEncode(splits.map((e) => e.toMap()).toList()),
        'timeline_json': jsonEncode(timeline.map((e) => e.toMap()).toList()),
        'thumbnail_path': thumbnailPath,
        'sync_status': syncStatus.name,
        'participants_json': jsonEncode(participants.map((e) => e.toMap()).toList()),
        'remote_path_json': remotePath?.toJson(),
        'region': region,
        'updated_at': updatedAt,
      };

  factory RunRecord.fromRow(Map<String, Object?> r) {
    List<T> list<T>(String key, T Function(Map) f) {
      final s = r[key] as String?;
      if (s == null || s.isEmpty) return [];
      return (jsonDecode(s) as List).map((e) => f(e as Map)).toList();
    }

    return RunRecord(
      id: r['id'] as String,
      ownerId: r['owner_id'] as String,
      ownerName: (r['owner_name'] as String?) ?? '',
      mode: RunMode.values.byName(r['mode'] as String),
      partyKey: r['party_key'] as String?,
      partyId: r['party_id'] as String?,
      goalType: goalTypeFrom(r['goal_type'] as String?),
      goalValue: (r['goal_value'] as num?)?.toDouble(),
      loyalty: (r['loyalty'] as int? ?? 0) == 1,
      status: RunStatus.values.byName(r['status'] as String),
      startedAt: r['started_at'] as int,
      endedAt: r['ended_at'] as int?,
      raceStartAt: r['race_start_at'] as int?,
      durationMs: (r['duration_ms'] as int?) ?? 0,
      distanceM: (r['distance_m'] as num?)?.toDouble() ?? 0,
      avgPaceSecPerKm: (r['avg_pace'] as num?)?.toDouble(),
      maxSpeedMps: (r['max_speed'] as num?)?.toDouble(),
      elevationGainM: (r['elevation_gain'] as num?)?.toDouble(),
      colorIndex: r['color_index'] as int?,
      splits: list('splits_json', KmSplit.fromMap),
      timeline: list('timeline_json', TimelineSample.fromMap),
      thumbnailPath: r['thumbnail_path'] as String?,
      syncStatus: SyncStatus.values.byName((r['sync_status'] as String?) ?? 'pending'),
      participants: list('participants_json', Participant.fromMap),
      remotePath: RemotePath.fromJson(r['remote_path_json'] as String?),
      region: r['region'] as String?,
      updatedAt: r['updated_at'] as int?,
    );
  }
}
