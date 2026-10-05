import 'package:flutter/material.dart';

/// 파티 ID 규칙.
///
/// * partyId (공유용) : `{hostUid}#{roomNo}`
/// * partyKey (DB 키) : `#` → `_`  (RTDB 키에 `#` 사용 불가)
class PartyIds {
  PartyIds._();

  static String toKey(String partyIdOrKey) => partyIdOrKey.trim().replaceAll('#', '_');

  static String toDisplay(String partyKey) {
    final i = partyKey.lastIndexOf('_');
    if (i < 0) return partyKey;
    return '${partyKey.substring(0, i)}#${partyKey.substring(i + 1)}';
  }
}

/// 파티원 고유 색 (colorIndex 0..9)
class MemberColors {
  MemberColors._();

  static const colors = <Color>[
    Color(0xFFCCFF00), // neon lime
    Color(0xFF40C4FF), // sky
    Color(0xFFFF4081), // pink
    Color(0xFFFFAB40), // orange
    Color(0xFFB388FF), // purple
    Color(0xFF64FFDA), // teal
    Color(0xFFFF5252), // red
    Color(0xFFFFFF00), // yellow
    Color(0xFF448AFF), // blue
    Color(0xFFFF80AB), // light pink
  ];

  /// google_maps BitmapDescriptor.defaultMarkerWithHue 용 hue
  static const hues = <double>[75, 200, 330, 30, 265, 165, 0, 60, 220, 345];

  static Color of(int? index) => colors[(index ?? 0) % colors.length];
  static double hueOf(int? index) => hues[(index ?? 0) % hues.length];
}
