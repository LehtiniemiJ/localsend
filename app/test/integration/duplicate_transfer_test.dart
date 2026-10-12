@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
// Needed to open the explicit native library in this integration test.
// ignore: depend_on_referenced_packages
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart' show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/duplicate_file_helper.dart';
import 'package:localsend_isolates/rust/api/cancel.dart' as rust_cancel;
import 'package:localsend_isolates/rust/api/model.dart' show DeviceType;
import 'package:localsend_isolates/rust/api/server.dart'
    show RsHttpServer, RsServerEvent, RsServerEvent_FileUpload, RsServerEvent_PrepareUpload, WebI18n, WebMode, WebPages, WebParams, startServer;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/util/file_hash.dart' as file_hash;
import 'package:localsend_isolates/util/rust.dart' show RustFileDtoExt;

Future<void>? _rustInitialization;

void main() {
  test('duplicate contents are omitted from upload tokens and all-duplicate transfers return 204', () async {
    final library = _findRustLibrary();
    if (library == null) {
      markTestSkipped('Rust dylib not found; build it with cargo build -p rust_lib_localsend_app');
      return;
    }
    await _initializeRust(library);

    final testServer = await _startTestServer();
    addTearDown(testServer.close);

    final duplicateIdentifier = '00100328bed2dabaf97a64e1320da2409153d6ff504a23d61568590a0a52624e';
    final newIdentifier = 'a' * 64;
    final duplicateBytes = utf8.encode('existing Signal attachment');
    final newBytes = utf8.encode('new attachment to transfer');
    await File('${testServer.destination.path}/$duplicateIdentifier').writeAsBytes(duplicateBytes);
    final extraDuplicates = [
      for (var i = 1; i <= 3; i++)
        _OfferedFile(id: 'duplicate-$i', fileName: i.toRadixString(16).padLeft(64, '0'), bytes: utf8.encode('existing attachment $i')),
    ];
    for (final file in extraDuplicates) {
      await File('${testServer.destination.path}/${file.fileName}').writeAsBytes(file.bytes);
    }

    final offeredFiles = [
      ...extraDuplicates,
      _OfferedFile(
        id: 'duplicate-file-id',
        fileName: duplicateIdentifier,
        bytes: duplicateBytes,
      ),
      _OfferedFile(
        id: 'new-file-id',
        fileName: newIdentifier,
        bytes: newBytes,
      ),
    ];

    final prepareFuture = _prepareUpload(testServer.client, testServer.port, offeredFiles);
    final prepareEvent = await _nextPrepareUpload(testServer.events);
    final duplicateIds = await _findDuplicates(prepareEvent, testServer.destination.path);
    expect(duplicateIds, {'duplicate-file-id', ...extraDuplicates.map((file) => file.id)});

    final acceptedIds = prepareEvent.files.keys.where((id) => !duplicateIds.contains(id)).toList();
    await testServer.server
        .respondPrepareUpload(sessionId: prepareEvent.sessionId, acceptedFileIds: acceptedIds)
        .timeout(const Duration(seconds: 10));

    final prepareResponse = await prepareFuture;
    expect(prepareResponse.statusCode, HttpStatus.ok);
    final tokens = _tokens(prepareResponse.body);
    expect(tokens.keys, {'new-file-id'});

    for (final entry in tokens.entries) {
      final offered = offeredFiles.singleWhere((file) => file.id == entry.key);
      final uploadFuture = _upload(
        testServer.client,
        testServer.port,
        sessionId: prepareEvent.sessionId,
        fileId: entry.key,
        token: entry.value,
        bytes: offered.bytes,
      );
      final uploadEvent = await _nextFileUpload(testServer.events, prepareEvent.sessionId);
      await _respondToUpload(testServer, uploadEvent);
      expect((await uploadFuture).statusCode, HttpStatus.ok);
    }
    expect(testServer.uploadEvents.map((event) => event.fileId), ['new-file-id']);
    expect(await File('${testServer.destination.path}/new-file-id').readAsBytes(), newBytes);
    expect(await File('${testServer.destination.path}/$duplicateIdentifier').readAsBytes(), duplicateBytes);

    final allDuplicateFile = _OfferedFile(
      id: 'already-present',
      fileName: duplicateIdentifier,
      bytes: duplicateBytes,
    );
    final uploadCountBeforeAllDuplicate = testServer.uploadEvents.length;
    final allDuplicatePrepare = _prepareUpload(testServer.client, testServer.port, [allDuplicateFile]);
    final allDuplicateEvent = await _nextPrepareUpload(testServer.events);
    final allDuplicateIds = await _findDuplicates(allDuplicateEvent, testServer.destination.path);
    expect(allDuplicateIds, {'already-present'});

    await testServer.server
        .respondPrepareUpload(
          sessionId: allDuplicateEvent.sessionId,
          acceptedFileIds: allDuplicateEvent.files.keys.where((id) => !allDuplicateIds.contains(id)).toList(),
        )
        .timeout(const Duration(seconds: 10));
    final allDuplicateResponse = await allDuplicatePrepare;
    expect(allDuplicateResponse.statusCode, HttpStatus.noContent);
    expect(testServer.uploadEvents.length, uploadCountBeforeAllDuplicate, reason: 'the all-duplicate request must emit no upload event');
  });

  test('cancelled duplicate scan cannot answer a later prepare-upload session', () async {
    final library = _findRustLibrary();
    if (library == null) {
      markTestSkipped('Rust dylib not found; build it with cargo build -p rust_lib_localsend_app');
      return;
    }
    await _initializeRust(library);

    final testServer = await _startTestServer();
    addTearDown(testServer.close);

    final existingIdentifier = 'b' * 64;
    final pendingBytes = utf8.encode('file whose duplicate scan is cancelled');
    await File('${testServer.destination.path}/$existingIdentifier').writeAsBytes(pendingBytes);
    final pendingFile = _OfferedFile(
      id: 'session-a-file',
      fileName: existingIdentifier,
      bytes: pendingBytes,
    );
    final prepareAFuture = _prepareUpload(testServer.client, testServer.port, [pendingFile]);
    final prepareAEvent = await _nextPrepareUpload(testServer.events);

    final hashStarted = Completer<void>();
    final releaseHash = Completer<void>();
    var cancelled = false;
    final scanFuture = findDuplicateFileIds(
      incomingFiles: prepareAEvent.files.values.map((file) => file.toDart()),
      destinationDirectory: testServer.destination.path,
      calculateHash: (path) async {
        hashStarted.complete();
        await releaseHash.future;
        return _calculateHash(path);
      },
      isCancelled: () => cancelled,
    );
    await hashStarted.future.timeout(const Duration(seconds: 10));

    final cancelResponse = await _cancelPendingUpload(testServer.client, testServer.port);
    expect(cancelResponse.statusCode, HttpStatus.ok);
    cancelled = true;
    releaseHash.complete();
    expect(await scanFuture, isEmpty);
    expect((await prepareAFuture).statusCode, HttpStatus.forbidden);

    final nextBytes = utf8.encode('session B can still be accepted');
    final nextFile = _OfferedFile(
      id: 'session-b-file',
      fileName: 'c' * 64,
      bytes: nextBytes,
    );
    final prepareBFuture = _prepareUpload(testServer.client, testServer.port, [nextFile]);
    final prepareBEvent = await _nextPrepareUpload(testServer.events);
    expect(prepareBEvent.sessionId, isNot(prepareAEvent.sessionId));

    await expectLater(
      testServer.server.respondPrepareUpload(sessionId: prepareAEvent.sessionId, acceptedFileIds: const []).timeout(const Duration(seconds: 10)),
      throwsA(anything),
    );

    final duplicateIds = await _findDuplicates(prepareBEvent, testServer.destination.path);
    expect(duplicateIds, isEmpty);
    await testServer.server
        .respondPrepareUpload(
          sessionId: prepareBEvent.sessionId,
          acceptedFileIds: prepareBEvent.files.keys.where((id) => !duplicateIds.contains(id)).toList(),
        )
        .timeout(const Duration(seconds: 10));
    final prepareBResponse = await prepareBFuture;
    expect(prepareBResponse.statusCode, HttpStatus.ok);
    final token = _tokens(prepareBResponse.body).entries.single;

    final uploadFuture = _upload(
      testServer.client,
      testServer.port,
      sessionId: prepareBEvent.sessionId,
      fileId: token.key,
      token: token.value,
      bytes: nextBytes,
    );
    final uploadEvent = await _nextFileUpload(testServer.events, prepareBEvent.sessionId);
    expect(uploadEvent.fileId, 'session-b-file');
    await _respondToUpload(testServer, uploadEvent);
    expect((await uploadFuture).statusCode, HttpStatus.ok);
    expect(testServer.uploadEvents.map((event) => event.fileId), ['session-b-file']);
  });
}

File? _findRustLibrary() {
  final paths = <String?>[
    Platform.environment['LOCALSEND_TEST_LIBRARY'],
    '${Directory.current.path}/build/linux/x64/debug/bundle/lib/librust_lib_localsend_app.so',
    '${Directory.current.path}/app/build/linux/x64/debug/bundle/lib/librust_lib_localsend_app.so',
  ].whereType<String>().where((path) => path.isNotEmpty);
  for (final path in paths) {
    final file = File(path);
    if (file.existsSync()) {
      return file;
    }
  }
  return null;
}

Future<void> _initializeRust(File library) =>
    _rustInitialization ??= RustLib.init(externalLibrary: ExternalLibrary.open(library.path)).timeout(const Duration(seconds: 10));

Future<_TestServer> _startTestServer() async {
  final port = await _reservePort();
  final server = await startServer(
    port: port,
    tls: null,
    alias: 'Receiver',
    version: '2.2',
    deviceModel: 'Test',
    deviceType: DeviceType.desktop,
    fingerprint: 'RECEIVER-FINGERPRINT',
    pin: null,
    verifyChecksums: true,
    web: const WebParams(
      mode: WebMode.disabled(),
      i18N: WebI18n(
        waiting: '',
        enterPin: '',
        invalidPin: '',
        tooManyAttempts: '',
        rejected: '',
        uploadRejected: '',
        busy: '',
        files: '',
        fileName: '',
        size: '',
        dropHint: '',
      ),
      pages: WebPages(),
    ),
    showToken: null,
  ).timeout(const Duration(seconds: 10));
  final destination = await Directory.systemTemp.createTemp('localsend-duplicate-transfer-');
  final eventController = StreamController<RsServerEvent>.broadcast();
  final eventSubscription = server.listen().listen(
    (event) {
      if (!eventController.isClosed) {
        eventController.add(event);
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!eventController.isClosed) {
        eventController.addError(error, stackTrace);
      }
    },
  );
  final uploadEvents = <RsServerEvent_FileUpload>[];
  final uploadSubscription = eventController.stream
      .where((event) => event is RsServerEvent_FileUpload)
      .cast<RsServerEvent_FileUpload>()
      .listen(uploadEvents.add);
  return _TestServer(
    server: server,
    port: port,
    client: HttpClient(),
    events: StreamIterator(eventController.stream),
    eventController: eventController,
    eventSubscription: eventSubscription,
    uploadSubscription: uploadSubscription,
    uploadEvents: uploadEvents,
    destination: destination,
  );
}

Future<int> _reservePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<RsServerEvent_PrepareUpload> _nextPrepareUpload(StreamIterator<RsServerEvent> events) async {
  while (await events.moveNext().timeout(const Duration(seconds: 10))) {
    final event = events.current;
    if (event is RsServerEvent_PrepareUpload) {
      return event;
    }
  }
  throw StateError('The server event stream closed before prepare-upload');
}

Future<RsServerEvent_FileUpload> _nextFileUpload(StreamIterator<RsServerEvent> events, String sessionId) async {
  while (await events.moveNext().timeout(const Duration(seconds: 10))) {
    final event = events.current;
    if (event is RsServerEvent_FileUpload && event.sessionId == sessionId) {
      return event;
    }
  }
  throw StateError('The server event stream closed before file-upload');
}

Future<_HttpResponse> _prepareUpload(HttpClient client, int port, List<_OfferedFile> files) async {
  final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/localsend/v2/prepare-upload'));
  request.headers.contentType = ContentType.json;
  request.write(
    jsonEncode({
      'info': {
        'alias': 'Sender',
        'version': '2.2',
        'fingerprint': 'SENDER-FINGERPRINT',
        'port': 1,
        'protocol': 'http',
        'download': false,
      },
      'files': {
        for (final file in files)
          file.id: {
            'id': file.id,
            'fileName': file.fileName,
            'size': file.bytes.length,
            'fileType': 'application/octet-stream',
            'sha256': file.checksum,
          },
      },
    }),
  );
  final response = await request.close().timeout(const Duration(seconds: 10));
  return _HttpResponse(response.statusCode, await utf8.decodeStream(response));
}

Future<_HttpResponse> _upload(
  HttpClient client,
  int port, {
  required String sessionId,
  required String fileId,
  required String token,
  required List<int> bytes,
}) async {
  final request = await client.postUrl(
    Uri.parse('http://127.0.0.1:$port/api/localsend/v2/upload?sessionId=$sessionId&fileId=$fileId&token=$token'),
  );
  request.headers.contentLength = bytes.length;
  request.add(bytes);
  final response = await request.close().timeout(const Duration(seconds: 10));
  return _HttpResponse(response.statusCode, await utf8.decodeStream(response));
}

Future<_HttpResponse> _cancelPendingUpload(HttpClient client, int port) async {
  final request = await client.postUrl(Uri.parse('http://127.0.0.1:$port/api/localsend/v2/cancel'));
  final response = await request.close().timeout(const Duration(seconds: 10));
  return _HttpResponse(response.statusCode, await utf8.decodeStream(response));
}

Map<String, String> _tokens(String body) {
  final response = jsonDecode(body) as Map<String, dynamic>;
  return (response['files'] as Map<String, dynamic>).cast<String, String>();
}

Future<Set<String>> _findDuplicates(RsServerEvent_PrepareUpload event, String destination) {
  return findDuplicateFileIds(
    incomingFiles: event.files.values.map((file) => file.toDart()),
    destinationDirectory: destination,
    calculateHash: _calculateHash,
  );
}

Future<String> _calculateHash(String path) async {
  final hash = await file_hash
      .calculateFileHash(
        path: path,
        bytes: null,
        cancelToken: rust_cancel.createCancellationToken(),
      )
      .timeout(const Duration(seconds: 10));
  return hash;
}

Future<void> _respondToUpload(_TestServer testServer, RsServerEvent_FileUpload event) async {
  final path = '${testServer.destination.path}/${event.fileId}';
  await for (final _
      in testServer.server
          .respondFileUpload(
            sessionId: event.sessionId,
            fileId: event.fileId,
            path: path,
            fileDescriptor: null,
            fileSize: event.file.size,
          )
          .timeout(const Duration(seconds: 10))) {}
}

class _OfferedFile {
  final String id;
  final String fileName;
  final List<int> bytes;

  _OfferedFile({required this.id, required this.fileName, required this.bytes});

  String get checksum => sha256.convert(bytes).toString();
}

class _HttpResponse {
  final int statusCode;
  final String body;

  const _HttpResponse(this.statusCode, this.body);
}

class _TestServer {
  final RsHttpServer server;
  final int port;
  final HttpClient client;
  final StreamIterator<RsServerEvent> events;
  final StreamController<RsServerEvent> eventController;
  final StreamSubscription<RsServerEvent> eventSubscription;
  final StreamSubscription<RsServerEvent_FileUpload> uploadSubscription;
  final List<RsServerEvent_FileUpload> uploadEvents;
  final Directory destination;

  const _TestServer({
    required this.server,
    required this.port,
    required this.client,
    required this.events,
    required this.eventController,
    required this.eventSubscription,
    required this.uploadSubscription,
    required this.uploadEvents,
    required this.destination,
  });

  Future<void> close() async {
    client.close(force: true);
    await server.stop().timeout(const Duration(seconds: 10));
    unawaited(events.cancel());
    unawaited(uploadSubscription.cancel());
    unawaited(eventSubscription.cancel());
    await destination.delete(recursive: true);
  }
}
