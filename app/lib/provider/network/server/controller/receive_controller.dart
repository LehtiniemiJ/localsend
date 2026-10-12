import 'dart:async';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/model/state/server/receive_session_state.dart';
import 'package:localsend_app/model/state/server/receiving_file.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/progress_page.dart';
import 'package:localsend_app/pages/receive_page.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/file_transfer_provider.dart';
import 'package:localsend_app/provider/http_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/security_provider.dart';
import 'package:localsend_app/provider/selection/selected_receiving_files_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/duplicate_file_helper.dart';
import 'package:localsend_app/util/native/directories.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/widget/dialogs/duplicate_check_dialog.dart';
import 'package:localsend_app/widget/dialogs/open_file_dialog.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_status.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:localsend_isolates/model/session_status.dart';
import 'package:localsend_isolates/rust/api/cancel.dart' as rust_cancel;
import 'package:localsend_isolates/rust/api/server.dart' show SessionEndReasonV2;
import 'package:localsend_isolates/util/file_hash.dart' as file_hash;
import 'package:localsend_isolates/util/rust.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:logging/logging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:uuid/uuid.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('ReceiveController');

/// Handles all server events for receiving files.
/// The HTTP requests themselves are served by the Rust server which emits
/// the events handled here.
class ReceiveController {
  final ServerUtils server;

  ReceiveController(this.server);

  String? _pendingSessionId;
  int _scanGeneration = 0;
  rust_cancel.RsCancellationToken? _scanCancelToken;
  Future<void>? _duplicateScan;
  String? _displayedSessionId;
  DialogRoute<void>? _duplicateCheckRoute;

  /// Invalidates pending work before closing or restarting the server.
  void invalidatePendingRequest() {
    final route = _duplicateCheckRoute;
    _duplicateCheckRoute = null;
    if (route?.isActive == true) {
      route!.navigator?.removeRoute(route);
    }
    _pendingSessionId = null;
    _scanGeneration++;
    _scanCancelToken?.cancel();
    _scanCancelToken = null;
    _duplicateScan = null;
    _displayedSessionId = null;
  }

  /// A device registered itself on this server.
  Future<void> onRegister(HttpServerRegisterEvent event) async {
    if (event.info.fingerprint == server.ref.read(securityProvider).certificateHash) {
      // "I talked to myself lol"
      return;
    }

    // Feed the device into the discovery store; it comes back (and is
    // registered) via the [StartDiscoveryListener] stream.
    server.ref.redux(parentIsolateProvider).dispatch(IsolateDiscoveryAddDeviceAction(device: event.info.toDevice(event.ip, withChannel: true)));
    server.ref.notifier(discoveryLoggerProvider).addLog('[DISCOVER/TCP] Received "/register" HTTP request: ${event.info.alias} (${event.ip})');
  }

  /// A sender requests to upload files.
  /// The Rust server already checked the PIN and enforces that only one
  /// session can be active at a time.
  Future<void> onPrepareUpload(HttpServerPrepareUploadEvent event) async {
    if (server.getStateOrNull()?.session != null) {
      // The Rust server is the authority on the single-session invariant:
      // a new request means the old session is over (e.g. finished but still
      // displayed, or aborted while waiting).
      closeSession();
    }

    _pendingSessionId = event.sessionId;
    final preparationGeneration = ++_scanGeneration;
    final settings = server.ref.read(settingsProvider);
    final destinationDir = settings.destination ?? await getDefaultDestinationDirectory();
    final cacheDir = await getCacheDirectory();
    final sessionId = event.sessionId;
    final files = {
      for (final entry in event.files.entries) entry.key: entry.value.toDart(),
    };
    final saveToGallery = checkPlatformWithGallery() && settings.saveToGallery && files.values.every((f) => !f.fileName.contains('/'));
    if (_pendingSessionId != sessionId || _scanGeneration != preparationGeneration || server.getStateOrNull() == null) {
      return;
    }

    // The fingerprint of the sender's mTLS certificate cannot be spoofed, unlike the
    // self-reported fingerprint in the JSON payload which is only used as fallback
    // when encryption is disabled.
    final senderFingerprint = event.certFingerprint ?? event.info.fingerprint;

    _logger.info('Session Id: $sessionId');
    _logger.info('Destination Directory: $destinationDir');

    server.setState(
      (oldState) => oldState?.copyWith(
        session: ReceiveSessionState(
          sessionId: sessionId,
          status: SessionStatus.waiting,
          sender: event.info.toDevice(event.ip, withChannel: false).copyWith(fingerprint: senderFingerprint),
          senderAlias: server.ref.read(favoritesProvider).firstWhereOrNull((e) => e.fingerprint == senderFingerprint)?.alias ?? event.info.alias,
          files: {
            for (final file in files.values)
              file.id: ReceivingFile(
                file: file,
                token: null,
                desiredName: null,
                path: null,
                savedToGallery: false,
                errorMessage: null,
              ),
          },
          startTime: null,
          endTime: null,
          destinationDirectory: destinationDir,
          cacheDirectory: cacheDir,
          saveToGallery: saveToGallery,
          createdDirectories: {},
        ),
      ),
    );

    server.ref.notifier(selectedReceivingFilesProvider).setFiles(files.values.toList());
    await _startDuplicateScan(sessionId);
    final preparedSession = server.getStateOrNull()?.session;
    if (_pendingSessionId != sessionId || preparedSession?.sessionId != sessionId || preparedSession?.status != SessionStatus.waiting) {
      return;
    }
    final duplicateFileIds = preparedSession!.duplicateFileIds;

    bool quickSave = settings.quickSave && server.getState().session?.message == null;
    final quickSaveFromFavorites = settings.quickSaveFromFavorites && server.getState().session?.message == null;
    if (quickSaveFromFavorites) {
      final bool isFavorite = server.ref.read(favoritesProvider).any((e) => e.fingerprint == senderFingerprint);
      if (isFavorite) {
        quickSave = true;
      }
    }
    if (server.getState().webUpload && settings.receiveViaLinkAutoAccept && server.getState().session?.message == null) {
      // The upload page (receive via link) is being served and requests should be accepted automatically.
      quickSave = true;
    }

    if (quickSave) {
      // Push before accepting: the permission request in [acceptFileRequest] may block for a while.
      // ignore: use_build_context_synchronously, unawaited_futures
      Routerino.context.pushImmediately(
        () => ProgressPage(
          showAppBar: false,
          closeSessionOnClose: true,
          sessionId: sessionId,
        ),
      );

      // accept all files
      await acceptFileRequest({
        for (final f in files.values)
          if (!duplicateFileIds.contains(f.id)) f.id: f.fileName,
      });
      return;
    }

    if (checkPlatformHasTray() && (await windowManager.isMinimized() || !(await windowManager.isVisible()) || !(await windowManager.isFocused()))) {
      await showFromTray();
    }

    if (_pendingSessionId != sessionId || server.getStateOrNull()?.session?.sessionId != sessionId) {
      return;
    }
    final message = server.getState().session?.message;
    if (message != null) {
      // Message already received
      await server.ref
          .redux(receiveHistoryProvider)
          .dispatchAsync(
            AddHistoryEntryAction(
              entryId: const Uuid().v4(),
              fileName: message,
              fileType: FileType.text,
              path: null,
              savedToGallery: false,
              isMessage: true,
              fileSize: utf8.encode(message).length,
              senderAlias: server.getState().session!.senderAlias,
              timestamp: DateTime.now().toUtc(),
            ),
          );
    }

    if (_pendingSessionId != sessionId || server.getStateOrNull()?.session?.sessionId != sessionId) {
      return;
    }

    final receiveProvider = ViewProvider((ref) {
      // No select: comparing the selected session runs the dart_mappable deep equality
      // over the whole files map on every state change.
      final currentSession = ref.watch(serverProvider)?.session;
      final session = currentSession?.sessionId == event.sessionId ? currentSession : null;
      return ReceivePageVm(
        status: session?.status,
        sender: session?.sender ?? Device.empty,
        showSenderInfo: true,
        files: session?.files.values.map((f) => f.file).toList() ?? [],
        duplicateFileIds: session?.duplicateFileIds ?? {},
        message: message,
        onAccept: () async {
          if (ref.read(serverProvider)?.session?.sessionId != event.sessionId) {
            return;
          }
          if (message != null) {
            // accept nothing
            await ref.notifier(serverProvider).acceptFileRequest({});
            return;
          }

          final sessionId = ref.read(serverProvider)?.session?.sessionId;
          if (sessionId == null || sessionId != event.sessionId) {
            return;
          }

          final selectedFiles = ref.read(selectedReceivingFilesProvider);

          // Push before accepting: the permission request in [acceptFileRequest] may block for a while.
          unawaited(
            Routerino.context.pushAndRemoveUntilImmediately(
              removeUntil: ReceivePage,
              builder: () => ProgressPage(
                showAppBar: false,
                closeSessionOnClose: true,
                sessionId: sessionId,
              ),
            ),
          );

          await ref.notifier(serverProvider).acceptFileRequest(selectedFiles);
        },
        onDecline: () {
          if (ref.read(serverProvider)?.session?.sessionId == event.sessionId) {
            ref.notifier(serverProvider).declineFileRequest();
          }
        },
        onClose: () {
          if (ref.read(serverProvider)?.session?.sessionId == event.sessionId) {
            ref.notifier(serverProvider).closeSession();
          }
        },
      );
    });

    _displayedSessionId = sessionId;
    // ignore: use_build_context_synchronously, unawaited_futures
    Routerino.context.push(() => ReceivePage(receiveProvider));
  }

  /// An accepted file started being uploaded.
  /// The server isolate receives and saves the file on its own
  /// ([HttpServerReceiveConfig] was sent with the accept decision);
  /// only the session state is updated here.
  void onFileUpload(HttpServerFileUploadEvent event) {
    final receiveState = server.getStateOrNull()?.session;
    const allowedStates = {SessionStatus.sending, SessionStatus.finishedWithErrors};
    if (receiveState == null || receiveState.sessionId != event.sessionId || !allowedStates.contains(receiveState.status)) {
      _logger.warning('Failing upload of file ${event.fileId}: no matching active session');
      // Fail the upload (and any further ones) by cancelling the session on the Rust side.
      server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerCancelSessionAction(sessionId: event.sessionId));
      return;
    }

    final fileId = event.fileId;
    final receivingFile = receiveState.files[fileId];
    if (receivingFile == null || receivingFile.desiredName == null) {
      _logger.warning('Unexpected fileId: $fileId');
      server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerCancelSessionAction(sessionId: event.sessionId));
      return;
    }

    // begin of actual file transfer
    server.ref.notifier(fileTransferProvider).setStatus(sessionId: event.sessionId, fileId: fileId, status: FileStatus.sending);
    if (receiveState.startTime == null || receiveState.status != SessionStatus.sending) {
      server.setState(
        (oldState) => oldState?.copyWith(
          session: receiveState.copyWith(
            startTime: receiveState.startTime ?? DateTime.now().millisecondsSinceEpoch,
            status: SessionStatus.sending, // in case it was finishedWithErrors and user retries a failed file
          ),
        ),
      );
    }
  }

  /// The receive progress of a file reported by the server isolate.
  void onFileUploadProgress(HttpServerFileUploadProgressEvent event) {
    final receiveState = server.getStateOrNull()?.session;
    if (receiveState == null || receiveState.sessionId != event.sessionId) {
      return;
    }

    server.ref
        .notifier(fileTransferProvider)
        .setProgress(
          sessionId: event.sessionId,
          fileId: event.fileId,
          progress: event.progress,
        );

    _updateForegroundServiceProgress(receiveState);
  }

  /// Reports the total session progress to the foreground service notification,
  /// so that it stays up to date while the app is minimized.
  void _updateForegroundServiceProgress(ReceiveSessionState session) {
    if (!TransferNotification.shouldUpdate) {
      // Checked before the sum below because progress events arrive several times per second per file.
      return;
    }

    final transferNotifier = server.ref.read(fileTransferProvider);
    int currentBytes = 0;
    int totalBytes = 0;
    for (final receivingFile in session.files.values) {
      if (receivingFile.desiredName == null) {
        // not accepted by the user
        continue;
      }
      final size = receivingFile.file.size;
      totalBytes += size;
      currentBytes += (transferNotifier.getProgress(sessionId: session.sessionId, fileId: receivingFile.file.id) * size).round();
    }

    TransferNotification.update(
      sessionId: session.sessionId,
      currentBytes: currentBytes,
      totalBytes: totalBytes,
      startTime: session.startTime,
      endTime: session.endTime,
    );
  }

  /// A file has been received completely (or failed) by the server isolate.
  Future<void> onFileUploadResult(HttpServerFileUploadResultEvent event) async {
    final receiveState = server.getStateOrNull()?.session;
    const allowedStates = {SessionStatus.sending, SessionStatus.finishedWithErrors};
    if (receiveState == null || receiveState.sessionId != event.sessionId || !allowedStates.contains(receiveState.status)) {
      return;
    }

    final fileId = event.fileId;
    final receivingFile = receiveState.files[fileId];
    if (receivingFile == null || receivingFile.desiredName == null) {
      _logger.warning('Unexpected fileId: $fileId');
      return;
    }

    final fileType = receivingFile.file.fileType;
    final filePath = event.path;
    final error = event.error;

    if (error == null) {
      server.ref.notifier(fileTransferProvider).setStatus(sessionId: event.sessionId, fileId: fileId, status: FileStatus.finished);
      server.setState(
        (oldState) => oldState?.copyWith(
          session: oldState.session?.fileFinished(
            fileId: fileId,
            path: filePath,
            savedToGallery: event.savedToGallery,
            errorMessage: null,
          ),
        ),
      );

      // Track it in history
      await server.ref
          .redux(receiveHistoryProvider)
          .dispatchAsync(
            AddHistoryEntryAction(
              entryId: fileId,
              fileName: receivingFile.desiredName!,
              fileType: fileType,
              path: filePath,
              savedToGallery: event.savedToGallery,
              isMessage: false,
              fileSize: receivingFile.file.size,
              senderAlias: receiveState.senderAlias,
              timestamp: DateTime.now().toUtc(),
            ),
          );
    } else {
      server.ref.notifier(fileTransferProvider).setStatus(sessionId: event.sessionId, fileId: fileId, status: FileStatus.failed);
      server.setState(
        (oldState) => oldState?.copyWith(
          session: oldState.session?.fileFinished(
            fileId: fileId,
            path: null,
            savedToGallery: false,
            errorMessage: error,
          ),
        ),
      );
    }

    server.ref
        .notifier(fileTransferProvider)
        .setProgress(
          sessionId: receiveState.sessionId,
          fileId: fileId,
          progress: 1,
        );

    final session = server.getStateOrNull()?.session;
    if (session == null) {
      return;
    }

    _updateForegroundServiceProgress(session);

    final statuses = server.ref.read(fileTransferProvider).getStatuses(session.sessionId);
    if (allowedStates.contains(session.status) && statuses.isFinishedOrError) {
      // The transfer is over, the process no longer needs to be kept alive for it.
      TransferNotification.stop(session.sessionId);

      final hasError = statuses.any((status) => status == FileStatus.failed);
      server.setState(
        (oldState) => oldState?.copyWith(
          session: oldState.session!.copyWith(
            status: hasError ? SessionStatus.finishedWithErrors : SessionStatus.finished,
            endTime: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      );
      final settings = server.ref.read(settingsProvider);
      // Only auto-close fully successful sessions: a failed file may still be
      // retried by the sender (e.g. after a checksum mismatch), which requires
      // the session to stay open.
      bool quickSave = settings.quickSave && !hasError && server.getState().session?.message == null;
      final quickSaveFromFavorites = settings.quickSaveFromFavorites && !hasError && server.getState().session?.message == null;
      if (quickSaveFromFavorites) {
        final bool isFavorite = server.ref.read(favoritesProvider).any((e) => e.fingerprint == session.sender.fingerprint);
        if (isFavorite) {
          quickSave = true;
        }
      }
      if (quickSave) {
        // close the session **after** the response has been sent
        Future.delayed(Duration.zero, () {
          closeSession();
          _logger.info('Closing session');

          // ignore: use_build_context_synchronously, discarded_futures
          Routerino.context.pushRootImmediately(() => const HomePage(initialTab: HomeTab.receive, appStart: false));

          // open the dialog to open file instantly
          if (filePath != null && filePath.isNotEmpty) {
            // ignore: discarded_futures
            OpenFileDialog.open(
              Routerino.context, // ignore: use_build_context_synchronously
              filePath: filePath,
              fileType: fileType,
              openGallery: event.savedToGallery,
            );
          }
        });
      }
      _logger.info('Received all files.');
    }
  }

  /// An upload session ended on the Rust server.
  void onSessionEnd(HttpServerSessionEndEvent event) {
    if (_pendingSessionId == event.sessionId) {
      invalidatePendingRequest();
    }
    final receiveSession = server.getStateOrNull()?.session;
    if (receiveSession == null || receiveSession.sessionId != event.sessionId) {
      return;
    }

    switch (event.reason) {
      case SessionEndReasonV2.finished:
        // Already handled when the last file finished.
        break;
      case SessionEndReasonV2.cancelled:
        _cancelBySender(server);
    }
  }

  /// The sender aborted the request while the user was still deciding.
  void onPrepareUploadAborted(HttpServerPrepareUploadAbortedEvent event) {
    final wasDisplayed = _displayedSessionId == event.sessionId;
    if (_pendingSessionId == event.sessionId) {
      invalidatePendingRequest();
    }
    final receiveSession = server.getStateOrNull()?.session;
    if (receiveSession == null || receiveSession.sessionId != event.sessionId || receiveSession.status != SessionStatus.waiting) {
      return;
    }

    if (!wasDisplayed) {
      closeSession();
      return;
    }

    _cancelBySender(server);
  }

  /// A remote device cancels a transfer this application is currently
  /// *sending* to it.
  void onCancelReceived(HttpServerCancelReceivedEvent event) {
    final sendSessions = server.ref.read(sendProvider);
    final selectedSession = sendSessions.values.firstWhereOrNull((s) => s.remoteSessionId == event.sessionId);
    if (selectedSession == null) {
      return;
    }

    if (selectedSession.target.ip != event.ip) {
      return;
    }

    if (selectedSession.status != SessionStatus.sending) {
      return;
    }

    server.ref
        .notifier(sendProvider)
        .cancelSessionByReceiver(
          selectedSession.sessionId,
        );
  }

  /// Another application instance requested the running application to show itself.
  /// The show token has already been checked by the Rust server.
  void onShow(HttpServerShowEvent event) {
    if (!checkPlatformIsDesktop()) {
      return;
    }

    // ignore: discarded_futures
    showFromTray().catchError((e) {
      // don't wait for it
      _logger.severe('Failed to show from tray', e);
    });

    final args = event.args;
    if (args.isEmpty) {
      return;
    }

    // ignore: unawaited_futures, discarded_futures
    server.ref.redux(selectedSendingFilesProvider).dispatchAsyncTakeResult(LoadSelectionFromArgsAction(args)).then((filesAdded) {
      if (filesAdded) {
        server.ref.redux(homePageControllerProvider).dispatch(ChangeTabAction(HomeTab.send));
      }
    });
  }

  /// Accepts the file request with the given [fileNameMap] (file id -> desired file name).
  Future<void> acceptFileRequest(Map<String, String> fileNameMap) async {
    final expectedSessionId = server.getStateOrNull()?.session?.sessionId;
    if (expectedSessionId == null) {
      return;
    }
    var selection = Map.of(fileNameMap);
    while (_duplicateScan != null) {
      await _duplicateScan!;
      // A destination change may have started another scan while awaiting.
      selection = Map.of(server.ref.read(selectedReceivingFilesProvider));
    }
    fileNameMap = selection;
    final session = server.getStateOrNull()?.session;
    if (session == null || session.sessionId != expectedSessionId || session.status != SessionStatus.waiting) {
      return;
    }

    if (fileNameMap.isEmpty) {
      // nothing selected, the Rust server responds with 204 and creates no session
      // This usually happens for message transfers
      server.ref
          .redux(parentIsolateProvider)
          .dispatch(IsolateHttpServerPrepareUploadDecisionAction(sessionId: session.sessionId, config: _buildReceiveConfig(session, {})));
      closeSession();
      return;
    }

    server.setState(
      (oldState) {
        final receiveState = oldState!.session!;
        return oldState.copyWith(
          session: receiveState.copyWith(
            status: SessionStatus.sending,
            files: Map.fromEntries(
              receiveState.files.values.map((entry) {
                final desiredName = fileNameMap[entry.file.id];
                return MapEntry(
                  entry.file.id,
                  ReceivingFile(
                    file: entry.file,
                    token: null,
                    desiredName: desiredName,
                    path: null,
                    savedToGallery: false,
                    errorMessage: null,
                  ),
                );
              }),
            ),
          ),
        );
      },
    );

    server.ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: session.sessionId,
          statuses: {
            for (final file in session.files.values) file.file.id: fileNameMap.containsKey(file.file.id) ? FileStatus.queue : FileStatus.skipped,
          },
        );

    // The storage permission only exists below Android 13 (scoped storage): newer versions
    // auto-deny the request, but the round trip through the system permission activity
    // still blocks the UI noticeably.
    final androidSdkInt = server.ref.read(deviceInfoProvider).androidSdkInt;
    if (checkPlatform([TargetPlatform.android]) && androidSdkInt != null && androidSdkInt < 33) {
      try {
        final result = await Permission.storage.request();
        _logger.info('storage permission: $result');
      } catch (e) {
        _logger.warning('Could not request storage permission', e);
      }
    }

    // Keep the process alive for the whole transfer. Started here because:
    // - the app is still in the foreground, and Android 12+ rejects starting a foreground service
    //   from the background,
    // - the service may ask for the notification permission, which Android cancels when it overlaps
    //   with the storage permission requests above.
    // From here on, the server isolate receives all accepted files on its own
    // and reports back via upload progress/result events.
    final updatedSession = server.getStateOrNull()?.session;
    if (updatedSession == null || updatedSession.sessionId != session.sessionId || updatedSession.status != SessionStatus.sending) {
      return;
    }
    TransferNotification.start(sessionId: session.sessionId, receiving: true);
    server.ref
        .redux(parentIsolateProvider)
        .dispatch(
          IsolateHttpServerPrepareUploadDecisionAction(sessionId: session.sessionId, config: _buildReceiveConfig(updatedSession, fileNameMap)),
        );
  }

  Future<void> _startDuplicateScan(String sessionId) {
    _scanCancelToken?.cancel();
    _scanCancelToken = null;
    final generation = ++_scanGeneration;
    late final Future<void> scan;
    scan = _refreshDuplicates(sessionId, generation).whenComplete(() {
      if (identical(_duplicateScan, scan)) {
        _duplicateScan = null;
      }
    });
    _duplicateScan = scan;
    return scan;
  }

  Future<void> _refreshDuplicates(String sessionId, int generation) async {
    final session = server.getStateOrNull()?.session;
    if (session == null || session.sessionId != sessionId || session.status != SessionStatus.waiting) {
      return;
    }
    bool cancelled() =>
        _scanGeneration != generation ||
        _pendingSessionId != sessionId ||
        server.getStateOrNull()?.session?.sessionId != sessionId ||
        server.getStateOrNull()?.session?.status != SessionStatus.waiting;
    var duplicates = <String>{};
    if (server.ref.read(settingsProvider).skipDuplicateFiles && !session.saveToGallery) {
      final token = rust_cancel.createCancellationToken();
      _scanCancelToken = token;
      final checkedFiles = ValueNotifier<int>(0);
      final context = Routerino.context;
      final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DuplicateCheckDialog(senderAlias: session.senderAlias, checkedFiles: checkedFiles, onCancel: cancelSession),
      );
      final oldRoute = _duplicateCheckRoute;
      if (oldRoute?.isActive == true) {
        oldRoute!.navigator?.removeRoute(oldRoute);
      }
      _duplicateCheckRoute = route;
      unawaited(Navigator.of(context, rootNavigator: true).push(route));
      if (checkPlatformHasTray()) {
        unawaited(showFromTray().catchError((Object error) => _logger.warning('Could not show duplicate check: $error')));
      }
      try {
        duplicates = await findDuplicateFileIds(
          incomingFiles: session.files.values.map((file) => file.file),
          destinationDirectory: session.destinationDirectory,
          calculateHash: (path) async {
            final hash = await file_hash.calculateFileHash(path: path, bytes: null, cancelToken: token);
            if (!cancelled()) {
              checkedFiles.value++;
            }
            return hash;
          },
          isCancelled: cancelled,
        );
      } finally {
        if (identical(_duplicateCheckRoute, route)) {
          _duplicateCheckRoute = null;
        }
        if (route.isActive) {
          route.navigator?.removeRoute(route);
        }
        checkedFiles.dispose();
        if (identical(_scanCancelToken, token)) {
          _scanCancelToken = null;
        }
      }
    }
    if (cancelled()) {
      return;
    }
    final current = server.getStateOrNull()!.session!;
    final selected = Map.of(server.ref.read(selectedReceivingFilesProvider));
    for (final file in current.files.values) {
      final id = file.file.id;
      if (duplicates.contains(id) && !current.duplicateFileIds.contains(id)) {
        selected.remove(id);
      } else if (!duplicates.contains(id) && current.duplicateFileIds.contains(id)) {
        selected.putIfAbsent(id, () => file.file.fileName);
      }
    }
    server.ref.notifier(selectedReceivingFilesProvider).setSelection(selected);
    server.ref
        .notifier(fileTransferProvider)
        .setStatuses(
          sessionId: sessionId,
          statuses: {
            for (final file in current.files.values) file.file.id: selected.containsKey(file.file.id) ? FileStatus.queue : FileStatus.skipped,
          },
        );
    server.setState((oldState) => oldState?.copyWith(session: oldState.session?.copyWith(duplicateFileIds: duplicates)));
    _logger.info('Found ${duplicates.length} duplicate file(s) before upload');
  }

  HttpServerReceiveConfig _buildReceiveConfig(ReceiveSessionState session, Map<String, String> fileNameMap) {
    return HttpServerReceiveConfig(
      sessionId: session.sessionId,
      fileNameMap: fileNameMap,
      destinationDirectory: session.destinationDirectory,
      cacheDirectory: session.cacheDirectory,
      saveToGallery: session.saveToGallery,
      androidSdkInt: server.ref.read(deviceInfoProvider).androidSdkInt,
    );
  }

  void declineFileRequest() {
    final session = server.getStateOrNull()?.session;
    if (session == null || session.status != SessionStatus.waiting) {
      return;
    }

    server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerPrepareUploadDecisionAction(sessionId: session.sessionId, config: null));
    closeSession();
  }

  /// Updates the destination directory for the current session.
  void setSessionDestinationDir(String destinationDirectory) {
    if (server.getStateOrNull()?.session?.status != SessionStatus.waiting) {
      return;
    }
    server.setState(
      (oldState) => oldState?.copyWith(
        session: oldState.session?.copyWith(
          destinationDirectory: destinationDirectory.replaceAll('\\', '/'),
        ),
      ),
    );
    final sessionId = server.getStateOrNull()?.session?.sessionId;
    if (sessionId != null) {
      unawaited(_startDuplicateScan(sessionId));
    }
  }

  /// Updates the "saveToGallery" setting for the current session.
  void setSessionSaveToGallery(bool saveToGallery) {
    if (server.getStateOrNull()?.session?.status != SessionStatus.waiting) {
      return;
    }
    server.setState(
      (oldState) => oldState?.copyWith(
        session: oldState.session?.copyWith(
          saveToGallery: saveToGallery,
        ),
      ),
    );
    final sessionId = server.getStateOrNull()?.session?.sessionId;
    if (sessionId != null) {
      unawaited(_startDuplicateScan(sessionId));
    }
  }

  /// In addition to [closeSession], this method also
  /// - cancels the session on the Rust server so that further uploads fail
  /// - notifies the sender that the session has been canceled
  void cancelSession() async {
    final session = server.getStateOrNull()?.session;
    if (session == null) {
      // the server is not running
      return;
    }

    // fail further uploads
    server.ref.redux(parentIsolateProvider).dispatch(IsolateHttpServerCancelSessionAction(sessionId: session.sessionId));

    // notify sender
    final target = session.sender;
    try {
      server.ref
          .read(httpProvider)
          .pinnedTo(target.fingerprint)
          // ignore: unawaited_futures
          .cancel(
            protocol: target.getProtocolType(),
            ip: target.ip!,
            port: target.port,
            sessionId: session.sessionId,
          );
    } catch (e) {
      _logger.warning('Failed to notify sender', e);
    }

    closeSession();
  }

  void closeSession() {
    invalidatePendingRequest();
    final sessionId = server.getStateOrNull()?.session?.sessionId;
    if (sessionId == null) {
      return;
    }

    TransferNotification.stop(sessionId);

    server.setState(
      (oldState) => oldState?.copyWith(
        session: null,
      ),
    );
    server.ref.notifier(fileTransferProvider).removeSession(sessionId);
  }
}

void _cancelBySender(ServerUtils server) {
  final receiveSession = server.getStateOrNull()?.session;
  if (receiveSession == null) {
    return;
  }

  TransferNotification.stop(receiveSession.sessionId);

  if (receiveSession.status == SessionStatus.waiting) {
    // received cancel during accept/decline
    // pop just in case if user is in [ReceiveOptionsPage]
    Routerino.context.popUntil(ReceivePage);
  }

  server.setState(
    (oldState) => oldState?.copyWith(
      session: oldState.session?.copyWith(
        status: SessionStatus.canceledBySender,
        endTime: DateTime.now().millisecondsSinceEpoch,
      ),
    ),
  );
}

extension on ReceiveSessionState {
  ReceiveSessionState fileFinished({
    required String fileId,
    required String? path,
    required bool savedToGallery,
    required String? errorMessage,
  }) {
    return copyWith(
      files: {...files}
        ..update(
          fileId,
          (file) => file.copyWith(
            path: path,
            savedToGallery: savedToGallery,
            errorMessage: errorMessage,
          ),
        ),
    );
  }
}
