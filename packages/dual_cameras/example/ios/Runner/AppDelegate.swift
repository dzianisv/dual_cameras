import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Last-video thumbnail (issue #50): one frame as JPEG bytes, via
    // AVAssetImageGenerator. Own channel, not the share channel — see
    // ThumbnailChannel.kt for the reason; the share channel has no iOS
    // handler at all (iOS Delete is Dart File.delete, Share hidden).
    let thumbnail = FlutterMethodChannel(
      name: "dual_cameras_example/thumbnail",
      binaryMessenger: engineBridge.binaryMessenger)
    thumbnail.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(
          code: "thumbnail_failed", message: "app delegate gone", details: nil))
        return
      }
      if call.method == "videoThumbnail" {
        self.videoThumbnail(call, result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// `videoThumbnail {path, maxWidth, quality, timeMs}` -> JPEG bytes
  /// (FlutterStandardTypedData) of the frame at `timeMs` (default 500),
  /// width capped at `maxWidth` (default 128), height auto-scaled to the
  /// source aspect, JPEG `quality` (default 75). Mirrors
  /// ThumbnailChannel.kt on Android. A failure returns a FlutterError —
  /// the Dart side treats it as an invisible fallback (icon tile).
  private func videoThumbnail(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
      let path = args["path"] as? String
    else {
      result(FlutterError(
        code: "thumbnail_failed", message: "path required", details: nil))
      return
    }
    let maxWidth = (args["maxWidth"] as? NSNumber)?.doubleValue ?? 128
    let quality = (args["quality"] as? NSNumber)?.doubleValue ?? 75
    let timeMs = (args["timeMs"] as? NSNumber)?.doubleValue ?? 500
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .video).first else {
      result(FlutterError(
        code: "thumbnail_failed", message: "no video track: \(path)", details: nil))
      return
    }
    let natural = track.naturalSize.applying(track.preferredTransform)
    let width = abs(natural.width)
    let height = abs(natural.height)
    guard width > 0, height > 0 else {
      result(FlutterError(
        code: "thumbnail_failed", message: "zero-size video track: \(path)", details: nil))
      return
    }
    let scale = min(1.0, maxWidth / width)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: width * scale, height: height * scale)
    let time = CMTimeMakeWithSeconds(timeMs / 1000.0, preferredTimescale: 600)
    do {
      let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
      guard let data = UIImage(cgImage: cgImage)
        .jpegData(compressionQuality: quality / 100.0)
      else {
        result(FlutterError(
          code: "thumbnail_failed", message: "JPEG encode failed: \(path)", details: nil))
        return
      }
      result(FlutterStandardTypedData(bytes: data))
    } catch {
      result(FlutterError(
        code: "thumbnail_failed", message: error.localizedDescription, details: nil))
    }
  }
}
