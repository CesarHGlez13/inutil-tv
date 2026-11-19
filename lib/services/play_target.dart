import 'package:flutter/material.dart';

import '../models/models.dart';
import 'tv_mode_service.dart';
import 'tv_remote_service.dart';

/// Compuerta única de **"Destino: TV"**.
///
/// Cuando el usuario eligió la Smart TV como destino (chip `Destino: TV` del
/// panel de control remoto) y la TV está en línea, **todo** el contenido que se
/// lance desde el celular debe reproducirse en la TV, no en el teléfono.
///
/// Cada punto de entrada de reproducción (hero, Seguir viendo, canales en vivo,
/// búsqueda, detalles) pasa por aquí; así el comportamiento no depende de que
/// cada pantalla recuerde consultar la preferencia.
class PlayTarget {
  PlayTarget._();

  /// Decisión pura (sin Flutter) para poder probarla: ¿el destino es la TV?
  ///
  /// En la propia Smart TV (`isTvDevice`) nunca se "envía" el contenido a otra
  /// parte: ahí se reproduce en local por definición.
  static bool resolve({required bool isTvDevice, required bool playOnTv}) =>
      !isTvDevice && playOnTv;

  /// Versión para árboles de widgets: lee modo TV + preferencia + conectividad.
  ///
  /// `TvRemoteService.playOnTv` ya incluye `isTvOnline`, de modo que con la TV
  /// apagada el contenido vuelve a reproducirse en el celular.
  static bool isTvDestination(BuildContext context) => resolve(
        isTvDevice: TvModeService.of(context),
        playOnTv: TvRemoteService.instance.playOnTv,
      );

  /// Envía una película o episodio a la TV. `true` si la TV lo aceptó.
  static Future<bool> sendVod(
    VodItem item, {
    VodEpisode? episode,
    Duration? position,
  }) =>
      TvRemoteService.instance.sendVodToTv(
        item,
        episode: episode,
        positionSec: position?.inSeconds ?? 0,
      );

  /// Envía un canal en vivo a la TV. `true` si la TV lo aceptó.
  static Future<bool> sendChannel(Channel channel) =>
      TvRemoteService.instance.sendChannelToTv(channel);

  /// Confirmación breve (no bloqueante) del resultado del envío.
  static void report(BuildContext context, {required bool ok}) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        content: Text(
          ok
              ? '▶ Reproduciendo en tu Smart TV'
              : 'La Smart TV no respondió · reproduciendo aquí',
        ),
      ),
    );
  }
}
