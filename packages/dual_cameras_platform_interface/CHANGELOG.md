## Unreleased

* Pigeon `DualCameraHostApi`: add `setExposureCompensation(double ev)` and
  `getExposureCompensationRange()` returning the new `ExposureCompensationRange`
  (minEv/maxEv/stepEv). Generated code hand-synced to Pigeon v22.7.4
  (run `dart run pigeon --input pigeons/messages.dart` to regenerate).

## 0.1.0

* Initial release: front+back simultaneous capture with a unified manual GPU
  compositor (GLES on Android, Metal on iOS), single composited `.mp4` +
  composited photo, live preview, capability detection, and thermal telemetry.
