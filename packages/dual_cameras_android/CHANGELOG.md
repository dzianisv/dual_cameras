## Unreleased

* Color-grade stage in the compositor's blit shader (the single fan-out
  point for preview + recording): exposure, S-curve contrast, saturation,
  split-tone (teal shadows / warm highlights), vignette — all uniform
  driven via `GradeParams`; `moody` preset ships with v1 parameters.

## Unreleased

* Implement exposure compensation on both cameras via CameraX
  `ExposureState` (`setExposureCompensationIndex`, EV -> nearest index,
  clamped to the intersected range of both cameras). No-op when unsupported.

## 0.1.0

* Initial release: front+back simultaneous capture with a unified manual GPU
  compositor (GLES on Android, Metal on iOS), single composited `.mp4` +
  composited photo, live preview, capability detection, and thermal telemetry.
