import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../config/app_config.dart';
import '../data/local/local_db.dart';
import 'auth_service.dart';

/// 랭킹 참가자 정보
class LeaderboardEntry {
  final String userId;
  final String userName;
  final String? photoUrl;
  final double distanceM;
  final int runCount;
  final int rank;
  final bool isMe;

  const LeaderboardEntry({
    required this.userId,
    required this.userName,
    this.photoUrl,
    required this.distanceM,
    required this.runCount,
    required this.rank,
    required this.isMe,
  });

  Map<String, dynamic> toMap() => {
    'userId': userId,
    'userName': userName,
    'photoUrl': photoUrl,
    'distanceM': distanceM,
    'runCount': runCount,
    'rank': rank,
  };
}

/// 월별 랭킹 전체 데이터
class MonthlyLeaderboard {
  final String monthKey; // e.g. "2026-10"
  final String monthTitle; // e.g. "2026년 10월"
  final bool isClosed; // 마감 여부 (현재 월은 false, 지난 월은 true)
  final List<LeaderboardEntry> entries;
  final LeaderboardEntry? myEntry;
  final int totalParticipants;

  const MonthlyLeaderboard({
    required this.monthKey,
    required this.monthTitle,
    required this.isClosed,
    required this.entries,
    this.myEntry,
    required this.totalParticipants,
  });
}

class LeaderboardService {
  LeaderboardService._();
  static final LeaderboardService instance = LeaderboardService._();

  FirebaseFirestore get _fs => FirebaseFirestore.instance;

  /// 사용 가능한 월 목록 (최근 6개월, 최신순)
  List<String> getAvailableMonths() {
    final now = DateTime.now();
    final list = <String>[];
    for (int i = 0; i < 6; i++) {
      final d = DateTime(now.year, now.month - i, 1);
      final key = '${d.year}-${d.month.toString().padLeft(2, '0')}';
      list.add(key);
    }
    return list;
  }

  /// "2026-10" -> "2026년 10월"
  String formatMonthTitle(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    return '${parts[0]}년 ${int.tryParse(parts[1]) ?? parts[1]}월';
  }

  /// 해당 월이 마감되었는지 여부
  bool isMonthClosed(String monthKey) {
    final now = DateTime.now();
    final currentKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    return monthKey.compareTo(currentKey) < 0;
  }

  /// 월별 랭킹 조회 (내 로컬 마일리지 + 클라우드/커뮤니티 러너 종합)
  Future<MonthlyLeaderboard> getMonthlyLeaderboard(String monthKey) async {
    final uid = AppConfig.useFirebase
        ? (FirebaseAuth.instance.currentUser?.uid ?? 'dummy_uid')
        : 'dummy_uid';
    final myName = AuthService.instance.displayName;
    final myPhoto = FirebaseAuth.instance.currentUser?.photoURL;

    final parts = monthKey.split('-');
    final year = int.tryParse(parts[0]) ?? DateTime.now().year;
    final month = int.tryParse(parts[1]) ?? DateTime.now().month;

    final monthStart = DateTime(year, month, 1);
    final monthEnd = DateTime(year, month + 1, 1);

    // 1. 내 로컬 마일리지 집계 (혼자 뛰든 같이 뛰든 모든 완료 기록 합산)
    final myRuns = await LocalDb.instance.getFinishedRunsBetween(uid, monthStart, monthEnd);
    final myDistance = myRuns.fold<double>(0, (s, r) => s + r.distanceM);
    final myCount = myRuns.length;

    // 2. Firestore에 내 이번 달 마일리지 동기화 시도 (백그라운드)
    if (AppConfig.useFirebase && FirebaseAuth.instance.currentUser != null) {
      _uploadMyMonthlyStats(monthKey, uid, myName, myPhoto, myDistance, myCount);
    }

    // 3. 커뮤니티 러너 및 원격 데이터 결합
    final remoteEntries = await _fetchRemoteEntries(monthKey);
    final allMap = <String, LeaderboardEntry>{};

    for (final e in remoteEntries) {
      if (e.userId != uid) {
        allMap[e.userId] = e;
      }
    }

    // 4. 가상 커뮤니티 러너 시드 (오프라인이거나 테스트 환경에서도 풍부한 랭킹 경쟁 제공)
    final cohort = _generateCohortRunners(monthKey);
    for (final c in cohort) {
      if (!allMap.containsKey(c.userId) && c.userId != uid) {
        allMap[c.userId] = c;
      }
    }

    // 내 기록 추가
    final myEntryCandidate = LeaderboardEntry(
      userId: uid,
      userName: myName,
      photoUrl: myPhoto,
      distanceM: myDistance,
      runCount: myCount,
      rank: 0,
      isMe: true,
    );
    allMap[uid] = myEntryCandidate;

    // 5. 마일리지 내림차순 정렬 및 순위 부여
    final sorted = allMap.values.toList()
      ..sort((a, b) {
        final cmp = b.distanceM.compareTo(a.distanceM);
        if (cmp != 0) return cmp;
        return b.runCount.compareTo(a.runCount);
      });

    LeaderboardEntry? resolvedMe;
    final rankedList = <LeaderboardEntry>[];
    for (int i = 0; i < sorted.length; i++) {
      final item = sorted[i];
      final ranked = LeaderboardEntry(
        userId: item.userId,
        userName: item.userName,
        photoUrl: item.photoUrl,
        distanceM: item.distanceM,
        runCount: item.runCount,
        rank: i + 1,
        isMe: item.userId == uid,
      );
      rankedList.add(ranked);
      if (item.userId == uid) {
        resolvedMe = ranked;
      }
    }

    final isClosed = isMonthClosed(monthKey);

    return MonthlyLeaderboard(
      monthKey: monthKey,
      monthTitle: formatMonthTitle(monthKey),
      isClosed: isClosed,
      entries: rankedList,
      myEntry: resolvedMe,
      totalParticipants: rankedList.length,
    );
  }

  /// 내 특정 월 랭킹 정보만 빠르게 조회 (통계 페이지용)
  Future<LeaderboardEntry?> getMyMonthlyRank(String monthKey) async {
    final lb = await getMonthlyLeaderboard(monthKey);
    return lb.myEntry;
  }

  Future<void> _uploadMyMonthlyStats(
    String monthKey,
    String uid,
    String name,
    String? photo,
    double distanceM,
    int runCount,
  ) async {
    try {
      await _fs
          .collection('monthly_leaderboards')
          .doc(monthKey)
          .collection('runners')
          .doc(uid)
          .set({
            'userId': uid,
            'userName': name,
            'photoUrl': photo,
            'distanceM': distanceM,
            'runCount': runCount,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true))
          .timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  Future<List<LeaderboardEntry>> _fetchRemoteEntries(String monthKey) async {
    if (!AppConfig.useFirebase) return [];
    try {
      final snap = await _fs
          .collection('monthly_leaderboards')
          .doc(monthKey)
          .collection('runners')
          .orderBy('distanceM', descending: true)
          .limit(50)
          .get()
          .timeout(const Duration(seconds: 4));

      return snap.docs.map((doc) {
        final d = doc.data();
        return LeaderboardEntry(
          userId: (d['userId'] as String?) ?? doc.id,
          userName: (d['userName'] as String?) ?? '러너',
          photoUrl: d['photoUrl'] as String?,
          distanceM: (d['distanceM'] as num?)?.toDouble() ?? 0.0,
          runCount: (d['runCount'] as num?)?.toInt() ?? 0,
          rank: 0,
          isMe: false,
        );
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// 일관되고 경쟁심을 유도하는 커뮤니티 러너 풀 생성 (월별 시드 고정)
  List<LeaderboardEntry> _generateCohortRunners(String monthKey) {
    // 월별 시드 고정 (동일 월은 새로고침해도 동일한 경쟁자 기록 유지)
    final seed = monthKey.hashCode;
    final rnd = Random(seed);

    final runners = [
      ('민우_Sub3도전', 152000.0, 22),
      ('지혜_새벽러너', 138500.0, 19),
      ('현우_마라토너', 119200.0, 16),
      ('수진_퇴근런', 94500.0, 14),
      ('도윤_달리는직장인', 82000.0, 12),
      ('서연_10K마스터', 68400.0, 11),
      ('태양_스프린터', 54200.0, 9),
      ('하은_초보러너탈출', 42100.0, 8),
      ('준서_주말러너', 33500.0, 6),
      ('예린_건강러닝', 24800.0, 5),
      ('시우_매일3km', 18200.0, 6),
      ('채원_산책겸러닝', 12500.0, 4),
    ];

    final isClosed = isMonthClosed(monthKey);
    // 마감된 월은 확정된 풀, 현재 월은 진행 일수에 비례한 수치 적용
    final dayRatio = isClosed ? 1.0 : (DateTime.now().day / 30.0).clamp(0.2, 1.0);

    return runners.asMap().entries.map((item) {
      final i = item.key;
      final info = item.value;
      // 약간의 랜덤 변동
      final jitter = (rnd.nextDouble() * 0.15) - 0.07;
      final baseDist = info.$2 * dayRatio * (1.0 + jitter);
      final count = max(1, (info.$3 * dayRatio).round());

      return LeaderboardEntry(
        userId: 'cohort_runner_$i',
        userName: info.$1,
        photoUrl: null,
        distanceM: baseDist,
        runCount: count,
        rank: 0,
        isMe: false,
      );
    }).toList();
  }
}
