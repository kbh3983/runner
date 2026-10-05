import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// iOS 는 앱 업데이트 시 컨테이너 절대경로가 바뀌므로
/// DB 에는 Documents 기준 **상대경로**만 저장하고 런타임에 해석한다.
class AppPaths {
  AppPaths._();

  static late String documents;

  static Future<void> init() async {
    documents = (await getApplicationDocumentsDirectory()).path;
  }

  static File resolve(String relPath) => File(p.join(documents, relPath));

  static Future<Directory> ensureDir(String relDir) async {
    final dir = Directory(p.join(documents, relDir));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
