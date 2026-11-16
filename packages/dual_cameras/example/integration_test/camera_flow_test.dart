import 'dart:typed_data';

import 'package:dual_cameras_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';

import 'gallery_probe.dart';

// Issue #79, Track B step 2: the camera-flow instrumentation test.
// Drives the real camera flow end to end — open camera, record ONE
// 30 s take with map + captions ON, stop — and asserts the video EXISTS
// in MediaStore with duration > 0, from inside the test, via the native
// GalleryProbeChannel. Runs and passes on the CI emulator, where the
// front-vs-rear feeds-differ assertion SKIPS (same test pattern on both
// feeds); on a real device (Firebase Test Lab) the same test runs with
// --dart-define=STORYCAM_REAL_DEVICE=true and feeds-differ RUNS.
//
// UI labels (verified against lib/): the shutter carries its label as a
// Semantics label + Tooltip message, not a Text widget — so the shutter
// is found with find.byTooltip, never find.text. The switches are
// SwitchListTiles (find the Switch ancestor of the title Text). The
// Settings sheet closes with the 'Close Camera settings' tooltip button.

// Build-time flag (default false): only a real device gets distinct
// front/rear feeds. CI emulator builds pass no dart-define, so the
// feeds-differ block SKIPS and the test still passes. Test Lab builds
// pass --dart-define=STORYCAM_REAL_DEVICE=true to `flutter build apk`
// AND as base64 -Pdart-defines to `gradlew assembleAndroidTest` (the
// define must reach the test bundle, not just lib/main.dart).
const bool _realDevice = bool.fromEnvironment('STORYCAM_REAL_DEVICE');

// Same fractional boxes + thresholds as tools/preview_diff.py.
const List<double> _frontBoxFrac = <double>[0.52, 0.67, 0.76, 0.79];
const List<double> _rearBoxFrac = <double>[0.55, 0.28, 0.95, 0.45];
const double _minMeanDiff = 5.0;
const double _minMeanBrightness = 8.0;

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('camera flow: 30 s take with map + captions, video in MediaStore',
      (WidgetTester tester) async {
    final int testStartEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final GalleryProbe probe = GalleryProbe();

    await tester.pumpWidget(const DemoApp());
    await tester.pump();

    // 1. Camera init (auto-init, issue #46): wait for 'Start recording'
    // up to 60 s, polling every 1 s. If absent, tap 'Open camera' once
    // (the retry), wait a further 30 s, then fail with a screenshot +
    // the visible status text in the failure message.
    final bool ready = await _waitFor(
      tester,
      find.byTooltip('Start recording'),
      const Duration(seconds: 60),
    );
    if (!ready) {
      if (find.byTooltip('Open camera').evaluate().isNotEmpty) {
        await tester.tap(find.byTooltip('Open camera'));
        await tester.pump();
      }
      final bool retried = await _waitFor(
        tester,
        find.byTooltip('Start recording'),
        const Duration(seconds: 30),
      );
      if (!retried) {
        final String status = tester
            .widgetList<Text>(find.byType(Text))
            .map((Text t) => t.data ?? '')
            .where((String s) => s.isNotEmpty)
            .join(' | ');
        try {
          await binding.convertFlutterSurfaceToImage();
          final List<int> shot =
              await binding.takeScreenshot('camera-flow-init-failed');
          await probe.saveScreenshot('camera-flow-init-failed.png', shot);
        } catch (_) {
          // Best-effort failure evidence only; the fail below is the signal.
        }
        fail('camera did not initialize: no Start recording after 60 s '
            '+ one Open camera retry + 30 s. Visible text: $status');
      }
    }

    // 2. Settings: verify 'Location circle' ON and 'Auto-captions' ON
    // (read the switch state, tap only if OFF), then close the sheet.
    await tester.tap(find.byKey(const Key('menu-settings')));
    await tester.pump();
    expect(
      await _waitFor(
        tester,
        find.text('Location circle'),
        const Duration(seconds: 10),
      ),
      isTrue,
      reason: 'Settings sheet did not open',
    );
    await _ensureSwitchOn(tester, 'Location circle');
    await _ensureSwitchOn(tester, 'Auto-captions');
    await tester.tap(find.byTooltip('Close Camera settings'));
    await tester.pump();
    expect(
      await _waitFor(
        tester,
        find.byTooltip('Start recording'),
        const Duration(seconds: 10),
      ),
      isTrue,
      reason: 'camera screen did not come back after closing Settings',
    );

    // 3. Record. Mid-recording (~15 s) take one dual-preview screenshot
    // via takeScreenshot, after convertFlutterSurfaceToImage() (required
    // on Android before takeScreenshot, or the camera Texture may
    // capture black). The screenshot is saved via the probe channel so
    // it lands at /sdcard/Download/storycam-feeds-diff.png.
    await tester.tap(find.byTooltip('Start recording'));
    await tester.pump();
    final DateTime recordStart = DateTime.now();
    await _waitWithPump(tester, const Duration(seconds: 15));
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    final List<int> screenshotBytes =
        await binding.takeScreenshot('feeds-diff');
    await probe.saveScreenshot('storycam-feeds-diff.png', screenshotBytes);

    // Feeds-differ assertion: real-device-only. On the emulator it
    // prints SKIP and the test still passes.
    if (_realDevice) {
      _expectFeedsDiffer(screenshotBytes);
    } else {
      // ignore: avoid_print
      print('SKIP: feeds-differ is real-device-only');
    }

    // 4. Record 30 s total, then stop. Wait for the 'Last video' tile
    // (<= 30 s) — a secondary UI signal only; the MediaStore poll below
    // is the proof.
    final Duration elapsed = DateTime.now().difference(recordStart);
    if (elapsed < const Duration(seconds: 30)) {
      await _waitWithPump(tester, const Duration(seconds: 30) - elapsed);
    }
    await tester.tap(find.byTooltip('Stop recording'));
    await tester.pump();
    expect(
      await _waitFor(
        tester,
        find.byKey(const Key('last-video-thumbnail')),
        const Duration(seconds: 30),
      ),
      isTrue,
      reason: 'Last video tile did not appear within 30 s after stop',
    );

    // 5. MediaStore assertion via the probe: poll queryLatest() every
    // 1 s for up to 30 s and exit only when durationMs > 0 (a row with
    // durationMs == 0 means the scanner has not filled DURATION yet,
    // not a failure). Then assert row exists, durationMs > 0, size > 0,
    // dateAdded within 900 s of test start. The take-length check
    // (duration >= 28 s, 2 s tolerance on the 30 s recording) is a
    // separate assertion, never the MediaStore assertion.
    Map<String, int>? row;
    final DateTime pollDeadline =
        DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(pollDeadline)) {
      row = await probe.queryLatest();
      if (row != null && row['durationMs']! > 0) {
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      await tester.pump();
    }
    expect(row, isNotNull, reason: 'no video row in MediaStore');
    expect(row!['durationMs'], greaterThan(0),
        reason: 'MediaStore DURATION still 0 after the 30 s poll');
    expect(row['size'], greaterThan(0));
    final int dateAdded = row['dateAdded']!;
    expect(dateAdded, greaterThanOrEqualTo(testStartEpoch - 900));
    expect(dateAdded, lessThanOrEqualTo(testStartEpoch + 900));
    expect(row['durationMs'], greaterThanOrEqualTo(28000),
        reason: 'take-length check: 30 s recording is shorter than 28 s');
  });
}

/// Polls [finder] once a second until it matches or [timeout] expires.
/// Returns true when the finder matched. Pumps frames while waiting so
/// the camera-init path keeps running.
Future<bool> _waitFor(
  WidgetTester tester,
  Finder finder,
  Duration timeout,
) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return true;
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await tester.pump();
  return finder.evaluate().isNotEmpty;
}

/// Real-time wait that keeps pumping frames (recording timer, map
/// ticks) instead of freezing the UI with pumpAndSettle.
Future<void> _waitWithPump(WidgetTester tester, Duration duration) async {
  final DateTime end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 500));
    await Future<void>.delayed(const Duration(seconds: 1));
  }
}

/// Reads the Switch behind the SwitchListTile titled [title] and taps
/// it only when OFF, then verifies it reads ON. Same
/// --ensure-switch-on rule as the screenshots workflow.
Future<void> _ensureSwitchOn(WidgetTester tester, String title) async {
  final Finder switchFinder = find.ancestor(
    of: find.text(title),
    matching: find.byType(Switch),
  );
  expect(switchFinder, findsOneWidget, reason: 'no Switch for $title');
  await tester.ensureVisible(switchFinder);
  await tester.pump();
  if (tester.widget<Switch>(switchFinder).value == false) {
    await tester.tap(switchFinder);
    await tester.pump();
  }
  expect(tester.widget<Switch>(switchFinder).value, isTrue,
      reason: '$title switch did not read ON');
}

/// On-device front-vs-rear pixel diff on the mid-recording screenshot:
/// mean absolute per-channel diff between the two feed regions must be
/// >= 5.0, and each region's mean brightness must be >= 8.0 (below
/// which a region is not a video feed at all — the black guard).
void _expectFeedsDiffer(List<int> pngBytes) {
  final img.Image? image = img.decodePng(Uint8List.fromList(pngBytes));
  expect(image, isNotNull, reason: 'screenshot PNG did not decode');
  final ({double r, double g, double b}) front =
      _regionMean(image!, _frontBoxFrac);
  final ({double r, double g, double b}) rear =
      _regionMean(image, _rearBoxFrac);
  final double frontBrightness = (front.r + front.g + front.b) / 3;
  final double rearBrightness = (rear.r + rear.g + rear.b) / 3;
  expect(frontBrightness, greaterThanOrEqualTo(_minMeanBrightness),
      reason: 'front feed region is black (brightness $frontBrightness)');
  expect(rearBrightness, greaterThanOrEqualTo(_minMeanBrightness),
      reason: 'rear feed region is black (brightness $rearBrightness)');
  final double meanDiff = ((front.r - rear.r).abs() +
          (front.g - rear.g).abs() +
          (front.b - rear.b).abs()) /
      3;
  expect(meanDiff, greaterThanOrEqualTo(_minMeanDiff),
      reason: 'front/rear feed regions do not differ '
          '(mean diff $meanDiff < $_minMeanDiff)');
}

/// Mean per-channel colour of the fractional box [frac] =
/// (x0, y0, x1, y1) in [image].
({double r, double g, double b}) _regionMean(
    img.Image image, List<double> frac) {
  final int x0 = (image.width * frac[0]).floor();
  final int y0 = (image.height * frac[1]).floor();
  final int x1 = (image.width * frac[2]).ceil();
  final int y1 = (image.height * frac[3]).ceil();
  double r = 0;
  double g = 0;
  double b = 0;
  int count = 0;
  for (int y = y0; y < y1; y++) {
    for (int x = x0; x < x1; x++) {
      final img.Pixel pixel = image.getPixel(x, y);
      r += pixel.r.toDouble();
      g += pixel.g.toDouble();
      b += pixel.b.toDouble();
      count++;
    }
  }
  return (r: r / count, g: g / count, b: b / count);
}
