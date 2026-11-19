import 'package:flutter/foundation.dart';

/// Coordinador global de reproducciones a pantalla completa.
///
/// Las TV Box de gama baja (Onn 4K, 2 GB de RAM) sólo tienen un
/// decodificador MediaCodec libre en la práctica. Si el reproductor de
/// "TV en Vivo" sigue vivo —aunque esté detenido— mientras una película
/// abre el suyo, la película se queda sin decodificador de hardware y mpv
/// cae a software: la imagen se ve trabada y un hilo nativo se clava
/// alrededor del 100 % de un núcleo.
///
/// La pantalla de película avisa aquí al abrir y al cerrar; la pantalla de
/// TV en Vivo destruye y vuelve a crear su reproductor en consecuencia.
class FullscreenPlaybackCoordinator {
  FullscreenPlaybackCoordinator._();

  static final FullscreenPlaybackCoordinator instance =
      FullscreenPlaybackCoordinator._();

  int _refs = 0;

  /// `true` mientras hay alguna reproducción a pantalla completa activa.
  final ValueNotifier<bool> isActive = ValueNotifier<bool>(false);

  /// Llamado por la pantalla de reproducción a pantalla completa en `initState`.
  void begin() {
    _refs++;
    if (!isActive.value) isActive.value = true;
  }

  /// Llamado por la pantalla de reproducción cuando su reproductor ya fue
  /// liberado de verdad, para que TV en Vivo pueda crear el suyo.
  void end() {
    if (_refs > 0) _refs--;
    if (_refs == 0 && isActive.value) isActive.value = false;
  }
}
