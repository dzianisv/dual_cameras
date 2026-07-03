## 0.1.1

* Crisp full-frame back camera: pick a non-binned ~720p multicam format for the
  back (primary) camera and the cheap binned format for the front inset, with a
  hardwareCost-relief downgrade for lower-end devices.
* Release the camera and mic immediately on dispose (remove all inputs/outputs
  and await teardown) so a following single-camera session can acquire the
  hardware without waiting on ARC.
* True circular picture-in-picture: size the inset off the shorter side so a
  circle is a real square in pixels, with corner radius = half the side.

## 0.1.0

* Initial release: front+back simultaneous capture with a unified manual GPU
  compositor (GLES on Android, Metal on iOS), single composited `.mp4` +
  composited photo, live preview, capability detection, and thermal telemetry.
