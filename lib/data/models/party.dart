import 'package:cloud_firestore/cloud_firestore.dart';

import 'run_record.dart';

class PartyMember {
  final String uid;
  final String name;
  final String? photoUrl;
  final int colorIndex;
  final int joinedAt;

  const PartyMember({
    required this.uid,
    required this.name,
    this.photoUrl,
    required this.colorIndex,
    required this.joinedAt,
  });

  factory PartyMember.fromMap(String uid, Map m) => PartyMember(
        uid: uid,
        name: (m['name'] as String?) ?? 'Runner',
        photoUrl: m['photoUrl'] as String?,
        colorIndex: (m['colorIndex'] as num?)?.toInt() ?? 0,
        joinedAt: (m['joinedAt'] as num?)?.toInt() ?? 0,
      );

  Participant toParticipant() => Participant(uid: uid, name: name, colorIndex: colorIndex);
}

enum PartyStatus { waiting, running, finished, success, failed }

/// Firestore `parties/{partyKey}`
class Party {
  final String id; // uid#roomNo (공유용)
  final String key; // DB 키
  final String hostId;
  final String hostName;
  final int roomNo;
  final int maxMembers;
  final GoalType goalType;
  final double? goalValue;
  final bool loyalty;
  final PartyStatus status;
  final List<String> memberIds;
  final Map<String, PartyMember> members;
  final int? startAt;
  final int? loyaltyDeadline;
  final double loyaltyTotalM;
  final Map<String, double> loyaltyContributions;
  final Map<String, Map>? finalLive;

  const Party({
    required this.id,
    required this.key,
    required this.hostId,
    required this.hostName,
    required this.roomNo,
    required this.maxMembers,
    required this.goalType,
    this.goalValue,
    required this.loyalty,
    required this.status,
    required this.memberIds,
    required this.members,
    this.startAt,
    this.loyaltyDeadline,
    this.loyaltyTotalM = 0,
    this.loyaltyContributions = const {},
    this.finalLive,
  });

  bool isHost(String uid) => hostId == uid;
  bool get isActive => status == PartyStatus.waiting || status == PartyStatus.running;

  List<PartyMember> get sortedMembers {
    final list = members.values.toList()
      ..sort((a, b) {
        if (a.uid == hostId) return -1;
        if (b.uid == hostId) return 1;
        return a.joinedAt.compareTo(b.joinedAt);
      });
    return list;
  }

  String get displayName => '$hostName님의 파티 #$roomNo';

  factory Party.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data() ?? {};
    final membersRaw = (d['members'] as Map?) ?? {};
    final lp = (d['loyaltyProgress'] as Map?) ?? {};
    final contrib = (lp['contributions'] as Map?) ?? {};
    return Party(
      id: (d['id'] as String?) ?? doc.id,
      key: doc.id,
      hostId: (d['hostId'] as String?) ?? '',
      hostName: (d['hostName'] as String?) ?? 'Runner',
      roomNo: (d['roomNo'] as num?)?.toInt() ?? 0,
      maxMembers: (d['maxMembers'] as num?)?.toInt() ?? 2,
      goalType: goalTypeFrom(d['goalType'] as String?),
      goalValue: (d['goalValue'] as num?)?.toDouble(),
      loyalty: (d['loyalty'] as bool?) ?? false,
      status: PartyStatus.values.firstWhere(
        (e) => e.name == d['status'],
        orElse: () => PartyStatus.waiting,
      ),
      memberIds: ((d['memberIds'] as List?) ?? []).cast<String>(),
      members: membersRaw.map((k, v) => MapEntry(k as String, PartyMember.fromMap(k, v as Map))),
      startAt: (d['startAt'] as num?)?.toInt(),
      loyaltyDeadline: (d['loyaltyDeadline'] as num?)?.toInt(),
      loyaltyTotalM: (lp['totalM'] as num?)?.toDouble() ?? 0,
      loyaltyContributions: contrib.map((k, v) => MapEntry(k as String, (v as num).toDouble())),
      finalLive: (d['finalLive'] as Map?)?.map((k, v) => MapEntry(k as String, v as Map)),
    );
  }
}

/// RTDB `liveSessions/{partyKey}/members/{uid}` — 단체 러닝 실시간 최소 데이터
class LiveMember {
  final String userId;
  final String name;
  final int colorIndex;
  final double distanceKm;
  final double baseDistanceKm;
  final int pace; // sec/km
  final double? latitude;
  final double? longitude;
  final String status; // READY|RUNNING|PAUSED|FINISHED
  final bool connected;
  final int updatedAt;

  const LiveMember({
    required this.userId,
    required this.name,
    required this.colorIndex,
    required this.distanceKm,
    this.baseDistanceKm = 0,
    required this.pace,
    this.latitude,
    this.longitude,
    required this.status,
    this.connected = true,
    required this.updatedAt,
  });

  double get teamContributionKm => baseDistanceKm + distanceKm;

  factory LiveMember.fromMap(String uid, Map m) => LiveMember(
        userId: uid,
        name: (m['name'] as String?) ?? 'Runner',
        colorIndex: (m['colorIndex'] as num?)?.toInt() ?? 0,
        distanceKm: (m['distance'] as num?)?.toDouble() ?? 0,
        baseDistanceKm: (m['baseDistance'] as num?)?.toDouble() ?? 0,
        pace: (m['pace'] as num?)?.toInt() ?? 0,
        latitude: (m['latitude'] as num?)?.toDouble(),
        longitude: (m['longitude'] as num?)?.toDouble(),
        status: (m['status'] as String?) ?? 'READY',
        connected: (m['connected'] as bool?) ?? true,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
      );

  String get statusLabel {
    if (!connected && status != 'FINISHED') return '연결 끊김';
    switch (status) {
      case 'RUNNING':
        return '러닝중';
      case 'PAUSED':
        return '일시정지';
      case 'FINISHED':
        return '완료';
      default:
        return '준비';
    }
  }
}
