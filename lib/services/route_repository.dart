import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../data/local/local_db.dart';
import '../data/models/run_record.dart';

/// 러닝 경로 조회: 로컬 GPS 원본이 있으면 그것을, 없으면(서버에서 복원된 기록) 다운샘플 경로 사용
class RouteRepository {
  RouteRepository._();

  static Future<List<List<LatLng>>> segmentsFor(RunRecord run) async {
    final pts = await LocalDb.instance.getPoints(run.id);
    if (pts.isNotEmpty) {
      final result = <List<LatLng>>[];
      int? seg;
      for (final p in pts) {
        if (p.segment != seg) {
          result.add([]);
          seg = p.segment;
        }
        result.last.add(p.latLng);
      }
      return result;
    }
    return run.remotePath?.segments ?? [];
  }
}
