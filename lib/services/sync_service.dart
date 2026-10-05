import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/app_config.dart';
import '../core/geo.dart';
import '../data/local/local_db.dart';
import '../data/models/gps_point.dart';
import '../data/models/run_record.dart';

/// Local DB → Firestore 동기화.
///
/// * 러닝 종료 직후 시도하고, 실패하면 `sync_status = pending` 으로 남겨둔다.
/// * 네트워크가 복구되거나 앱이 다시 열리면 자동으로 재시도한다.
/// * 업로드는 runId 를 문서 ID 로 쓰므로 여러 번 시도해도 중복되지 않는다.
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  FirebaseFirestore get _fs => FirebaseFirestore.instance;
  StreamSubscription? _connSub;
  bool _running = false;
  bool _again = false;

  final ValueNotifier<bool> syncing = ValueNotifier(false);

  void start() {
    _connSub ??= Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) syncAll();
    });
    syncAll();
  }

  Future<void> syncAll() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    syncing.value = true;
    try {
      do {
        _again = false;
        final runs = await LocalDb.instance.getRunsToSync(uid);
        for (final r in runs) {
          try {
            if (r.syncStatus == SyncStatus.pending) {
              await _upload(r);
            } else if (r.syncStatus == SyncStatus.memoPending) {
              await _uploadMemos(r.id);
            }
            await LocalDb.instance.setSyncStatus(r.id, SyncStatus.synced);
          } catch (e) {
            debugPrint('sync failed for ${r.id} (will retry later): $e');
            break; // 네트워크 문제일 가능성이 높으니 다음 기회에
          }
        }
      } while (_again);
    } finally {
      _running = false;
      syncing.value = false;
    }
  }

  Future<void> _upload(RunRecord r) async {
    final ref = _fs.collection('runs').doc(r.id);
    // 이전 시도가 서버에 반영됐지만 응답을 못 받은 경우 → 메모만 갱신
    final existing = await ref.get(const GetOptions(source: Source.server)).timeout(const Duration(seconds: 15));
    if (existing.exists) {
      await _uploadMemos(r.id);
      return;
    }
    final doc = await buildRemoteDoc(r);
    await ref.set(doc).timeout(const Duration(seconds: 20));
  }

  Future<void> _uploadMemos(String runId) async {
    final memos = await LocalDb.instance.getMemos(runId);
    await _fs.collection('runs').doc(runId).update({
      'memos': memos.map((m) => m.toRemote()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    }).timeout(const Duration(seconds: 20));
  }

  /// Firestore 에 올릴 완료 기록. GPS 원본 대신 다운샘플된 encoded polyline 만 올린다.
  Future<Map<String, dynamic>> buildRemoteDoc(RunRecord r) async {
    final points = await LocalDb.instance.getPoints(r.id);
    final path = _buildPath(points, r);
    final memos = await LocalDb.instance.getMemos(r.id);
    return {
      'id': r.id,
      'ownerId': r.ownerId,
      'ownerName': r.ownerName,
      'mode': r.mode.name,
      'partyKey': r.partyKey,
      'partyId': r.partyId,
      'goalType': r.goalType.name,
      'goalValue': r.goalValue,
      'loyalty': r.loyalty,
      'startedAt': r.startedAt,
      'endedAt': r.endedAt ?? r.startedAt + r.durationMs,
      'raceStartAt': r.raceStartAt,
      'durationMs': r.durationMs,
      'distanceM': double.parse(r.distanceM.toStringAsFixed(1)),
      'avgPaceSecPerKm': r.avgPaceSecPerKm,
      'maxSpeedMps': r.maxSpeedMps,
      'elevationGainM': r.elevationGainM,
      'colorIndex': r.colorIndex,
      'splits': r.splits.map((s) => s.toMap()).toList(),
      'timeline': r.timeline.map((t) => t.toMap()).toList(),
      'path': path.encoded,
      'pathTimes': path.times,
      'pathBreaks': path.breaks,
      'memos': memos.map((m) => m.toRemote()).toList(),
      'clientVersion': '1.0.0',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  ({String encoded, List<int> times, List<int> breaks}) _buildPath(List<GpsPoint> pts, RunRecord r) {
    if (pts.isEmpty) {
      final remote = r.remotePath;
      if (remote != null) {
        return (encoded: Geo.encodePolyline(remote.points), times: <int>[], breaks: remote.breaks);
      }
      return (encoded: '', times: <int>[], breaks: <int>[]);
    }
    // 포인트 수가 많으면 최소 간격을 늘려가며 다운샘플 (구간 시작/끝은 유지)
    var step = 5.0;
    List<GpsPoint> sampled;
    while (true) {
      sampled = [];
      GpsPoint? last;
      for (var i = 0; i < pts.length; i++) {
        final p = pts[i];
        final isSegEdge = last == null ||
            p.segment != last.segment ||
            i == pts.length - 1 ||
            pts[i + 1].segment != p.segment;
        if (isSegEdge || Geo.distance(last.lat, last.lng, p.lat, p.lng) >= step) {
          sampled.add(p);
          last = p;
        }
      }
      if (sampled.length <= AppConfig.maxUploadPathPoints || step > 500) break;
      step *= 1.6;
    }
    final latLngs = <LatLng>[];
    final times = <int>[];
    final breaks = <int>[];
    int? seg;
    for (var i = 0; i < sampled.length; i++) {
      final p = sampled[i];
      if (seg != null && p.segment != seg) breaks.add(i);
      seg = p.segment;
      latLngs.add(p.latLng);
      times.add(((p.ts - r.startedAt) / 1000).round());
    }
    return (encoded: Geo.encodePolyline(latLngs), times: times, breaks: breaks);
  }

  /// 새 기기/재설치 시 서버의 완료 기록을 Local DB 로 복원 (GPS 원본 대신 다운샘플 경로)
  Future<int> pullRemote() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return 0;
    try {
      final snap = await _fs
          .collection('runs')
          .where('ownerId', isEqualTo: uid)
          .orderBy('startedAt', descending: true)
          .limit(300)
          .get()
          .timeout(const Duration(seconds: 20));
      var added = 0;
      for (final d in snap.docs) {
        if (await LocalDb.instance.runExists(d.id)) continue;
        final run = runFromRemote(d.data());
        await LocalDb.instance.upsertRun(run, notify: false);
        final memos = ((d.data()['memos'] as List?) ?? [])
            .map((m) => RunMemo(
                  id: m['id'] as String,
                  runId: d.id,
                  text: m['text'] as String,
                  createdAt: (m['createdAt'] as num).toInt(),
                ))
            .toList();
        await LocalDb.instance.replaceMemos(d.id, memos);
        added++;
      }
      if (added > 0) LocalDb.instance.changes.value++;
      return added;
    } catch (e) {
      debugPrint('pullRemote failed: $e');
      return 0;
    }
  }

  static RunRecord runFromRemote(Map<String, dynamic> m) {
    final path = (m['path'] as String?) ?? '';
    final breaks = ((m['pathBreaks'] as List?) ?? []).map((e) => (e as num).toInt()).toList();
    return RunRecord(
      id: m['id'] as String,
      ownerId: m['ownerId'] as String,
      ownerName: (m['ownerName'] as String?) ?? 'Runner',
      mode: m['mode'] == 'group' ? RunMode.group : RunMode.solo,
      partyKey: m['partyKey'] as String?,
      partyId: m['partyId'] as String?,
      goalType: goalTypeFrom(m['goalType'] as String?),
      goalValue: (m['goalValue'] as num?)?.toDouble(),
      loyalty: (m['loyalty'] as bool?) ?? false,
      status: RunStatus.finished,
      startedAt: (m['startedAt'] as num).toInt(),
      endedAt: (m['endedAt'] as num?)?.toInt(),
      raceStartAt: (m['raceStartAt'] as num?)?.toInt(),
      durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      distanceM: (m['distanceM'] as num?)?.toDouble() ?? 0,
      avgPaceSecPerKm: (m['avgPaceSecPerKm'] as num?)?.toDouble(),
      maxSpeedMps: (m['maxSpeedMps'] as num?)?.toDouble(),
      elevationGainM: (m['elevationGainM'] as num?)?.toDouble(),
      colorIndex: (m['colorIndex'] as num?)?.toInt(),
      splits: ((m['splits'] as List?) ?? []).map((e) => KmSplit.fromMap(e as Map)).toList(),
      timeline: ((m['timeline'] as List?) ?? []).map((e) => TimelineSample.fromMap(e as Map)).toList(),
      syncStatus: SyncStatus.synced,
      remotePath: path.isEmpty ? null : RemotePath(Geo.decodePolyline(path), breaks),
    );
  }
}
