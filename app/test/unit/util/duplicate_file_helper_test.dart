import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/duplicate_file_helper.dart';
import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:localsend_isolates/model/file_type.dart';

void main() {
  group('hashFromDeduplicatedFilename', () {
    test('recognizes opaque 64-character identifiers and collision suffixes', () {
      const identifier = '00100328bed2dabaf97a64e1320da2409153d6ff504a23d61568590a0a52624e';

      expect(hashFromDeduplicatedFilename(identifier), identifier);
      expect(hashFromDeduplicatedFilename('$identifier (2)'), identifier);
      expect(hashFromDeduplicatedFilename('$identifier (12)'), identifier);
      expect(hashFromDeduplicatedFilename('$identifier.txt'), isNull);
      expect(hashFromDeduplicatedFilename('$identifier copy'), isNull);
    });
  });

  group('findDuplicateFileIds', () {
    late Directory tempDirectory;

    setUp(() async {
      tempDirectory = await Directory.systemTemp.createTemp('localsend-duplicates-');
    });

    tearDown(() async {
      await tempDirectory.delete(recursive: true);
    });

    test('checks actual contents and finds the matching numbered copy', () async {
      const identifier = '00100328bed2dabaf97a64e1320da2409153d6ff504a23d61568590a0a52624e';
      final bytes = utf8.encode('Signal attachment bytes');
      final checksum = _checksum(bytes);
      expect(checksum, isNot(identifier));
      final wrongBytes = utf8.encode('Signal attachment byteX');
      expect(wrongBytes.length, bytes.length);

      final nestedDirectory = Directory('${tempDirectory.path}/files/00')..createSync(recursive: true);
      await File('${nestedDirectory.path}/$identifier').writeAsBytes(wrongBytes);
      await File('${nestedDirectory.path}/$identifier (2)').writeAsBytes(bytes);
      await File('${nestedDirectory.path}/unrelated-name').writeAsBytes(bytes);

      final duplicates = await findDuplicateFileIds(
        incomingFiles: [
          _file(id: 'matching-content', fileName: identifier, hash: checksum, size: bytes.length),
          _file(id: 'wrong-checksum', fileName: identifier, hash: 'f' * 64, size: bytes.length),
          _file(id: 'wrong-size', fileName: identifier, hash: checksum, size: bytes.length + 1),
        ],
        destinationDirectory: tempDirectory.path,
        calculateHash: _calculateHash,
      );

      expect(duplicates, {'matching-content'});
    });

    test('independently matches same-name and same-size files by checksum', () async {
      final identifier = 'a' * 64;
      final firstBytes = utf8.encode('first');
      final secondBytes = utf8.encode('other');
      final missingBytes = utf8.encode('third');
      expect(firstBytes.length, secondBytes.length);
      expect(secondBytes.length, missingBytes.length);

      await File('${tempDirectory.path}/$identifier').writeAsBytes(firstBytes);
      await File('${tempDirectory.path}/$identifier (2)').writeAsBytes(secondBytes);

      final duplicates = await findDuplicateFileIds(
        incomingFiles: [
          _file(id: 'first', fileName: identifier, hash: _checksum(firstBytes), size: firstBytes.length),
          _file(id: 'second', fileName: '$identifier (4)', hash: _checksum(secondBytes), size: secondBytes.length),
          _file(id: 'missing', fileName: identifier, hash: _checksum(missingBytes), size: missingBytes.length),
        ],
        destinationDirectory: tempDirectory.path,
        calculateHash: _calculateHash,
      );

      expect(duplicates, {'first', 'second'});
    });

    test('hashes distinct identifiers concurrently up to the requested limit', () async {
      const maxConcurrentHashes = 3;
      final files = <FileDto>[];
      final checksums = <String, String>{};
      for (var i = 0; i < maxConcurrentHashes + 2; i++) {
        final identifier = _identifier(i);
        final path = '${tempDirectory.path}/$identifier';
        final bytes = utf8.encode('file-$i');
        await File(path).writeAsBytes(bytes);
        files.add(
          _file(
            id: 'file-$i',
            fileName: identifier,
            hash: _fakeChecksum(i),
            size: bytes.length,
          ),
        );
        checksums[path] = _fakeChecksum(i);
      }

      final reachedLimit = Completer<void>();
      final releaseHashes = Completer<void>();
      var activeHashes = 0;
      var peakActiveHashes = 0;
      final hashing = findDuplicateFileIds(
        incomingFiles: files,
        destinationDirectory: tempDirectory.path,
        maxConcurrentHashes: maxConcurrentHashes,
        calculateHash: (path) async {
          activeHashes++;
          if (activeHashes > peakActiveHashes) {
            peakActiveHashes = activeHashes;
          }
          if (activeHashes == maxConcurrentHashes && !reachedLimit.isCompleted) {
            reachedLimit.complete();
          }
          await releaseHashes.future;
          activeHashes--;
          return checksums[path]!;
        },
      );

      await reachedLimit.future.timeout(const Duration(seconds: 5));
      expect(activeHashes, maxConcurrentHashes);
      expect(peakActiveHashes, maxConcurrentHashes);
      releaseHashes.complete();

      final duplicates = await hashing.timeout(const Duration(seconds: 5));
      expect(duplicates, files.map((file) => file.id).toSet());
      expect(peakActiveHashes, maxConcurrentHashes);
    });

    test('defaults to hashing four distinct identifiers concurrently', () async {
      const defaultConcurrency = 4;
      final files = <FileDto>[];
      final checksums = <String, String>{};
      for (var i = 0; i < defaultConcurrency + 1; i++) {
        final identifier = _identifier(i + 10);
        final path = '${tempDirectory.path}/$identifier';
        final bytes = utf8.encode('default-$i');
        await File(path).writeAsBytes(bytes);
        files.add(
          _file(
            id: 'default-$i',
            fileName: identifier,
            hash: _fakeChecksum(i + 10),
            size: bytes.length,
          ),
        );
        checksums[path] = _fakeChecksum(i + 10);
      }

      final reachedDefault = Completer<void>();
      final releaseHashes = Completer<void>();
      var activeHashes = 0;
      var peakActiveHashes = 0;
      final hashing = findDuplicateFileIds(
        incomingFiles: files,
        destinationDirectory: tempDirectory.path,
        calculateHash: (path) async {
          activeHashes++;
          if (activeHashes > peakActiveHashes) {
            peakActiveHashes = activeHashes;
          }
          if (activeHashes == defaultConcurrency && !reachedDefault.isCompleted) {
            reachedDefault.complete();
          }
          await releaseHashes.future;
          activeHashes--;
          return checksums[path]!;
        },
      );

      await reachedDefault.future.timeout(const Duration(seconds: 5));
      expect(activeHashes, defaultConcurrency);
      releaseHashes.complete();
      final duplicates = await hashing.timeout(const Duration(seconds: 5));

      expect(duplicates, files.map((file) => file.id).toSet());
      expect(peakActiveHashes, defaultConcurrency);
    });

    test('checks numbered copies sequentially and stops after a matching copy', () async {
      final identifier = _identifier(20);
      final firstBytes = utf8.encode('copy-00');
      final matchingBytes = utf8.encode('copy-01');
      final checksum = _fakeChecksum(21);
      await File('${tempDirectory.path}/$identifier').writeAsBytes(firstBytes);
      await File('${tempDirectory.path}/$identifier (2)').writeAsBytes(matchingBytes);
      await File('${tempDirectory.path}/$identifier (3)').writeAsBytes(matchingBytes);
      final hashedPaths = <String>[];

      final duplicates = await findDuplicateFileIds(
        incomingFiles: [_file(id: 'copy', fileName: identifier, hash: checksum, size: matchingBytes.length)],
        destinationDirectory: tempDirectory.path,
        maxConcurrentHashes: 3,
        calculateHash: (path) async {
          hashedPaths.add(path);
          return hashedPaths.length == 2 ? checksum : _fakeChecksum(22);
        },
      );

      expect(duplicates, {'copy'});
      expect(hashedPaths, hasLength(2));
      expect(hashedPaths.toSet(), hasLength(2));
    });

    test('cancellation stops queued hashes and discards duplicates', () async {
      const maxConcurrentHashes = 2;
      final files = <FileDto>[];
      for (var i = 0; i < maxConcurrentHashes + 2; i++) {
        final identifier = _identifier(i + 30);
        final bytes = utf8.encode('cancel-$i');
        await File('${tempDirectory.path}/$identifier').writeAsBytes(bytes);
        files.add(
          _file(
            id: 'cancel-$i',
            fileName: identifier,
            hash: _fakeChecksum(i + 30),
            size: bytes.length,
          ),
        );
      }

      final twoHashesStarted = Completer<void>();
      final releaseHashes = Completer<void>();
      final startedPaths = <String>[];
      var cancelled = false;
      final hashing = findDuplicateFileIds(
        incomingFiles: files,
        destinationDirectory: tempDirectory.path,
        maxConcurrentHashes: maxConcurrentHashes,
        calculateHash: (path) async {
          startedPaths.add(path);
          if (startedPaths.length == maxConcurrentHashes && !twoHashesStarted.isCompleted) {
            twoHashesStarted.complete();
          }
          await releaseHashes.future;
          return _fakeChecksum(30 + startedPaths.indexOf(path));
        },
        isCancelled: () => cancelled,
      );

      await twoHashesStarted.future.timeout(const Duration(seconds: 5));
      cancelled = true;
      releaseHashes.complete();
      final duplicates = await hashing.timeout(const Duration(seconds: 5));

      expect(startedPaths, hasLength(maxConcurrentHashes));
      expect(duplicates, isEmpty);
    });

    test('a candidate hash error does not prevent other identifiers matching', () async {
      final brokenIdentifier = _identifier(40);
      final goodIdentifier = _identifier(41);
      final bytes = utf8.encode('same-size');
      await File('${tempDirectory.path}/$brokenIdentifier').writeAsBytes(bytes);
      await File('${tempDirectory.path}/$goodIdentifier').writeAsBytes(bytes);

      final duplicates = await findDuplicateFileIds(
        incomingFiles: [
          _file(id: 'broken', fileName: brokenIdentifier, hash: _fakeChecksum(40), size: bytes.length),
          _file(id: 'good', fileName: goodIdentifier, hash: _fakeChecksum(41), size: bytes.length),
        ],
        destinationDirectory: tempDirectory.path,
        maxConcurrentHashes: 2,
        calculateHash: (path) async {
          if (path.endsWith(brokenIdentifier)) {
            throw StateError('injected checksum failure');
          }
          return _fakeChecksum(41);
        },
      );

      expect(duplicates, {'good'});
    });

    test('rejects a concurrency limit below one', () async {
      for (final limit in [0, -1]) {
        await expectLater(
          findDuplicateFileIds(
            incomingFiles: const [],
            destinationDirectory: tempDirectory.path,
            maxConcurrentHashes: limit,
            calculateHash: _calculateHash,
          ),
          throwsArgumentError,
        );
      }
    });

    test('does not read unrelated names or skip files without checksums', () async {
      final identifier = 'b' * 64;
      final bytes = utf8.encode('contents');
      await File('${tempDirectory.path}/unrelated-name').writeAsBytes(bytes);
      await File('${tempDirectory.path}/$identifier').writeAsBytes(bytes);
      final hashedPaths = <String>[];

      final duplicates = await findDuplicateFileIds(
        incomingFiles: [
          _file(id: 'unhashed', fileName: identifier, hash: null, size: bytes.length),
          _file(id: 'unrelated', fileName: 'ordinary-filename', hash: _checksum(bytes), size: bytes.length),
        ],
        destinationDirectory: tempDirectory.path,
        calculateHash: (path) async {
          hashedPaths.add(path);
          return _checksum(bytes);
        },
      );

      expect(duplicates, isEmpty);
      expect(hashedPaths, isEmpty);
    });

    test('returns no duplicates when the destination is missing', () async {
      final identifier = 'c' * 64;
      final bytes = utf8.encode('contents');
      final missingDestination = '${tempDirectory.path}/missing';

      final duplicates = await findDuplicateFileIds(
        incomingFiles: [_file(id: 'file', fileName: identifier, hash: _checksum(bytes), size: bytes.length)],
        destinationDirectory: missingDestination,
        calculateHash: (path) async => throw StateError('There are no destination candidates'),
      );

      expect(duplicates, isEmpty);
    });

    test('discards partial results when cancelled during hashing', () async {
      final identifier = 'd' * 64;
      final bytes = utf8.encode('contents');
      await File('${tempDirectory.path}/$identifier').writeAsBytes(bytes);
      var cancelled = false;

      final duplicates = await findDuplicateFileIds(
        incomingFiles: [_file(id: 'file', fileName: identifier, hash: _checksum(bytes), size: bytes.length)],
        destinationDirectory: tempDirectory.path,
        calculateHash: (path) async {
          cancelled = true;
          return _checksum(bytes);
        },
        isCancelled: () => cancelled,
      );

      expect(duplicates, isEmpty);
    });

    test('skips content URI destinations', () async {
      final duplicates = await findDuplicateFileIds(
        incomingFiles: [_file(id: 'file', fileName: 'e' * 64, hash: 'a' * 64, size: 0)],
        destinationDirectory: 'content://example/tree',
        calculateHash: (path) async => throw StateError('Content URIs are not scanned'),
      );

      expect(duplicates, isEmpty);
    });
  });
}

FileDto _file({
  required String id,
  required String fileName,
  required String? hash,
  required int size,
}) {
  return FileDto(
    id: id,
    fileName: fileName,
    size: size,
    fileType: FileType.other,
    hash: hash,
    preview: null,
    metadata: null,
  );
}

String _checksum(List<int> bytes) => sha256.convert(bytes).toString();

String _identifier(int value) => value.toRadixString(16).padLeft(64, '0');

String _fakeChecksum(int value) => (value + 100).toRadixString(16).padLeft(64, '0');

Future<String> _calculateHash(String path) async {
  return _checksum(await File(path).readAsBytes());
}
