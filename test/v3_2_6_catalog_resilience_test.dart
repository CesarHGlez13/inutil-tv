import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tubotv/services/vod_catalog_service.dart';
import 'package:tubotv/widgets/catalog_empty_state.dart';

/// Resiliencia del catálogo (v3.2.6): en redes que no dejan entrar a los
/// servidores (WiFi de empresa, hoteles, filtros) las pestañas de Cine, Series
/// y Anime no pueden quedar en blanco ni mentir con un «no hay resultados».
///
/// Aquí `flutter_test` mockiza el HTTP y responde 400 a todo, así que cada
/// fuente falla: es exactamente el escenario de una red restringida.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    VodCatalogService().clearPageCaches();
  });

  group('respaldos del catálogo sin red', () {
    test('Cine usa el catálogo empaquetado si ningún servidor responde', () async {
      final peliculas = await VodCatalogService().getMovies(page: 1);

      expect(
        peliculas,
        isNotEmpty,
        reason: 'sin red debe quedar al menos el catálogo empaquetado',
      );
      expect(
        VodCatalogService().ultimoErrorDeRed,
        isTrue,
        reason: 'la pestaña llena por respaldo debe admitir que la red falló',
      );
    });

    test('una categoría inexistente no deja la pestaña en cero', () async {
      final r = await VodCatalogService()
          .getMovies(page: 1, genre: 'genero-que-no-existe');

      expect(
        r,
        isNotEmpty,
        reason: 'más vale mostrar el catálogo completo que una pantalla vacía',
      );
    });

    test('«Estrenos» no se queda en cero aunque los títulos no digan estrenos',
        () async {
      final dir = await Directory.systemTemp.createTemp('copia_estrenos');
      File('${dir.path}/inutiltv_catalogo_copia.json').writeAsStringSync(
        jsonEncode({
          'peliculas': [
            {
              'id': 'p_la_odisea',
              'title': 'La Odisea',
              'poster': 'https://image.tmdb.org/t/p/w500/a.jpg',
              'overview': 'epica',
              'genre': 'Aventura',
              'isSeries': false,
              'provider': 'poseidon',
            },
            {
              'id': 'p_los_croods',
              'title': 'Los Croods',
              'poster': 'https://image.tmdb.org/t/p/w500/b.jpg',
              'overview': 'familia',
              'genre': 'Animación',
              'isSeries': false,
              'provider': 'poseidon',
            },
          ],
          'series': <Map<String, dynamic>>[],
          'anime': <Map<String, dynamic>>[],
        }),
      );
      VodCatalogService().copiaDirParaPruebas = dir.path;
      VodCatalogService().clearPageCaches();

      final estrenos = await VodCatalogService()
          .getMovies(page: 1, genre: 'estrenos');

      expect(
        estrenos.length,
        2,
        reason: 'un filtro que no coincide con nada debe mostrar el catálogo, '
            'no una pestaña vacía',
      );
      await dir.delete(recursive: true);
    });

    test('Anime avisa que no llegó el catálogo cuando no hay nada', () async {
      final dir = await Directory.systemTemp.createTemp('copia_vacia');
      VodCatalogService().copiaDirParaPruebas = dir.path;
      VodCatalogService().clearPageCaches();

      final anime = await VodCatalogService().getAnime(page: 1);

      expect(anime, isEmpty);
      expect(
        VodCatalogService().ultimoErrorDeRed,
        isTrue,
        reason: 'sin servidores y sin copia hay que decirlo, no callarse',
      );
      await dir.delete(recursive: true);
    });

    test('la última copia buena guardada en el teléfono salva la pestaña',
        () async {
      final dir = await Directory.systemTemp.createTemp('copia_anime');
      File('${dir.path}/inutiltv_catalogo_copia.json').writeAsStringSync(
        jsonEncode({
          'peliculas': <Map<String, dynamic>>[],
          'series': <Map<String, dynamic>>[],
          'anime': [
            {
              'id': 'jk_prueba',
              'title': 'One Piece',
              'poster': 'https://cdn.jkdesa.com/img/120x171/1.jpg',
              'backdrop': 'https://cdn.jkdesa.com/img/120x171/1.jpg',
              'overview': 'piratas',
              'genre': 'Anime',
              'isSeries': true,
              'isAnime': true,
              'provider': 'jkanime',
            },
          ],
        }),
      );
      VodCatalogService().copiaDirParaPruebas = dir.path;
      VodCatalogService().clearPageCaches();

      final anime = await VodCatalogService().getAnime(page: 1);

      expect(anime.map((e) => e.title), contains('One Piece'));
      expect(
        VodCatalogService().ultimoErrorDeRed,
        isTrue,
        reason: 'la copia local salvó la pestaña, pero la red no dio títulos',
      );
      await dir.delete(recursive: true);
    });

    test('Series tampoco queda vacío sin red', () async {
      final dir = await Directory.systemTemp.createTemp('copia_series');
      File('${dir.path}/inutiltv_catalogo_copia.json').writeAsStringSync(
        jsonEncode({
          'peliculas': <Map<String, dynamic>>[],
          'series': [
            {
              'id': 'sk_breaking_bad',
              'title': 'Breaking Bad',
              'poster': 'https://image.tmdb.org/t/p/w500/1.jpg',
              'overview': 'un profe de química',
              'genre': 'Drama',
              'isSeries': true,
              'provider': 'serieskao',
            },
            {
              'id': 'sk_the_walking_dead',
              'title': 'The Walking Dead',
              'poster': 'https://image.tmdb.org/t/p/w500/2.jpg',
              'overview': 'zombis',
              'genre': 'Terror',
              'isSeries': true,
              'provider': 'serieskao',
            },
          ],
          'anime': <Map<String, dynamic>>[],
        }),
      );
      VodCatalogService().copiaDirParaPruebas = dir.path;
      VodCatalogService().clearPageCaches();

      final series = await VodCatalogService().getSeries(page: 1);

      expect(series, isNotEmpty, reason: 'el respaldo local debe alcanzar');
      await dir.delete(recursive: true);
    });
  });

  group('estado vacío honesto', () {
    testWidgets('con red caída dice la verdad y deja reintentar', (tester) async {
      var reintentos = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogEmptyState(
              fallaRed: true,
              onRetry: () => reintentos++,
              tituloSinResultados: 'No se encontraron películas',
            ),
          ),
        ),
      );

      expect(find.text('No llegó el catálogo'), findsOneWidget);
      expect(find.textContaining('Tu red no deja entrar'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);

      await tester.tap(find.text('Reintentar'));
      await tester.pump();
      expect(reintentos, 1);
    });

    testWidgets('sin red caída no culpa a la conexión', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogEmptyState(
              fallaRed: false,
              onRetry: () {},
              tituloSinResultados: 'No se encontraron animes',
            ),
          ),
        ),
      );

      expect(find.text('No se encontraron animes'), findsOneWidget);
      expect(find.text('No llegó el catálogo'), findsNothing);
    });
  });
}
