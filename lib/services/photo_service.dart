import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/local/local_db.dart';
import '../data/models/gps_point.dart';
import 'app_paths.dart';

/// 러닝 사진 — **로컬 전용** (서버 저장 비용 없음).
/// 사진 파일은 앱 Documents/photos/{runId}/ 에 복사하고 DB 에는 상대경로만 저장한다.
class PhotoService {
  PhotoService._();
  static final PhotoService instance = PhotoService._();

  final _picker = ImagePicker();

  Future<RunPhoto?> add(String runId, ImageSource source) async {
    final picked = await _picker.pickImage(source: source, maxWidth: 2048, imageQuality: 85);
    if (picked == null) return null;
    final relDir = p.join('photos', runId);
    await AppPaths.ensureDir(relDir);
    final id = const Uuid().v4();
    final ext = p.extension(picked.path).isEmpty ? '.jpg' : p.extension(picked.path);
    final relPath = p.join(relDir, '$id$ext');
    await File(picked.path).copy(AppPaths.resolve(relPath).path);
    final photo = RunPhoto(
      id: id,
      runId: runId,
      relPath: relPath,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await LocalDb.instance.insertPhoto(photo);
    return photo;
  }

  Future<void> delete(RunPhoto photo) async {
    try {
      final f = AppPaths.resolve(photo.relPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    await LocalDb.instance.deletePhoto(photo.id);
  }

  File file(RunPhoto photo) => AppPaths.resolve(photo.relPath);
}
