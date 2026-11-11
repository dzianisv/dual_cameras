/// Caption language: what the recognizer is told to expect.
///
/// Auto (`''`) is Whisper language detection and stays the default. Auto is
/// unreliable on very short utterances (~1 s): with almost no phonetic
/// context the model can fall back to its highest prior (English) and
/// decode a Russian word as English — the v0.5.0 phone defect (Den said
/// «Привет», the caption came back "THERE YET."). Picking a language
/// removes detection from the equation entirely for that recording.
enum CaptionLanguage {
  /// Automatic language detection (sherpa-onnx: empty language).
  auto('', 'Auto'),

  /// Russian — recognizer runs with `language: 'ru'`.
  russian('ru', 'Русский'),

  /// English — recognizer runs with `language: 'en'`.
  english('en', 'English');

  const CaptionLanguage(this.code, this.label);

  /// The code passed straight to sherpa-onnx (`''` = auto-detect).
  final String code;

  /// The label shown in the Captions sheet.
  final String label;

  /// Parse a stored code; anything unknown (including null) is Auto, so a
  /// corrupt or future value can never break captioning.
  static CaptionLanguage fromCode(String? code) =>
      values.firstWhere((value) => value.code == code,
          orElse: () => CaptionLanguage.auto);
}
