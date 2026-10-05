import 'package:intl/intl.dart';

/// 화면/음성 표시용 포맷 함수 모음.
class Fmt {
  Fmt._();

  /// 미터 → "4.82"
  static String km(double meters, {int digits = 2}) =>
      (meters / 1000).toStringAsFixed(digits);

  /// sec/km → 5'25"
  static String pace(double? secPerKm) {
    if (secPerKm == null || !secPerKm.isFinite || secPerKm <= 0 || secPerKm > 3600) {
      return "-'--\"";
    }
    final s = secPerKm.round();
    return "${s ~/ 60}'${(s % 60).toString().padLeft(2, '0')}\"";
  }

  /// sec/km → "5분 25초" (음성 안내용)
  static String paceSpeech(double? secPerKm) {
    if (secPerKm == null || !secPerKm.isFinite || secPerKm <= 0) return '측정 불가';
    final s = secPerKm.round();
    return '${s ~/ 60}분 ${s % 60}초';
  }

  /// ms → "1:02:03" / "32:10"
  static String duration(int ms) {
    final total = (ms / 1000).floor();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  static String durationKo(int ms) {
    final total = (ms / 1000).floor();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) return '$h시간 $m분';
    if (m > 0) return '$m분 $s초';
    return '$s초';
  }

  static String date(int epochMs) =>
      DateFormat('yyyy.MM.dd (E)', 'ko_KR').format(DateTime.fromMillisecondsSinceEpoch(epochMs));

  static String dateTime(int epochMs) => DateFormat('yyyy.MM.dd (E) HH:mm', 'ko_KR')
      .format(DateTime.fromMillisecondsSinceEpoch(epochMs));

  static String time(int epochMs) =>
      DateFormat('a h:mm', 'ko_KR').format(DateTime.fromMillisecondsSinceEpoch(epochMs));

  static String goal(String goalType, num? goalValue) {
    switch (goalType) {
      case 'distance':
        return '${((goalValue ?? 0) / 1000).toStringAsFixed(2)} km';
      case 'time':
        return '${((goalValue ?? 0) / 60).round()} 분';
      default:
        return '자유 러닝';
    }
  }

  static String rankLabel(int rank) {
    switch (rank) {
      case 1:
        return '🥇';
      case 2:
        return '🥈';
      case 3:
        return '🥉';
      default:
        return '$rank위';
    }
  }
}
