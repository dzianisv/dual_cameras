import 'package:dual_cameras_example/captions/caption_jobs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native job bridge restores durable state and sends targeted actions', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(CaptionJobs.channel, (call) async {
      calls.add(call);
      if (call.method == 'list') return [{'id': 'persisted', 'state': 'running', 'stage': 'Transcribing', 'progress': 55}];
      if (call.method == 'enqueue') return 'new';
      if (call.method == 'notificationsEnabled') return false;
      return null;
    });
    final jobs = CaptionJobs();
    final restored = await jobs.list();
    expect(restored.single.label, 'Transcribing · 55%');
    expect(restored.single.canStop, isTrue);
    expect(await jobs.enqueue('/source.mp4'), 'new');
    await jobs.cancel('persisted');
    await jobs.open('persisted');
    await jobs.share('persisted');
    expect(await jobs.notificationsEnabled(), isFalse);
    for (final call in calls.where((c) => ['cancel', 'open', 'share'].contains(c.method))) {
      expect(call.arguments, {'id': 'persisted'});
    }
  });

  test('cancelling jobs remain active but cannot be stopped twice', () {
    final job = CaptionJob.fromMap({'id': 'one', 'state': 'cancelling', 'progress': 120});
    expect(job.active, isTrue);
    expect(job.canStop, isFalse);
    expect(job.ready, isFalse);
    expect(job.progress, 100);
  });
}
