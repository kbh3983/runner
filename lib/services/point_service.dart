import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../core/format.dart';
import '../data/local/local_db.dart';
import '../data/models/run_record.dart';
import 'leaderboard_service.dart';

/// 포인트 적립/사용 내역
class PointRecord {
  final String id;
  final String userId;
  final int points;
  final String type;
  final String title;
  final String? description;
  final int createdAt;
  final String? refId;

  const PointRecord({
    required this.id,
    required this.userId,
    required this.points,
    required this.type,
    required this.title,
    this.description,
    required this.createdAt,
    this.refId,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'user_id': userId,
        'points': points,
        'type': type,
        'title': title,
        'description': description,
        'created_at': createdAt,
        'ref_id': refId,
      };

  factory PointRecord.fromMap(Map<String, dynamic> map) => PointRecord(
        id: map['id'] as String,
        userId: map['user_id'] as String,
        points: (map['points'] as num).toInt(),
        type: map['type'] as String,
        title: map['title'] as String,
        description: map['description'] as String?,
        createdAt: (map['created_at'] as num).toInt(),
        refId: map['ref_id'] as String?,
      );
}

/// 미션 데이터 모델
class RunningMission {
  final String id;
  final String title;
  final String description;
  final int rewardPoints;
  final String category; // '연속 달리기', '같이뛰기 & 소셜', '월간 랭킹', '주간 챌린지'
  final IconData icon;
  final Color accentColor;
  final int currentProgress;
  final int targetProgress;
  final String progressLabel;
  final bool isCompleted;

  const RunningMission({
    required this.id,
    required this.title,
    required this.description,
    required this.rewardPoints,
    required this.category,
    required this.icon,
    required this.accentColor,
    required this.currentProgress,
    required this.targetProgress,
    required this.progressLabel,
    required this.isCompleted,
  });

  double get progressRatio => targetProgress > 0
      ? (currentProgress / targetProgress).clamp(0.0, 1.0)
      : (isCompleted ? 1.0 : 0.0);
}

/// 러닝 완료 시 획득한 포인트 결과
class RunPointRewardResult {
  final int totalEarned;
  final int mileagePoints;
  final List<PointRecord> missionAwards;

  const RunPointRewardResult({
    required this.totalEarned,
    required this.mileagePoints,
    required this.missionAwards,
  });
}

/// 러닝 포인트 및 미션 관리 서비스
class PointService {
  PointService._();
  static final PointService instance = PointService._();

  final ValueNotifier<int> balance = ValueNotifier<int>(0);
  bool _initialized = false;

  String get _currentUid => AppConfig.useFirebase
      ? FirebaseAuth.instance.currentUser?.uid ?? 'guest_uid'
      : 'dummy_uid';

  /// 초기화 및 잔액 로드 + 과거 러닝 포인트 마이그레이션 백필
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await refreshBalance();
    await _backfillIfNeeded();
    await checkMonthlyLeaderboardRewards();
  }

  /// 잔액 갱신
  Future<int> refreshBalance() async {
    final uid = _currentUid;
    final total = await LocalDb.instance.getTotalPoints(uid);
    balance.value = total;
    return total;
  }

  /// 특정 refId로 포인트가 이미 지급되었는지 확인
  Future<bool> hasAward(String refId) async {
    return await LocalDb.instance.hasPointWithRefId(refId);
  }

  /// 포인트 지급
  Future<PointRecord?> awardPoints({
    required int points,
    required String type,
    required String title,
    String? description,
    String? refId,
    int? createdAt,
  }) async {
    if (points <= 0) return null;
    final uid = _currentUid;
    final time = createdAt ?? DateTime.now().millisecondsSinceEpoch;

    if (refId != null && await hasAward(refId)) {
      return null; // 중복 지급 방지
    }

    final id = 'pt_${time}_${Random().nextInt(99999)}';
    final record = PointRecord(
      id: id,
      userId: uid,
      points: points,
      type: type,
      title: title,
      description: description,
      createdAt: time,
      refId: refId,
    );

    await LocalDb.instance.insertPointHistory(record.toMap());
    await refreshBalance();

    // Firebase 연동 시 원격 동기화
    if (AppConfig.useFirebase && FirebaseAuth.instance.currentUser != null) {
      _syncToFirestore(record).ignore();
    }

    return record;
  }

  Future<void> _syncToFirestore(PointRecord record) async {
    try {
      final userDoc = FirebaseFirestore.instance.collection('users').doc(record.userId);
      await userDoc.collection('point_history').doc(record.id).set(record.toMap());
      await userDoc.set({
        'point_balance': balance.value,
        'points_updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Firestore point sync failed: $e');
    }
  }

  /// 러닝 완료 시 포인트 & 미션 종합 처리
  Future<RunPointRewardResult> processRunPoints(RunRecord run) async {
    await init();
    final uid = _currentUid;
    int totalEarned = 0;
    int mileagePoints = 0;
    final List<PointRecord> awards = [];

    // 1. 마일리지 적립: 1km 당 1포인트 (500m 이상이면 최소 1포인트 지급)
    final km = (run.distanceM / 1000).floor();
    mileagePoints = km >= 1 ? km : (run.distanceM >= 500 ? 1 : 0);

    if (mileagePoints > 0) {
      final mileageAward = await awardPoints(
        points: mileagePoints,
        type: 'mileage',
        title: '${Fmt.km(run.distanceM, digits: 1)}km 러닝 마일리지 적립',
        description: '1km당 1P 지급 (완주 거리: ${Fmt.km(run.distanceM, digits: 2)}km)',
        refId: 'run_mileage_${run.id}',
        createdAt: run.endedAt ?? run.startedAt,
      );
      if (mileageAward != null) {
        totalEarned += mileagePoints;
      }
    }

    // 2. 친구와 같이뛰기 미션: 1회 이상 달릴 시 1포인트
    final isGroupRun = run.mode == RunMode.group || run.partyKey != null || run.isGroup;
    if (isGroupRun) {
      final partyAward = await awardPoints(
        points: 1,
        type: 'together_run',
        title: '친구와 같이뛰기 미션 성공 🤝',
        description: '친구와 함께 발맞춰 달리기를 완료했어요!',
        refId: 'mission_together_${run.id}',
        createdAt: run.endedAt ?? run.startedAt,
      );
      if (partyAward != null) {
        awards.add(partyAward);
        totalEarned += 1;
      }
    }

    // 3. 같이뛰기 의리게임 10km 이상 성공 시 10포인트
    final isLoyaltySuccess = run.loyalty && run.distanceM >= 10000;
    if (isLoyaltySuccess) {
      final loyaltyAward = await awardPoints(
        points: 10,
        type: 'loyalty_10km',
        title: '같이뛰기 의리게임 10km 완주 미션 성공 🔥',
        description: '친구들과 의리를 지켜 10km 이상 완주를 성공했어요!',
        refId: 'mission_loyalty_10km_${run.id}',
        createdAt: run.endedAt ?? run.startedAt,
      );
      if (loyaltyAward != null) {
        awards.add(loyaltyAward);
        totalEarned += 10;
      }
    }

    // 4. 연속 달리기 미션 (3일 연속 달리기 3P, 5일 연속 달리기 5P, 7일 연속 달리기 7P)
    final runs = await LocalDb.instance.getFinishedRuns(uid);
    final streak = _calculateCurrentStreak(runs, DateTime.fromMillisecondsSinceEpoch(run.startedAt));
    final runDateStr = _dateStr(DateTime.fromMillisecondsSinceEpoch(run.startedAt));

    // 3일 연속 달리기 미션
    if (streak >= 3) {
      final streak3Award = await awardPoints(
        points: 3,
        type: 'streak_3',
        title: '3일 연속 달리기 미션 성공 🔥',
        description: '3일 동안 쉬지 않고 꾸준히 달렸어요!',
        refId: 'mission_streak_3_$runDateStr',
        createdAt: run.endedAt ?? run.startedAt,
      );
      if (streak3Award != null) {
        awards.add(streak3Award);
        totalEarned += 3;
      }
    }

    // 5일 연속 달리기 미션
    if (streak >= 5) {
      final streak5Award = await awardPoints(
        points: 5,
        type: 'streak_5',
        title: '5일 연속 달리기 미션 성공 ⚡',
        description: '대단해요! 5일 연속으로 달리기 습관을 이어갔어요!',
        refId: 'mission_streak_5_$runDateStr',
        createdAt: run.endedAt ?? run.startedAt,
      );
      if (streak5Award != null) {
        awards.add(streak5Award);
        totalEarned += 5;
      }
    }

    // 7일 연속 달리기 (완벽한 일주일) 미션
    if (streak >= 7) {
      final streak7Award = await awardPoints(
        points: 7,
        type: 'streak_7',
        title: '7일 연속 달리기 (완벽한 일주일) 미션 성공 👑',
        description: '일주일 동안 매일 달린 마스터 러너!',
        refId: 'mission_streak_7_$runDateStr',
        createdAt: run.endedAt ?? run.startedAt,
      );
      if (streak7Award != null) {
        awards.add(streak7Award);
        totalEarned += 7;
      }
    }

    // 5. 오늘 첫 러닝 출석 미션: 1포인트
    final dailyAward = await awardPoints(
      points: 1,
      type: 'daily_first',
      title: '오늘의 첫 러닝 출석 미션 성공 ☀️',
      description: '오늘도 건강하게 러닝을 시작했어요!',
      refId: 'mission_daily_$runDateStr',
      createdAt: run.endedAt ?? run.startedAt,
    );
    if (dailyAward != null) {
      awards.add(dailyAward);
      totalEarned += 1;
    }

    // 6. 주말 러너 미션: 주말(토/일) 러닝 2포인트
    final runDate = DateTime.fromMillisecondsSinceEpoch(run.startedAt);
    if (runDate.weekday == DateTime.saturday || runDate.weekday == DateTime.sunday) {
      final weekendAward = await awardPoints(
        points: 2,
        type: 'weekend_run',
        title: '주말 러너 미션 성공 🏖️',
        description: '주말에도 쉬지 않고 달린 열정 러너!',
        refId: 'mission_weekend_$runDateStr',
        createdAt: run.endedAt ?? run.startedAt,
      );
      if (weekendAward != null) {
        awards.add(weekendAward);
        totalEarned += 2;
      }
    }

    // 7. 주간 누적 마일리지 10km (5P) / 20km (10P)
    final weekStart = runDate.subtract(Duration(days: runDate.weekday - 1));
    final weekKey = '${weekStart.year}_W${(weekStart.difference(DateTime(weekStart.year, 1, 1)).inDays / 7).floor()}';
    final weekRuns = runs.where((r) {
      final d = DateTime.fromMillisecondsSinceEpoch(r.startedAt);
      return !d.isBefore(DateTime(weekStart.year, weekStart.month, weekStart.day)) &&
          d.isBefore(DateTime(weekStart.year, weekStart.month, weekStart.day).add(const Duration(days: 7)));
    });
    final weekDistM = weekRuns.fold<double>(0.0, (acc, r) => acc + r.distanceM);

    if (weekDistM >= 10000) {
      final w10Award = await awardPoints(
        points: 5,
        type: 'weekly_10km',
        title: '주간 누적 10km 달성 미션 성공 🏅',
        description: '이번 주 누적 10km 이상을 달성했어요!',
        refId: 'mission_w10_$weekKey',
        createdAt: run.endedAt ?? run.startedAt,
      );
      if (w10Award != null) {
        awards.add(w10Award);
        totalEarned += 5;
      }
    }

    if (weekDistM >= 20000) {
      final w20Award = await awardPoints(
        points: 10,
        type: 'weekly_20km',
        title: '주간 누적 20km 달성 미션 성공 🌟',
        description: '이번 주 20km 이상을 질주한 슈퍼 러너!',
        refId: 'mission_w20_$weekKey',
        createdAt: run.endedAt ?? run.startedAt,
      );
      if (w20Award != null) {
        awards.add(w20Award);
        totalEarned += 10;
      }
    }

    return RunPointRewardResult(
      totalEarned: totalEarned,
      mileagePoints: mileagePoints,
      missionAwards: awards,
    );
  }

  /// 월별 랭킹 순위 보상 체크 (1등: 10P, 2등: 5P, 3등: 3P)
  Future<void> checkMonthlyLeaderboardRewards() async {
    final now = DateTime.now();
    // 지난 3개월 간의 마감된 월별 랭킹 확인
    for (int i = 1; i <= 3; i++) {
      final targetDate = DateTime(now.year, now.month - i, 1);
      final monthKey = '${targetDate.year}-${targetDate.month.toString().padLeft(2, '0')}';
      final refId = 'rank_reward_$monthKey';

      if (await hasAward(refId)) continue;

      final lb = await LeaderboardService.instance.getMonthlyLeaderboard(monthKey);
      final me = lb.myEntry;
      if (me == null) continue;

      int rankReward = 0;
      String medal = '';
      if (me.rank == 1) {
        rankReward = 10;
        medal = '🥇 1위';
      } else if (me.rank == 2) {
        rankReward = 5;
        medal = '🥈 2위';
      } else if (me.rank == 3) {
        rankReward = 3;
        medal = '🥉 3위';
      }

      if (rankReward > 0) {
        await awardPoints(
          points: rankReward,
          type: 'monthly_rank_${me.rank}',
          title: '$monthKey 월간 랭킹 $medal 달성 보상 🏆',
          description: '월간 마일리지 랭킹 TOP 3에 입상하여 보너스 포인트를 획득했어요!',
          refId: refId,
        );
      }
    }
  }

  /// 과거 러닝 기록의 마일리지 및 미션 포인트 백필 (기존 사용자가 있을 경우)
  Future<void> _backfillIfNeeded() async {
    final uid = _currentUid;
    final history = await LocalDb.instance.getPointHistory(uid, limit: 1);
    if (history.isNotEmpty) return; // 이미 포인트 데이터가 있으면 패스

    final runs = await LocalDb.instance.getFinishedRuns(uid);
    if (runs.isEmpty) return;

    for (final run in runs) {
      final km = (run.distanceM / 1000).floor();
      final pts = km >= 1 ? km : (run.distanceM >= 500 ? 1 : 0);
      if (pts > 0) {
        await awardPoints(
          points: pts,
          type: 'mileage',
          title: '${Fmt.km(run.distanceM, digits: 1)}km 러닝 마일리지 적립',
          description: '기존 러닝 마일리지 포인트 적립',
          refId: 'run_mileage_${run.id}',
          createdAt: run.endedAt ?? run.startedAt,
        );
      }
    }
  }

  /// 미션 목록 및 현재 진행 상태 조회
  Future<List<RunningMission>> getActiveMissions() async {
    final uid = _currentUid;
    final runs = await LocalDb.instance.getFinishedRuns(uid);
    final now = DateTime.now();

    final streak = _calculateCurrentStreak(runs, now);
    final todayStr = _dateStr(now);

    final todayRan = runs.any((r) => _dateStr(DateTime.fromMillisecondsSinceEpoch(r.startedAt)) == todayStr);
    final togetherRunCount = runs.where((r) => r.mode == RunMode.group || r.partyKey != null || r.isGroup).length;
    final loyalty10Count = runs.where((r) => r.loyalty && r.distanceM >= 10000).length;

    // 주간 누적 거리
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    final weekRuns = runs.where((r) {
      final d = DateTime.fromMillisecondsSinceEpoch(r.startedAt);
      return !d.isBefore(DateTime(weekStart.year, weekStart.month, weekStart.day)) &&
          d.isBefore(DateTime(weekStart.year, weekStart.month, weekStart.day).add(const Duration(days: 7)));
    });
    final weekDistKm = (weekRuns.fold<double>(0.0, (acc, r) => acc + r.distanceM) / 1000).clamp(0.0, 999.0);

    return [
      // 1. 연속 달리기 미션
      RunningMission(
        id: 'streak_3',
        title: '3일 연속 달리기',
        description: '쉬지 않고 3일 연속으로 달려보세요!',
        rewardPoints: 3,
        category: '연속 달리기',
        icon: Icons.local_fire_department_rounded,
        accentColor: const Color(0xFFFF9800),
        currentProgress: streak.clamp(0, 3),
        targetProgress: 3,
        progressLabel: '$streak / 3일',
        isCompleted: streak >= 3,
      ),
      RunningMission(
        id: 'streak_5',
        title: '5일 연속 달리기',
        description: '강력한 러닝 습관 형성! 5일 연속 질주',
        rewardPoints: 5,
        category: '연속 달리기',
        icon: Icons.bolt_rounded,
        accentColor: const Color(0xFFFF5722),
        currentProgress: streak.clamp(0, 5),
        targetProgress: 5,
        progressLabel: '$streak / 5일',
        isCompleted: streak >= 5,
      ),
      RunningMission(
        id: 'streak_7',
        title: '7일 연속 달리기 (완벽한 일주일)',
        description: '일주일 동안 매일 러닝 완료',
        rewardPoints: 7,
        category: '연속 달리기',
        icon: Icons.workspace_premium_rounded,
        accentColor: const Color(0xFFFFD700),
        currentProgress: streak.clamp(0, 7),
        targetProgress: 7,
        progressLabel: '$streak / 7일',
        isCompleted: streak >= 7,
      ),
      RunningMission(
        id: 'daily_first',
        title: '오늘의 첫 러닝 출석',
        description: '오늘 러닝 1회 완료하기',
        rewardPoints: 1,
        category: '연속 달리기',
        icon: Icons.wb_sunny_rounded,
        accentColor: const Color(0xFF00E676),
        currentProgress: todayRan ? 1 : 0,
        targetProgress: 1,
        progressLabel: todayRan ? '출석 완료' : '미완료',
        isCompleted: todayRan,
      ),

      // 2. 같이뛰기 & 소셜 미션
      RunningMission(
        id: 'together_run',
        title: '친구와 같이뛰기 1회 완료',
        description: '친구와 파티 러닝으로 함께 발맞춰 달리기',
        rewardPoints: 1,
        category: '같이뛰기 & 소셜',
        icon: Icons.groups_rounded,
        accentColor: const Color(0xFF29B6F6),
        currentProgress: togetherRunCount.clamp(0, 1),
        targetProgress: 1,
        progressLabel: togetherRunCount >= 1 ? '완료' : '0 / 1회',
        isCompleted: togetherRunCount >= 1,
      ),
      RunningMission(
        id: 'loyalty_10km',
        title: '의리게임 10km 완주 성공',
        description: '같이뛰기 의리게임에서 10km 이상 완주 성공',
        rewardPoints: 10,
        category: '같이뛰기 & 소셜',
        icon: Icons.handshake_rounded,
        accentColor: const Color(0xFFE040FB),
        currentProgress: loyalty10Count.clamp(0, 1),
        targetProgress: 1,
        progressLabel: loyalty10Count >= 1 ? '성공' : '0 / 1회',
        isCompleted: loyalty10Count >= 1,
      ),

      // 3. 월간 랭킹 보상
      RunningMission(
        id: 'monthly_rank_1',
        title: '월간 랭킹 1위 보상',
        description: '월간 마일리지 랭킹 1위 등극 시 지급',
        rewardPoints: 10,
        category: '월간 랭킹',
        icon: Icons.emoji_events_rounded,
        accentColor: const Color(0xFFFFD700),
        currentProgress: 0,
        targetProgress: 1,
        progressLabel: '월말 자동 정산',
        isCompleted: false,
      ),
      RunningMission(
        id: 'monthly_rank_2_3',
        title: '월간 랭킹 2~3위 보상',
        description: '월간 마일리지 랭킹 2위(5P), 3위(3P) 지급',
        rewardPoints: 5,
        category: '월간 랭킹',
        icon: Icons.military_tech_rounded,
        accentColor: const Color(0xFFC0C0C0),
        currentProgress: 0,
        targetProgress: 1,
        progressLabel: '월말 자동 정산',
        isCompleted: false,
      ),

      // 4. 주간 챌린지 미션
      RunningMission(
        id: 'weekly_10km',
        title: '이번 주 누적 10km 달리기',
        description: '월요일부터 일요일까지 10km 완주',
        rewardPoints: 5,
        category: '주간 챌린지',
        icon: Icons.directions_run_rounded,
        accentColor: const Color(0xFF69F0AE),
        currentProgress: weekDistKm.floor().clamp(0, 10),
        targetProgress: 10,
        progressLabel: '${weekDistKm.toStringAsFixed(1)} / 10 km',
        isCompleted: weekDistKm >= 10,
      ),
      RunningMission(
        id: 'weekly_20km',
        title: '이번 주 누적 20km 달리기',
        description: '이번 주 마일리지 20km 이상 돌파',
        rewardPoints: 10,
        category: '주간 챌린지',
        icon: Icons.speed_rounded,
        accentColor: const Color(0xFF7C4DFF),
        currentProgress: weekDistKm.floor().clamp(0, 20),
        targetProgress: 20,
        progressLabel: '${weekDistKm.toStringAsFixed(1)} / 20 km',
        isCompleted: weekDistKm >= 20,
      ),
    ];
  }

  /// 포인트 내역 조회
  Future<List<PointRecord>> getPointHistory({int limit = 100}) async {
    final uid = _currentUid;
    final rows = await LocalDb.instance.getPointHistory(uid, limit: limit);
    return rows.map(PointRecord.fromMap).toList();
  }

  // --- 유틸리티 ---

  static String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static int _calculateCurrentStreak(List<RunRecord> all, DateTime now) {
    DateTime utc(DateTime d) => DateTime.utc(d.year, d.month, d.day);
    final daySet = all.map((r) {
      final d = DateTime.fromMillisecondsSinceEpoch(r.startedAt);
      return utc(DateTime(d.year, d.month, d.day));
    }).toSet();

    var cursor = utc(DateTime(now.year, now.month, now.day));
    if (!daySet.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    var current = 0;
    while (daySet.contains(cursor)) {
      current++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return current;
  }
}
