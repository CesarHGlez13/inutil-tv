import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_info.dart';
import 'firebase_config.dart';
import 'firebase_firestore_service.dart';

enum InutilPopupKind {
  support,
  announcement,
  ad;

  static InutilPopupKind fromString(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'ad' || 'sponsor' => InutilPopupKind.ad,
        'announcement' || 'news' => InutilPopupKind.announcement,
        _ => InutilPopupKind.support,
      };
}

@immutable
class InutilPopupCampaign {
  const InutilPopupCampaign({
    required this.id,
    required this.kind,
    required this.badge,
    required this.emoji,
    required this.headline,
    required this.body,
    required this.primaryCta,
    required this.secondaryCta,
    required this.actionUrl,
    this.footnote =
        '100 % voluntario · Sin suscripciones · Directo al creador',
  });

  final String id;
  final InutilPopupKind kind;
  final String badge;
  final String emoji;
  final String headline;
  final String body;
  final String primaryCta;
  final String secondaryCta;
  final String actionUrl;
  final String footnote;
}

/// Servicio modular de pop-ups rotativos de apoyo y anuncios remotos desde
/// Firebase (`app_config/tv_promo_popup` o `app_config/promo_popup`), portado
/// directamente de Inútil Music v2.4.
class InutilPromoPopupService {
  InutilPromoPopupService._();
  static final InutilPromoPopupService instance = InutilPromoPopupService._();

  static const _prefsIndexKey = 'inutiltv_promo_popup_last_index_v1';
  static const _prefsLastShownMsKey = 'inutiltv_promo_popup_last_shown_ms_v1';
  static const _prefsSessionsKey = 'inutiltv_promo_popup_sessions_v1';
  static const _prefsSeenRemoteIdKey = 'inutiltv_promo_popup_seen_remote_id_v1';

  static const Duration minCooldown = Duration(hours: 6);
  static const int sessionInterval = 3;

  static const List<InutilPopupCampaign> creatorCampaigns = [
    InutilPopupCampaign(
      id: 'tv-coffee-code',
      kind: InutilPopupKind.support,
      badge: 'MENSAJE DEL CREADOR',
      emoji: '☕',
      headline: 'El creador lleva meses viviendo de café y código',
      body:
          'Mientras disfrutas TV en vivo, cine, series y anime sin comerciales eternos, '
          'César afina cada servidor a medianoche. ¿Le invitas unos tacos para seguir '
          'mejorando la Familia Inútil?',
      primaryCta: 'Invitar unos tacos 🌮',
      secondaryCta: 'Hoy no, que aguante 😅',
      actionUrl: AppInfo.supportDevelopmentUrl,
    ),
    InutilPopupCampaign(
      id: 'tv-no-ads',
      kind: InutilPopupKind.support,
      badge: 'CERO INTERRUPCIONES',
      emoji: '🍿',
      headline: 'Sacrificamos las palomitas para quitarte los anuncios',
      body:
          'Inutix TV no corta tu capítulo favorito con pop-ups invasivos ni suscripciones '
          'escondidas. Un apoyo voluntario ayuda a mantener los servidores al 100 %.',
      primaryCta: 'Apoyar al creador 💛',
      secondaryCta: 'Luego le invito',
      actionUrl: AppInfo.supportDevelopmentUrl,
    ),
    InutilPopupCampaign(
      id: 'tv-maruchan',
      kind: InutilPopupKind.support,
      badge: 'APOYO VOLUNTARIO',
      emoji: '🍜',
      headline: 'Patrocina una Maruchan de lujo para el dev',
      body:
          'Con lo que cuesta un refresco ayudas a que Inutix TV e Inútil Music sigan '
          'creciendo con precarga instantánea, más canales y diseño impecable.',
      primaryCta: 'Aportar mi granito ✨',
      secondaryCta: 'Tal vez después',
      actionUrl: AppInfo.supportDevelopmentUrl,
    ),
    InutilPopupCampaign(
      id: 'tv-real-human',
      kind: InutilPopupKind.support,
      badge: 'HECHO A MANO',
      emoji: '📺',
      headline: 'Plot twist: tu app de TV la mantiene un humano real',
      body:
          'Sin corporaciones gigantes detrás: solo desvelos probando canales y '
          'servidores para ti. Si Inutix TV ya te salvó el partido o el maratón, '
          'considera apoyar el proyecto.',
      primaryCta: 'Quiero apoyar 💛',
      secondaryCta: 'Seguir viendo',
      actionUrl: AppInfo.supportDevelopmentUrl,
    ),
    InutilPopupCampaign(
      id: 'tv-server-wifi',
      kind: InutilPopupKind.support,
      badge: 'ENERGÍA DEL SERVIDOR',
      emoji: '⚡',
      headline: 'Se aceptan donaciones para la luz y el Wi-Fi',
      body:
          'Mantener la sincronización de canales, respaldos en la nube y actualizaciones '
          'OTA cuesta café, luz e internet. Échanos una mano para seguir en vivo 24/7.',
      primaryCta: 'Recargar energía ⚡',
      secondaryCta: 'Ahorita no puedo',
      actionUrl: AppInfo.supportDevelopmentUrl,
    ),
    InutilPopupCampaign(
      id: 'tv-battery-4pct',
      kind: InutilPopupKind.support,
      badge: 'BATERÍA BAJA',
      emoji: '🔋',
      headline: 'Nivel de energía del creador: 4 %',
      body:
          'Conecta un apoyo voluntario para recargar a César y desbloquear todavía '
          'más mejoras en las próximas versiones de Inutix TV.',
      primaryCta: 'Recargar al creador 🔋',
      secondaryCta: 'En la quincena 😉',
      actionUrl: AppInfo.supportDevelopmentUrl,
    ),
  ];

  Future<InutilPopupCampaign> nextRotatingCampaign() async {
    final prefs = await SharedPreferences.getInstance();
    final lastIndex = prefs.getInt(_prefsIndexKey) ?? -1;
    final nextIndex = (lastIndex + 1) % creatorCampaigns.length;
    await prefs.setInt(_prefsIndexKey, nextIndex);
    return creatorCampaigns[nextIndex];
  }

  Future<InutilPopupCampaign?> evaluateScheduledPopup() async {
    final prefs = await SharedPreferences.getInstance();
    final sessions = (prefs.getInt(_prefsSessionsKey) ?? 0) + 1;
    await prefs.setInt(_prefsSessionsKey, sessions);

    // 1. Aviso remoto desde Firestore (primero específico de TV, luego global)
    final remote = await _fetchRemoteCampaign();
    if (remote != null) {
      final seenRemoteId = prefs.getString(_prefsSeenRemoteIdKey) ?? '';
      if (remote.id.isNotEmpty && remote.id != seenRemoteId) {
        await prefs.setString(_prefsSeenRemoteIdKey, remote.id);
        await prefs.setInt(
          _prefsLastShownMsKey,
          DateTime.now().millisecondsSinceEpoch,
        );
        return remote;
      }
    }

    // 2. Cadencia amigable local (sesión 2 y luego cada 3 sesiones con 6h cooldown)
    final lastShownMs = prefs.getInt(_prefsLastShownMsKey) ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final elapsed = Duration(milliseconds: nowMs - lastShownMs);
    final dueBySession =
        sessions == 2 || (sessions > 2 && sessions % sessionInterval == 0);
    if (!dueBySession) return null;
    if (lastShownMs > 0 && elapsed < minCooldown) return null;

    await prefs.setInt(_prefsLastShownMsKey, nowMs);
    return nextRotatingCampaign();
  }

  Future<InutilPopupCampaign?> _fetchRemoteCampaign() async {
    for (final docPath in const [
      'app_config/tv_promo_popup',
      'app_config/promo_popup',
    ]) {
      final camp = await _fetchDocCampaign(docPath);
      if (camp != null) return camp;
    }
    return null;
  }

  Future<InutilPopupCampaign?> _fetchDocCampaign(String docPath) async {
    try {
      final response = await InutilFirestoreService.instance
          .sendWithRelayFallback(
        label: 'GET $docPath',
        urlBuilder: () => Uri.parse(
          '${FirebaseConfig.firestoreBaseUrl}/$docPath?${FirebaseConfig.keyParam}',
        ),
        send: (uri) => http.get(uri).timeout(const Duration(seconds: 4)),
      );
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      final fields = decoded['fields'];
      if (fields is! Map<String, dynamic>) return null;

      bool readBool(String k) =>
          (fields[k] as Map<String, dynamic>?)?['booleanValue'] == true;
      String readStr(String k) =>
          ((fields[k] as Map<String, dynamic>?)?['stringValue'] ?? '')
              .toString()
              .trim();

      if (!readBool('enabled')) return null;
      final headline = readStr('headline');
      final body = readStr('body');
      if (headline.isEmpty || body.isEmpty) return null;

      final kind = InutilPopupKind.fromString(readStr('kind'));
      final id = readStr('campaignId').isNotEmpty
          ? readStr('campaignId')
          : 'remote-${headline.hashCode}';
      return InutilPopupCampaign(
        id: id,
        kind: kind,
        badge: readStr('badge').isNotEmpty
            ? readStr('badge')
            : kind == InutilPopupKind.ad
                ? 'PATROCINADO'
                : 'AVISO DE INÚTILTV',
        emoji: readStr('emoji').isNotEmpty ? readStr('emoji') : '✨',
        headline: headline,
        body: body,
        primaryCta: readStr('primaryCta').isNotEmpty
            ? readStr('primaryCta')
            : 'Ver más',
        secondaryCta: readStr('secondaryCta').isNotEmpty
            ? readStr('secondaryCta')
            : 'Cerrar',
        actionUrl: readStr('actionUrl').isNotEmpty
            ? readStr('actionUrl')
            : AppInfo.supportDevelopmentUrl,
        footnote: readStr('footnote').isNotEmpty
            ? readStr('footnote')
            : kind == InutilPopupKind.ad
                ? 'Anuncio · Ayuda a mantener Inutix TV gratis'
                : 'Familia Inútil · Gracias por ser parte',
      );
    } catch (_) {
      return null;
    }
  }
}
