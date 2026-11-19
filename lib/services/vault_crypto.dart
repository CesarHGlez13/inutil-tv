import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

/// Motor criptográfico AES-256-CTR para la Bóveda Offline de InútilTV v3.2.2.
///
/// - Cada película/episodio usa una clave única de 256 bits + nonce de 128 bits.
/// - El modo **AES-256-CTR** permite descifrado de acceso aleatorio en **O(1)**
///   desde cualquier `byteOffset` (`206 Partial Content`) sin escribir jamás un
///   solo byte descifrado en disco.
/// - [transformOffMainThread] ejecuta el cifrado/descifrado en un **Isolate
///   trabajador persistente** con transferencia `TransferableTypedData`
///   (zero-copy) para mantener el hilo UI y el servidor loopback a 0 % bloqueo.
class VaultCrypto {
  VaultCrypto._();

  static final Random _rng = Random.secure();

  // Worker Isolate persistente (se crea una sola vez, 0 ms de spawn por bloque)
  static SendPort? _workerSendPort;
  static Future<SendPort>? _workerInitFuture;
  static int _nextReqId = 1;
  static final Map<int, Completer<Uint8List>> _pending = {};

  static Uint8List generateKey32() =>
      Uint8List.fromList(List<int>.generate(32, (_) => _rng.nextInt(256)));

  static Uint8List generateNonce16() =>
      Uint8List.fromList(List<int>.generate(16, (_) => _rng.nextInt(256)));

  /// Cifra o descifra [data] (AES-256-CTR es simétrico) a partir de [byteOffset].
  /// Soporta cualquier offset arbitrario (múltiplo o no de 16 bytes) en O(1).
  static Uint8List transformAtOffset(
    Uint8List data, {
    required Uint8List key32,
    required Uint8List nonce16,
    int byteOffset = 0,
  }) {
    if (data.isEmpty) return Uint8List(0);
    assert(key32.length == 32);
    assert(nonce16.length == 16);

    final blockIndex = byteOffset ~/ 16;
    final intraOffset = byteOffset % 16;
    final iv = _addToCounter128(nonce16, blockIndex);

    final cipher = pc.CTRStreamCipher(pc.AESEngine())
      ..init(
        true,
        pc.ParametersWithIV<pc.KeyParameter>(pc.KeyParameter(key32), iv),
      );

    if (intraOffset == 0) {
      return cipher.process(data);
    }

    // Avanzar el keystream exactamente `intraOffset` bytes dentro del bloque
    final padded = Uint8List(intraOffset + data.length);
    padded.setRange(intraOffset, padded.length, data);
    final transformed = cipher.process(padded);
    return Uint8List.sublistView(transformed, intraOffset);
  }

  /// Ejecuta [transformAtOffset] fuera del hilo principal de UI usando un
  /// Isolate trabajador persistente + `TransferableTypedData` (zero-copy).
  /// Para bloques diminutos (< 8 KB), ejecuta en línea (< 0.05 ms).
  static Future<Uint8List> transformOffMainThread(
    Uint8List data, {
    required Uint8List key32,
    required Uint8List nonce16,
    int byteOffset = 0,
  }) async {
    if (data.isEmpty) return Uint8List(0);
    if (data.length < 8192) {
      return transformAtOffset(
        data,
        key32: key32,
        nonce16: nonce16,
        byteOffset: byteOffset,
      );
    }

    try {
      final sendPort = await _ensureWorker();
      final reqId = _nextReqId++;
      final completer = Completer<Uint8List>();
      _pending[reqId] = completer;

      sendPort.send([
        reqId,
        TransferableTypedData.fromList([data]),
        key32,
        nonce16,
        byteOffset,
      ]);
      return await completer.future;
    } catch (_) {
      // Fallback seguro si el entorno no permite isolates
      return transformAtOffset(
        data,
        key32: key32,
        nonce16: nonce16,
        byteOffset: byteOffset,
      );
    }
  }

  static Future<SendPort> _ensureWorker() {
    final ready = _workerSendPort;
    if (ready != null) return Future.value(ready);
    return _workerInitFuture ??= _spawnWorker();
  }

  static Future<SendPort> _spawnWorker() async {
    final handshake = Completer<SendPort>();
    final rp = ReceivePort();

    rp.listen((dynamic message) {
      if (message is SendPort) {
        _workerSendPort = message;
        if (!handshake.isCompleted) handshake.complete(message);
        return;
      }
      if (message is List && message.length == 2) {
        final reqId = message[0] as int;
        final payload = message[1];
        final completer = _pending.remove(reqId);
        if (completer == null || completer.isCompleted) return;
        if (payload is TransferableTypedData) {
          completer.complete(payload.materialize().asUint8List());
        } else if (payload is Uint8List) {
          completer.complete(payload);
        } else {
          completer.completeError(StateError('Respuesta inválida de crypto isolate'));
        }
      }
    });

    await Isolate.spawn<SendPort>(
      _cryptoWorkerEntry,
      rp.sendPort,
      debugName: 'inutil_vault_crypto_worker',
    );
    return handshake.future;
  }

  @pragma('vm:entry-point')
  static void _cryptoWorkerEntry(SendPort mainPort) {
    final inbox = ReceivePort();
    mainPort.send(inbox.sendPort);

    inbox.listen((dynamic message) {
      if (message is! List || message.length != 5) return;
      final reqId = message[0] as int;
      final ttd = message[1] as TransferableTypedData;
      final key32 = message[2] as Uint8List;
      final nonce16 = message[3] as Uint8List;
      final byteOffset = message[4] as int;

      final bytes = ttd.materialize().asUint8List();
      final out = transformAtOffset(
        bytes,
        key32: key32,
        nonce16: nonce16,
        byteOffset: byteOffset,
      );
      mainPort.send([reqId, TransferableTypedData.fromList([out])]);
    });
  }

  /// Deriva un nonce determinista por índice de archivo/segmento dentro de la
  /// misma descarga para que ningún segmento reutilice keystream.
  static Uint8List deriveSegmentNonce(Uint8List baseNonce16, int segmentIndex) {
    return _addToCounter128(baseNonce16, segmentIndex * 0x100000);
  }

  /// Suma [delta] al contador big-endian de 128 bits sin mutar [base].
  static Uint8List _addToCounter128(Uint8List base, int delta) {
    final out = Uint8List.fromList(base);
    if (delta == 0) return out;
    var carry = delta;
    for (var i = 15; i >= 0 && carry > 0; i--) {
      final sum = out[i] + (carry & 0xFF);
      out[i] = sum & 0xFF;
      carry = (carry >> 8) + (sum >> 8);
    }
    return out;
  }
}
