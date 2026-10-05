import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/run_record.dart';
import '../../services/run_tracker.dart';
import '../../theme/app_theme.dart';
import 'treadmill_screen.dart';

/// 러닝 목표 입력 위젯 (자유 / 거리(00.00km) / 시간(분)). 둘 중 하나만 선택 가능.
class GoalPicker extends StatefulWidget {
  const GoalPicker({super.key, required this.onChanged, this.allowLoyalty = false});

  final void Function(GoalType type, double? value, bool loyalty) onChanged;
  final bool allowLoyalty;

  @override
  State<GoalPicker> createState() => _GoalPickerState();
}

class _GoalPickerState extends State<GoalPicker> {
  GoalType _type = GoalType.none;
  final _distanceCtrl = TextEditingController();
  final _timeCtrl = TextEditingController();
  bool _loyalty = false;

  @override
  void dispose() {
    _distanceCtrl.dispose();
    _timeCtrl.dispose();
    super.dispose();
  }

  void _emit() {
    double? value;
    if (_type == GoalType.distance) {
      final km = double.tryParse(_distanceCtrl.text.replaceAll(',', '.'));
      value = km == null ? null : (km * 1000);
    } else if (_type == GoalType.time) {
      final min = int.tryParse(_timeCtrl.text);
      value = min == null ? null : min * 60.0;
    }
    widget.onChanged(_type, value, _type == GoalType.distance && _loyalty);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<GoalType>(
          segments: const [
            ButtonSegment(value: GoalType.none, label: Text('자유'), icon: Icon(Icons.all_inclusive)),
            ButtonSegment(value: GoalType.distance, label: Text('거리'), icon: Icon(Icons.straighten)),
            ButtonSegment(value: GoalType.time, label: Text('시간'), icon: Icon(Icons.timer_outlined)),
          ],
          selected: {_type},
          showSelectedIcon: false,
          style: SegmentedButton.styleFrom(
            selectedBackgroundColor: AppColors.neon,
            selectedForegroundColor: Colors.black,
          ),
          onSelectionChanged: (s) {
            setState(() => _type = s.first);
            _emit();
          },
        ),
        const SizedBox(height: 16),
        if (_type == GoalType.none)
          const Text(
            '목표 없이 달려요. 직접 정지할 때까지 러닝이 계속돼요.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary),
          ),
        if (_type == GoalType.distance) ...[
          TextField(
            controller: _distanceCtrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d{0,2}([.,]\d{0,2})?')),
            ],
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
            decoration: const InputDecoration(hintText: '00.00', suffixText: 'km'),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 6),
          const Text('해당 거리에 도달하면 러닝이 자동 종료돼요',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          if (widget.allowLoyalty) ...[
            const SizedBox(height: 8),
            CheckboxListTile(
              value: _loyalty,
              onChanged: (v) {
                setState(() => _loyalty = v ?? false);
                _emit();
              },
              activeColor: AppColors.neon,
              checkColor: Colors.black,
              contentPadding: EdgeInsets.zero,
              title: const Text('🤝 의리게임', style: TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text('파티원 모두의 거리 합계가 목표에 도달해야 레이스가 끝나요. 24시간 안에 못 채우면 실패!'),
            ),
          ],
        ],
        if (_type == GoalType.time) ...[
          TextField(
            controller: _timeCtrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w900),
            decoration: const InputDecoration(hintText: '30', suffixText: '분'),
            onChanged: (_) => _emit(),
          ),
          const SizedBox(height: 6),
          const Text('해당 시간(일시정지 제외)이 지나면 러닝이 자동 종료돼요',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        ],
      ],
    );
  }
}

/// 혼자 러닝 시작 전 옵션 시트
Future<RunConfig?> showStartOptionsSheet(BuildContext context) {
  return showModalBottomSheet<RunConfig>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => const _StartOptionsSheet(),
  );
}

class _StartOptionsSheet extends StatefulWidget {
  const _StartOptionsSheet();

  @override
  State<_StartOptionsSheet> createState() => _StartOptionsSheetState();
}

enum RunLocation { outdoor, treadmill }

class _StartOptionsSheetState extends State<_StartOptionsSheet> {
  RunLocation _loc = RunLocation.outdoor;
  GoalType _type = GoalType.none;
  double? _value;

  bool get _valid {
    if (_loc == RunLocation.treadmill) return true;
    if (_type == GoalType.none) return true;
    if (_value == null || _value! <= 0) return false;
    if (_type == GoalType.distance) return _value! >= 100;
    return _value! >= 60;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 0, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('러닝 시작', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 16),
          SegmentedButton<RunLocation>(
            segments: const [
              ButtonSegment(value: RunLocation.outdoor, label: Text('야외 러닝'), icon: Icon(Icons.park)),
              ButtonSegment(value: RunLocation.treadmill, label: Text('러닝머신'), icon: Icon(Icons.fitness_center)),
            ],
            selected: {_loc},
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              selectedBackgroundColor: AppColors.neon,
              selectedForegroundColor: Colors.black,
            ),
            onSelectionChanged: (s) => setState(() => _loc = s.first),
          ),
          const SizedBox(height: 24),
          if (_loc == RunLocation.outdoor) ...[
            const Text('목표는 선택사항이에요', style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            GoalPicker(onChanged: (t, v, _) => setState(() {
                  _type = t;
                  _value = v;
                })),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _valid
                  ? () => Navigator.pop(
                        context,
                        RunConfig(mode: RunMode.solo, goalType: _type, goalValue: _type == GoalType.none ? null : _value),
                      )
                  : null,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('시작하기'),
            ),
          ] else ...[
            const Text(
              '러닝머신은 거리를 자동으로 잴 수 없어요.\n달리기를 마치고 난 뒤 직접 기록을 입력하고 계기판 사진을 찍어 인증해야 합니다.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(context); // close sheet
                Navigator.push(context, MaterialPageRoute(builder: (_) => const TreadmillScreen()));
              },
              icon: const Icon(Icons.edit_document),
              label: const Text('기록 입력하러 가기'),
            ),
          ],
        ],
      ),
    );
  }
}
