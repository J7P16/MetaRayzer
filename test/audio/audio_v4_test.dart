import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/app/app_settings.dart';
import 'package:metarayzer/src/app/key_value_store.dart';
import 'package:metarayzer/src/app/progression.dart';
import 'package:metarayzer/src/audio/audio_service.dart';
import 'package:metarayzer/src/games/wizard/wizard_config.dart';

import '../app/tracking_controller_test.dart' show FakeNative;

void main() {
  group('volumes and music', () {
    late FakeNative native;
    late AppSettings settings;
    late AudioService audio;

    setUp(() {
      native = FakeNative();
      settings = AppSettings(store: MemoryStore());
      audio = AudioService(native: native, settings: settings, nowMs: () => 0);
    });
    tearDown(() => audio.dispose());

    test('the engine receives master × channel volumes, 0 for a disabled channel', () async {
      settings
        ..masterVolume = 0.5
        ..sfxVolume = 0.8
        ..musicVolume = 0.6
        ..ambientVolume = 0.4;
      await Future<void>.delayed(Duration.zero);
      expect(native.configs.last['sfx'], closeTo(0.4, 1e-9));
      expect(native.configs.last['music'], closeTo(0.3, 1e-9));
      expect(native.configs.last['ambient'], closeTo(0.2, 1e-9));
      settings.musicEnabled = false;
      await Future<void>.delayed(Duration.zero);
      expect(native.configs.last['music'], 0);
      expect(native.configs.last['sfx'], closeTo(0.4, 1e-9), reason: 'music off leaves effects alone');
      settings.sfxEnabled = false;
      await Future<void>.delayed(Duration.zero);
      expect(native.configs.last['sfx'], 0);
      expect(native.configs.last['ambient'], 0);
    });

    test('sound effects off: nothing is sent to the engine', () {
      settings.sfxEnabled = false;
      expect(audio.play(Sounds.shieldBlock), isFalse);
      expect(native.plays, isEmpty);
    });

    test('requesting the playing track again never restarts it', () {
      audio.setMusic(MusicTracks.menu);
      audio.setMusic(MusicTracks.menu);
      audio.setMusic(MusicTracks.day);
      audio.setMusic(MusicTracks.day);
      audio.setMusic(MusicTracks.night);
      audio.setMusic(null);
      audio.setMusic(null);
      expect(native.musicRequests, [MusicTracks.menu, MusicTracks.day, MusicTracks.night, null]);
    });
  });

  group('settings persistence', () {
    test('new audio and display settings survive a restart; reset restores defaults', () async {
      final store = MemoryStore();
      final a = AppSettings(store: store)
        ..masterVolume = 0.7
        ..musicVolume = 0.2
        ..musicEnabled = false
        ..sfxEnabled = false
        ..showMenuCamera = false
        ..audioOutput = AudioOutputChoice.companion;
      await Future<void>.delayed(Duration.zero);
      final b = AppSettings(store: store);
      await b.load();
      expect(b.masterVolume, 0.7);
      expect(b.musicVolume, 0.2);
      expect(b.musicEnabled, isFalse);
      expect(b.sfxEnabled, isFalse);
      expect(b.showMenuCamera, isFalse);
      expect(b.audioOutput, AudioOutputChoice.companion);
      b.resetToDefaults();
      expect(b.masterVolume, AppSettings.defaultMasterVolume);
      expect(b.musicEnabled, isTrue);
      expect(b.showMenuCamera, isTrue);
      a.dispose();
    });
  });

  group('requested vs. verified output route', () {
    test('iPhone route: confirmed only when iOS reports the glasses as a Bluetooth output', () {
      final s = AudioRouteStatus.from({
        'kind': 'companion',
        'phone': {
          'engine': true,
          'played': 12,
          'outputs': [
            {'name': 'Ray-Ban Meta 0A1B', 'type': 'BluetoothA2DPOutput'},
          ],
        },
      });
      expect(s.verification, RouteVerification.glassesConfirmed);
      expect(s.glassesConfirmed, isTrue);
      expect(s.active, contains('Ray-Ban Meta'));
      expect(s.active, contains('Bluetooth A2DP'));
      expect(s.phonePlayed, 12);
    });

    test('iPhone route playing on its speaker: not the glasses, with a hint', () {
      final s = AudioRouteStatus.from({
        'kind': 'companion',
        'phone': {
          'engine': true,
          'outputs': [
            {'name': 'Speaker', 'type': 'Speaker'},
          ],
        },
      });
      expect(s.verification, RouteVerification.otherConfirmed);
      expect(s.glassesConfirmed, isFalse);
      expect(s.hint, contains('Audio output picker'));
    });

    test('iPhone route with an unrecognized Bluetooth device is not claimed as the glasses', () {
      final s = AudioRouteStatus.from({
        'kind': 'companion',
        'phone': {
          'engine': true,
          'outputs': [
            {'name': 'Car Audio', 'type': 'BluetoothA2DPOutput'},
          ],
        },
      });
      expect(s.verification, RouteVerification.otherConfirmed);
    });

    test('the preference alone (no phone report, or audio not running) is never confirmed', () {
      expect(AudioRouteStatus.from({'kind': 'companion'}).verification, RouteVerification.unconfirmed);
      expect(
        AudioRouteStatus.from({
          'kind': 'companion',
          'phone': {'engine': false, 'error': 'session busy'},
        }).verification,
        RouteVerification.unconfirmed,
      );
    });

    test('phone disconnected → fallback to the Mac; Mac devices verified by binding', () {
      expect(AudioRouteStatus.from({'kind': 'fallback', 'name': 'MacBook Pro Speakers', 'note': 'iPhone companion not connected'}).verification, RouteVerification.fallback);
      expect(AudioRouteStatus.from({'kind': 'device', 'name': 'Ray-Ban Meta', 'glasses': true, 'bound': true}).verification, RouteVerification.glassesConfirmed);
      expect(AudioRouteStatus.from({'kind': 'device', 'name': 'Ray-Ban Meta', 'glasses': true, 'bound': false}).verification, RouteVerification.unconfirmed);
      expect(AudioRouteStatus.from({'kind': 'mac', 'name': 'MacBook Pro Speakers'}).verification, RouteVerification.otherConfirmed);
      expect(AudioRouteStatus.from(const {'kind': 'starting'}).verification, RouteVerification.starting);
    });
  });

  group('permanent progression', () {
    test('a Version 3 save that already has Chain Lightning keeps it', () async {
      final store = MemoryStore();
      await store.setString('progression.v1', '{"unlocked":["chain_lightning"]}'); // as v3 wrote it
      final p = Progression(store: store);
      await p.load();
      expect(p.isUnlocked(SpellIds.chainLightning), isTrue);
    });

    test('an unlock survives a simulated restart and is reported only once', () async {
      final store = MemoryStore();
      final first = Progression(store: store);
      await first.load();
      expect(await first.unlock(SpellIds.chainLightning), isTrue);
      expect(await first.unlock(SpellIds.chainLightning), isFalse);
      final restarted = Progression(store: store);
      await restarted.load();
      expect(restarted.isUnlocked(SpellIds.chainLightning), isTrue);
      expect(await restarted.unlock(SpellIds.chainLightning), isFalse);
    });
  });
}
