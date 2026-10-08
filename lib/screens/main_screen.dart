import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../core/format.dart';
import '../data/local/local_db.dart';
import '../data/models/party.dart';
import '../data/models/run_record.dart';
import '../services/auth_service.dart';
import '../services/deep_link_service.dart';
import '../services/party_service.dart';
import '../services/point_service.dart';
import '../services/push_service.dart';
import '../services/run_tracker.dart';
import '../services/server_clock.dart';
import '../services/sync_service.dart';
import '../services/weather_service.dart';
import '../theme/app_theme.dart';
import 'history/history_screen.dart';
import 'leaderboard/leaderboard_screen.dart';
import 'party/party_sheets.dart';
import 'points/points_screen.dart';
import 'run/run_finish_screen.dart';
import 'run/run_screen.dart';
import 'run/start_options_sheet.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late final String uid = AppConfig.useFirebase
      ? FirebaseAuth.instance.currentUser!.uid
      : 'dummy_uid';
  StreamSubscription<List<Party>>? _partySub;
  StreamSubscription<FinishReason>? _finishSub;
  List<Party> _parties = [];
  final Set<String> _autoLaunched = {};
  bool _runOpen = false;

  @override
  void initState() {
    super.initState();
    PointService.instance.init();
    _partySub = PartyService.instance.myActiveParties(uid).listen((list) {
      setState(() => _parties = list);
      _checkAutoStart(list);
    }, onError: (Object e) => debugPrint('parties stream error: $e'));
    DeepLinkService.instance.pendingInvite.addListener(_onInvite);
    PushService.instance.opened.addListener(_onPushOpened);
    // 러닝 화면을 내려둔 상태에서 목표 달성 등으로 종료되면 종료 화면으로
    _finishSub = RunTracker.instance.onFinished.listen((_) {
      final run = RunTracker.instance.run;
      if (_runOpen || run == null || !mounted) return;
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => RunFinishScreen(runId: run.id)));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkUnfinishedRun();
      _onInvite();
      _requestPermissions();
    });
  }

  Future<void> _requestPermissions() async {
    try {
      await RunTracker.ensurePermission();
    } catch (_) {}
    // 위치 권한 처리 후 날씨 정보 로드
    WeatherService.instance.refresh(force: true);
  }

  @override
  void dispose() {
    _partySub?.cancel();
    _finishSub?.cancel();
    DeepLinkService.instance.pendingInvite.removeListener(_onInvite);
    PushService.instance.opened.removeListener(_onPushOpened);
    super.dispose();
  }

  // ------------------------------------------------------------ 자동 처리

  /// 비정상 종료로 남아있는 러닝 → 이어하기 / 저장하고 끝내기
  Future<void> _checkUnfinishedRun() async {
    if (RunTracker.instance.isActive) return;
    final run = await LocalDb.instance.getUnfinishedRun(uid);
    if (run == null || !mounted) return;
    final resume = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: AppColors.surfaceHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: AppColors.neon, width: 1.0),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('진행 중이던 러닝이 있어요', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
              const SizedBox(height: 8),
              Text('${Fmt.dateTime(run.startedAt)} 시작', style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(4)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(Fmt.km(run.distanceM), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: AppColors.neon, letterSpacing: -1)),
                        const SizedBox(height: 2),
                        const Text('km', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w700)),
                      ],
                    ),
                    Container(width: 1, height: 32, color: AppColors.outline),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(Fmt.duration(run.durationMs), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
                        const SizedBox(height: 4),
                        const Text('시간', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    flex: 1000,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                        side: const BorderSide(color: AppColors.outline),
                      ),
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('종료하기', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w700, fontSize: 14)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1618,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.neon,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('이어서 달리기', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await RunTracker.instance.restore(run);
    if (!mounted) return;
    if (resume == true) {
      _openRun(RunScreen.resume());
    } else {
      final r = await RunTracker.instance.finish(FinishReason.manual);
      if (r != null && mounted) {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => RunFinishScreen(runId: r.id)));
      }
    }
  }

  /// 방장이 시작하면 파티원 앱이 자동으로 카운트다운 화면으로 이동
  Future<void> _checkAutoStart(List<Party> parties) async {
    if (RunTracker.instance.isActive || _runOpen) return;
    for (final p in parties) {
      if (p.status != PartyStatus.running || p.startAt == null) continue;
      if (_autoLaunched.contains(p.key)) continue;
      final sinceStart = ServerClock.nowMs() - p.startAt!;
      if (sinceStart > const Duration(minutes: 2).inMilliseconds) continue;
      final existing = await LocalDb.instance.getRunsForParty(uid, p.key);
      if (existing.isNotEmpty) continue;
      _autoLaunched.add(p.key);
      if (!mounted) return;
      await launchGroupRun(p);
      return;
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.surfaceHigh,
          margin: const EdgeInsets.only(bottom: 24, left: 16, right: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.neon, width: 1.5),
          ),
          content: Row(
            children: [
              const Icon(Icons.info_outline_rounded, color: AppColors.neon),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  msg,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      );
  }

  void _onInvite() {
    final invite = DeepLinkService.instance.pendingInvite.value;
    if (invite == null || !mounted) return;
    DeepLinkService.instance.pendingInvite.value = null;
    // 한 번에 하나의 러닝만: 러닝 중에는 새 파티에 참여할 수 없음
    if (RunTracker.instance.isActive || _runOpen) {
      _toast('이미 러닝이 진행 중이에요. 러닝을 끝낸 뒤 참여해주세요.');
      return;
    }
    showJoinPartySheet(context, initialId: invite.id, initialPw: invite.pw);
  }

  Future<void> _onPushOpened() async {
    final m = PushService.instance.opened.value;
    if (m == null || !mounted) return;
    PushService.instance.opened.value = null;
    final key = m.data['partyKey'] as String?;
    if (key == null) return;
    final party = await PartyService.instance.get(key).catchError((_) => null);
    if (party == null || !mounted) return;
    if (party.isActive) {
      showPartyDetailSheet(context, party.key, onRun: launchGroupRun);
    }
  }

  // ------------------------------------------------------------ 러닝 시작

  Future<void> _openRun(Widget screen) async {
    _runOpen = true;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => screen, fullscreenDialog: true));
    _runOpen = false;
  }

  Future<void> _startSolo() async {
    if (RunTracker.instance.isActive) {
      _openRun(RunScreen.resume());
      return;
    }
    if (_runOpen) return;
    // 한 번에 하나의 러닝만: 같이 뛰기 참여 중에는 혼자 러닝 불가
    if (_parties.isNotEmpty) {
      _toast('같이 뛰기에 참여 중이에요. 파티가 끝난 뒤에 혼자 러닝을 시작할 수 있어요.');
      return;
    }
    try {
      await RunTracker.ensurePermission();
    } on LocationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    final cfg = await showStartOptionsSheet(context);
    if (cfg == null || !mounted) return;
    _openRun(RunScreen(config: cfg));
  }

  Future<void> _onTogetherTap() async {
    // 한 번에 하나의 러닝만: 혼자 러닝 중에는 같이 뛰기 불가
    if (RunTracker.instance.isActive || _runOpen) {
      _toast('이미 러닝이 진행 중이에요. 러닝을 끝낸 뒤에 이용해주세요.');
      return;
    }
    try {
      await RunTracker.ensurePermission();
    } on LocationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (!mounted) return;
    showTogetherSheet(context);
  }

  /// 단체 러닝 화면 열기 (카운트다운 포함)
  Future<void> launchGroupRun(Party party) async {
    if (RunTracker.instance.isActive) {
      // 같은 파티의 러닝이면 이어서, 아니면 안내
      if (RunTracker.instance.isGroup &&
          RunTracker.instance.run?.partyKey == party.key) {
        _openRun(RunScreen.resume());
      } else {
        _toast('이미 러닝이 진행 중이에요. 러닝을 끝낸 뒤에 시작해주세요.');
      }
      return;
    }
    if (_runOpen) {
      _toast('이미 러닝이 진행 중이에요.');
      return;
    }
    try {
      await RunTracker.ensurePermission();
    } on LocationException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    var base = 0.0;
    if (party.loyalty) {
      final prev = await LocalDb.instance.getRunsForParty(uid, party.key);
      base = prev
          .where((r) => r.status == RunStatus.finished)
          .fold(0.0, (s, r) => s + r.distanceM);
    }
    if (!mounted) return;
    final startAt = party.startAt;
    final countdownTo =
        (startAt != null && ServerClock.nowMs() < startAt + 1500)
        ? startAt
        : null;
    _openRun(
      RunScreen(
        config: RunConfig.fromParty(party, uid, baseDistanceM: base),
        countdownTo: countdownTo,
        countdownAlways: true,
      ),
    );
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final user = AppConfig.useFirebase
        ? FirebaseAuth.instance.currentUser
        : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          AppConfig.appName,
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: -0.5),
        ),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: SyncService.instance.syncing,
            builder: (_, syncing, _) => syncing
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          // 러닝 게임머니 포인트 뱃지
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
          PopupMenuButton<String>(
            icon: CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.surfaceHigh,
              backgroundImage: user?.photoURL != null
                  ? NetworkImage(user!.photoURL!)
                  : null,
              child: user?.photoURL == null
                  ? const Icon(Icons.person, size: 18)
                  : null,
            ),
            onSelected: (v) async {
              if (v == 'logout') {
                if (RunTracker.instance.isActive) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('러닝 중에는 로그아웃할 수 없어요')),
                  );
                  return;
                }
                await PushService.instance.removeToken();
                await AuthService.instance.signOut();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Text(AuthService.instance.displayName),
              ),
              const PopupMenuItem(value: 'logout', child: Text('로그아웃')),
            ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const _MonthSummary(),
            const _WeatherCard(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_parties.isNotEmpty) ...[
                          _PartyStrip(
                            parties: _parties,
                            uid: uid,
                            onRun: launchGroupRun,
                          ),
                          const SizedBox(height: 36),
                        ],
                        ListenableBuilder(
                          listenable: RunTracker.instance,
                          builder: (_, _) => Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              _CircleAction(
                                size: 150,
                                filled: true,
                                icon: RunTracker.instance.isActive
                                    ? Icons.play_arrow_rounded
                                    : Icons.directions_run_rounded,
                                label: RunTracker.instance.isActive
                                    ? '러닝 중'
                                    : '러닝 시작',
                                onTap: _startSolo,
                              ),
                              const SizedBox(width: 24),
                              _CircleAction(
                                size: 96,
                                filled: false,
                                icon: Icons.groups_rounded,
                                label: '같이 뛰기',
                                onTap: _onTogetherTap,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _BottomBar(
              onHome: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const HistoryScreen())),
              onLeaderboard: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LeaderboardScreen())),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.size,
    required this.filled,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final double size;
  final bool filled;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: filled ? AppColors.neon : AppColors.surface,
          shape: CircleBorder(
            side: filled
                ? BorderSide.none
                : const BorderSide(color: AppColors.neon, width: 2),
          ),
          elevation: 0,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: size,
              height: size,
              decoration: filled
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.neon.withValues(alpha: 0.45),
                          blurRadius: 36,
                          spreadRadius: 2,
                        ),
                      ],
                    )
                  : null,
              child: Icon(
                icon,
                size: size * 0.48,
                color: filled ? Colors.black : AppColors.neon,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: filled ? 17 : 15,
          ),
        ),
      ],
    );
  }
}

/// "러닝 시작" 버튼 위에 표시되는 내 파티 목록
class _PartyStrip extends StatelessWidget {
  const _PartyStrip({
    required this.parties,
    required this.uid,
    required this.onRun,
  });

  final List<Party> parties;
  final String uid;
  final Future<void> Function(Party) onRun;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 112,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: parties.length,
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemBuilder: (_, i) => PartyCard(
          party: parties[i],
          uid: uid,
          onTap: () =>
              showPartyDetailSheet(context, parties[i].key, onRun: onRun),
        ),
      ),
    );
  }
}

class _MonthSummary extends StatelessWidget {
  const _MonthSummary();

  @override
  Widget build(BuildContext context) {
    final uid = AppConfig.useFirebase
        ? FirebaseAuth.instance.currentUser!.uid
        : 'dummy_uid';
    return ValueListenableBuilder<int>(
      valueListenable: LocalDb.instance.changes,
      builder: (_, _, _) {
        final now = DateTime.now();
        return FutureBuilder<List<RunRecord>>(
          future: LocalDb.instance.getFinishedRunsBetween(
            uid,
            DateTime(now.year, now.month),
            DateTime(now.year, now.month + 1),
          ),
          builder: (_, snap) {
            final runs = snap.data ?? [];
            final dist = runs.fold<double>(0, (s, r) => s + r.distanceM);
            final time = runs.fold<int>(0, (s, r) => s + r.durationMs);
            final days = runs.map((r) {
              final d = DateTime.fromMillisecondsSinceEpoch(r.startedAt);
              return d.day;
            }).toSet();
            return Container(
              margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: StatColumn(
                      value: Fmt.km(dist, digits: 1),
                      unit: ' km',
                      label: '${now.month}월 마일리지',
                    ),
                  ),
                  Expanded(
                    child: StatColumn(value: '${runs.length}', unit: '회', label: '러닝 횟수'),
                  ),
                  Expanded(
                    child: StatColumn(value: '${days.length}', unit: '일', label: '달린 날'),
                  ),
                  Expanded(
                    child: StatColumn(value: Fmt.minutes(time), label: '총 시간'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// 오늘 러닝 참고 정보: 지역 / 기온 / 날씨 / 미세먼지
class _WeatherCard extends StatefulWidget {
  const _WeatherCard();

  @override
  State<_WeatherCard> createState() => _WeatherCardState();
}

class _WeatherCardState extends State<_WeatherCard>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WeatherService.instance.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) WeatherService.instance.refresh();
  }

  Color _dustColor(DustGrade? g) => switch (g) {
    DustGrade.good => AppColors.route,
    DustGrade.normal => AppColors.gold,
    DustGrade.bad => const Color(0xFFFF9800),
    DustGrade.veryBad => AppColors.danger,
    null => AppColors.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WeatherState>(
      valueListenable: WeatherService.instance.state,
      builder: (_, s, _) {
        final info = s.info;
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
          ),
          child: info != null ? _content(info) : _placeholder(s),
        );
      },
    );
  }

  Widget _placeholder(WeatherState s) {
    final loading =
        s.status == WeatherStatus.loading || s.status == WeatherStatus.idle;
    return InkWell(
      onTap: loading
          ? null
          : () => WeatherService.instance.refresh(force: true),
      child: SizedBox(
        height: 135,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(
                Icons.refresh,
                size: 18,
                color: AppColors.textSecondary,
              ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                loading
                    ? '오늘의 러닝 날씨를 불러오는 중...'
                    : '${s.message ?? '날씨 정보를 불러오지 못했어요'} (눌러서 다시 시도)',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(WeatherInfo w) {
    final (emoji, desc) = w.condition;
    return InkWell(
      onTap: () => WeatherService.instance.refresh(force: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.place_rounded,
                size: 14,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  w.region ?? '현재 위치',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '오늘의 러닝 날씨',
                style: TextStyle(
                  color: AppColors.neon.withValues(alpha: 0.9),
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 34)),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${w.tempC.round()}°',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      '$desc · 체감 ${w.feelsLikeC.round()}°',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _dustChip('미세먼지', w.pm10Grade, w.pm10),
              const SizedBox(width: 8),
              _dustChip('초미세', w.pm25Grade, w.pm25),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _mini(Icons.water_drop_outlined, '습도 ${w.humidity}%'),
              const SizedBox(width: 14),
              _mini(Icons.air, '바람 ${w.windMps.toStringAsFixed(1)}m/s'),
              if (w.rainProbability != null) ...[
                const SizedBox(width: 14),
                _mini(Icons.umbrella_outlined, '강수 ${w.rainProbability}%'),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.neon.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              w.advice,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dustChip(String label, DustGrade? grade, double? value) {
    final color = _dustColor(grade);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 10),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            grade?.label ?? '-',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (value != null)
          Text(
            '${value.round()}㎍/㎥',
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10,
            ),
          ),
      ],
    );
  }

  Widget _mini(IconData icon, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: AppColors.textSecondary),
      const SizedBox(width: 4),
      Text(
        text,
        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
      ),
    ],
  );
}

class StatColumn extends StatelessWidget {
  const StatColumn({super.key, required this.value, this.unit, required this.label});
  final String value;
  final String? unit;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: AppColors.neon,
                ),
              ),
            ),
          ),
          if (unit != null)
            Text(
              unit!,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.textSecondary,
              ),
            ),
        ],
      ),
      const SizedBox(height: 2),
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
      ),
    ],
  );
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.onHome, required this.onLeaderboard});
  final VoidCallback onHome;
  final VoidCallback onLeaderboard;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onHome,
                child: const SizedBox(
                  height: 56,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.calendar_month_rounded, color: AppColors.neon, size: 20),
                      SizedBox(width: 8),
                      Text(
                        '러닝 기록',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Material(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onLeaderboard,
                child: Container(
                  height: 56,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFFFD700).withValues(alpha: 0.35)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.emoji_events_rounded, color: Color(0xFFFFD700), size: 20),
                      SizedBox(width: 8),
                      Text(
                        '월간 랭킹',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: Color(0xFFFFD700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
