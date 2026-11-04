## Unreleased

* Add `DualCameraController.setExposureCompensation(double ev)` and
  `getExposureCompensationRange()` — the Sony-style EV dial, applied live to
  both cameras (fixes overexposed video). Backward compatible.

## 0.1.2

* Require `dual_cameras_ios` ^0.1.1: crisp full-frame back camera, immediate
  camera/mic release on dispose, and true circular picture-in-picture.

## 0.1.1

* Docs: use an absolute banner image URL in the README so it renders on pub.dev.

## 0.1.0

* Initial release: front+back simultaneous capture with a unified manual GPU
  compositor (GLES on Android, Metal on iOS), single composited `.mp4` +
  composited photo, live preview, capability detection, and thermal telemetry.
