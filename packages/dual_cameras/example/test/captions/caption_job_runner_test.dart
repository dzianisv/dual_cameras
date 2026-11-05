import 'package:dual_cameras_example/captions/caption_job_runner.dart';
import 'package:dual_cameras_example/captions/caption_jobs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Stop before ready acknowledges cancellation without preparing a model',
      () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CaptionJobs.channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') return {'cancelled': true};
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CaptionJobs.channel, null));

    await runCaptionJob();

    expect(calls.map((call) => call.method), ['ready', 'cancelled']);
  });
}
