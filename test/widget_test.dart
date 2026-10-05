import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:running_app/core/format.dart';
import 'package:running_app/core/geo.dart';
import 'package:running_app/core/party_ids.dart';
import 'package:running_app/services/party_service.dart';

void main() {
  group('Geo', () {
    test('polyline encode/decode roundtrip (Google reference)', () {
      final pts = [const LatLng(38.5, -120.2), const LatLng(40.7, -120.95), const LatLng(43.252, -126.453)];
      final enc = Geo.encodePolyline(pts);
      expect(enc, '_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      final dec = Geo.decodePolyline(enc);
      for (var i = 0; i < pts.length; i++) {
        expect(dec[i].latitude, closeTo(pts[i].latitude, 1e-5));
        expect(dec[i].longitude, closeTo(pts[i].longitude, 1e-5));
      }
    });

    test('haversine ~111km per degree latitude', () {
      expect(Geo.distance(37, 127, 38, 127), closeTo(111195, 200));
    });

    test('splitByBreaks', () {
      final pts = List.generate(6, (i) => LatLng(i.toDouble(), 0));
      final segs = Geo.splitByBreaks(pts, [2, 4]);
      expect(segs.map((s) => s.length).toList(), [2, 2, 2]);
    });
  });

  group('Fmt', () {
    test('pace', () {
      expect(Fmt.pace(325), "5'25\"");
      expect(Fmt.pace(null), "-'--\"");
      expect(Fmt.paceSpeech(325), '5분 25초');
    });
    test('duration', () {
      expect(Fmt.duration(65000), '01:05');
      expect(Fmt.duration(3725000), '1:02:05');
    });
  });

  group('PartyIds', () {
    test('key conversion is reversible', () {
      const id = 'abcXYZ123#7';
      final key = PartyIds.toKey(id);
      expect(key, 'abcXYZ123_7');
      expect(PartyIds.toDisplay(key), id);
    });

    test('custom uid with colon', () {
      expect(PartyIds.toDisplay(PartyIds.toKey('kakao:123#2')), 'kakao:123#2');
    });

    test('parse invite text', () {
      const text = '파티 ID: abc#3\n비밀번호: 123456\n바로 참여: runtogether://join?id=abc%233&pw=123456';
      final inv = PartyService.parseInvite(text);
      expect(inv.id, 'abc#3');
      expect(inv.pw, '123456');
    });
  });
}
