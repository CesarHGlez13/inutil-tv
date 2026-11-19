import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/play_target.dart';
import 'package:tubotv/services/tv_remote_service.dart';

/// Regresión del bug reportado tras 3.3.13: con el chip `Destino: TV` activo,
/// el botón **"Reproducir"** del hero (y "Seguir viendo", y las tarjetas de
/// canales) seguía abriendo el reproductor del celular.
///
/// Causa: la preferencia `playOnTv` sólo la consultaba `VodDetailModal` (la
/// pantalla de "Detalles"). El hero y los canales llamaban a `PlayerScreen`
/// sin pasar por la compuerta.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayTarget.resolve — decisión pura', () {
    test('celular + Destino: TV ⇒ se reproduce en la TV', () {
      expect(PlayTarget.resolve(isTvDevice: false, playOnTv: true), isTrue);
    });

    test('celular + Destino: Móvil ⇒ se reproduce aquí', () {
      expect(PlayTarget.resolve(isTvDevice: false, playOnTv: false), isFalse);
    });

    test('en la propia Smart TV nunca se reenvía el contenido', () {
      expect(PlayTarget.resolve(isTvDevice: true, playOnTv: true), isFalse);
      expect(PlayTarget.resolve(isTvDevice: true, playOnTv: false), isFalse);
    });
  });

  group('PlayTarget.isTvDestination — estado real del servicio', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      // Arranca cada caso sin TV en línea y con el destino en el celular.
      TvRemoteService.instance.setTvStateForTest(const TvPlaybackState());
      await TvRemoteService.instance.setPlayOnTv(false);
    });

    testWidgets('TV en línea + Destino: TV ⇒ destino es la TV', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          },
        ),
      ));

      expect(PlayTarget.isTvDestination(ctx), isFalse,
          reason: 'sin TV en línea el contenido debe quedar en el celular');

      TvRemoteService.instance.setTvStateForTest(TvPlaybackState(
        online: true,
        lanHost: '192.168.100.17',
        updatedAt: DateTime.now(),
      ));
      await TvRemoteService.instance.setPlayOnTv(true);

      expect(PlayTarget.isTvDestination(ctx), isTrue,
          reason:
              'con Destino: TV y la TV conectada TODO el contenido va a la TV');
    });

    testWidgets('la TV se cae ⇒ el destino vuelve al celular', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          },
        ),
      ));

      TvRemoteService.instance.setTvStateForTest(TvPlaybackState(
        online: true,
        updatedAt: DateTime.now(),
      ));
      await TvRemoteService.instance.setPlayOnTv(true);
      expect(PlayTarget.isTvDestination(ctx), isTrue);

      // TV reportándose offline (state online:false) ⇒ no se envía al vacío.
      TvRemoteService.instance.setTvStateForTest(const TvPlaybackState());
      expect(PlayTarget.isTvDestination(ctx), isFalse);
    });
  });

  group('Compuerta aplicada en todos los puntos de reproducción', () {
    test('home: hero, Seguir viendo y canales consultan PlayTarget', () {
      final src = File('lib/screens/home_tab.dart').readAsStringSync();

      expect(src.contains("import '../services/play_target.dart';"), isTrue,
          reason: 'home_tab debe importar la compuerta');
      // Dos compuertas: una para VOD (hero / Seguir viendo) y otra para canales.
      expect(
          RegExp('PlayTarget\\.isTvDestination\\(context\\)')
              .allMatches(src)
              .length,
          greaterThanOrEqualTo(2),
          reason: '_playVod y _playLiveDirect deben consultar el destino');
      expect(src.contains('PlayTarget.sendVod('), isTrue);
      expect(src.contains('PlayTarget.sendChannel('), isTrue);
    });

    test('búsqueda: canales consultan PlayTarget', () {
      final src = File('lib/screens/search_screen.dart').readAsStringSync();

      expect(src.contains("import '../services/play_target.dart';"), isTrue);
      expect(src.contains('PlayTarget.isTvDestination(context)'), isTrue);
      expect(src.contains('PlayTarget.sendChannel('), isTrue);
    });

    test('el CTA del hero anuncia el destino real (Reproducir en TV)', () {
      final src = File('lib/widgets/hero_carousel.dart').readAsStringSync();

      expect(src.contains("import '../services/play_target.dart';"), isTrue);
      expect(src.contains('PlayTarget.isTvDestination(context)'), isTrue,
          reason: 'el botón debe saber si el destino es la Smart TV');
      expect(src.contains('listenable: TvRemoteService.instance'), isTrue,
          reason: 'la etiqueta cambia en el momento que se activa Destino: TV');
      expect(src.contains("'Reproducir en TV'"), isTrue,
          reason: 'así el usuario ve que el play irá a la TV');
    });

    test('modal y hero usan la misma etiqueta de destino TV', () {
      final modal =
          File('lib/widgets/vod_detail_modal.dart').readAsStringSync();

      expect(modal.contains("'Reproducir en TV'"), isTrue,
          reason: 'misma redacción en los dos accesos principales');
    });

    test('descargas siguen locales (la TV no ve el almacenamiento del celular)',
        () {
      final src = File('lib/screens/downloads_screen.dart').readAsStringSync();

      expect(src.contains('PlayTarget'), isFalse,
          reason: 'el contenido descargado no se puede enviar a la TV');
    });
  });

  group('Detener (stop) sale del contenido en la Smart TV', () {
    test('el reproductor viejo no le roba el control remoto al nuevo', () {
      void viejo(TvRemoteCommand c) {}
      void nuevo(TvRemoteCommand c) {}
      final s = TvRemoteService.instance;

      s.registerActivePlayerHandler(viejo); // initState del reproductor viejo
      s.registerActivePlayerHandler(nuevo); // el celular lanza otro título
      s.unregisterActivePlayerHandler(
          viejo); // dispose viejo, llega ~300 ms tarde

      expect(s.isPlayerHandlerRegisteredFor(nuevo), isTrue,
          reason:
              'stop/pausa/volumen deben seguir llegando al reproductor actual');

      s.unregisterActivePlayerHandler(nuevo); // recién ahora sí sale el actual
      expect(s.isPlayerHandlerRegisteredFor(nuevo), isFalse,
          reason: 'salir del reproductor correcto sí limpia el registro');
    });

    test('main.dart atiende stop y sale del contenido', () {
      final src = File('lib/main.dart').readAsStringSync();

      expect(src.contains("case 'stop':"), isTrue,
          reason:
              'el comando stop necesita rama propia en la navegación del sistema');
      final branch =
          RegExp(r"case 'stop':([\s\S]{0,220}?)break;").firstMatch(src);
      expect(branch, isNotNull);
      expect(branch!.group(1)!.contains('popUntil'), isTrue,
          reason: 'detener debe cerrar el reproductor hasta la pantalla raíz');
    });

    test('player_screen ya no borra el handler a ciegas', () {
      final src = File('lib/screens/player_screen.dart').readAsStringSync();

      expect(
          RegExp(r'unregisterActivePlayerHandler\(\s*_handleRemoteCommand')
              .hasMatch(src),
          isTrue,
          reason: 'el dispose debe desregistrar sólo su propio handler');
      expect(src.contains('registerActivePlayerHandler(null)'), isFalse,
          reason: 'el reproductor viejo no puede desregistrar al nuevo');
    });
  });
}
