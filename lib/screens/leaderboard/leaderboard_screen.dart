import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../services/leaderboard_service.dart';
import '../../services/point_service.dart';
import '../../theme/app_theme.dart';
import '../points/points_screen.dart';

class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key, this.initialMonthKey});
  final String? initialMonthKey;

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  late List<String> _months;
  late String _selectedMonth;
  MonthlyLeaderboard? _data;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _months = LeaderboardService.instance.getAvailableMonths();
    _selectedMonth = widget.initialMonthKey ?? _months.first;
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() => _loading = true);
    final res = await LeaderboardService.instance.getMonthlyLeaderboard(_selectedMonth);
    // 월별 랭킹 보상 자동 확인
    PointService.instance.checkMonthlyLeaderboardRewards().ignore();
    if (!mounted) return;
    setState(() {
      _data = res;
      _loading = false;
    });
  }

  void _onMonthChanged(String? month) {
    if (month == null || month == _selectedMonth) return;
    setState(() => _selectedMonth = month);
    _fetch();
  }

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppColors.neon, width: 1.2),
        ),
        title: const Row(
          children: [
            Icon(Icons.emoji_events_rounded, color: AppColors.neon),
            SizedBox(width: 8),
            Text('월간 랭킹 안내', style: TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '🏃 마일리지 합산 방식',
              style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
            SizedBox(height: 4),
            Text(
              '혼자 뛰기, 같이 뛰기(그룹 러닝), 러닝머신 등 모든 완료된 러닝의 누적 거리가 실시간으로 합산됩니다.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
            ),
            SizedBox(height: 12),
            Text(
              '📅 월별 마감 및 갱신',
              style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.textPrimary),
            ),
            SizedBox(height: 4),
            Text(
              '랭킹은 매월 1일 00:00부터 말일 23:59까지 집계되며, 말일이 지나면 최종 순위가 확정되어 명예의 전당으로 기록됩니다.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
            ),
            SizedBox(height: 12),
            Text(
              '🎁 월간 랭킹 보너스 포인트',
              style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFFFD700)),
            ),
            SizedBox(height: 4),
            Text(
              '월말 마감 시 최종 1위(10P), 2위(5P), 3위(3P)에게 러닝 게임머니 보너스 포인트가 지급됩니다.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인', style: TextStyle(color: AppColors.neon, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final entries = data?.entries ?? [];
    final top1 = entries.isNotEmpty ? entries[0] : null;
    final top2 = entries.length > 1 ? entries[1] : null;
    final top3 = entries.length > 2 ? entries[2] : null;
    final restList = entries.length > 3 ? entries.sublist(3) : <LeaderboardEntry>[];
    final myEntry = data?.myEntry;

    return Scaffold(
      appBar: AppBar(
        title: const Text('월간 마일리지 랭킹', style: TextStyle(fontWeight: FontWeight.w900)),
        actions: [
          // 러닝 포인트 바로가기
          ValueListenableBuilder<int>(
            valueListenable: PointService.instance.balance,
            builder: (context, pts, _) => InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PointsScreen()),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                margin: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFD700).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFFFFD700).withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('🪙', style: TextStyle(fontSize: 13)),
                    const SizedBox(width: 4),
                    Text(
                      '$pts P',
                      style: const TextStyle(
                        color: Color(0xFFFFD700),
                        fontWeight: FontWeight.w900,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.info_outline_rounded),
            tooltip: '랭킹 안내',
            onPressed: _showInfoDialog,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // 월 선택 헤더 바
          _buildMonthSelectorHeader(data),

          // 본문
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppColors.neon))
                : RefreshIndicator(
                    onRefresh: _fetch,
                    color: AppColors.neon,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                      children: [
                        // 랭킹 보너스 포인트 안내 배너
                        InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const PointsScreen()),
                          ),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  const Color(0xFFFFD700).withValues(alpha: 0.18),
                                  AppColors.surface,
                                ],
                              ),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: const Color(0xFFFFD700).withValues(alpha: 0.35),
                              ),
                            ),
                            child: const Row(
                              children: [
                                Text('🎁', style: TextStyle(fontSize: 16)),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '월말 최종 랭킹 보너스: 1위 10P · 2위 5P · 3위 3P!',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFFFFD700),
                                    ),
                                  ),
                                ),
                                Icon(Icons.chevron_right, size: 16, color: Color(0xFFFFD700)),
                              ],
                            ),
                          ),
                        ),

                        // 1위 ~ 3위 특별 포디움 (Podium)
                        if (top1 != null)
                          _PodiumSection(top1: top1, top2: top2, top3: top3),

                        const SizedBox(height: 24),

                        // 4위 이하 리스트 헤더
                        if (restList.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                            child: Row(
                              children: [
                                Text(
                                  '전체 순위',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                                Spacer(),
                                Text(
                                  '누적 마일리지',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ...restList.map((e) => _RankListTile(entry: e)),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
      // 하단 내 순위 고정 바
      bottomSheet: (myEntry != null && !_loading) ? _MyRankBottomBar(entry: myEntry, total: data?.totalParticipants ?? 0) : null,
    );
  }

  Widget _buildMonthSelectorHeader(MonthlyLeaderboard? data) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.outline, width: 0.5)),
      ),
      child: Row(
        children: [
          // 월 드롭다운
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedMonth,
              dropdownColor: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(16),
              icon: const Icon(Icons.keyboard_arrow_down_rounded, color: AppColors.neon),
              items: _months.map((m) {
                final title = LeaderboardService.instance.formatMonthTitle(m);
                final isClosed = LeaderboardService.instance.isMonthClosed(m);
                return DropdownMenuItem(
                  value: m,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isClosed
                              ? Colors.grey.withValues(alpha: 0.2)
                              : AppColors.neon.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isClosed ? '마감' : '진행중',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: isClosed ? Colors.grey : AppColors.neon,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
              onChanged: _onMonthChanged,
            ),
          ),
          const Spacer(),
          // 참가자 수 안내
          if (data != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  data.isClosed ? Icons.lock_clock_rounded : Icons.fiber_manual_record,
                  size: 10,
                  color: data.isClosed ? Colors.grey : AppColors.neon,
                ),
                const SizedBox(width: 5),
                Text(
                  '${data.totalParticipants}명 참가',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// 1위, 2위, 3위 특별 표시 포디움 (시상대)
class _PodiumSection extends StatelessWidget {
  const _PodiumSection({
    required this.top1,
    this.top2,
    this.top3,
  });

  final LeaderboardEntry top1;
  final LeaderboardEntry? top2;
  final LeaderboardEntry? top3;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            const Color(0xFFFFD700).withValues(alpha: 0.08),
            AppColors.surface,
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFFFD700).withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.military_tech_rounded, color: Color(0xFFFFD700), size: 20),
              SizedBox(width: 6),
              Text(
                'TOP 3 챔피언',
                style: TextStyle(
                  color: Color(0xFFFFD700),
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 2등 (Silver)
              Expanded(
                child: top2 != null
                    ? _PodiumColumn(
                        entry: top2!,
                        rank: 2,
                        pedestalHeight: 110,
                        badgeColor: const Color(0xFFC0C0C0),
                        glowColor: Colors.white24,
                        medalEmoji: '🥈',
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),

              // 1등 (Gold - 가장 높고 빛남)
              Expanded(
                child: _PodiumColumn(
                  entry: top1,
                  rank: 1,
                  pedestalHeight: 145,
                  badgeColor: const Color(0xFFFFD700),
                  glowColor: const Color(0xFFFFD700).withValues(alpha: 0.4),
                  medalEmoji: '🥇',
                  isFirst: true,
                ),
              ),
              const SizedBox(width: 8),

              // 3등 (Bronze)
              Expanded(
                child: top3 != null
                    ? _PodiumColumn(
                        entry: top3!,
                        rank: 3,
                        pedestalHeight: 90,
                        badgeColor: const Color(0xFFCD7F32),
                        glowColor: const Color(0xFFCD7F32).withValues(alpha: 0.3),
                        medalEmoji: '🥉',
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PodiumColumn extends StatelessWidget {
  const _PodiumColumn({
    required this.entry,
    required this.rank,
    required this.pedestalHeight,
    required this.badgeColor,
    required this.glowColor,
    required this.medalEmoji,
    this.isFirst = false,
  });

  final LeaderboardEntry entry;
  final int rank;
  final double pedestalHeight;
  final Color badgeColor;
  final Color glowColor;
  final String medalEmoji;
  final bool isFirst;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 왕관 (1등 전용)
        if (isFirst)
          const Text('👑', style: TextStyle(fontSize: 22))
        else
          const SizedBox(height: 12),

        // 프로필 아바타 + 메달 뱃지
        Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: glowColor,
                    blurRadius: isFirst ? 16 : 8,
                    spreadRadius: isFirst ? 3 : 1,
                  ),
                ],
                border: Border.all(color: badgeColor, width: isFirst ? 2.5 : 1.5),
              ),
              child: CircleAvatar(
                radius: isFirst ? 32 : 26,
                backgroundColor: AppColors.surfaceHigh,
                backgroundImage: entry.photoUrl != null ? NetworkImage(entry.photoUrl!) : null,
                child: entry.photoUrl == null
                    ? Text(
                        entry.userName.isNotEmpty ? entry.userName[0] : '?',
                        style: TextStyle(
                          fontSize: isFirst ? 20 : 16,
                          fontWeight: FontWeight.w900,
                          color: badgeColor,
                        ),
                      )
                    : null,
              ),
            ),
            Positioned(
              bottom: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  medalEmoji,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        // 러너 이름
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                entry.userName,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: isFirst ? 14 : 12,
                  color: entry.isMe ? AppColors.neon : AppColors.textPrimary,
                ),
              ),
            ),
            if (entry.isMe) ...[
              const SizedBox(width: 3),
              const Text('(나)', style: TextStyle(color: AppColors.neon, fontSize: 10, fontWeight: FontWeight.bold)),
            ],
          ],
        ),

        const SizedBox(height: 2),

        // 마일리지
        Text(
          '${Fmt.km(entry.distanceM, digits: 1)} km',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: isFirst ? 15 : 13,
            color: badgeColor,
          ),
        ),

        const SizedBox(height: 8),

        // 단상 (Pedestal)
        Container(
          width: double.infinity,
          height: pedestalHeight,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                badgeColor.withValues(alpha: isFirst ? 0.45 : 0.25),
                badgeColor.withValues(alpha: 0.05),
              ],
            ),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
            border: Border.all(color: badgeColor.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$rank',
                style: TextStyle(
                  fontSize: isFirst ? 38 : 28,
                  fontWeight: FontWeight.w900,
                  color: badgeColor,
                  height: 1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${entry.runCount}회 완주',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 4위 이하 랭킹 리스트 타일
class _RankListTile extends StatelessWidget {
  const _RankListTile({required this.entry});
  final LeaderboardEntry entry;

  @override
  Widget build(BuildContext context) {
    final isMe = entry.isMe;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isMe ? AppColors.neon.withValues(alpha: 0.08) : AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isMe ? AppColors.neon : AppColors.outline.withValues(alpha: 0.4),
          width: isMe ? 1.5 : 1,
        ),
      ),
      child: Row(
        children: [
          // 순위 번호
          SizedBox(
            width: 32,
            child: Text(
              '${entry.rank}',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 16,
                color: isMe ? AppColors.neon : AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),

          // 아바타
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.surfaceHigh,
            backgroundImage: entry.photoUrl != null ? NetworkImage(entry.photoUrl!) : null,
            child: entry.photoUrl == null
                ? Text(
                    entry.userName.isNotEmpty ? entry.userName[0] : '?',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: isMe ? AppColors.neon : AppColors.textPrimary,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),

          // 이름 + 횟수
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.userName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: isMe ? AppColors.neon : AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.neon,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          '나',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${entry.runCount}회 완주',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),

          // 마일리지
          Text(
            '${Fmt.km(entry.distanceM, digits: 1)} km',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              fontSize: 16,
              color: isMe ? AppColors.neon : AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 하단 내 순위 고정 바
class _MyRankBottomBar extends StatelessWidget {
  const _MyRankBottomBar({required this.entry, required this.total});
  final LeaderboardEntry entry;
  final int total;

  @override
  Widget build(BuildContext context) {
    final topPct = total > 0 ? ((entry.rank / total) * 100).toStringAsFixed(1) : '0';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
        border: const Border(top: BorderSide(color: AppColors.neon, width: 1.5)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // 순위 뱃지
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.neon,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${entry.rank}위',
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 14),

            // 내 정보
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '내 순위',
                        style: TextStyle(
                          color: AppColors.neon,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '상위 $topPct%',
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '총 ${entry.runCount}회 · ${Fmt.km(entry.distanceM, digits: 1)} km 달리는 중 🏃',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
