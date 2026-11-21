package app.storycam

import android.content.Intent
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Issue #105: draw edge-to-edge on Android 15 (API 35) — content
    // behind the status + navigation bars. The Flutter engine already
    // defaults to edge-to-edge for targetSdk 35+, but Play Console does
    // not count the implicit default, so make it explicit here.
    // (androidx.activity's enableEdgeToEdge() does NOT apply:
    // FlutterActivity extends android.app.Activity, not
    // ComponentActivity, so use WindowCompat directly.)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
    }

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
