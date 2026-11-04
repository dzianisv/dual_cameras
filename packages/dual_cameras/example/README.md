# StoryCam example

StoryCam records both perspectives in one portrait video using the
`dual_cameras` plugin. Its dark camera interface keeps the complete 9:16
composition visible. The shutter opens the camera, then starts/stops recording;
photo and camera-swap controls sit alongside it. Filters and captions are quick
controls. Short screens scroll the secondary controls; landscape uses a side
rail. Controls respect safe areas and provide labels for assistive technology.

Camera settings contains the circular-selfie switch, expandable exposure
controls when supported, session details (including saved file paths and
errors), and the existing debug geometry/telemetry tools.

The app prepares the caption speech model at startup. The progress line shows
preparation, readiness, or a retryable failure, and discloses the roughly 100 MB
first-use download. Camera capture does not wait for the model. Post-recording
captions share that preparation task; the original video is saved first and is
retained if captions fail. Legacy caches without completion receipts are
redownloaded once by the hardened model manager.

From this directory, use `flutter pub get`, `flutter analyze`, and
`flutter test`. Use `flutter run` on a supported concurrent-camera Android
phone or iPhone for real capture verification. The desktop and web targets
cannot exercise the native dual-camera pipeline.

Widget tests use fake camera, permission, gallery and model services. They
cover permission denial, unsupported hardware, repeated record taps, saving,
caption preparation/failure, disposal, sheet navigation, 320×480 / 390×844 /
844×390 layouts, 2× text, safe-area shutter placement, accessible activation,
and the preview's 9:16 texture dimensions. They do not verify real camera
frames, gallery access, microphone sync, GPU performance or native inference.

The launcher artwork remains the existing asset until the approved StoryCam
icon is provided. Application IDs and plugin/package names are unchanged.
