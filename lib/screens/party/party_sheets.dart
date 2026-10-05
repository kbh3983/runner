import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../core/party_ids.dart';
import '../../data/local/local_db.dart';
import '../../data/models/party.dart';
import '../../data/models/run_record.dart';
import '../../services/party_service.dart';
import '../../services/server_clock.dart';
import '../../theme/app_theme.dart';
import '../group/group_result_screen.dart';
import '../run/start_options_sheet.dart';

// ====================================================================== 같이 뛰기

Future<void> showTogetherSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('같이 뛰기', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          const Text('파티를 만들거나, 공유받은 파티에 참여하세요', style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _BigChoice(
                  icon: Icons.add_circle_outline,
                  label: '파티 만들기',
                  onTap: () {
                    Navigator.pop(ctx);
                    showCreatePartySheet(context);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _BigChoice(
                  icon: Icons.login_rounded,
                  label: '참여하기',
                  onTap: () {
                    Navigator.pop(ctx);
                    showJoinPartySheet(context);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _BigChoice extends StatelessWidget {
  const _BigChoice({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceHigh,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: SizedBox(
          height: 120,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 40, color: AppColors.neon),
              const SizedBox(height: 10),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ],
          ),
        ),
      ),
    );
  }
}

// ====================================================================== 파티 만들기

Future<void> showCreatePartySheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _CreatePartySheet(),
  );
}

class _CreatePartySheet extends StatefulWidget {
  const _CreatePartySheet();

  @override
  State<_CreatePartySheet> createState() => _CreatePartySheetState();
}

class _CreatePartySheetState extends State<_CreatePartySheet> {
  int _members = 2;
  GoalType _goalType = GoalType.none;
  double? _goalValue;
  bool _loyalty = false;
  final _pwCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pwCtrl.dispose();
    super.dispose();
  }

  bool get _valid {
    if (!RegExp(r'^\d{6}$').hasMatch(_pwCtrl.text)) return false;
    if (_goalType == GoalType.distance) return (_goalValue ?? 0) >= 100;
    if (_goalType == GoalType.time) return (_goalValue ?? 0) >= 60;
    return true;
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await PartyService.instance.create(
        maxMembers: _members,
        goalType: _goalType,
        goalValue: _goalValue,
        loyalty: _loyalty,
        password: _pwCtrl.text,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('파티가 만들어졌어요! (${res.partyId}) 파티를 눌러 공유하세요')),
      );
    } on PartyException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '파티를 만들지 못했어요: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('파티 만들기', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 20),
            const Text('같이 뛸 인원 (나 포함)', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(16)),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton.filledTonal(
                    onPressed: _members > 2 ? () => setState(() => _members--) : null,
                    icon: const Icon(Icons.remove),
                  ),
                  Text('$_members명', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: AppColors.neon, foregroundColor: Colors.black),
                    onPressed: _members < AppConfig.maxPartyMembers ? () => setState(() => _members++) : null,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Text('최대 10명', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 20),
            const Text('러닝 목표 (선택)', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            GoalPicker(
              allowLoyalty: true,
              onChanged: (t, v, l) => setState(() {
                _goalType = t;
                _goalValue = v;
                _loyalty = l;
              }),
            ),
            const SizedBox(height: 20),
            const Text('비밀번호 (숫자 6자리)', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            TextField(
              controller: _pwCtrl,
              keyboardType: TextInputType.number,
              obscureText: false,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, letterSpacing: 12, fontWeight: FontWeight.w900),
              decoration: const InputDecoration(hintText: '000000', counterText: ''),
              onChanged: (_) => setState(() {}),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _valid && !_busy ? _create : null,
              child: _busy
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('파티 만들기'),
            ),
          ],
        ),
      ),
    );
  }
}

// ====================================================================== 참여하기

Future<void> showJoinPartySheet(BuildContext context, {String? initialId, String? initialPw}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _JoinPartySheet(initialId: initialId, initialPw: initialPw),
  );
}

class _JoinPartySheet extends StatefulWidget {
  const _JoinPartySheet({this.initialId, this.initialPw});
  final String? initialId;
  final String? initialPw;

  @override
  State<_JoinPartySheet> createState() => _JoinPartySheetState();
}

class _JoinPartySheetState extends State<_JoinPartySheet> {
  late final _idCtrl = TextEditingController(text: widget.initialId ?? '');
  late final _pwCtrl = TextEditingController(text: widget.initialPw ?? '');
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialId == null) _tryClipboard(silent: true);
  }

  @override
  void dispose() {
    _idCtrl.dispose();
    _pwCtrl.dispose();
    super.dispose();
  }

  Future<void> _tryClipboard({bool silent = false}) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    final invite = PartyService.parseInvite(text);
    if (invite.id != null) {
      setState(() {
        _idCtrl.text = invite.id!;
        if (invite.pw != null) _pwCtrl.text = invite.pw!;
      });
    } else if (!silent && text.trim().isNotEmpty) {
      setState(() => _idCtrl.text = text.trim());
    }
  }

  bool get _valid => _idCtrl.text.trim().contains('#') && RegExp(r'^\d{6}$').hasMatch(_pwCtrl.text);

  Future<void> _join() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await PartyService.instance.join(_idCtrl.text, _pwCtrl.text);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('파티에 참여했어요! 방장이 시작하면 자동으로 출발해요')));
    } on PartyException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '참여하지 못했어요: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('파티 참여하기', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 4),
          const Text('공유받은 파티 ID와 비밀번호를 입력하세요', style: TextStyle(color: AppColors.textSecondary)),
          const SizedBox(height: 20),
          TextField(
            controller: _idCtrl,
            decoration: InputDecoration(
              labelText: '파티 ID',
              hintText: '예) abc123#1',
              suffixIcon: IconButton(
                tooltip: '붙여넣기',
                icon: const Icon(Icons.content_paste),
                onPressed: () => _tryClipboard(),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pwCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: '비밀번호 6자리', counterText: ''),
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _valid && !_busy ? _join : null,
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('참여하기'),
          ),
        ],
      ),
    );
  }
}

// ====================================================================== 파티 카드

class PartyCard extends StatelessWidget {
  const PartyCard({super.key, required this.party, required this.uid, required this.onTap});

  final Party party;
  final String uid;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final running = party.status == PartyStatus.running;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          width: 220,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: running ? AppColors.neon : AppColors.outline, width: running ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _StatusChip(party: party),
                  const Spacer(),
                  if (party.isHost(uid)) const Icon(Icons.star_rounded, size: 18, color: AppColors.gold),
                ],
              ),
              const Spacer(),
              Text(party.displayName,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.group, size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Text('${party.memberIds.length}/${party.maxMembers}',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  const SizedBox(width: 10),
                  const Icon(Icons.flag, size: 14, color: AppColors.textSecondary),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      party.loyalty ? '의리 ${Fmt.goal(party.goalType.name, party.goalValue)}' : Fmt.goal(party.goalType.name, party.goalValue),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.party});
  final Party party;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (party.status) {
      PartyStatus.waiting => ('대기중', AppColors.textSecondary),
      PartyStatus.running => (party.loyalty ? '의리게임 진행중' : '러닝중', AppColors.neon),
      PartyStatus.finished => ('종료', AppColors.textSecondary),
      PartyStatus.success => ('성공', AppColors.neon),
      PartyStatus.failed => ('실패', AppColors.danger),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }
}

// ====================================================================== 파티 상세

Future<void> showPartyDetailSheet(
  BuildContext context,
  String partyKey, {
  required Future<void> Function(Party) onRun,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PartyDetailSheet(partyKey: partyKey, onRun: onRun),
  );
}

class _PartyDetailSheet extends StatefulWidget {
  const _PartyDetailSheet({required this.partyKey, required this.onRun});
  final String partyKey;
  final Future<void> Function(Party) onRun;

  @override
  State<_PartyDetailSheet> createState() => _PartyDetailSheetState();
}

class _PartyDetailSheetState extends State<_PartyDetailSheet> {
  final uid = AppConfig.useFirebase ? FirebaseAuth.instance.currentUser!.uid : 'dummy_uid';
  bool _busy = false;

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on PartyException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<bool> _confirm(String title, String body, String ok, {bool danger = false}) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ok, style: TextStyle(color: danger ? AppColors.danger : AppColors.neon)),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  Future<void> _share(Party party, {bool copyOnly = false}) async {
    final pw = await LocalDb.instance.getPartySecret(party.key);
    final text = PartyService.instance.shareText(party, pw);
    if (copyOnly) {
      await Clipboard.setData(ClipboardData(text: text));
      _toast(pw == null ? '파티 ID를 복사했어요 (비밀번호는 직접 알려주세요)' : '파티 ID와 비밀번호를 복사했어요');
      return;
    }
    await SharePlus.instance.share(ShareParams(text: text, subject: '${AppConfig.appNameKo} 같이 뛰기 초대'));
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Party?>(
      stream: PartyService.instance.watch(widget.partyKey),
      builder: (context, snap) {
        if (snap.hasError) {
          return const _SheetMessage(icon: Icons.block, text: '파티에 접근할 수 없어요\n(삭제되었거나 강퇴되었어요)');
        }
        if (!snap.hasData && snap.connectionState == ConnectionState.waiting) {
          return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
        }
        final party = snap.data;
        if (party == null) return const _SheetMessage(icon: Icons.delete_outline, text: '삭제된 파티예요');
        if (!party.memberIds.contains(uid)) {
          return const _SheetMessage(icon: Icons.block, text: '더 이상 이 파티의 멤버가 아니에요');
        }
        final isHost = party.isHost(uid);
        final waiting = party.status == PartyStatus.waiting;
        final running = party.status == PartyStatus.running;

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          builder: (_, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(party.displayName,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                  ),
                  _StatusChip(party: party),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText('ID: ${party.id}', style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _InfoPill(icon: Icons.group, text: '${party.memberIds.length}/${party.maxMembers}명'),
                  _InfoPill(icon: Icons.flag, text: Fmt.goal(party.goalType.name, party.goalValue)),
                  if (party.loyalty) const _InfoPill(icon: Icons.handshake, text: '의리게임', highlight: true),
                ],
              ),
              if (party.loyalty && running) ...[
                const SizedBox(height: 16),
                _LoyaltyProgress(party: party),
              ],
              const SizedBox(height: 24),
              const Text('파티원', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              ...party.sortedMembers.map((m) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: MemberColors.of(m.colorIndex),
                      foregroundImage: m.photoUrl != null ? NetworkImage(m.photoUrl!) : null,
                      child: Text(m.name.characters.first, style: const TextStyle(color: Colors.black)),
                    ),
                    title: Text(m.name + (m.uid == uid ? ' (나)' : ''),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: m.uid == party.hostId ? const Text('방장', style: TextStyle(color: AppColors.gold)) : null,
                    trailing: isHost && waiting && m.uid != uid
                        ? TextButton(
                            onPressed: _busy
                                ? null
                                : () async {
                                    if (await _confirm('강퇴하기', '${m.name}님을 파티에서 내보낼까요?\n강퇴된 사용자는 다시 참여할 수 없어요.', '강퇴',
                                        danger: true)) {
                                      _guard(() => PartyService.instance.kick(party.key, m.uid));
                                    }
                                  },
                            child: const Text('강퇴', style: TextStyle(color: AppColors.danger)),
                          )
                        : null,
                  )),
              const SizedBox(height: 20),
              if (isHost && waiting)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final ok = await _confirm(
                            '러닝 시작',
                            '파티원 ${party.memberIds.length}명과 함께 출발할까요?\n시작 후에는 더 이상 참여할 수 없어요.',
                            '시작',
                          );
                          if (!ok) return;
                          
                          // 시트를 먼저 닫아야 _checkAutoStart 가 띄우는 RunScreen 이 팝되지 않음
                          if (mounted) Navigator.pop(this.context);
                          
                          try {
                            await PartyService.instance.start(party.key);
                          } catch (e) {
                            debugPrint('party start failed: $e');
                          }
                        },
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('러닝 시작'),
                ),
              if (running) ...[
                FutureBuilder<List<RunRecord>>(
                  future: LocalDb.instance.getRunsForParty(uid, party.key),
                  builder: (_, s) {
                    final mine = s.data ?? [];
                    final canRun = mine.isEmpty || party.loyalty;
                    final expired = party.loyaltyDeadline != null && ServerClock.nowMs() > party.loyaltyDeadline!;
                    if (!canRun || expired) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: FilledButton.icon(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onRun(party);
                        },
                        icon: const Icon(Icons.directions_run),
                        label: Text(mine.isEmpty ? '러닝 참여하기' : '이어 달리기 (기여 거리 추가)'),
                      ),
                    );
                  },
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    final nav = Navigator.of(context);
                    nav.pop();
                    nav.push(MaterialPageRoute(builder: (_) => GroupResultScreen(partyKey: party.key)));
                  },
                  icon: const Icon(Icons.leaderboard),
                  label: const Text('실시간 순위 / 기록 보기'),
                ),
              ],
              if (isHost) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _share(party),
                        icon: const Icon(Icons.share),
                        label: const Text('공유하기'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _share(party, copyOnly: true),
                        icon: const Icon(Icons.copy),
                        label: const Text('복사'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
                  onPressed: _busy
                      ? null
                      : () async {
                          if (await _confirm('모임 삭제하기', '파티를 삭제할까요? 파티원 모두에게서 사라져요.', '삭제', danger: true)) {
                            await _guard(() async {
                              await PartyService.instance.delete(party.key);
                              if (mounted) Navigator.pop(this.context);
                            });
                          }
                        },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('모임 삭제하기'),
                ),
              ] else if (waiting) ...[
                const SizedBox(height: 10),
                const Text('방장이 러닝을 시작하면 자동으로 카운트다운이 시작돼요',
                    textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          if (await _confirm('파티 나가기', '이 파티에서 나갈까요?', '나가기', danger: true)) {
                            await _guard(() async {
                              await PartyService.instance.leave(party.key);
                              if (mounted) Navigator.pop(this.context);
                            });
                          }
                        },
                  child: const Text('파티 나가기'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LoyaltyProgress extends StatelessWidget {
  const _LoyaltyProgress({required this.party});
  final Party party;

  @override
  Widget build(BuildContext context) {
    final goal = party.goalValue ?? 1;
    final ratio = (party.loyaltyTotalM / goal).clamp(0.0, 1.0);
    final left = party.loyaltyDeadline == null ? null : party.loyaltyDeadline! - ServerClock.nowMs();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('팀 합계 ${Fmt.km(party.loyaltyTotalM)} / ${Fmt.km(goal)} km (완료 기록 기준)',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: ratio,
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
            color: AppColors.neon,
            backgroundColor: AppColors.outline,
          ),
          if (left != null) ...[
            const SizedBox(height: 6),
            Text(left > 0 ? '남은 시간 ${Fmt.duration(left)}' : '제한 시간 종료',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.text, this.highlight = false});
  final IconData icon;
  final String text;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final c = highlight ? AppColors.neon : AppColors.textPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: c, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _SheetMessage extends StatelessWidget {
  const _SheetMessage({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 240,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      );
}

/// 다른 파일에서 쓰는 헬퍼
String partyDisplayId(String partyKey) => PartyIds.toDisplay(partyKey);
