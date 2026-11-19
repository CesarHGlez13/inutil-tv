import 'dart:async';
import 'package:flutter/foundation.dart';

/// Temporizador de sueño compartido de InútilTV (portado desde Inútil Music v2.4).
///
/// Funciona tanto en el reproductor VOD/Series/Anime (`PlayerScreen`) como en
/// TV en Vivo (`TvScreen`), con presets de tiempo y modo "Al terminar este episodio".
class SleepTimerService extends ChangeNotifier {
  SleepTimerService._();
  static final SleepTimerService instance = SleepTimerService._();

  final StreamController<String> _expiredController =
      StreamController<String>.broadcast();

  Timer? _ticker;
  DateTime? _endsAt;
  Duration? _selectedDuration;
  bool _stopAtEndOfEpisode = false;

  Stream<String> get onExpired => _expiredController.stream;

  bool get isActive =>
      _stopAtEndOfEpisode ||
      (_endsAt != null && _endsAt!.isAfter(DateTime.now()));

  bool get stopAtEndOfEpisode => _stopAtEndOfEpisode;
  Duration? get selectedDuration => _selectedDuration;

  Duration get remaining {
    if (_endsAt == null) return Duration.zero;
    final diff = _endsAt!.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  String get shortLabel {
    if (_stopAtEndOfEpisode) return 'Fin ep.';
    final d = remaining;
    if (d <= Duration.zero) return '';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void start(Duration duration) {
    _ticker?.cancel();
    _stopAtEndOfEpisode = false;
    _selectedDuration = duration;
    _endsAt = DateTime.now().add(duration);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_endsAt == null || !DateTime.now().isBefore(_endsAt!)) {
        _fire('Temporizador de sueño finalizado');
      } else {
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void startEndOfEpisode() {
    _ticker?.cancel();
    _ticker = null;
    _endsAt = null;
    _selectedDuration = null;
    _stopAtEndOfEpisode = true;
    notifyListeners();
  }

  /// Llamado por `PlayerScreen` cuando termina un episodio.
  /// Devuelve `true` si el temporizador consumió el evento y debe pausarse.
  bool consumeEndOfEpisodeIfArmed() {
    if (!_stopAtEndOfEpisode) return false;
    _fire('Reproducción pausada al terminar el episodio');
    return true;
  }

  void cancel() {
    _ticker?.cancel();
    _ticker = null;
    _endsAt = null;
    _selectedDuration = null;
    _stopAtEndOfEpisode = false;
    notifyListeners();
  }

  void _fire(String reason) {
    _ticker?.cancel();
    _ticker = null;
    _endsAt = null;
    _selectedDuration = null;
    _stopAtEndOfEpisode = false;
    notifyListeners();
    _expiredController.add(reason);
  }
}
