import 'dart:async';
import 'dart:math';

import 'package:audio_session/audio_session.dart';
import 'package:clock_app/alarm/types/alarm.dart';
import 'package:clock_app/audio/logic/ringtones.dart';
import 'package:clock_app/audio/types/ringtone_manager.dart';
import 'package:clock_app/developer/logic/logger.dart';
import 'package:clock_app/timer/types/timer.dart';
import 'package:just_audio/just_audio.dart';
import 'package:vibration/vibration.dart';

Random random = Random();

class RingtonePlayer {
  static AudioPlayer? _alarmPlayer;
  static AudioPlayer? _timerPlayer;
  static AudioPlayer? _mediaPlayer;
  static AudioPlayer? activePlayer;
  static bool _vibratorIsAvailable = false;
  // Cancel any old ramp when a new alarm starts or is dismissed.
  static int _volumeRampGeneration = 0;

  static Future<void> initialize() async {
    _alarmPlayer ??= AudioPlayer(handleInterruptions: true);
    _timerPlayer ??= AudioPlayer(handleInterruptions: true);
    _mediaPlayer ??= AudioPlayer(handleInterruptions: true);
    _mediaPlayer?.setAndroidAudioAttributes(
      const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        usage: AndroidAudioUsage.media,
      ),
    );
    _vibratorIsAvailable = (await Vibration.hasVibrator()) ?? false;
  }

  static Future<void> playUri(String ringtoneUri,
      {bool vibrate = false,
      LoopMode loopMode = LoopMode.one,
      AndroidAudioUsage channel = AndroidAudioUsage.alarm}) async {
    activePlayer = _mediaPlayer;
    await _play(ringtoneUri, vibrate: vibrate, loopMode: LoopMode.one);
  }


 
  static Future<void> playAlarm(Alarm alarm,
      {LoopMode loopMode = LoopMode.one}) async {
    ++_volumeRampGeneration;
    await activePlayer?.stop();
    _alarmPlayer = AudioPlayer(handleInterruptions: false);
    await _alarmPlayer?.setAndroidAudioAttributes(AndroidAudioAttributes(
      usage: alarm.audioChannel,
      contentType: AndroidAudioContentType.music,
    ));
    activePlayer = _alarmPlayer;
    String uri = await getRingtoneUri(alarm.ringtone);

    logger.t("Playing alarm with uri: $uri");

    await _play(uri,
        vibrate: alarm.vibrate,
        loopMode: LoopMode.one,
        volume: alarm.volume / 100,
        secondsToMaxVolume: alarm.risingVolumeDuration.inSeconds,
        startAtRandomPos: alarm.shouldStartMelodyAtRandomPos);
  }

  static Future<void> playTimer(ClockTimer timer,
      {LoopMode loopMode = LoopMode.one}) async {
    await _timerPlayer?.setAndroidAudioAttributes(AndroidAudioAttributes(
      usage: timer.audioChannel,
      contentType: AndroidAudioContentType.music,
    ));
    activePlayer = _timerPlayer;
    await _play(
      timer.ringtone.uri,
      vibrate: timer.vibrate,
      loopMode: LoopMode.one,
      volume: timer.volume / 100,
      secondsToMaxVolume: timer.risingVolumeDuration.inSeconds,
    );
  }

  static Future<void> setVolume(double volume) async {
    ++_volumeRampGeneration;
    final safeVolume = volume.clamp(0.0, 1.0).toDouble();
    logger.t("Setting volume to $safeVolume");
    await activePlayer?.setVolume(safeVolume);
  }

  static Future<void> _play(
    String ringtoneUri, {
    bool vibrate = false,
    LoopMode loopMode = LoopMode.one,
    double volume = 1.0,
    int secondsToMaxVolume = 0,
    bool startAtRandomPos = false,
  }) async {
    final player = activePlayer;
    if (player == null) return;
    final generation = ++_volumeRampGeneration;

    try {
      RingtoneManager.lastPlayedRingtoneUri = ringtoneUri;
      if (_vibratorIsAvailable && vibrate) {
        Vibration.vibrate(pattern: [500, 1000], repeat: 0);
      }
      await player.stop();
      await player.setLoopMode(loopMode);
      final duration = await player.setAudioSource(
        AudioSource.uri(Uri.parse(ringtoneUri)),
      );
      logger.t("Duration: $duration");

      if (duration != null && startAtRandomPos) {
        final randomNumber = random.nextInt(100) / 100.0;
        logger.t("Starting at random position: $randomNumber");
        await player.seek(duration * randomNumber);
      }

      if (generation != _volumeRampGeneration || activePlayer != player) {
        return;
      }

      final targetVolume = volume.clamp(0.0, 1.0).toDouble();
      final shouldRamp = secondsToMaxVolume > 0;
      await player.setVolume(shouldRamp ? 0.0 : targetVolume);
      if (generation != _volumeRampGeneration || activePlayer != player) {
        return;
      }

      // The play() Future resolves when the audio ends: never await it.
      unawaited(player.play());
      if (shouldRamp) {
        unawaited(_rampVolume(
          player,
          targetVolume,
          Duration(seconds: secondsToMaxVolume),
          generation,
        ));
      }
    } catch (e) {
      logger.e("Error playing $ringtoneUri: $e");
    }
  }

  static Future<void> _rampVolume(
    AudioPlayer player,
    double targetVolume,
    Duration duration,
    int generation,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      while (stopwatch.elapsed < duration) {
        if (generation != _volumeRampGeneration || activePlayer != player) {
          return;
        }
        final progress = (stopwatch.elapsed.inMilliseconds /
                duration.inMilliseconds)
            .clamp(0.0, 1.0);
        await player.setVolume(targetVolume * progress);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (generation == _volumeRampGeneration && activePlayer == player) {
        await player.setVolume(targetVolume);
      }
    } catch (e) {
      logger.e("Error increasing ringtone volume: $e");
    }
  }

  static Future<void> pause() async {
    ++_volumeRampGeneration;
    await activePlayer?.pause();
    if (_vibratorIsAvailable) {
      await Vibration.cancel();
    }
  }

  static Future<void> stop() async {
    ++_volumeRampGeneration;
    await activePlayer?.stop();
    final session = await AudioSession.instance;
    await session.setActive(false);
    if (_vibratorIsAvailable) {
      await Vibration.cancel();
    }
    RingtoneManager.lastPlayedRingtoneUri = "";
  }
}
