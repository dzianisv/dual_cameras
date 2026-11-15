import 'package:in_app_review/in_app_review.dart';

/// The Play In-App Review call, behind an injectable seam (issue #37).
///
/// The production implementation delegates to the [InAppReview] singleton;
/// widget tests inject a fake that records calls and returns a chosen
/// availability, so no test ever touches the real platform channel.
abstract class ReviewPrompt {
  /// Whether the Play In-App Review flow can be shown on this device.
  /// False on sideloaded builds without Play — the caller then skips
  /// without marking, so a later Play install can still prompt.
  Future<bool> isAvailable();

  /// Ask Play to show the in-app review dialog. Play throttles display
  /// silently; returning only means the request was issued.
  Future<void> requestReview();
}

/// Production [ReviewPrompt]: the [InAppReview] singleton, never called
/// directly from the recording flow — only through this facade.
class InAppReviewPrompt implements ReviewPrompt {
  InAppReviewPrompt([InAppReview? review])
      : _review = review ?? InAppReview.instance;

  final InAppReview _review;

  @override
  Future<bool> isAvailable() => _review.isAvailable();

  @override
  Future<void> requestReview() => _review.requestReview();
}
