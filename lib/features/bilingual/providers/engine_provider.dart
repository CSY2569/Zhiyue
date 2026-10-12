import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// Translation-engine (RetainPDF pipeline) state for the settings card: the
/// on-disk status. The engine ships inside the installation bundle; the
/// install/uninstall methods are kept for the FFI surface but are refused by
/// the Rust side (v1 has no in-app installer).
class EngineController extends AsyncNotifier<EngineStatus> {
  @override
  Future<EngineStatus> build() =>
      ref.read(translationRepositoryProvider).getEngineStatus();

  /// Re-reads the status from disk.
  Future<void> refresh() async {
    state = AsyncData(await ref.read(translationRepositoryProvider).getEngineStatus());
  }

  /// Downloads and installs the engine, reflecting progress in [state].
  /// The install fails as a final event carrying `error`.
  Future<void> install() async {
    final repo = ref.read(translationRepositoryProvider);
    state = const AsyncData(EngineStatus(
      kind: EngineStatusKind.installing,
      phase: '准备',
      progress: 0,
      version: '',
      sizeBytes: 0,
      error: null,
      bundled: false,
    ));
    try {
      await for (final ev in repo.installEngine()) {
        if (ev.error != null) {
          state = AsyncData(EngineStatus(
            kind: EngineStatusKind.failed,
            phase: ev.phase,
            progress: 0,
            version: '',
            sizeBytes: 0,
            error: ev.error,
            bundled: false,
          ));
          return;
        }
        state = AsyncData(EngineStatus(
          kind: ev.finished
              ? EngineStatusKind.installed
              : EngineStatusKind.installing,
          phase: ev.phase,
          progress: ev.progress,
          version: '',
          sizeBytes: 0,
          error: null,
          bundled: false,
        ));
      }
    } catch (e) {
      state = AsyncData(EngineStatus(
        kind: EngineStatusKind.failed,
        phase: '',
        progress: 0,
        version: '',
        sizeBytes: 0,
        error: e.toString(),
        bundled: false,
      ));
      return;
    }
    // Settle on the disk truth (versions / size come from the manifest).
    await refresh();
  }

  Future<void> cancel() =>
      ref.read(translationRepositoryProvider).cancelEngineInstall();

  Future<void> uninstall() async {
    await ref.read(translationRepositoryProvider).uninstallEngine();
    await refresh();
  }
}

final engineStatusProvider =
    AsyncNotifierProvider<EngineController, EngineStatus>(EngineController.new);