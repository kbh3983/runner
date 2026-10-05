import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../config/app_config.dart';
import '../core/party_ids.dart';
import '../data/local/local_db.dart';
import '../data/models/party.dart';
import '../data/models/run_record.dart';

class PartyException implements Exception {
  final String message;
  PartyException(this.message);
  @override
  String toString() => message;
}

/// 파티(같이 뛰기) 관리.
///
/// 파티 생성/참여/강퇴/삭제/시작은 비밀번호 검증과 정원 관리를 위해
/// 전부 Cloud Functions 를 통해서만 수행한다. 클라이언트는 읽기만 한다.
class PartyService {
  PartyService._();
  static final PartyService instance = PartyService._();

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseFunctions get _fn =>
      FirebaseFunctions.instanceFor(region: AppConfig.functionsRegion);

  Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> data,
  ) async {
    if (!AppConfig.useFirebase) {
      throw PartyException('서버 연결이 비활성화되어 있어 이 기능을 사용할 수 없어요 (테스트 모드).');
    }
    try {
      final res = await _fn.httpsCallable(name).call(data);
      return Map<String, dynamic>.from((res.data as Map?) ?? {});
    } on FirebaseFunctionsException catch (e) {
      throw PartyException(_message(e));
    }
  }

  String _message(FirebaseFunctionsException e) {
    if (e.message != null && e.message!.isNotEmpty && e.code != 'internal')
      return e.message!;
    switch (e.code) {
      case 'not-found':
        return '파티를 찾을 수 없어요';
      case 'permission-denied':
        return '권한이 없어요';
      case 'failed-precondition':
        return '러닝이 이미 시작되었어요';
      case 'resource-exhausted':
        return '파티 인원이 가득 찼어요';
      case 'unavailable':
        return '네트워크 연결을 확인해 주세요';
      default:
        return '요청을 처리하지 못했어요 (${e.code})';
    }
  }

  /// 내가 속한 진행 중(대기/러닝) 파티
  Stream<List<Party>> myActiveParties(String uid) {
    if (!AppConfig.useFirebase) return Stream.value([]);
    return _db
        .collection('parties')
        .where('memberIds', arrayContains: uid)
        .where('status', whereIn: ['waiting', 'running'])
        .snapshots()
        .map((s) {
          final list = s.docs.map(Party.fromDoc).toList();
          list.sort((a, b) => b.roomNo.compareTo(a.roomNo));
          return list;
        });
  }

  Stream<Party?> watch(String partyKey) {
    if (!AppConfig.useFirebase) return Stream.value(null);
    return _db
        .collection('parties')
        .doc(partyKey)
        .snapshots()
        .map((d) => d.exists ? Party.fromDoc(d) : null);
  }

  Future<Party?> get(String partyKey) async {
    if (!AppConfig.useFirebase) return null;
    final d = await _db.collection('parties').doc(partyKey).get();
    return d.exists ? Party.fromDoc(d) : null;
  }

  /// 파티원들의 완료 기록 (서버 검증본)
  Stream<List<Map<String, dynamic>>> results(String partyKey) {
    if (!AppConfig.useFirebase) return Stream.value([]);
    return _db
        .collection('parties')
        .doc(partyKey)
        .collection('results')
        .snapshots()
        .map((s) => s.docs.map((d) => d.data()).toList());
  }

  Future<({String partyId, String partyKey})> create({
    required int maxMembers,
    required GoalType goalType,
    double? goalValue,
    required bool loyalty,
    required String password,
  }) async {
    final res = await _call('createParty', {
      'maxMembers': maxMembers,
      'goalType': goalType.name,
      'goalValue': goalType == GoalType.none ? null : goalValue,
      'loyalty': loyalty,
      'password': password,
    });
    final partyKey = res['partyKey'] as String;
    // 비밀번호는 서버에 해시로만 저장됨 → 공유를 위해 방장 기기에만 보관
    await LocalDb.instance.savePartySecret(partyKey, password);
    return (partyId: res['partyId'] as String, partyKey: partyKey);
  }

  Future<String> join(String partyId, String password) async {
    final res = await _call('joinParty', {
      'partyId': partyId.trim(),
      'password': password.trim(),
    });
    return (res['partyKey'] as String?) ?? PartyIds.toKey(partyId);
  }

  Future<void> leave(String partyKey) =>
      _call('leaveParty', {'partyKey': partyKey});

  Future<void> kick(String partyKey, String uid) =>
      _call('kickMember', {'partyKey': partyKey, 'uid': uid});

  Future<void> delete(String partyKey) =>
      _call('deleteParty', {'partyKey': partyKey});

  Future<int> start(String partyKey) async {
    final res = await _call('startParty', {'partyKey': partyKey});
    return (res['startAt'] as num).toInt();
  }

  /// 공유 문구 (카톡/복사)
  String shareText(Party party, String? password) {
    final link = Uri(
      scheme: 'https',
      host: 'runner-1e27d.web.app',
      path: '/join',
      queryParameters: {'id': party.id, if (password != null) 'pw': password},
    ).toString();
    return [
      party.id,
      if (password != null) password,
      '',
      '🏃 ${party.displayName} 같이 뛰기',
      '바로 참여: $link',
    ].join('\n');
  }

  String _goalText(Party p) {
    switch (p.goalType) {
      case GoalType.distance:
        final km = ((p.goalValue ?? 0) / 1000).toStringAsFixed(2);
        return p.loyalty ? '팀 합계 $km km (의리게임)' : '$km km';
      case GoalType.time:
        return '${((p.goalValue ?? 0) / 60).round()}분';
      case GoalType.none:
        return '자유 러닝';
    }
  }

  /// 공유 문구/딥링크에서 파티 ID, 비밀번호 추출
  static ({String? id, String? pw}) parseInvite(String text) {
    // 딥링크 또는 웹 링크 모두 매칭
    final link = RegExp(
      r'(?:https://runner-1e27d\.web\.app/join|' + AppConfig.appScheme + r'://join)\?[^\s]+',
    ).firstMatch(text);
    if (link != null) {
      final uri = Uri.tryParse(link.group(0)!);
      if (uri != null) {
        return (id: uri.queryParameters['id'], pw: uri.queryParameters['pw']);
      }
    }
    
    // 딥링크가 없는 경우 첫 줄 ID, 둘째 줄 PW 형식 파싱
    final lines = text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    String? id;
    String? pw;
    if (lines.isNotEmpty && lines[0].contains('#')) {
      id = lines[0];
      if (lines.length > 1 && RegExp(r'^\d{6}$').hasMatch(lines[1])) {
        pw = lines[1];
      }
    }
    return (id: id, pw: pw);
  }
}
