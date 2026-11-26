import 'package:flutter_test/flutter_test.dart';
import 'package:tubotv/services/xuper_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Recomendaciones dinámicas y personalizadas estilo Spotify (InútilTV)', () {
    test('XuperService inicializa y genera rieles dinámicos con descubrimientos', () async {
      final service = XuperService();
      await service.initialize();

      final categories = service.getVodCategories();
      expect(categories, isNotEmpty);
      expect(categories.containsKey('Especialmente para ti'), isTrue,
          reason: 'Debe contener riel personalizado para el usuario');
      expect(categories.containsKey('Descubrimientos de la Semana'), isTrue,
          reason: 'Debe contener riel de descubrimiento dinámico');
      expect(categories.containsKey('Tendencias de la Semana'), isTrue);

      final featured = service.getFeaturedVod();
      expect(featured, isNotEmpty);
      expect(featured.length, lessThanOrEqualTo(6));
    });

    test('getFeaturedVod con seed diferente produce rotación válida', () async {
      final service = XuperService();
      await service.initialize();

      final featuredA = service.getFeaturedVod(seed: 10);
      final featuredB = service.getFeaturedVod(seed: 9999);

      expect(featuredA, isNotEmpty);
      expect(featuredB, isNotEmpty);
      expect(featuredA.every((v) => v.backdrop.isNotEmpty || v.poster.isNotEmpty), isTrue);
    });

    test('refreshLiveCatalog con forceShuffle rota categorías', () async {
      final service = XuperService();
      await service.initialize();

      await service.refreshLiveCatalog(forceShuffle: true);
      final categories = service.getVodCategories();

      expect(categories.containsKey('Especialmente para ti'), isTrue);
      expect(categories.containsKey('Descubrimientos de la Semana'), isTrue);
    });
  });
}
