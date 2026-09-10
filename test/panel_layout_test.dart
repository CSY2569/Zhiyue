import 'dart:ui' show Offset, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/features/reader/providers/panel_layout.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart'
    show SidebarType;

/// In-memory settings KV that records writes.
class _FakeSettings extends SettingsRepository {
  _FakeSettings([Map<String, String>? seed]) : _values = {...?seed};
  final Map<String, String> _values;
  final writes = <String, String>{};

  @override
  Future<String?> getSetting(String key) async => _values[key];

  @override
  Future<int> setSetting(String key, String value) async {
    _values[key] = value;
    writes[key] = value;
    return 1;
  }
}

ProviderContainer _container(_FakeSettings settings) {
  final c = ProviderContainer(overrides: [
    settingsRepositoryProvider.overrideWithValue(settings),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('defaults match the previous hardcoded sizes', () {
    final c = _container(_FakeSettings());
    final layout = c.read(panelLayoutProvider);
    expect(layout.thumbnailsWidth, 180);
    expect(layout.outlineWidth, 240);
    expect(layout.annotationsWidth, 240);
    expect(layout.aiPanelWidth, 320);
    expect(layout.cardSize, const Size(440, 360));
    expect(layout.widthFor(SidebarType.outline), 240);
  });

  test('resizeSidebar accumulates and clamps per sidebar', () {
    final c = _container(_FakeSettings());
    final n = c.read(panelLayoutProvider.notifier);
    n.resizeSidebar(SidebarType.outline, 60);
    expect(c.read(panelLayoutProvider).outlineWidth, 300);
    // Other sidebars untouched.
    expect(c.read(panelLayoutProvider).thumbnailsWidth, 180);
    // Clamps at the max / min.
    n.resizeSidebar(SidebarType.outline, 9999);
    expect(c.read(panelLayoutProvider).outlineWidth,
        PanelLayout.maxSidebarWidth);
    n.resizeSidebar(SidebarType.outline, -9999);
    expect(c.read(panelLayoutProvider).outlineWidth,
        PanelLayout.minSidebarWidth);
  });

  test('resizeAiPanel accumulates and clamps', () {
    final c = _container(_FakeSettings());
    final n = c.read(panelLayoutProvider.notifier);
    n.resizeAiPanel(-40);
    expect(c.read(panelLayoutProvider).aiPanelWidth, 280);
    n.resizeAiPanel(9999);
    expect(c.read(panelLayoutProvider).aiPanelWidth,
        PanelLayout.maxAiPanelWidth);
  });

  test('resizeCard changes width and height independently, clamped', () {
    final c = _container(_FakeSettings());
    final n = c.read(panelLayoutProvider.notifier);
    n.resizeCard(const Offset(80, -60));
    expect(c.read(panelLayoutProvider).cardSize, const Size(520, 300));
    n.resizeCard(const Offset(9999, 9999));
    expect(c.read(panelLayoutProvider).cardSize,
        const Size(PanelLayout.maxCardWidth, PanelLayout.maxCardHeight));
  });

  test('commit persists every size to the KV store', () async {
    final settings = _FakeSettings();
    final c = _container(settings);
    final n = c.read(panelLayoutProvider.notifier);
    n.resizeSidebar(SidebarType.thumbnails, 20);
    n.resizeSidebar(SidebarType.outline, 30);
    n.resizeSidebar(SidebarType.annotations, 10);
    n.resizeAiPanel(40);
    n.resizeCard(const Offset(60, 40));
    await n.commit();

    expect(settings.writes['panel_width_thumbnails'], '200.0');
    expect(settings.writes['panel_width_outline'], '270.0');
    expect(settings.writes['panel_width_annotations'], '250.0');
    expect(settings.writes['panel_width_ai'], '360.0');
    expect(settings.writes['card_size'], '500.0x400.0');
  });

  test('hydrates saved sizes from the KV store', () async {
    final settings = _FakeSettings({
      'panel_width_outline': '300.0',
      'panel_width_thumbnails': '220.0',
      'panel_width_annotations': '280.0',
      'panel_width_ai': '400.0',
      'card_size': '600.0x500.0',
    });
    final c = _container(settings);
    // build() kicks off the async hydrate; let it settle.
    c.read(panelLayoutProvider);
    await pumpEventQueue();

    final layout = c.read(panelLayoutProvider);
    expect(layout.outlineWidth, 300);
    expect(layout.thumbnailsWidth, 220);
    expect(layout.annotationsWidth, 280);
    expect(layout.aiPanelWidth, 400);
    expect(layout.cardSize, const Size(600, 500));
  });

  test('hydrate ignores malformed values and clamps out-of-range ones',
      () async {
    final settings = _FakeSettings({
      'panel_width_outline': 'not-a-number',
      'panel_width_ai': '99999', // clamped
      'card_size': 'broken',
    });
    final c = _container(settings);
    c.read(panelLayoutProvider);
    await pumpEventQueue();

    final layout = c.read(panelLayoutProvider);
    expect(layout.outlineWidth, 240, reason: 'malformed keeps default');
    expect(layout.aiPanelWidth, PanelLayout.maxAiPanelWidth);
    expect(layout.cardSize, const Size(440, 360),
        reason: 'broken card size keeps default');
  });
}
