import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';

import '../data/models/party.dart';

/// 단체 러닝 실시간 상태 (Firebase Realtime Database).
///
/// * 혼자 러닝에서는 절대 사용하지 않는다.
/// * 전체 GPS 경로는 보내지 않고, 화면 표시에 필요한 최소 데이터만 보낸다.
/// * 순위는 저장하지 않는다 → 받은 distance 로 앱에서 정렬.
class LiveSessionService {
  LiveSessionService(this.partyKey);

  final String partyKey;

  DatabaseReference get _root => FirebaseDatabase.instance.ref('liveSessions/$partyKey');

  DatabaseReference _memberRef(String uid) => _root.child('members/$uid');

  bool _disconnectHookSet = false;

  /// 파티원 실시간 상태
  Stream<Map<String, LiveMember>> members() => _root.child('members').onValue.map((e) {
        final v = e.snapshot.value;
        if (v is! Map) return <String, LiveMember>{};
        return v.map((k, val) => MapEntry(k as String, LiveMember.fromMap(k, val as Map)));
      }).handleError((Object e) {
        // 세션 정리 후에는 권한 오류가 날 수 있음 → 빈 값 취급
        debugPrint('live members error: $e');
      });

  /// 세션 메타 상태 (RUNNING / COMPLETED / FAILED)
  Stream<String?> metaStatus() => _root
      .child('meta/status')
      .onValue
      .map((e) => e.snapshot.value as String?)
      .handleError((Object e) => debugPrint('live meta error: $e'));

  /// 내 실시간 상태 전송. 실패해도 러닝은 계속된다 (RTDB 가 오프라인 큐잉).
  Future<void> publish({
    required String uid,
    required String name,
    required int colorIndex,
    required double distanceM,
    required double baseDistanceM,
    required double? avgPaceSec,
    required double? lat,
    required double? lng,
    required String status,
  }) async {
    try {
      final ref = _memberRef(uid);
      if (!_disconnectHookSet) {
        _disconnectHookSet = true;
        await ref.onDisconnect().update({'connected': false});
      }
      await ref.update({
        'userId': uid,
        'name': name.length > 50 ? name.substring(0, 50) : name,
        'colorIndex': colorIndex,
        'distance': double.parse((distanceM / 1000).toStringAsFixed(3)),
        'baseDistance': double.parse((baseDistanceM / 1000).toStringAsFixed(3)),
        'pace': (avgPaceSec == null || !avgPaceSec.isFinite) ? 0 : avgPaceSec.round(),
        'latitude': ?lat,
        'longitude': ?lng,
        'status': status,
        'connected': true,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (e) {
      debugPrint('live publish failed (ignored): $e');
    }
  }

  Future<void> dispose() async {
    try {
      await FirebaseDatabase.instance.ref('liveSessions/$partyKey/members').onDisconnect().cancel();
    } catch (_) {}
  }
}
