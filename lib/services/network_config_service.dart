import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_config.dart';
import 'inutil_vpn_tunnel.dart';

/// Bitacora de red opcional, pensada para depurar en escritorio y en la
/// prueba en vivo (`INUTILTV_REAL_NET=1 INUTILTV_NET_DEBUG=1 flutter test ...`).
/// Solo imprime si existe la variable de entorno `INUTILTV_NET_DEBUG`; en
/// Android `Platform.environment` llega vacio, asi que en produccion no se
/// imprime absolutamente nada.
final bool _netDebug = Platform.environment.containsKey('INUTILTV_NET_DEBUG');

void _dbg(String m) {
  if (!_netDebug) return;
  // ignore: avoid_print
  print('[NET] $m');
}

/// Motivo por el que una conexión pudo fallar (se usa solo para ayudar al
/// usuario a elegir la opción correcta en Ajustes; nunca se muestra crudo).
enum NetworkIssue { none, dnsBlocked, tlsInspected, proxyUnreachable }

/// Un resultado de la comprobación de conexión de Ajustes.
class NetworkCheck {
  const NetworkCheck({
    required this.label,
    required this.ok,
    required this.millis,
    this.detail = '',
  });

  final String label;
  final bool ok;
  final int millis;
  final String detail;
}

/// Resumen de `runDiagnostics()`.
class NetworkReport {
  const NetworkReport(this.checks, this.viaProxy, this.viaSecureDns);

  final List<NetworkCheck> checks;
  final bool viaProxy;
  final bool viaSecureDns;

  bool get allOk => checks.every((c) => c.ok);
  int get failures => checks.where((c) => !c.ok).length;
}

class _DnsEntry {
  _DnsEntry(this.ip, this.expiresAt);
  final String ip;
  final DateTime expiresAt;
}

/// Configuración y motor de red tolerante a restricciones de InútilTV v3.2.5.
///
/// Las redes corporativas / hoteleras / de aeropuerto suelen bloquear el video
/// por tres vías distintas, y esta clase cubre las tres sin trucos raros:
///
/// 1. **Filtrado de DNS:** el resolver de la red devuelve una IP nula o un
///    sumidero para los dominios de streaming. Se resuelve el nombre con
///    DNS-over-HTTPS (Cloudflare y Google, con caché y respaldo automático al
///    DNS del sistema si DoH está caído) y se conecta a esa IP real.
/// 2. **Proxy obligatorio (el equipo no tiene salida directa):** se usa el
///    proxy HTTP indicado en Ajustes. `dart:io` hace el `CONNECT` y el TLS
///    encima del socket que entrega este servicio, y el proxy resuelve el
///    nombre por nosotros (lo que además salta el filtrado de DNS).
/// 3. **Inspección TLS (certificado emitido por el firewall):** el handshake
///    falla contra la cadena raíz. Si el usuario lo permite, se reintenta una
///    sola vez confiando en el certificado de la propia red.
///
/// En una red doméstica normal nada de esto cambia el comportamiento: DoH sólo
/// acelera/valida la resolución y hay respaldo inmediato al DNS del sistema.
class NetworkConfigService extends ChangeNotifier {
  NetworkConfigService._();
  static final NetworkConfigService instance = NetworkConfigService._();

  static const _kSecureDns = 'inutiltv_net_secure_dns_v1';
  static const _kTlsFallback = 'inutiltv_net_tls_fallback_v1';
  static const _kProxy = 'inutiltv_net_proxy_v1';
  static const _kVpnTunnel = 'inutiltv_net_vpn_tunnel_v1';

  /// Entornos DoH públicos (JSON) en orden de preferencia.
  static const List<String> _kDohEndpoints = [
    'https://cloudflare-dns.com/dns-query',
    'https://dns.google/resolve',
  ];

  /// Entornos DoH por IP literal. Son los que salvan una red corporativa: si el
  /// DNS de la empresa miente sobre `cloudflare-dns.com`, el DNS cifrado moriría
  /// justo cuando más se necesita. Con la IP escrita no hay nada que resolver.
  static const List<String> _kDohEndpointsIpLiteral = [
    'https://1.1.1.1/dns-query',
    'https://1.0.0.1/dns-query',
    'https://8.8.8.8/resolve',
    'https://8.8.4.4/resolve',
  ];

  /// Orden en red doméstica: nombres primero (soportan HTTP/3, más rápido).
  static const List<String> _kDohOrderNormal = [
    ..._kDohEndpoints,
    ..._kDohEndpointsIpLiteral,
  ];

  /// Orden en red corporativa: IP literal primero, por lo dicho arriba.
  static const List<String> _kDohOrderCorporate = [
    ..._kDohEndpointsIpLiteral,
    ..._kDohEndpoints,
  ];

  /// Entornos DoH en uso (se pueden sustituir en las pruebas).
  List<String>? _dohEndpointsOverride;
  List<String> get _dohEndpoints =>
      _dohEndpointsOverride ??
      (corporateModeActive ? _kDohOrderCorporate : _kDohOrderNormal);

  static const Duration _dohQueryTimeout = Duration(seconds: 3);
  static const Duration _tlsHandshakeTimeout = Duration(seconds: 10);
  static const Duration _dohBlacklistTtl = Duration(minutes: 5);
  static const int _dnsCacheMaxEntries = 400;

  /// En `flutter test` no se toca la red real ni se instalan overrides, salvo
  /// que se pida explícitamente con `INUTILTV_REAL_NET=1` (ver el test live).
  static final bool _hermetic =
      (Platform.environment.containsKey('FLUTTER_TEST') || kIsWeb) &&
          !Platform.environment.containsKey('INUTILTV_REAL_NET');

  static const MethodChannel _deviceChannel = MethodChannel('inutil_tv/device');

  bool _loaded = false;
  bool _secureDns = true;
  bool _tlsFallback = true;
  bool _vpnTunnel = false;
  String _proxy = '';
  String _systemProxy = '';
  // La red de la empresa está filtrando de verdad: el DNS del sistema respondió
  // una IP de sumidero (loopback / 0.0.0.0) para un dominio externo.
  bool _dnsPoisoned = false;

  final Map<String, _DnsEntry> _dnsCache = {};
  final Map<String, Future<String?>> _dnsPending = {};
  final Set<String> _tlsInspectedHosts = {};
  DateTime? _dohDownUntil;
  DateTime? _preferDohFirstUntil;
  HttpClient? _dohClient;
  NetworkIssue _lastIssue = NetworkIssue.none;
  bool _overrideInstalled = false;

  // ---------------------------------------------------------------- estado

  bool get loaded => _loaded;

  /// DNS cifrado por HTTPS (activado por defecto: sólo aporta).
  bool get secureDnsEnabled => _secureDns;

  /// Reintento para redes que inspeccionan TLS (activado por defecto).
  bool get tlsFallbackEnabled => _tlsFallback;

  /// Modo VPN integrado: cifra todo el tráfico externo por `wss://api.inutix.com/v1/tun`.
  bool get vpnTunnelEnabled => _vpnTunnel;

  /// `true` cuando el Modo VPN está encendido y el proxy local `127.0.0.1` está listo.
  bool get vpnTunnelActive => _vpnTunnel && InutilVpnTunnel.instance.isRunning;

  /// `host:puerto` del proxy manual (vacío = usar proxy del sistema o salida directa).
  String get proxyHostPort => _proxy;

  /// `host:puerto` del proxy configurado en los ajustes Wi-Fi del sistema Android.
  String get systemProxyHostPort => _systemProxy;

  /// Proxy externo real (manual o del Wi-Fi corporativo), excluyendo el túnel VPN local.
  String get externalProxyHostPort =>
      _proxy.isNotEmpty ? _proxy : _systemProxy;

  /// Proxy efectivo activo: túnel VPN integrado si está encendido, o proxy externo.
  String get effectiveProxyHostPort => vpnTunnelActive
      ? InutilVpnTunnel.instance.localProxyHostPort
      : externalProxyHostPort;

  bool get systemProxyDetected =>
      !vpnTunnelActive && _proxy.isEmpty && _systemProxy.isNotEmpty;

  /// true cuando la red muestra señales de estar filtrando: proxy obligatorio
  /// (manual o detectado del Wi-Fi), DNS que mintió alguna vez, o inspección TLS
  /// ya confirmada. En ese modo el DNS cifrado usa primero los entornos por IP
  /// (no dependen del resolver de la empresa) y acepta el certificado del proxy,
  /// que es el que firma las conexiones.
  bool get corporateModeActive =>
      _systemProxy.isNotEmpty || _dnsPoisoned || _tlsInspectedHosts.isNotEmpty;

  bool get proxyEnabled => effectiveProxyHostPort.isNotEmpty;

  /// true cuando hay alguna restricción activada (proxy manual/sistema, VPN o DNS seguro).
  bool get restrictionsActive =>
      effectiveProxyHostPort.isNotEmpty || _secureDns || _vpnTunnel;

  /// Valor para la propiedad `proxy-url` de libmpv (null = sin proxy).
  String? get mpvProxyUrl =>
      effectiveProxyHostPort.isEmpty ? null : 'http://$effectiveProxyHostPort';

  /// `proxy-url` que le corresponde a una URL concreta de libmpv. Las URLs de
  /// `127.0.0.1` (nuestro proxy local de video) van SIEMPRE directas: el proxy
  /// de la empresa no puede bajarse nada desde el teléfono, y si libmpv le
  /// manda esa petición la reproducción se cae.
  static String? mpvProxyForUrl(String url) {
    final host = Uri.parse(url).host.toLowerCase();
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return null;
    }
    if (instance.vpnTunnelActive && _bypassesVpnTunnel(host)) {
      final ext = instance.externalProxyHostPort;
      return ext.isEmpty ? null : 'http://$ext';
    }
    final effective = instance.effectiveProxyHostPort;
    return effective.isEmpty ? null : 'http://$effective';
  }

  /// El DNS cifrado acepta el certificado de la red sólo cuando la red ya dio
  /// señales de inspeccionar (proxy obligatorio, DNS envenenado o MITM confirmado).
  bool get dohToleratesCertificates => _tlsFallback && corporateModeActive;

  /// Entornos DoH en orden de uso, expuesto para las pruebas.
  @visibleForTesting
  List<String> get dohEndpointsForAssertions => _dohEndpoints;

  NetworkIssue get lastIssue => _lastIssue;

  /// Consejo corto y sin tecnicismos para el mensaje de error del reproductor.
  /// `null` cuando no hay nada que sugerir.
  String? get playbackHint {
    switch (_lastIssue) {
      case NetworkIssue.dnsBlocked:
        if (!_secureDns) {
          return 'Tu red podría estar bloqueando el video. Activa '
              '"Búsqueda segura" en Ajustes > Red y conexión.';
        }
        if (_proxy.isEmpty) {
          return 'Tu red no deja salir directo. Escribe el proxy de tu '
              'empresa en Ajustes > Red y conexión.';
        }
        return null;
      case NetworkIssue.tlsInspected:
        if (!_tlsFallback) {
          return 'Tu red cifra lo que navegas. Activa "Redes que revisan el '
              'tráfico" en Ajustes > Red y conexión.';
        }
        return null;
      case NetworkIssue.proxyUnreachable:
        return 'El proxy de tu red no responde. Revísalo en Ajustes > Red y '
            'conexión.';
      case NetworkIssue.none:
        return null;
    }
  }

  /// true si DoH respondió al menos una vez (para el diagnóstico).
  bool get secureDnsWorking => _dohDownUntil == null;

  /// Permite forzar el motivo del último fallo en pruebas unitarias.
  @visibleForTesting
  set lastIssueForTest(NetworkIssue issue) => _lastIssue = issue;

  /// Entornos DoH usados por las pruebas (un servidor local hace de DNS).
  @visibleForTesting
  set dohEndpointsForTest(List<String> endpoints) =>
      _dohEndpointsOverride = List<String>.unmodifiable(endpoints);

  /// Deja el servicio como recién instalado, para pruebas aisladas.
  @visibleForTesting
  void resetForTest() {
    _dnsCache.clear();
    _dnsPending.clear();
    _tlsInspectedHosts.clear();
    _dohDownUntil = null;
    _preferDohFirstUntil = null;
    _dnsPoisoned = false;
    _dohClient?.close(force: true);
    _dohClient = null;
    _lastIssue = NetworkIssue.none;
    _dohEndpointsOverride = null;
    _systemProxy = '';
    _vpnTunnel = false;
  }

  /// `true` dentro de `flutter test`, donde no se toca la red real.
  @visibleForTesting
  static bool get hermeticTestEnvironment => _hermetic;

  @visibleForTesting
  void setSystemProxyForTest(String raw) {
    _systemProxy = _normalizeProxy(raw) ?? '';
  }

  /// Actualiza la detección del proxy HTTP configurado en el Wi-Fi del sistema
  /// (estándar en redes empresariales Android que requieren proxy autorizado).
  Future<void> refreshSystemProxy() async {
    if (_hermetic || kIsWeb || !Platform.isAndroid) return;
    try {
      final raw = await _deviceChannel
          .invokeMethod<String>('getSystemProxy')
          .timeout(const Duration(seconds: 2));
      final normalized = _normalizeProxy(raw ?? '') ?? '';
      if (normalized != _systemProxy) {
        _systemProxy = normalized;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final sp = await SharedPreferences.getInstance();
      _secureDns = sp.getBool(_kSecureDns) ?? true;
      _tlsFallback = sp.getBool(_kTlsFallback) ?? true;
      _vpnTunnel = sp.getBool(_kVpnTunnel) ?? false;
      _proxy = _normalizeProxy(sp.getString(_kProxy) ?? '') ?? '';
    } catch (_) {}
    await refreshSystemProxy();
    if (_vpnTunnel && !_hermetic) {
      await InutilVpnTunnel.instance.ensureStarted();
    }
    _loaded = true;
    installGlobalOverride();
    notifyListeners();
  }

  /// Activa o desactiva el Modo VPN integrado (`wss://api.inutix.com/v1/tun`).
  /// Devuelve `true` si el estado final quedó listo.
  Future<bool> setVpnTunnelEnabled(bool value) async {
    _vpnTunnel = value;
    await _persist(_kVpnTunnel, value);
    var ok = true;
    if (value) {
      ok = await InutilVpnTunnel.instance.ensureStarted();
      if (!ok) {
        _vpnTunnel = false;
        await _persist(_kVpnTunnel, false);
      }
    } else {
      await InutilVpnTunnel.instance.stop();
    }
    notifyListeners();
    return ok;
  }

  Future<void> setSecureDnsEnabled(bool value) async {
    if (_secureDns == value) return;
    _secureDns = value;
    if (!value) _dohDownUntil = null;
    notifyListeners();
    await _persist(_kSecureDns, value);
  }

  Future<void> setTlsFallbackEnabled(bool value) async {
    if (_tlsFallback == value) return;
    _tlsFallback = value;
    _tlsInspectedHosts.clear();
    notifyListeners();
    await _persist(_kTlsFallback, value);
  }

  /// Guarda [raw] (`host`, `host:puerto` o `http://host:puerto`).
  /// Devuelve un mensaje de error legible o `null` si todo quedó bien.
  Future<String?> setProxy(String raw) async {
    final clean = raw.trim();
    if (clean.isEmpty) {
      _proxy = '';
      notifyListeners();
      await _persist(_kProxy, '');
      return null;
    }
    final normalized = _normalizeProxy(clean);
    if (normalized == null) {
      return 'Escribe la dirección del proxy, por ejemplo 192.168.1.10:3128';
    }
    _proxy = normalized;
    notifyListeners();
    await _persist(_kProxy, normalized);
    return null;
  }

  Future<void> _persist(String key, Object value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (value is bool) {
        await sp.setBool(key, value);
      } else {
        await sp.setString(key, value.toString());
      }
    } catch (_) {}
  }

  /// `host:puerto` válido o `null` si el texto no tiene sentido.
  static String? _normalizeProxy(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return '';
    v = v.replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    v = v.replaceAll(RegExp(r'/+$'), '');
    if (v.isEmpty) return null;
    var host = v;
    var port = 3128; // puerto HTTP estándar, el más común en redes empresas
    final cut = v.lastIndexOf(':');
    if (cut > 0 && cut < v.length - 1) {
      host = v.substring(0, cut);
      final p = int.tryParse(v.substring(cut + 1));
      if (p == null || p < 1 || p > 65535) return null;
      port = p;
    }
    final hostOk = RegExp(
      r'^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$',
    ).hasMatch(host);
    final ipOk = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
    if (!hostOk && !ipOk) return null;
    return '$host:$port';
  }

  // ------------------------------------------------- instalación global

  /// Reemplaza `HttpClient()` de todo el proceso (incluidos `package:http`
  /// y los plugins) por uno con DNS seguro / proxy. Idempotente.
  void installGlobalOverride() {
    if (_overrideInstalled || _hermetic) return;
    _overrideInstalled = true;
    HttpOverrides.global = _InutilHttpOverrides();
  }

  /// Aplica la configuración a un `HttpClient` ya creado.
  ///
  /// [tolerateBadCertificates] debe ser `true` sólo en clientes de video,
  /// que siempre toleraron certificados rotos de CDNs; el resto (cuenta,
  /// catálogo, actualizaciones) mantiene la validación estricta.
  void apply(
    HttpClient client, {
    bool tolerateBadCertificates = false,
    Duration? connectTimeout,
  }) {
    if (_hermetic) return;
    final timeout = connectTimeout ?? const Duration(seconds: 10);
    client.connectionTimeout = timeout;

    // Se lee al momento de cada conexión, así un cambio desde Ajustes o el
    // proxy Wi-Fi del sistema aplica incluso a clientes ya creados.
    // Loopback (proxy HLS local 127.0.0.1) siempre va DIRECT para no romper reproducción.
    client.findProxy = (uri) => resolveProxyDirectiveForUri(uri);

    client.connectionFactory = (uri, proxyHost, proxyPort) => _connect(
          uri,
          proxyHost,
          proxyPort,
          timeout: timeout,
          tolerateBadCertificates: tolerateBadCertificates,
        );

    // Cuando hay proxy, el TLS lo hace dart:io dentro del tunel y es este
    // callback el unico que decide sobre el certificado. Sin proxy decide
    // `_handshake`, que hace el mismo favor la primera vez.
    client.badCertificateCallback = (cert, host, port) {
      if (tolerateBadCertificates) return true;
      if (!_tlsFallback) return false;
      if (_tlsInspectedHosts.contains(host)) return true;
      _tlsInspectedHosts.add(host);
      _lastIssue = NetworkIssue.tlsInspected;
      return true;
    };
  }

  // ------------------------------------------------------------- resolución

  /// Hosts que nunca entran al túnel VPN local para evitar bucles infinitos
  /// (el propio servidor del túnel, la LAN local y el refresco de sesión).
  static bool _bypassesVpnTunnel(String host) {
    final h = host.toLowerCase();
    if (h == 'localhost' || h == '127.0.0.1' || h == '::1') return true;
    if (h == 'api.inutix.com' ||
        h == 'backup.inutix.com' ||
        h == 'identitytoolkit.googleapis.com' ||
        h == 'securetoken.googleapis.com') {
      return true;
    }
    final tunHost = Uri.tryParse(InutilVpnTunnel.instance.endpoint)?.host.toLowerCase();
    if (tunHost != null && tunHost.isNotEmpty && h == tunHost) return true;
    // IPs privadas LAN (p. ej. relay S7 192.168.100.27 o mando TV local)
    if (h.startsWith('192.168.') || h.startsWith('10.')) return true;
    final m172 = RegExp(r'^172\.(\d{1,2})\.').firstMatch(h);
    if (m172 != null) {
      final second = int.tryParse(m172.group(1)!) ?? 0;
      if (second >= 16 && second <= 31) return true;
    }
    return false;
  }

  /// Directiva de proxy (`DIRECT` o `PROXY host:port`) para un [Uri].
  /// Loopback (`localhost`, `127.0.0.1`, `::1`) siempre permanece `DIRECT`.
  @visibleForTesting
  String resolveProxyDirectiveForUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return 'DIRECT';
    }
    if (vpnTunnelActive) {
      if (_bypassesVpnTunnel(host)) {
        final ext = externalProxyHostPort;
        return ext.isNotEmpty ? 'PROXY $ext' : 'DIRECT';
      }
      return 'PROXY ${InutilVpnTunnel.instance.localProxyHostPort}';
    }
    final effective = externalProxyHostPort;
    if (effective.isNotEmpty) return 'PROXY $effective';
    try {
      return HttpClient.findProxyFromEnvironment(uri);
    } catch (_) {
      return 'DIRECT';
    }
  }

  /// Resuelve [host] con DNS-over-HTTPS. `null` si DoH no responde o está
  /// desactivado: el llamador usa entonces el DNS del sistema.
  Future<String?> resolve(String host) async {
    _dbg('resolve($host) inicio');
    if (_hermetic || !_secureDns || effectiveProxyHostPort.isNotEmpty) {
      return null;
    }
    final lower = host.toLowerCase();
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(lower)) return lower;

    final cached = _dnsCache[lower];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.ip;
    }

    final pending = _dnsPending[lower];
    if (pending != null) return pending;

    final task = _queryDoh(lower).then((ip) {
      _dbg('resolve($host) then con $ip');
      if (ip != null) {
        _remember(lower, ip);
      }
      return ip;
    }).whenComplete(() {
      _dbg('resolve($host) whenComplete');
      _dnsPending.remove(lower);
    });
    _dnsPending[lower] = task;
    return task;
  }

  void _remember(String host, String ip) {
    if (_dnsCache.length > _dnsCacheMaxEntries) {
      final cutoff = DateTime.now().subtract(const Duration(minutes: 2));
      _dnsCache.removeWhere((_, e) => e.expiresAt.isBefore(cutoff));
      if (_dnsCache.length > _dnsCacheMaxEntries) _dnsCache.clear();
    }
    _dnsCache[host] = _DnsEntry(
      ip,
      DateTime.now().add(const Duration(minutes: 5)),
    );
  }

  HttpClient _getDohClient() {
    final existing = _dohClient;
    if (existing != null) return existing;
    final client = HttpClient()
      ..connectionTimeout = _dohQueryTimeout
      ..idleTimeout = const Duration(seconds: 45)
      ..maxConnectionsPerHost = 4;
    // Redes sin salida directa (empresas que sólo dejan pasar al proxy): el
    // propio DoH tiene que tunelizar por ese proxy, o se queda mudo justo
    // cuando el DNS de la red es el que miente.
    client.findProxy = resolveProxyDirectiveForUri;
    client.connectionFactory = (uri, proxyHost, proxyPort) => _plainConnect(
          uri,
          proxyHost,
          proxyPort,
          timeout: _dohQueryTimeout,
          tolerateBadCertificates: dohToleratesCertificates,
        );
    // Un proxy que inspecciona TLS firma él mismo el certificado del resolver;
    // rechazarlo dejaría el DNS seguro inutilizable en la red que más lo usa.
    client.badCertificateCallback = (cert, host, port) {
      if (!dohToleratesCertificates) return false;
      _lastIssue = NetworkIssue.tlsInspected;
      return true;
    };
    _dohClient = client;
    return client;
  }

  Future<String?> _queryDoh(String host) async {
    final downUntil = _dohDownUntil;
    if (downUntil != null && downUntil.isAfter(DateTime.now())) return null;

    var anyReachable = false;
    // Priorizar IPv4 ('A') primero en todos los resolvers (99% de CDNs de video);
    // sólo consultar 'AAAA' si ningún servidor devolvió registro A.
    for (final type in const ['A', 'AAAA']) {
      for (final base in _dohEndpoints) {
        _dbg('queryDoh($host) antes de _queryOnce $type en $base');
        final result = await _queryOnce(base, host, type);
        _dbg(
            'queryDoh($host) volvio $type -> ${result.ip} reachable=${result.reachable}');
        if (result.ip != null) return result.ip;
        if (result.reachable) anyReachable = true;
      }
    }
    // Sólo se descarta DoH si NINGÚN servidor respondió: un dominio muerto
    // no debe desactivar el DNS seguro para el resto de la app.
    if (!anyReachable) {
      _dohDownUntil = DateTime.now().add(_dohBlacklistTtl);
    }
    return null;
  }

  /// Consulta un entorno DoH reutilizando conexión TLS keep-alive.
  /// `reachable: false` significa que el entorno no contestó (bloqueo o apagón),
  /// distinto de "el dominio no existe".
  Future<({String? ip, bool reachable})> _queryOnce(
    String base,
    String host,
    String type,
  ) async {
    // El propio DoH SIEMPRE usa el DNS del sistema: si se resolviera con DoH
    // habría recursión infinita cuando la red también bloquea cloudflare-dns.
    final client = _getDohClient();
    try {
      final uri = Uri.parse(base).replace(
        queryParameters: {'name': host, 'type': type},
      );
      _dbg('queryOnce $host $type: pidiendo $uri');
      final req = await client.getUrl(uri).timeout(_dohQueryTimeout);
      req.headers.set('accept', 'application/dns-json');
      final res = await req.close().timeout(_dohQueryTimeout);
      _dbg('queryOnce $host $type: estado ${res.statusCode}');
      if (res.statusCode != 200) {
        await res.drain<void>().catchError((_) {});
        return (ip: null, reachable: false);
      }
      final body = await utf8.decoder
          .bind(res)
          .join()
          .timeout(_dohQueryTimeout, onTimeout: () => '');
      final json = jsonDecode(body);
      if (json is! Map) return (ip: null, reachable: false);
      final answers = json['Answer'];
      if (answers is! List) return (ip: null, reachable: true);
      for (final a in answers) {
        if (a is! Map) continue;
        final data = a['data']?.toString().trim() ?? '';
        if (data.isEmpty) continue;
        final isV4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(data);
        final isV6 =
            RegExp(r'^[0-9a-fA-F:]+$').hasMatch(data) && data.contains(':');
        if ((type == 'A' && isV4) || (type == 'AAAA' && isV6)) {
          return (ip: data, reachable: true);
        }
      }
      return (ip: null, reachable: true);
    } catch (_) {
      // red muy lenta o DoH bloqueado: se prueba el siguiente entorno
      return (ip: null, reachable: false);
    }
  }

  // ------------------------------------------------------------ conexiones

  /// Fabrica la conexión que `HttpClient` necesita (firma de `connectionFactory`).
  ///
  /// Con proxy, `proxyHost`/`proxyPort` vienen poblados y `dart:io` hace el
  /// `CONNECT` y el TLS encima del socket `tcp` que devolvemos; por eso ahí
  /// NO ciframos nosotros. Sin proxy, el socket debe llegar ya cifrado.
  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort, {
    required Duration timeout,
    required bool tolerateBadCertificates,
  }) async {
    if (proxyHost != null && proxyPort != null) {
      return _plainConnect(uri, proxyHost, proxyPort, timeout: timeout);
    }
    return _directConnect(uri,
        timeout: timeout, tolerateBadCertificates: tolerateBadCertificates);
  }

  /// Conexión TCP simple. Con proxy, `dart:io` hace el `CONNECT` y el TLS
  /// encima del socket que devolvemos; sin proxy (p. ej. el propio DoH) el
  /// socket debe llegar ya cifrado o el servidor corta la conexión.
  Future<ConnectionTask<Socket>> _plainConnect(
    Uri uri,
    String? proxyHost,
    int? proxyPort, {
    required Duration timeout,
    bool tolerateBadCertificates = false,
  }) async {
    final host = proxyHost ?? uri.host;
    final port = proxyPort ?? uri.port;
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: timeout);
    } catch (_) {
      socket?.destroy();
      if (proxyHost != null) _lastIssue = NetworkIssue.proxyUnreachable;
      rethrow;
    }

    final isTls = uri.scheme == 'https' || uri.scheme == 'wss';
    if (proxyHost != null || !isTls) {
      return ConnectionTask.fromSocket(
        Future.value(socket),
        () => socket?.destroy(),
      );
    }

    final secure = await SecureSocket.secure(
      socket,
      host: uri.host,
      onBadCertificate: (_) => tolerateBadCertificates,
    ).timeout(_tlsHandshakeTimeout);
    return ConnectionTask.fromSocket(
      Future.value(secure),
      () => secure.destroy(),
    );
  }

  static bool _isLocalOrIpHost(String host) {
    final lower = host.toLowerCase();
    return lower == 'localhost' ||
        lower == '127.0.0.1' ||
        lower == '::1' ||
        RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(lower);
  }

  Future<ConnectionTask<Socket>> _directConnect(
    Uri uri, {
    required Duration timeout,
    required bool tolerateBadCertificates,
  }) async {
    final host = uri.host;
    final port = uri.port;
    final needsTls = uri.scheme == 'https' || uri.scheme == 'wss';
    final lower = host.toLowerCase();
    final isLiteralOrLocal = _isLocalOrIpHost(lower);

    Socket? raw;
    String? targetIp;

    // 1. Si ya tenemos IP válida en caché DoH (0 ms) o detectamos red con DNS filtrado,
    //    usamos DoH primero. En redes normales/móviles lentas evitamos pagar un roundtrip
    //    extra de DoH por cada subdominio efímero de CDN y vamos directo al DNS del sistema
    //    (5-15 ms), con fallback instantáneo a DoH si el DNS local falla o bloquea el host.
    final cachedDoh = _dnsCache[lower];
    final hasFreshDohCache =
        cachedDoh != null && cachedDoh.expiresAt.isAfter(DateTime.now());
    final preferDohFirst = !isLiteralOrLocal &&
        _secureDns &&
        (hasFreshDohCache ||
            (_preferDohFirstUntil != null &&
                _preferDohFirstUntil!.isAfter(DateTime.now())));

    if (preferDohFirst) {
      final resolved = hasFreshDohCache ? cachedDoh.ip : await resolve(host);
      if (resolved != null && resolved != host) {
        try {
          raw = await Socket.connect(resolved, port, timeout: timeout);
          targetIp = resolved;
        } catch (_) {
          raw = null;
        }
      }
      if (raw == null) {
        try {
          raw = await Socket.connect(host, port, timeout: timeout);
        } on SocketException {
          if (resolved == null) _lastIssue = NetworkIssue.dnsBlocked;
          rethrow;
        }
      }
    } else {
      // Ruta rápida: DNS del sistema primero (0 ms de sobrecarga en Wi-Fi / 4G / red lenta)
      try {
        raw = await Socket.connect(host, port, timeout: timeout);
        // Si un firewall envenenó el DNS devolviendo 0.0.0.0/127.x para un host externo,
        // descartar y resolver por DoH.
        if (!isLiteralOrLocal &&
            (raw.remoteAddress.address == '0.0.0.0' ||
                raw.remoteAddress.isLoopback)) {
          raw.destroy();
          raw = null;
          // El DNS de la red mintió: a partir de ahora resolver por el camino
          // cifrado, que es lo que hace funcionar la app en redes corporativas.
          _dnsPoisoned = true;
          _preferDohFirstUntil =
              DateTime.now().add(const Duration(minutes: 10));
        }
      } catch (_) {
        raw = null;
      }

      if (raw == null && !isLiteralOrLocal && _secureDns) {
        final resolved = await resolve(host);
        if (resolved != null && resolved != host) {
          try {
            raw = await Socket.connect(resolved, port, timeout: timeout);
            targetIp = resolved;
            // La red local filtró o falló pero DoH sí conectó: preferir DoH los próximos 10 min.
            _preferDohFirstUntil =
                DateTime.now().add(const Duration(minutes: 10));
          } catch (_) {
            raw = null;
          }
        }
      }

      if (raw == null) {
        _lastIssue = NetworkIssue.dnsBlocked;
        throw SocketException('No se pudo conectar a $host:$port');
      }
    }
    _lastIssue = NetworkIssue.none;

    if (!needsTls) {
      final socket = raw;
      return ConnectionTask.fromSocket(
        Future.value(socket),
        () => socket.destroy(),
      );
    }

    final secure = await _handshake(
      raw,
      sniHost: host,
      target: targetIp ?? host,
      port: port,
      timeout: timeout,
      tolerateBadCertificates: tolerateBadCertificates,
      // Si el nombre lo resolvió el DNS de la red, ese IP puede ser un sumidero
      // corporativo: el handshake lo delata y se reintenta contra la IP real.
      dohRetry:
          (targetIp == null && !isLiteralOrLocal) ? () => resolve(host) : null,
    );
    return ConnectionTask.fromSocket(
      Future.value(secure),
      () => secure.destroy(),
    );
  }

  /// TLS con SNI estricto. Dos reintentos según lo que la red hizo:
  /// si el handshake falló contra una IP que dio el DNS de la red, se prueba
  /// contra la IP real del DNS cifrado (sumidero corporativo); si la IP era la
  /// correcta, el que falla es el certificado: la red inspecciona el tráfico y
  /// se reintenta una sola vez confiando en él.
  Future<SecureSocket> _handshake(
    Socket raw, {
    required String sniHost,
    required String target,
    required int port,
    required Duration timeout,
    required bool tolerateBadCertificates,
    Future<String?> Function()? dohRetry,
  }) async {
    final trusted =
        tolerateBadCertificates || _tlsInspectedHosts.contains(sniHost);
    try {
      return await SecureSocket.secure(
        raw,
        host: sniHost,
        onBadCertificate: (_) => trusted,
      ).timeout(_tlsHandshakeTimeout);
    } on HandshakeException {
      raw.destroy();
      // 1) La IP venía del DNS de la red: puede ser un sumidero. Reintentar
      //    contra la IP real antes de acusar a la red de inspeccionar.
      if (dohRetry != null) {
        final real = await dohRetry();
        if (real != null && real != target) {
          try {
            final viaDoh = await Socket.connect(real, port, timeout: timeout);
            _dnsPoisoned = true;
            _lastIssue = NetworkIssue.dnsBlocked;
            return await SecureSocket.secure(
              viaDoh,
              host: sniHost,
              onBadCertificate: (_) => true,
            ).timeout(_tlsHandshakeTimeout);
          } catch (_) {
            // No era la IP: se continúa con la tolerancia de certificado.
          }
        }
      }
      // El cortocorte fue el certificado: la red esta cifrando lo que navega.
      _lastIssue = NetworkIssue.tlsInspected;
      if (trusted || !_tlsFallback) rethrow;
      // Primera vez con esta red: reintento breve aceptando su certificado.
      _tlsInspectedHosts.add(sniHost);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final again = await Socket.connect(target, port, timeout: timeout);
      return SecureSocket.secure(
        again,
        host: sniHost,
        onBadCertificate: (_) => true,
      ).timeout(_tlsHandshakeTimeout);
    }
  }

  // ------------------------------------------------------------ diagnóstico

  /// Comprueba los cuatro frentes que necesita la app y devuelve latencias.
  Future<NetworkReport> runDiagnostics() async {
    _dbg('diagnostico: inicio');
    await refreshSystemProxy();
    final checks = <NetworkCheck>[];
    if (_vpnTunnel) {
      final probe = await InutilVpnTunnel.instance.probeTunnel();
      checks.add(NetworkCheck(
        label: 'Túnel VPN',
        ok: probe.ok,
        millis: probe.millis,
        detail: probe.detail,
      ));
    }
    checks.add(await _probe(
        'Cuenta',
        Uri.parse(
          '${FirebaseConfig.firestoreBaseUrl}/app_config/tv_release',
        )));
    checks.add(await _probeAlguna('Catálogo', const [
      'https://meta.inutix.com/healthz',
      'https://www.themoviedb.org/',
    ]));
    checks.add(await _probeAlguna('Video', const [
      'https://jkanime.net/',
      'https://www.poseidonhd2.co/',
    ]));
    checks.add(await _probeAlguna('Actualizaciones', const [
      'https://ota.inutix.com/release.json',
      'https://github.com/CesarHGlez13/inutil-tv/releases/latest/download/release.json',
    ]));
    // El frente nuevo: si el DNS cifrado está vivo. En una red corporativa es
    // lo que sostiene todo lo demás, y conviene verlo antes de echar a andar.
    checks.add(await _probeAlguna('DNS cifrado', const [
      'https://1.1.1.1/dns-query?type=A&name=example.com',
      'https://8.8.8.8/resolve?type=A&name=example.com',
    ]));
    return NetworkReport(checks, proxyEnabled, secureDnsEnabled);
  }

  /// Prueba varios sitios del mismo frente y aprueba con que uno responda.
  Future<NetworkCheck> _probeAlguna(
    String label,
    List<String> urls,
  ) async {
    NetworkCheck? peor;
    for (final url in urls) {
      final c = await _probe(label, Uri.parse(url));
      if (c.ok) return c;
      peor ??= c;
    }
    return peor ?? await _probe(label, Uri.parse(urls.first));
  }

  Future<NetworkCheck> _probe(String label, Uri uri) async {
    final sw = Stopwatch()..start();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    apply(client, connectTimeout: const Duration(seconds: 6));
    try {
      _dbg('sonda $label: $uri');
      final req = await client.headUrl(uri).timeout(const Duration(seconds: 6));
      final res = await req.close().timeout(const Duration(seconds: 6));
      // Un 401/403/404 sigue significando que la red SÍ deja pasar.
      final ok = res.statusCode < 500;
      return NetworkCheck(
        label: label,
        ok: ok,
        millis: sw.elapsedMilliseconds,
        detail: ok ? '' : 'HTTP ${res.statusCode}',
      );
    } on SocketException catch (e) {
      return NetworkCheck(
        label: label,
        ok: false,
        millis: sw.elapsedMilliseconds,
        detail: e.osError == null ? 'sin respuesta' : 'bloqueado',
      );
    } on HandshakeException {
      return NetworkCheck(
        label: label,
        ok: false,
        millis: sw.elapsedMilliseconds,
        detail: 'certificado',
      );
    } catch (_) {
      return NetworkCheck(
        label: label,
        ok: false,
        millis: sw.elapsedMilliseconds,
        detail: 'sin respuesta',
      );
    } finally {
      client.close(force: true);
    }
  }
}

class _InutilHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    NetworkConfigService.instance.apply(client);
    return client;
  }
}
