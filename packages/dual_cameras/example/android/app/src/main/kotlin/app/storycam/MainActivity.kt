package app.storycam

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CaptionsChannel.NAME,
        ).setMethodCallHandler { call, result ->
            CaptionsChannel.handle(this, call, result)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ShareChannel.NAME,
        ).setMethodCallHandler { call, result ->
            ShareChannel.handle(this, call, result)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ThumbnailChannel.NAME,
        ).setMethodCallHandler { call, result ->
            ThumbnailChannel.handle(call, result)
        }
        // Test-only probe for the camera-flow instrumentation test
        // (issue #79, Track B step 2): MediaStore query + screenshot
        // save. No product code calls this channel.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GalleryProbeChannel.NAME,
        ).setMethodCallHandler { call, result ->
            GalleryProbeChannel.handle(this, call, result)
        }
    }

    // Delete system confirmation (issue #50): ShareChannel.deleteVideo
    // launches the RecoverableSecurityException confirmation via
    // startIntentSenderForResult and holds the MethodChannel.Result
    // until the user answers — forward the result so the channel can
    // complete the pending delete (or report it cancelled).
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        super.onActivityResult(requestCode, resultCode, data)
        ShareChannel.onActivityResult(this, requestCode, resultCode)
    }
}
