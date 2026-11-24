import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_config.dart';

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

  /// Entornos DoH públicos (JSON) en orden de preferencia.
  static const List<String> _kDohEndpoints = [
    'https://cloudflare-dns.com/dns-query',
    'https://dns.google/resolve',
  ];

  /// Entornos DoH en uso (se pueden sustituir en las pruebas).
  List<String> _dohEndpoints = _kDohEndpoints;

  static const Duration _dohQueryTimeout = Duration(seconds: 3);
  static const Duration _tlsHandshakeTimeout = Duration(seconds: 10);
  static const Duration _dohBlacklistTtl = Duration(minutes: 5);
  static const int _dnsCacheMaxEntries = 400;

  /// En `flutter test` no se toca la red real ni se instalan overrides, salvo
  /// que se pida explícitamente con `INUTILTV_REAL_NET=1` (ver el test live).
  static final bool _hermetic =
      (Platform.environment.containsKey('FLUTTER_TEST') || kIsWeb) &&
          !Platform.environment.containsKey('INUTILTV_REAL_NET');

  bool _loaded = false;
  bool _secureDns = true;
  bool _tlsFallback = true;
  String _proxy = '';

  final Map<String, _DnsEntry> _dnsCache = {};
  final Map<String, Future<String?>> _dnsPending = {};
  final Set<String> _tlsInspectedHosts = {};
  DateTime? _dohDownUntil;
  NetworkIssue _lastIssue = NetworkIssue.none;
  bool _overrideInstalled = false;

  // ---------------------------------------------------------------- estado

  bool get loaded => _loaded;

  /// DNS cifrado por HTTPS (activado por defecto: sólo aporta).
  bool get secureDnsEnabled => _secureDns;

  /// Reintento para redes que inspeccionan TLS (activado por defecto).
  bool get tlsFallbackEnabled => _tlsFallback;

  /// `host:puerto` del proxy manual (vacío = salida directa).
  String get proxyHostPort => _proxy;

  bool get proxyEnabled => _proxy.isNotEmpty;

  /// true cuando hay alguna restricción activada (proxy o DNS seguro).
  bool get restrictionsActive => _proxy.isNotEmpty || _secureDns;

  /// Valor para la propiedad `proxy-url` de libmpv (null = sin proxy).
  String? get mpvProxyUrl => _proxy.isEmpty ? null : 'http://$_proxy';

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
      _dohEndpoints = List<String>.unmodifiable(endpoints);

  /// Deja el servicio como recién instalado, para pruebas aisladas.
  @visibleForTesting
  void resetForTest() {
    _dnsCache.clear();
    _dnsPending.clear();
    _tlsInspectedHosts.clear();
    _dohDownUntil = null;
    _lastIssue = NetworkIssue.none;
    _dohEndpoints = _kDohEndpoints;
  }

  /// `true` dentro de `flutter test`, donde no se toca la red real.
  @visibleForTesting
  static bool get hermeticTestEnvironment => _hermetic;

  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final sp = await SharedPreferences.getInstance();
      _secureDns = sp.getBool(_kSecureDns) ?? true;
      _tlsFallback = sp.getBool(_kTlsFallback) ?? true;
      _proxy = _normalizeProxy(sp.getString(_kProxy) ?? '') ?? '';
    } catch (_) {}
    _loaded = true;
    installGlobalOverride();
    notifyListeners();
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

    // Se lee al momento de cada conexión, así un cambio desde Ajustes aplica
    // incluso a los clientes que ya estaban creados y en uso.
    client.findProxy = (uri) {
      final proxy = _proxy;
      if (proxy.isNotEmpty) return 'PROXY $proxy';
      try {
        return HttpClient.findProxyFromEnvironment(uri);
      } catch (_) {
        return 'DIRECT';
      }
    };

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

  /// Resuelve [host] con DNS-over-HTTPS. `null` si DoH no responde o está
  /// desactivado: el llamador usa entonces el DNS del sistema.
  Future<String?> resolve(String host) async {
    _dbg('resolve($host) inicio');
    if (_hermetic || !_secureDns || _proxy.isNotEmpty) return null;
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

  Future<String?> _queryDoh(String host) async {
    final downUntil = _dohDownUntil;
    if (downUntil != null && downUntil.isAfter(DateTime.now())) return null;

    var anyReachable = false;
    for (final base in _dohEndpoints) {
      for (final type in const ['A', 'AAAA']) {
        _dbg('queryDoh($host) antes de _queryOnce $type en $base');
        final result = await _queryOnce(base, host, type);
        _dbg('queryDoh($host) volvio $type -> ${result.ip} reachable=${result.reachable}');
        if (result.ip != null) return result.ip;
        if (!result.reachable) break; // este entorno no responde: probar otro
        anyReachable = true;
      }
    }
    // Sólo se descarta DoH si NINGÚN servidor respondió: un dominio muerto
    // no debe desactivar el DNS seguro para el resto de la app.
    if (!anyReachable) {
      _dohDownUntil = DateTime.now().add(_dohBlacklistTtl);
    }
    return null;
  }

  /// Consulta un entorno DoH. `reachable: false` significa que el entorno no
  /// contestó (bloqueo o apagón), distinto de "el dominio no existe".
  Future<({String? ip, bool reachable})> _queryOnce(
    String base,
    String host,
    String type,
  ) async {
    // El propio DoH SIEMPRE usa el DNS del sistema: si se resolviera con DoH
    // habría recursión infinita cuando la red también bloquea cloudflare-dns.
    final client = HttpClient()..connectionTimeout = _dohQueryTimeout;
    client.connectionFactory = (uri, proxyHost, proxyPort) => _plainConnect(
          uri,
          proxyHost,
          proxyPort,
          timeout: _dohQueryTimeout,
        );
    try {
      final uri = Uri.parse(base).replace(
        queryParameters: {'name': host, 'type': type},
      );
      _dbg('queryOnce $host $type: pidiendo $uri');
      final req = await client.getUrl(uri).timeout(_dohQueryTimeout);
      req.headers.set('accept', 'application/dns-json');
      final res = await req.close().timeout(_dohQueryTimeout);
      _dbg('queryOnce $host $type: estado ${res.statusCode}');
      if (res.statusCode != 200) return (ip: null, reachable: false);
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
    } finally {
      client.close(force: true);
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
    return _directConnect(uri, timeout: timeout, tolerateBadCertificates: tolerateBadCertificates);
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

    if (proxyHost != null || uri.scheme != 'https') {
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

  Future<ConnectionTask<Socket>> _directConnect(
    Uri uri, {
    required Duration timeout,
    required bool tolerateBadCertificates,
  }) async {
    final host = uri.host;
    final port = uri.port;
    final needsTls = uri.scheme == 'https';
    final resolved = await resolve(host);

    Socket? raw;
    var viaCachedIp = false;
    // Intento 1: IP real del DNS seguro (si la red filtraba el nombre, esta
    // es la que funciona).
    if (resolved != null && resolved != host) {
      try {
        raw = await Socket.connect(resolved, port, timeout: timeout);
        viaCachedIp = true;
      } catch (_) {
        raw = null;
      }
    }
    // Intento 2 (o único): DNS del sistema, comportamiento original.
    if (raw == null) {
      try {
        raw = await Socket.connect(host, port, timeout: timeout);
      } on SocketException {
        // El DNS del sistema tampoco resolvió y no hay IP segura: la red está
        // filtrando los nombres (típico en WiFi de empresa o de hotel).
        if (resolved == null) _lastIssue = NetworkIssue.dnsBlocked;
        rethrow;
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
      target: viaCachedIp ? resolved! : host,
      port: port,
      timeout: timeout,
      tolerateBadCertificates: tolerateBadCertificates,
    );
    return ConnectionTask.fromSocket(
      Future.value(secure),
      () => secure.destroy(),
    );
  }

  /// TLS con SNI estricto; si la red inspecciona el tráfico (certificado
  /// emitido por el propio firewall) reintenta una vez confiando en él.
  Future<SecureSocket> _handshake(
    Socket raw, {
    required String sniHost,
    required String target,
    required int port,
    required Duration timeout,
    required bool tolerateBadCertificates,
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
    final checks = <NetworkCheck>[];
    checks.add(await _probe('Cuenta', Uri.parse(
      '${FirebaseConfig.firestoreBaseUrl}/app_config/tv_release',
    )));
    checks.add(await _probe('Catálogo', Uri.parse(
      'https://www.themoviedb.org/',
    )));
    checks.add(await _probeAlguna('Video', const [
      'https://jkanime.net/',
      'https://www.poseidonhd2.co/',
    ]));
    checks.add(await _probe('Actualizaciones', Uri.parse(
      'https://github.com/CesarHGlez13/inutil-tv/releases/latest/download/release.json',
    )));
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
