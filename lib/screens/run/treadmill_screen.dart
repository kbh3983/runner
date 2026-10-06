import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../data/local/local_db.dart';
import '../../data/models/run_record.dart';
import '../../services/app_paths.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import 'run_finish_screen.dart';

class TreadmillScreen extends StatefulWidget {
  const TreadmillScreen({super.key});

  @override
  State<TreadmillScreen> createState() => _TreadmillScreenState();
}

class _TreadmillScreenState extends State<TreadmillScreen> {
  final _distCtrl = TextEditingController();
  final _timeCtrl = TextEditingController();
  final _secCtrl = TextEditingController();
  File? _image;
  bool _saving = false;

  @override
  void dispose() {
    _distCtrl.dispose();
    _timeCtrl.dispose();
    _secCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 70);
    if (picked != null) {
      setState(() => _image = File(picked.path));
    }
  }

  Future<void> _save() async {
    final distText = _distCtrl.text.replaceAll(',', '.');
    final distKm = double.tryParse(distText);
    final timeMin = int.tryParse(_timeCtrl.text) ?? 0;
    final timeSec = int.tryParse(_secCtrl.text) ?? 0;

    if (distKm == null || distKm <= 0) {
      _err('거리를 올바르게 입력해주세요.');
      return;
    }
    if (timeSec >= 60) {
      _err('초는 0~59 사이로 입력해주세요.');
      return;
    }
    if (timeMin * 60 + timeSec <= 0) {
      _err('시간을 올바르게 입력해주세요.');
      return;
    }
    if (_image == null) {
      _err('러닝머신 계기판 사진을 촬영해주세요.');
      return;
    }

    setState(() => _saving = true);

    try {
      final dir = await AppPaths.ensureDir('treadmill');
      final fileName = '${const Uuid().v4()}.jpg';
      final savedImage = await _image!.copy(p.join(dir.path, fileName));
      final relPath = 'treadmill/$fileName';

      final durationMs = (timeMin * 60 + timeSec) * 1000;
      final distanceM = distKm * 1000;

      final now = DateTime.now().millisecondsSinceEpoch;
      final auth = AuthService.instance;

      final run = RunRecord(
        id: const Uuid().v4(),
        ownerId: auth.currentUser?.uid ?? 'dummy_uid',
        ownerName: auth.displayName,
        mode: RunMode.treadmill,
        status: RunStatus.finished,
        startedAt: now - durationMs,
        endedAt: now,
        durationMs: durationMs,
        distanceM: distanceM,
        thumbnailPath: relPath,
        avgPaceSecPerKm: (durationMs / 1000) / (distanceM / 1000),
      );

      await LocalDb.instance.upsertRun(run);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => RunFinishScreen(runId: run.id)),
      );
    } catch (e) {
      _err('저장에 실패했어요: $e');
      setState(() => _saving = false);
    }
  }

  void _err(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('러닝머신 기록 추가')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('러닝머신은 GPS 측정이 어려워요.\n직접 달린 거리와 시간을 입력하고 계기판을 인증해주세요.',
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 32),
            TextField(
              controller: _distCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d{0,3}([.,]\d{0,2})?'))],
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                labelText: '달린 거리 (km)',
                hintText: '예: 5.00',
                suffixText: 'km',
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _timeCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      labelText: '달린 시간 (분)',
                      hintText: '예: 30',
                      suffixText: '분',
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _secCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      labelText: '초',
                      hintText: '예: 25',
                      suffixText: '초',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),
            const Text('인증샷 (필수)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _pickImage,
              child: Container(
                height: 200,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  image: _image != null ? DecorationImage(image: FileImage(_image!), fit: BoxFit.cover) : null,
                ),
                child: _image == null
                    ? const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.camera_alt, size: 48, color: AppColors.textSecondary),
                          SizedBox(height: 8),
                          Text('여기를 눌러 계기판 사진 촬영', style: TextStyle(color: AppColors.textSecondary)),
                        ],
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 48),
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              child: _saving
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('기록 저장하기', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}
