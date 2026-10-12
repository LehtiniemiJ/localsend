import 'dart:io';

import 'package:localsend_isolates/model/dto/file_dto.dart';
import 'package:path/path.dart' as p;

final _hashPattern = RegExp(r'^[a-f0-9]{64}$', caseSensitive: false);
final _hashNamePattern = RegExp(r'^([a-f0-9]{64})(?: \(\d+\))?$', caseSensitive: false);

/// Returns the 64-character identifier in a filename, optionally followed by
/// LocalSend's collision suffix (for example, `IDENTIFIER (2)`).
///
/// The identifier is treated as an opaque filename key. It does not need to be
/// the SHA-256 of the file contents.
String? hashFromDeduplicatedFilename(String filename) {
  return _hashNamePattern.firstMatch(p.basename(filename))?.group(1)?.toLowerCase();
}

/// Finds incoming files whose contents match a same-named file in the
/// destination, including LocalSend collision copies such as `IDENTIFIER (2)`.
///
/// Only incoming files with a valid SHA-256 checksum and a 64-character
/// hexadecimal filename identifier are considered. Existing candidates must
/// have the same normalized identifier and size, then their actual contents
/// are hashed and compared with the incoming checksum. Unrelated filenames are
/// never read. Content URIs cannot be enumerated as ordinary files and are
/// skipped.
///
/// At most [maxConcurrentHashes] filename groups are checked concurrently.
/// Numbered copies within one group are tried sequentially so matching a file
/// avoids hashing its remaining identical copies.
///
/// If [isCancelled] becomes true while scanning or hashing, the scan stops and
/// returns no duplicates so a partial result cannot be applied to the request.
Future<Set<String>> findDuplicateFileIds({
  required Iterable<FileDto> incomingFiles,
  required String destinationDirectory,
  required Future<String> Function(String path) calculateHash,
  bool Function()? isCancelled,
  int maxConcurrentHashes = 4,
}) async {
  if (maxConcurrentHashes < 1) {
    throw ArgumentError.value(maxConcurrentHashes, 'maxConcurrentHashes', 'Must be at least 1');
  }
  bool cancelled() => isCancelled?.call() ?? false;

  if (cancelled() || destinationDirectory.startsWith('content://')) {
    return {};
  }

  final incomingByNameAndSize = <String, Map<int, List<FileDto>>>{};
  for (final file in incomingFiles) {
    if (cancelled()) {
      return {};
    }
    final identifier = hashFromDeduplicatedFilename(file.fileName);
    final checksum = file.hash?.toLowerCase();
    if (identifier == null || checksum == null || !_hashPattern.hasMatch(checksum)) {
      continue;
    }
    incomingByNameAndSize.putIfAbsent(identifier, () => {}).putIfAbsent(file.size, () => []).add(file);
  }
  if (incomingByNameAndSize.isEmpty || cancelled()) {
    return {};
  }

  final candidatesByName = <String, List<File>>{};
  final pendingDirectories = <Directory>[Directory(destinationDirectory)];
  while (pendingDirectories.isNotEmpty) {
    if (cancelled()) {
      return {};
    }
    final directory = pendingDirectories.removeLast();
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (cancelled()) {
          return {};
        }
        if (entity is Directory) {
          pendingDirectories.add(entity);
        } else if (entity is File) {
          final identifier = hashFromDeduplicatedFilename(entity.path);
          if (identifier != null && incomingByNameAndSize.containsKey(identifier)) {
            candidatesByName.putIfAbsent(identifier, () => []).add(entity);
          }
        }
      }
    } on FileSystemException {
      // An inaccessible or concurrently removed subdirectory should not block
      // receiving other files.
    }
  }

  final duplicates = <String>{};
  Future<void> checkCandidates(MapEntry<String, List<File>> entry) async {
    if (cancelled()) {
      return;
    }
    final remainingByChecksum = <int, Set<String>>{};
    for (final sizeEntry in incomingByNameAndSize[entry.key]!.entries) {
      remainingByChecksum[sizeEntry.key] = sizeEntry.value.map((file) => file.hash!.toLowerCase()).toSet();
    }

    for (final candidate in entry.value) {
      if (cancelled()) {
        return;
      }
      try {
        final candidateSize = await candidate.length();
        if (cancelled()) {
          return;
        }
        final expectedChecksums = remainingByChecksum[candidateSize];
        if (expectedChecksums == null || expectedChecksums.isEmpty) {
          continue;
        }

        final actualChecksum = (await calculateHash(candidate.path)).toLowerCase();
        if (cancelled()) {
          return;
        }
        if (!_hashPattern.hasMatch(actualChecksum) || !expectedChecksums.remove(actualChecksum)) {
          continue;
        }

        duplicates.addAll(
          incomingByNameAndSize[entry.key]![candidateSize]!.where((file) => file.hash!.toLowerCase() == actualChecksum).map((file) => file.id),
        );
      } on FileSystemException {
        // A candidate may disappear or become unreadable while scanning.
      } catch (_) {
        // A checksum failure should not prevent receiving the other files.
      }
    }
  }

  // Each worker takes one group synchronously before yielding at a file read.
  // This bounds open files without creating a future for every candidate.
  final groups = candidatesByName.entries.iterator;
  Future<void> worker() async {
    while (!cancelled() && groups.moveNext()) {
      await checkCandidates(groups.current);
    }
  }

  final workerCount = candidatesByName.length < maxConcurrentHashes ? candidatesByName.length : maxConcurrentHashes;
  await Future.wait(List.generate(workerCount, (_) => worker()));

  return cancelled() ? {} : duplicates;
}
