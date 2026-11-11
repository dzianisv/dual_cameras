import 'package:flutter/services.dart';

/// Durable Android jobs. This bridge owns no work or video files: the native
/// scheduler survives the widget, activity and app process that enqueued it.
class CaptionJobs {
  static const channel = MethodChannel('dual_cameras_example/caption_jobs');

  /// Queue a caption job for [mp4]. [language] is the sherpa-onnx code
  /// chosen when the job was enqueued ('' = Auto); the native side stores
  /// it with the job and the headless runner reads it back from `ready`,
  /// so a job always uses the language that was current at enqueue time.
  Future<String> enqueue(String mp4, {String language = ''}) async {
    final id = await channel.invokeMethod<String>(
        'enqueue', {'mp4': mp4, 'language': language});
    if (id == null || id.isEmpty) {
      throw StateError('Caption job was not queued');
    }
    return id;
  }

  Future<List<CaptionJob>> list() async {
    final jobs = await channel.invokeListMethod<Object?>('list') ?? [];
    return jobs
        .map(
            (job) => CaptionJob.fromMap(Map<Object?, Object?>.from(job as Map)))
        .toList();
  }

  Future<bool> notificationsEnabled() async =>
      await channel.invokeMethod<bool>('notificationsEnabled') ?? false;
  Future<String?> retry(String id) =>
      channel.invokeMethod<String>('retry', {'id': id});
  Future<void> cancel(String id) => channel.invokeMethod('cancel', {'id': id});
  Future<void> open(String id) => channel.invokeMethod('open', {'id': id});
  Future<void> share(String id) => channel.invokeMethod('share', {'id': id});
}

class CaptionJob {
  const CaptionJob(
      {required this.id,
      required this.state,
      required this.stage,
      required this.progress,
      this.output,
      this.error});

  factory CaptionJob.fromMap(Map<Object?, Object?> map) => CaptionJob(
        id: map['id'] as String,
        state: map['state'] as String? ?? 'queued',
        stage: map['stage'] as String? ?? 'Waiting to start',
        progress: ((map['progress'] as num?)?.toInt() ?? 0).clamp(0, 100),
        output: map['output'] as String?,
        error: map['error'] as String?,
      );

  final String id, state, stage;
  final int progress;
  final String? output, error;
  bool get canStop => state == 'queued' || state == 'running';
  bool get active => canStop || state == 'cancelling';
  bool get ready => state == 'succeeded' && output != null;

  String get label => switch (state) {
        'queued' => 'Captions queued',
        'running' => '$stage · $progress%',
        'succeeded' => stage.isEmpty ? 'Captions ready' : stage,
        'cancelling' => 'Stopping captions…',
        'cancelled' => 'Captions stopped · original kept',
        'failed' => 'Captions failed · original kept',
        _ => stage,
      };
}
