package com.romanslack.dual_cameras_android.camera

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ConcurrentCamera
import androidx.camera.core.Preview
import androidx.camera.core.UseCaseGroup
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.util.concurrent.Executor
import kotlin.math.roundToInt

/**
 * Binds the front + back cameras concurrently (CameraX) and delivers each
 * feed into one of the GL compositor's [Surface]s. We deliberately do NOT use
 * CompositionSettings — the cameras are texture sources only (MASTER_PLAN §4).
 */
class CameraSource(private val context: Context) {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { mainHandler.post(it) }
    private val lifecycle = SimpleLifecycleOwner()
    private var provider: ProcessCameraProvider? = null
    private var boundCameras: List<Camera> = emptyList()

    fun bind(
        backSurface: Surface,
        frontSurface: Surface,
        onResolution: (isFront: Boolean, width: Int, height: Int) -> Unit,
        onRotation: (isFront: Boolean, degrees: Int) -> Unit,
        onError: (Throwable) -> Unit,
    ) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                val cameraProvider = future.get()
                provider = cameraProvider
                cameraProvider.unbindAll()
                Log.i(TAG, "provider ready; concurrentInfos=${cameraProvider.availableConcurrentCameraInfos.size}")

                // Let each camera run its NATIVE resolution/aspect — forcing
                // 16:9 makes the HAL pre-stretch the sensor's 4:3, which we
                // can't undo. The compositor center-crops to fit the canvas.
                val backPreview = Preview.Builder().build().also {
                    it.setSurfaceProvider(mainExecutor) { request ->
                        Log.i(TAG, "back surface requested ${request.resolution}")
                        onResolution(false, request.resolution.width, request.resolution.height)
                        request.provideSurface(backSurface, mainExecutor) {
                            Log.i(TAG, "back surface released ${it.resultCode}")
                        }
                    }
                }
                val frontPreview = Preview.Builder().build().also {
                    it.setSurfaceProvider(mainExecutor) { request ->
                        Log.i(TAG, "front surface requested ${request.resolution}")
                        onResolution(true, request.resolution.width, request.resolution.height)
                        request.provideSurface(frontSurface, mainExecutor) {
                            Log.i(TAG, "front surface released ${it.resultCode}")
                        }
                    }
                }
                val backConfig = ConcurrentCamera.SingleCameraConfig(
                    CameraSelector.DEFAULT_BACK_CAMERA,
                    UseCaseGroup.Builder().addUseCase(backPreview).build(),
                    lifecycle,
                )
                val frontConfig = ConcurrentCamera.SingleCameraConfig(
                    CameraSelector.DEFAULT_FRONT_CAMERA,
                    UseCaseGroup.Builder().addUseCase(frontPreview).build(),
                    lifecycle,
                )
                lifecycle.start()
                val cam = cameraProvider.bindToLifecycle(listOf(backConfig, frontConfig))
                boundCameras = cam.cameras
                Log.i(TAG, "bindToLifecycle OK; cameras=${cam.cameras.size}")
                for (camera in cam.cameras) {
                    val info = camera.cameraInfo
                    val isFront = info.lensFacing == CameraSelector.LENS_FACING_FRONT
                    Log.i(TAG, "${if (isFront) "front" else "back"} sensorRotation=${info.sensorRotationDegrees}")
                    onRotation(isFront, info.sensorRotationDegrees)
                }
            } catch (t: Throwable) {
                Log.e(TAG, "bind failed", t)
                onError(t)
            }
        }, mainExecutor)
    }

    fun release() {
        mainHandler.post {
            try {
                provider?.unbindAll()
            } catch (_: Throwable) {
            }
            lifecycle.stop()
            provider = null
            boundCameras = emptyList()
        }
    }

    /**
     * Sony-style EV dial: apply exposure compensation to both cameras.
     * Converts EV to the nearest compensation index via each camera's
     * [androidx.camera.core.ExposureState] and clamps to its range.
     * No-op for cameras without support; never throws.
     */
    fun setExposureCompensation(ev: Double) {
        for (camera in boundCameras) {
            try {
                val state = camera.cameraInfo.exposureState
                if (!state.isExposureCompensationSupported) continue
                val step = state.exposureCompensationStep.toDouble()
                if (step <= 0.0) continue
                val range = state.exposureCompensationRange
                val index = (ev / step).roundToInt().coerceIn(range.lower, range.upper)
                camera.cameraControl.setExposureCompensationIndex(index)
            } catch (t: Throwable) {
                Log.w(TAG, "setExposureCompensation failed", t)
            }
        }
    }

    /**
     * Intersection of both cameras' exposure-compensation ranges, in EV as
     * (minEv, maxEv, stepEv). Returns (0, 0, 0) when nothing is bound or
     * either camera lacks support.
     */
    fun exposureCompensationRange(): Triple<Double, Double, Double> {
        var minEv = Double.NEGATIVE_INFINITY
        var maxEv = Double.POSITIVE_INFINITY
        var stepEv = 0.0
        var count = 0
        for (camera in boundCameras) {
            val state = try {
                camera.cameraInfo.exposureState
            } catch (t: Throwable) {
                return Triple(0.0, 0.0, 0.0)
            }
            if (!state.isExposureCompensationSupported) return Triple(0.0, 0.0, 0.0)
            val step = state.exposureCompensationStep.toDouble()
            if (step <= 0.0) return Triple(0.0, 0.0, 0.0)
            val range = state.exposureCompensationRange
            minEv = maxOf(minEv, range.lower * step)
            maxEv = minOf(maxEv, range.upper * step)
            stepEv = maxOf(stepEv, step)
            count++
        }
        if (count == 0 || minEv >= maxEv) return Triple(0.0, 0.0, 0.0)
        return Triple(minEv, maxEv, stepEv)
    }

    private companion object {
        const val TAG = "DualCam"
    }

    /** Minimal always-resumed LifecycleOwner for the headless camera session. */
    private class SimpleLifecycleOwner : LifecycleOwner {
        private val registry = LifecycleRegistry(this)
        override val lifecycle: Lifecycle get() = registry

        fun start() {
            registry.currentState = Lifecycle.State.RESUMED
        }

        fun stop() {
            registry.currentState = Lifecycle.State.DESTROYED
        }
    }
}
