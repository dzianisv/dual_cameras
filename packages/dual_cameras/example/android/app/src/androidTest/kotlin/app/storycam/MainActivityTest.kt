package app.storycam

import androidx.test.rule.ActivityTestRule
import dev.flutter.plugins.integration_test.FlutterTestRunner
import org.junit.Rule
import org.junit.runner.RunWith

/**
 * Instrumentation-test entry point for `flutter test integration_test`
 * (issue #79, Track B step 2), per the Flutter `integration_test`
 * README (Kotlin example). Without this runner class there is no test
 * entry point for the instrumentation APK on Firebase Test Lab.
 *
 * The @Rule field below is REQUIRED, not optional: FlutterTestRunner
 * scans the test class's declared fields for one @Rule-annotated
 * ActivityTestRule instance, and its run() throws
 * RuntimeException("Unable to run tests due to missing activity rule")
 * at runtime without it. An annotation-only class compiles fine, so a
 * dry build cannot catch a missing field — it fails only at runtime.
 */
@RunWith(FlutterTestRunner::class)
class MainActivityTest {
    @Rule
    @JvmField
    val rule: ActivityTestRule<MainActivity> = ActivityTestRule(MainActivity::class.java, initialTouchMode = true, launchActivity = false)
}
