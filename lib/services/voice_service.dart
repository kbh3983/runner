import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/format.dart';

/// 음성 안내 (페이스 메이커 / 카운트다운)
class VoiceService {
  VoiceService._();
  static final VoiceService instance = VoiceService._();

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  Future<void> _chain = Future.value();

  Future<void> init() async {
    if (_ready) return;
    try {
      await _tts.setLanguage('ko-KR');
      await _tts.setSpeechRate(Platform.isIOS ? 0.5 : 0.55);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(true);
      if (Platform.isIOS) {
        // 백그라운드/무음모드에서도 안내, 음악은 잠시 작게
        await _tts.setSharedInstance(true);
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
            IosTextToSpeechAudioCategoryOptions.duckOthers,
          ],
          IosTextToSpeechAudioMode.voicePrompt,
        );
      }
      _ready = true;
    } catch (e) {
      debugPrint('TTS init failed: $e');
    }
  }

  /// 순서대로 재생 (겹치지 않게 큐잉)
  Future<void> speak(String text) {
    _chain = _chain.then((_) async {
      try {
        await init();
        await _tts.speak(text);
      } catch (e) {
        debugPrint('TTS speak failed: $e');
      }
    });
    return _chain;
  }

  /// 즉시 재생 (카운트다운처럼 타이밍이 중요한 경우)
  Future<void> speakNow(String text) async {
    try {
      await init();
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> announceStart() => speak('러닝이 시작되었습니다');

  Future<void> announceFinish() => speak('러닝이 종료되었습니다');

  Future<void> announceKm({
    required int km,
    required double lapPaceSec,
    required double? avgPaceSec,
  }) =>
      speak('현재 거리 : $km 키로미터, '
          '키로당 페이스 : ${Fmt.paceSpeech(lapPaceSec)}, '
          '평균 키로당 페이스 : ${Fmt.paceSpeech(avgPaceSec)}');
}
