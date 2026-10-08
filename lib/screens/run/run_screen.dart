import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../core/party_ids.dart';
import '../../core/route_smoother.dart';
import '../../data/models/run_record.dart';
import '../../services/auth_service.dart';
import '../../services/run_tracker.dart';
import '../../services/server_clock.dart';
import '../../services/voice_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/map_marker_helper.dart';
import '../../widgets/route_map.dart';
import 'run_finish_screen.dart';

/// 러닝 화면 (혼자 / 같이 뛰기 공용)
class RunScreen extends StatefulWidget {
  const RunScreen({
    super.key,
    required RunConfig this.config,
    this.countdownTo,
    this.countdownAlways = false,
  }) : resumeExisting = false;

  /// 이미 진행 중인(또는 복구된) 러닝으로 돌아가기
  const RunScreen.resume({super.key})
    : config = null,
      countdownTo = null,
      countdownAlways = false,
      resumeExisting = true;

  final RunConfig? config;

  /// 단체 러닝 공통 출발 시각 (서버 시각)
  final int? countdownTo;

  /// countdownTo 가 지났어도 5초 카운트다운 후 출발 (늦게 합류한 경우)
  final bool countdownAlways;
  final bool resumeExisting;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> {
  final tracker = RunTracker.instance;
  GoogleMapController? _map;
  bool _follow = true;
  String? _selectedMember;
  int _lastCameraMove = 0;
  LatLng? _initial;
  bool _mapReady = false;
  StreamSubscription<FinishReason>? _finishSub;

  BitmapDescriptor? _startIcon;
  final Map<int, BitmapDescriptor> _kmIcons = {};

  // 카운트다운
  Timer? _cdTimer;
  int? _cdShown; // 화면에 보이는 숫자 (0 = GO)
  int? _cdWaitSec; // 5초 이전 대기
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    tracker.addListener(_onTracker);
    _finishSub = tracker.onFinished.listen((_) => _goFinish());
    MapMarkerHelper.getStartMarker().then((icon) {
      if (mounted) setState(() => _startIcon = icon);
    });
    RunTracker.currentLatLng().then((p) {
      if (mounted && p != null) setState(() => _initial = p);
    });
    if (!widget.resumeExisting) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
    }
  }

  @override
  void dispose() {
    tracker.removeListener(_onTracker);
    _finishSub?.cancel();
    _cdTimer?.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------ 시작 / 카운트다운

  Future<void> _prepare() async {
    try {
      await RunTracker.ensurePermission();
    } on LocationException catch (e) {
      _fail(e.message);
      return;
    }
    final cfg = widget.config!;
    if (cfg.mode == RunMode.group &&
        widget.countdownTo == null &&
        !widget.countdownAlways) {
      await _startNow();
    } else {
      // 혼자 러닝: countdownTo 없이 5초 카운트다운 후 출발
      _startCountdown();
    }
  }

  void _startCountdown() {
    final targetLocal = widget.countdownTo != null
        ? ServerClock.toLocal(widget.countdownTo!)
        : DateTime.now().millisecondsSinceEpoch + 5000;
    final effectiveTarget =
        targetLocal < DateTime.now().millisecondsSinceEpoch + 1000
        ? DateTime.now().millisecondsSinceEpoch + 5000
        : targetLocal;
    VoiceService.instance.init();
    _cdTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      final remaining = effectiveTarget - DateTime.now().millisecondsSinceEpoch;
      if (remaining > 5000) {
        final w = (remaining / 1000).ceil();
        if (w != _cdWaitSec) setState(() => _cdWaitSec = w);
        return;
      }
      if (remaining > 0) {
        final n = (remaining / 1000).ceil();
        if (n != _cdShown) {
          setState(() {
            _cdWaitSec = null;
            _cdShown = n;
          });
          VoiceService.instance.speakNow('$n');
        }
        return;
      }
      t.cancel();
      setState(() => _cdShown = 0);
      VoiceService.instance.speakNow('고!');
      _startNow(announce: false).then((_) {
        VoiceService.instance.announceStart();
        Future.delayed(const Duration(milliseconds: 900), () {
          if (mounted) setState(() => _cdShown = null);
        });
      });
    });

    final initialRemaining =
        effectiveTarget - DateTime.now().millisecondsSinceEpoch;
    if (initialRemaining > 5000) {
      setState(() => _cdWaitSec = (initialRemaining / 1000).ceil());
    } else if (initialRemaining > 0) {
      setState(() => _cdShown = (initialRemaining / 1000).ceil());
      VoiceService.instance.speakNow('$_cdShown');
    }
  }

  Future<void> _startNow({bool announce = true}) async {
    if (_starting || tracker.isActive) return;
    _starting = true;
    try {
      final auth = AuthService.instance;
      final uid = AppConfig.useFirebase ? auth.currentUser!.uid : 'dummy_uid';
      await tracker.start(widget.config!, uid: uid, name: auth.displayName);
      if (announce) VoiceService.instance.announceStart();
    } on LocationException catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail('러닝을 시작하지 못했어요: $e');
    } finally {
      _starting = false;
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    Navigator.of(context).maybePop();
  }

  void _goFinish() {
    final run = tracker.run;
    if (run == null || !mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => RunFinishScreen(runId: run.id)),
    );
  }

  // ------------------------------------------------------------ 지도

  void _onTracker() {
    if (!mounted) return;
    setState(() {});
    final pos = tracker.position;
    if (_follow && pos != null && _map != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      // 실시간으로 부드럽게 카메라 추적 (600ms 주기)
      if (now - _lastCameraMove > 600) {
        _lastCameraMove = now;
        _map!.animateCamera(CameraUpdate.newLatLng(pos));
      }
    }

    // 신규 1km 마커 비동기 로딩
    final splits = tracker.run?.splits ?? const [];
    for (final s in splits) {
      if (!_kmIcons.containsKey(s.km) && s.lat != null && s.lng != null) {
        MapMarkerHelper.getKmMarker(s.km).then((icon) {
          if (mounted) setState(() => _kmIcons[s.km] = icon);
        });
      }
    }
  }

  void _recenter() {
    setState(() {
      _follow = true;
      _selectedMember = null;
    });
    final pos = tracker.position;
    if (pos != null) _map?.animateCamera(CameraUpdate.newLatLngZoom(pos, 16));
  }

  void _focusMember(String uid) {
    final m = tracker.liveMembers[uid];
    if (uid == tracker.run?.ownerId) {
      _recenter();
      return;
    }
    setState(() {
      _follow = false;
      _selectedMember = uid;
    });
    if (m?.latitude != null) {
      final p = LatLng(m!.latitude!, m.longitude!);
      _map?.animateCamera(CameraUpdate.newLatLngZoom(p, 16));
      _map?.showMarkerInfoWindow(MarkerId('m_$uid'));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${m?.name ?? '파티원'}님의 위치 정보가 아직 없어요')),
      );
    }
  }

  Set<Polyline> _polylines() {
    final set = <Polyline>{};

    for (var i = 0; i < tracker.segments.length; i++) {
      final seg = tracker.segments[i];
      if (seg.length < 2) continue;

      final paces = i < tracker.segmentPaces.length ? tracker.segmentPaces[i] : <double?>[];
      // 스무딩 처리로 울퉁불퉁한 GPS 지터 제거 (직선 구간 보정)
      final smoothed = RouteSmoother.smoothPoints(seg);

      if (paces.isEmpty) {
        set.add(
          Polyline(
            polylineId: PolylineId('me_${i}_0'),
            points: smoothed,
            color: AppColors.neon,
            width: 4,
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            zIndex: 2,
          ),
        );
        continue;
      }

      // 페이스별 컬러 버킷팅 및 청킹
      const numBuckets = 8;
      int getBucket(double? pace) {
        if (pace == null || pace <= 0) return numBuckets ~/ 2;
        final t = ((480.0 - pace) / (480.0 - 240.0)).clamp(0.0, 1.0);
        return (t * (numBuckets - 1)).round();
      }

      var currentBucket = getBucket(paces.first);
      var currentChunk = <LatLng>[smoothed.first];
      var paceSum = paces.first ?? 360.0;
      var paceCount = 1;
      var chunkIdx = 0;

      for (var j = 1; j < smoothed.length; j++) {
        final p = j < paces.length ? paces[j] : null;
        final b = getBucket(p);
        final coord = smoothed[j];

        if (b != currentBucket && currentChunk.length >= 2) {
          currentChunk.add(coord);
          final avgP = paceSum / paceCount;
          set.add(
            Polyline(
              polylineId: PolylineId('me_${i}_$chunkIdx'),
              points: List.of(currentChunk),
              color: RouteSmoother.paceColor(avgP),
              width: 4,
              jointType: JointType.round,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
              zIndex: 2,
            ),
          );
          chunkIdx++;
          currentChunk = [coord];
          currentBucket = b;
          paceSum = p ?? 360.0;
          paceCount = 1;
        } else {
          currentChunk.add(coord);
          if (p != null) {
            paceSum += p;
            paceCount++;
          }
        }
      }

      if (currentChunk.length >= 2) {
        final avgP = paceSum / paceCount;
        set.add(
          Polyline(
            polylineId: PolylineId('me_${i}_$chunkIdx'),
            points: currentChunk,
            color: RouteSmoother.paceColor(avgP),
            width: 4,
            jointType: JointType.round,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            zIndex: 2,
          ),
        );
      }
    }

    tracker.memberTrails.forEach((uid, trail) {
      if (trail.length < 2) return;
      final color = MemberColors.of(tracker.liveMembers[uid]?.colorIndex);
      set.add(
        Polyline(
          polylineId: PolylineId('t_$uid'),
          points: List.of(trail),
          color: color.withValues(alpha: uid == _selectedMember ? 0.95 : 0.55),
          width: uid == _selectedMember ? 5 : 3,
          zIndex: 1,
        ),
      );
    });

    return set;
  }

  Set<Marker> _markers() {
    final me = tracker.run?.ownerId;
    final set = <Marker>{};

    // 1) 출발 커스텀 마커
    final firstSeg = tracker.segments.firstOrNull;
    if (firstSeg != null && firstSeg.isNotEmpty) {
      set.add(
        Marker(
          markerId: const MarkerId('start'),
          position: firstSeg.first,
          icon: _startIcon ?? BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
          anchor: const Offset(0.5, 0.5),
          infoWindow: const InfoWindow(title: '출발'),
          zIndexInt: 10,
        ),
      );
    }

    // 2) 1km, 2km 등 킬로미터 마커 뱃지
    final splits = tracker.run?.splits ?? const [];
    for (final s in splits) {
      if (s.lat != null && s.lng != null) {
        final icon = _kmIcons[s.km];
        if (icon != null) {
          set.add(
            Marker(
              markerId: MarkerId('km_${s.km}'),
              position: LatLng(s.lat!, s.lng!),
              icon: icon,
              anchor: const Offset(0.5, 0.5),
              zIndexInt: 5,
            ),
          );
        }
      }
    }

    // 3) 파티원 마커
    for (final m in tracker.liveMembers.values) {
      if (m.userId != me && m.latitude != null) {
        set.add(
          Marker(
            markerId: MarkerId('m_${m.userId}'),
            position: LatLng(m.latitude!, m.longitude!),
            icon: BitmapDescriptor.defaultMarkerWithHue(
              MemberColors.hueOf(m.colorIndex),
            ),
            infoWindow: InfoWindow(
              title: m.name,
              snippet:
                  '${m.distanceKm.toStringAsFixed(2)} km · ${m.statusLabel}',
            ),
            zIndexInt: m.userId == _selectedMember ? 2 : 1,
          ),
        );
      }
    }

    return set;
  }

  // ------------------------------------------------------------ 컨트롤

  Future<void> _confirmStop() async {
    final ok = await showDialog<bool>(
      context: context,
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
              const Text(
                '러닝을 종료할까요?',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          Fmt.km(tracker.distanceM),
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: AppColors.neon,
                            letterSpacing: -1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'km',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    Container(width: 1, height: 32, color: AppColors.outline),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          Fmt.duration(tracker.movingMs),
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '시간',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
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
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                        side: const BorderSide(color: AppColors.outline),
                      ),
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text(
                        '계속 달리기',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
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
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text(
                        '종료하기',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true) await tracker.finish(FinishReason.manual);
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final isGroup = widget.config?.mode == RunMode.group || tracker.isGroup;
    final run = tracker.run;
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              AspectRatio(aspectRatio: 1, child: _buildMap()),
              _StatsPanel(tracker: tracker, compact: isGroup),
              if (isGroup)
                Expanded(
                  flex: 8,
                  child: _GroupPanel(
                    tracker: tracker,
                    onTapMember: _focusMember,
                    selected: _selectedMember,
                  ),
                ),
              if (!isGroup) const Spacer(flex: 3),
              const SizedBox(height: 112),
            ],
          ),
          // 상단 버튼
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _RoundIcon(
                    icon: Icons.keyboard_arrow_down,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const Spacer(),
                  if (run?.goalType != null && run!.goalType != GoalType.none)
                    _GoalBadge(tracker: tracker),
                  const Spacer(),
                  _RoundIcon(
                    icon: _follow
                        ? Icons.my_location
                        : Icons.location_searching,
                    onTap: _recenter,
                  ),
                ],
              ),
            ),
          ),
          // 일시정지/재생/정지 — 항상 최상단 레이어, 하단 중앙
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: SafeArea(
              top: false,
              child: _Controls(tracker: tracker, onStop: _confirmStop),
            ),
          ),
          if (_cdShown != null || _cdWaitSec != null)
            _CountdownOverlay(number: _cdShown, waitSec: _cdWaitSec),
        ],
      ),
    );
  }

  Widget _buildMap() {
    if (!AppConfig.useMaps) {
      return Container(
        color: const Color(0xFF1E1E1E),
        child: const Center(
          child: Text(
            '지도가 비활성화되어 있습니다.',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }
    final pos = tracker.position ?? _initial;
    return Listener(
      // 사용자가 지도를 드래그하면 따라가기 해제
      onPointerMove: (_) {
        if (_follow) setState(() => _follow = false);
      },
      child: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: pos ?? const LatLng(37.5665, 126.9780),
              zoom: 16,
            ),
            onMapCreated: (c) {
              _map = c;
              if (pos != null)
                c.moveCamera(CameraUpdate.newLatLngZoom(pos, 16));
              Future.delayed(const Duration(milliseconds: 700), () {
                if (mounted) setState(() => _mapReady = true);
              });
            },
            style: kDarkMapStyle,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            compassEnabled: false,
            polylines: _polylines(),
            markers: _markers(),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _mapReady ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeOut,
                child: Container(color: const Color(0xFF1D2026)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.bg.withValues(alpha: 0.85),
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.all(10), child: Icon(icon)),
    ),
  );
}

class _GoalBadge extends StatelessWidget {
  const _GoalBadge({required this.tracker});
  final RunTracker tracker;

  @override
  Widget build(BuildContext context) {
    final r = tracker.run!;
    double ratio;
    String text;
    if (r.goalType == GoalType.distance && r.loyalty) {
      ratio = tracker.teamTotalKm * 1000 / (r.goalValue ?? 1);
      text =
          '팀 ${tracker.teamTotalKm.toStringAsFixed(2)} / ${Fmt.km(r.goalValue ?? 0)} km';
    } else if (r.goalType == GoalType.distance) {
      ratio = tracker.distanceM / (r.goalValue ?? 1);
      text = '목표 ${Fmt.km(r.goalValue ?? 0)} km';
    } else {
      ratio = tracker.movingMs / ((r.goalValue ?? 1) * 1000);
      final left = ((r.goalValue ?? 0) * 1000 - tracker.movingMs)
          .clamp(0, double.infinity)
          .toInt();
      text = '남은 시간 ${Fmt.duration(left)}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 140,
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 4,
              color: AppColors.neon,
              backgroundColor: AppColors.outline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({required this.tracker, required this.compact});
  final RunTracker tracker;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.bg,
      padding: EdgeInsets.fromLTRB(20, compact ? 12 : 24, 20, compact ? 8 : 16),
      child: Column(
        children: [
          StatTile(
            value: Fmt.km(tracker.distanceM),
            label: '거리 (km)',
            big: true,
            color: AppColors.neon,
          ),
          SizedBox(height: compact ? 8 : 20),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  value: Fmt.pace(tracker.avgPaceSec),
                  label: '평균 페이스',
                ),
              ),
              Expanded(
                child: StatTile(
                  value: Fmt.duration(tracker.movingMs),
                  label: '시간',
                ),
              ),
              Expanded(
                child: StatTile(
                  value: Fmt.pace(tracker.currentPaceSec),
                  label: '현재 페이스',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RankEntry {
  final String uid;
  final String name;
  final int colorIndex;
  final double km;
  final int pace;
  final String status;
  final bool me;
  const _RankEntry(
    this.uid,
    this.name,
    this.colorIndex,
    this.km,
    this.pace,
    this.status,
    this.me,
  );
}

/// 같이 뛰기: 파티원 리스트 + 실시간 순위 (distance DESC, 앱에서 계산 — DB 에 저장하지 않음)
class _GroupPanel extends StatelessWidget {
  const _GroupPanel({
    required this.tracker,
    required this.onTapMember,
    required this.selected,
  });
  final RunTracker tracker;
  final void Function(String uid) onTapMember;
  final String? selected;

  List<_RankEntry> _entries() {
    final me = tracker.run?.ownerId;
    final map = <String, _RankEntry>{};
    for (final p in tracker.config.participants) {
      map[p.uid] = _RankEntry(
        p.uid,
        p.name,
        p.colorIndex,
        0,
        0,
        '대기',
        p.uid == me,
      );
    }
    for (final m in tracker.liveMembers.values) {
      if (m.userId == me) continue;
      map[m.userId] = _RankEntry(
        m.userId,
        m.name,
        m.colorIndex,
        m.distanceKm,
        m.pace,
        m.statusLabel,
        false,
      );
    }
    if (me != null) {
      map[me] = _RankEntry(
        me,
        tracker.run!.ownerName,
        tracker.run!.colorIndex ?? 0,
        tracker.distanceM / 1000,
        tracker.avgPaceSec?.round() ?? 0,
        tracker.state == TrackerState.paused ? '일시정지' : '러닝중',
        true,
      );
    }
    final list = map.values.toList()..sort((a, b) => b.km.compareTo(a.km));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries();
    return Container(
      color: AppColors.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 파티원 칩 (누르면 지도에서 위치 보기)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: entries
                  .map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        selected: selected == e.uid,
                        onSelected: (_) => onTapMember(e.uid),
                        avatar: CircleAvatar(
                          backgroundColor: MemberColors.of(e.colorIndex),
                          radius: 7,
                        ),
                        label: Text(e.me ? '나' : e.name),
                        selectedColor: MemberColors.of(
                          e.colorIndex,
                        ).withValues(alpha: 0.3),
                        showCheckmark: false,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text(
              '실시간 순위',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: entries.length,
              itemBuilder: (_, i) {
                final e = entries[i];
                return InkWell(
                  onTap: () => onTapMember(e.uid),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: e.me
                          ? AppColors.neon.withValues(alpha: 0.08)
                          : AppColors.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border(
                        left: BorderSide(
                          color: MemberColors.of(e.colorIndex),
                          width: 4,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 40,
                          child: Text(
                            Fmt.rankLabel(i + 1),
                            style: TextStyle(
                              fontSize: i < 3 ? 22 : 15,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            e.me ? '${e.name} (나)' : e.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          e.status,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          Fmt.pace(e.pace.toDouble()),
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${e.km.toStringAsFixed(2)} km',
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.tracker, required this.onStop});
  final RunTracker tracker;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final state = tracker.state;
    if (state == TrackerState.running) {
      return Center(
        child: _BigButton(
          icon: Icons.pause_rounded,
          color: AppColors.neon,
          onTap: tracker.pause,
          size: 84,
        ),
      );
    }
    if (state == TrackerState.paused) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 24),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.gold.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '일시정지됨',
              style: TextStyle(
                color: AppColors.gold,
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _BigButton(
                icon: Icons.stop_rounded,
                color: AppColors.danger,
                onTap: onStop,
                size: 76,
              ),
              const SizedBox(width: 36),
              _BigButton(
                icon: Icons.play_arrow_rounded,
                color: AppColors.neon,
                onTap: tracker.resume,
                size: 76,
              ),
            ],
          ),
        ],
      );
    }
    return const SizedBox(height: 84);
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.size,
    this.label,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Material(
        color: color,
        shape: const CircleBorder(),
        elevation: 8,
        shadowColor: color.withValues(alpha: 0.6),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: size * 0.55, color: Colors.black),
          ),
        ),
      ),
      if (label != null) ...[
        const SizedBox(height: 6),
        Text(label!, style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    ],
  );
}

class _CountdownOverlay extends StatelessWidget {
  const _CountdownOverlay({this.number, this.waitSec});
  final int? number;
  final int? waitSec;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.82),
        alignment: Alignment.center,
        child: waitSec != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '곧 출발합니다',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$waitSec초',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 18,
                    ),
                  ),
                ],
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (c, a) =>
                    ScaleTransition(scale: a, child: c),
                child: Text(
                  number == 0 ? 'GO!' : '${number ?? ''}',
                  key: ValueKey(number),
                  style: const TextStyle(
                    fontSize: 140,
                    fontWeight: FontWeight.w900,
                    color: AppColors.neon,
                  ),
                ),
              ),
      ),
    );
  }
}
