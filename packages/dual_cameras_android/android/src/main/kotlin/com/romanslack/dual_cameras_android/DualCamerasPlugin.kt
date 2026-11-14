package com.romanslack.dual_cameras_android

import android.content.Context
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Size
import android.view.Surface
import java.util.concurrent.Executor
import kotlin.math.roundToInt
import com.romanslack.dual_cameras_android.camera.CameraSource
import com.romanslack.dual_cameras_android.gl.CompositeLayout
import com.romanslack.dual_cameras_android.pipeline.RenderThread
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * Android implementation of dual_cameras.
 *
 * Capability detection + Pigeon wiring (Phase 0), and the unified GLES
 * compositor -> MediaCodec/MediaMuxer recording pipeline (Phase 1). Photo
 * capture and the perf HUD land in Phase 2; see ARCHITECTURE.md.
 */
class DualCamerasPlugin : FlutterPlugin, DualCameraHostApi {

  private var context: Context? = null
  private var textureRegistry: TextureRegistry? = null
  private var flutterApi: DualCameraFlutterApi? = null

  private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
  private var renderThread: RenderThread? = null
  private var cameraSource: CameraSource? = null
  private var currentLayout: CompositeLayout? = null
  private var recordAudio = true
  private var hevc = false
  private var compositeW = 1280
  private var compositeH = 720
  private val mainHandler = Handler(Looper.getMainLooper())
  private val mainExecutor = Executor { mainHandler.post(it) }
  private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
  private var debugChannel: MethodChannel? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    textureRegistry = binding.textureRegistry
    flutterApi = DualCameraFlutterApi(binding.binaryMessenger)
    DualCameraHostApi.setUp(binding.binaryMessenger, this)
    debugChannel = MethodChannel(binding.binaryMessenger, DEBUG_CHANNEL).also {
      it.setMethodCallHandler(::handleDebug)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    releaseSession()
    DualCameraHostApi.setUp(binding.binaryMessenger, null)
    debugChannel?.setMethodCallHandler(null)
    debugChannel = null
    flutterApi = null
    textureRegistry = null
    context = null
  }

  // --- DualCameraHostApi ---

  override fun probeSupport(callback: (Result<CameraCapabilities>) -> Unit) {
    callback(Result.success(detectCapabilities()))
  }

  override fun initialize(
    config: RecordingConfig,
    callback: (Result<InitResult>) -> Unit,
  ) {
    val ctx = context
    val registry = textureRegistry
    if (ctx == null || registry == null) {
      callback(Result.failure(IllegalStateException("Plugin not attached")))
      return
    }
    try {
      // A second initialize() (e.g. resume re-init, issue #13) must not
      // leak the previous session: release it before overwriting
      // surfaceProducer / renderThread / cameraSource. Safe when nothing
      // is initialized yet — every release is null-guarded.
      releaseSession()
      val (w, h) = resolutionFor(config.resolution)
      compositeW = w
      compositeH = h
      recordAudio = config.recordAudio
      hevc = config.codec == VideoCodec.HEVC
      val layout = toCompositeLayout(config.layout, w, h)
      currentLayout = layout

      val producer = registry.createSurfaceProducer()
      producer.setSize(w, h)
      surfaceProducer = producer

      val render = RenderThread(w, h, layout)
      val source = CameraSource(ctx)
      render.listener = object : RenderThread.Listener {
        override fun onCameraSurfaces(back: Surface, front: Surface) {
          source.bind(
            back, front,
            onResolution = { isFront, sw, sh -> render.setSourceSize(isFront, sw, sh) },
            onRotation = { isFront, deg -> render.setSourceRotation(isFront, deg) },
            onError = { err ->
              flutterApi?.onError("camera_bind", err.message ?: "bind failed") {}
            },
          )
        }
      }
      render.statsListener = { fps, ms, dropped ->
        mainHandler.post {
          flutterApi?.onFrameStats(
            FrameStats(fps, ms, dropped, ThermalLevel.NOMINAL),
          ) {}
        }
      }
      render.setPreviewSurface(producer.surface, w, h)
      producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
        override fun onSurfaceAvailable() {
          render.setPreviewSurface(producer.surface, w, h)
        }

        override fun onSurfaceDestroyed() {
          render.setPreviewSurface(null, w, h)
        }
      })
      renderThread = render
      cameraSource = source

      // Listener is now wired; hand over the camera surfaces to start the feed.
      render.startCameraFeed()

      registerThermalListener(ctx)
      val textureId = producer.id()
      flutterApi?.onReady(textureId) {}
      callback(Result.success(InitResult(textureId, detectCapabilities())))
    } catch (t: Throwable) {
      callback(Result.failure(t))
    }
  }

  /** Proactive thermal monitoring (ThermalGovernor, ARCHITECTURE.md §10). */
  private fun registerThermalListener(ctx: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
    if (thermalListener != null) return
    val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
    val listener = PowerManager.OnThermalStatusChangedListener { status ->
      flutterApi?.onThermal(mapThermal(status)) {}
    }
    pm.addThermalStatusListener(mainExecutor, listener)
    thermalListener = listener
  }

  private fun unregisterThermalListener() {
    val ctx = context ?: return
    val pm = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
    thermalListener?.let {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) pm.removeThermalStatusListener(it)
    }
    thermalListener = null
  }

  private fun mapThermal(status: Int): ThermalLevel = when {
    status >= PowerManager.THERMAL_STATUS_CRITICAL -> ThermalLevel.CRITICAL
    status == PowerManager.THERMAL_STATUS_SEVERE -> ThermalLevel.SERIOUS
    status == PowerManager.THERMAL_STATUS_MODERATE -> ThermalLevel.FAIR
    else -> ThermalLevel.NOMINAL
  }

  override fun startRecording(callback: (Result<Unit>) -> Unit) {
    val render = renderThread
    val ctx = context
    if (render == null || ctx == null) {
      callback(notYet("startRecording (not initialized)"))
      return
    }
    val path = File(ctx.cacheDir, "dcr_${System.nanoTime()}.mp4").absolutePath
    render.startRecording(path, recordAudio, hevc)
    flutterApi?.onRecordingStarted {}
    callback(Result.success(Unit))
  }

  override fun stopRecording(callback: (Result<String>) -> Unit) {
    val render = renderThread
    if (render == null) {
      callback(notYet("stopRecording (not initialized)"))
      return
    }
    render.stopRecordingResult { path ->
      mainHandler.post {
        flutterApi?.onRecordingStopped(path) {}
        callback(Result.success(path))
      }
    }
    return
  }

  override fun takePhoto(callback: (Result<String>) -> Unit) {
    val render = renderThread
    val ctx = context
    if (render == null || ctx == null) {
      callback(notYet("takePhoto (not initialized)"))
      return
    }
    val path = File(ctx.cacheDir, "dcr_${System.nanoTime()}.jpg").absolutePath
    render.takePhoto(
      path,
      done = { mainHandler.post { callback(Result.success(it)) } },
      fail = { mainHandler.post { callback(Result.failure(it)) } },
    )
  }

  override fun swapPrimary(callback: (Result<Unit>) -> Unit) {
    val layout = currentLayout ?: return callback(notYet("swapPrimary (not initialized)"))
    val swapped = layout.copy(primaryFront = !layout.primaryFront)
    currentLayout = swapped
    renderThread?.updateLayout(swapped)
    callback(Result.success(Unit))
  }

  override fun setLayout(layout: LayoutConfig, callback: (Result<Unit>) -> Unit) {
    if (surfaceProducer == null) return callback(notYet("setLayout (not initialized)"))
    val composite = toCompositeLayout(layout, compositeW, compositeH)
    currentLayout = composite
    renderThread?.updateLayout(composite)
    callback(Result.success(Unit))
  }

  override fun setExposureCompensation(ev: Double, callback: (Result<Unit>) -> Unit) {
    try {
      cameraSource?.setExposureCompensation(ev)
      callback(Result.success(Unit))
    } catch (t: Throwable) {
      callback(Result.failure(t))
    }
  }

  override fun getExposureCompensationRange(callback: (Result<ExposureCompensationRange>) -> Unit) {
    try {
      val (minEv, maxEv, stepEv) = cameraSource?.exposureCompensationRange()
        ?: Triple(0.0, 0.0, 0.0)
      callback(Result.success(ExposureCompensationRange(minEv, maxEv, stepEv)))
    } catch (t: Throwable) {
      callback(Result.failure(t))
    }
  }

  override fun setFilter(filter: VideoFilter, callback: (Result<Unit>) -> Unit) {
    try {
      renderThread?.setFilter(filter)
      callback(Result.success(Unit))
    } catch (t: Throwable) {
      callback(Result.failure(t))
    }
  }

  override fun getLenses(front: Boolean, callback: (Result<List<LensOption>>) -> Unit) {
    try {
      callback(Result.success(probeLenses(front)))
    } catch (t: Throwable) {
      callback(Result.failure(t))
    }
  }

  override fun setLens(front: Boolean, ratio: Double, callback: (Result<Unit>) -> Unit) {
    try {
      val ok = cameraSource?.setLensZoom(front, ratio.toFloat()) ?: false
      if (ok) {
        callback(Result.success(Unit))
      } else {
        callback(Result.failure(IllegalStateException(
          "Lens ${formatRatio(ratio)}x is not available right now " +
            "(camera not ready, or the ratio is outside the zoom range)")))
      }
    } catch (t: Throwable) {
      callback(Result.failure(t))
    }
  }

  override fun supports4k(callback: (Result<Boolean>) -> Unit) {
    try {
      callback(Result.success(probeSupports4k()))
    } catch (t: Throwable) {
      callback(Result.failure(t))
    }
  }

  /**
   * Lens probe (issue #20): the ratios the camera API offers for one facing.
   *
   * Physical lenses come from Camera2: each physical camera's focal length
   * against the main (1x) lens — the physical camera with the largest sensor
   * (on phones the main sensor is the largest; ultrawide/tele are smaller).
   * When no physical cameras are readable, the logical camera's zoom range
   * says whether it is wider than 1x. Front 1.5x is the zoom preset Den
   * asked for (wireframe v5): the front camera has no telephoto lens, so
   * 1.5x is offered when the API's zoom range covers it; rear pills are
   * physical lenses only. Nothing here is hardcoded to a phone model.
   */
  private fun probeLenses(front: Boolean): List<LensOption> {
    val ctx = context ?: return emptyList()
    val manager = ctx.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
      ?: return emptyList()
    val facing = if (front) {
      CameraCharacteristics.LENS_FACING_FRONT
    } else {
      CameraCharacteristics.LENS_FACING_BACK
    }
    val logicalId = manager.cameraIdList.firstOrNull { id ->
      try {
        manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING) == facing
      } catch (_: Throwable) {
        false
      }
    } ?: return emptyList()
    val chars = try {
      manager.getCameraCharacteristics(logicalId)
    } catch (_: Throwable) {
      return emptyList()
    }
    val ratios = mutableSetOf<Double>()
    var mainFocal = 0f
    var mainArea = -1f
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      val focals = mutableMapOf<String, Float>()
      val physical = try {
        chars.physicalCameraIds
      } catch (_: Throwable) {
        emptySet<String>()
      }
      for (pid in physical) {
        try {
          val pc = manager.getCameraCharacteristics(pid)
          val f = pc.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            ?.firstOrNull() ?: continue
          val size = pc.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            ?: continue
          focals[pid] = f
          val area = size.width * size.height
          if (area > mainArea) {
            mainArea = area
            mainFocal = f
          }
        } catch (_: Throwable) {
          continue
        }
      }
      if (mainFocal > 0f) {
        for ((_, f) in focals) {
          val r = (f / mainFocal).toDouble()
          if (r in 0.4..10.0) ratios.add(roundToTenth(r))
        }
      }
    }
    val zoomRange = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
    } else {
      null
    }
    if (ratios.isEmpty()) {
      // Single physical camera (or unreadable focals): the logical camera
      // may still be wider than 1x — the zoom range says so.
      if (zoomRange != null && zoomRange.lower < 0.95f) {
        ratios.add(roundToTenth(zoomRange.lower.toDouble()))
      }
      ratios.add(1.0)
    } else {
      ratios.add(1.0)
    }
    if (front && zoomRange != null && zoomRange.upper >= 1.5f) ratios.add(1.5)
    return ratios.filter { it in 0.4..10.0 }.sorted()
      .map { LensOption(it, formatRatio(it)) }
  }

  /**
   * 4K probe (issue #20): both cameras must list 3840x2160 as a
   * MediaRecorder output size, and an AVC encoder must accept 3840x2160.
   * This is a capability probe only — it cannot prove two concurrent 4K
   * streams stay within the thermal budget; the ThermalGovernor still
   * watches, and a 4K session that fails to bind surfaces as an error
   * with a retry, like any other camera failure.
   */
  private fun probeSupports4k(): Boolean {
    val ctx = context ?: return false
    val manager = ctx.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
      ?: return false
    val target = Size(3840, 2160)
    for (facing in listOf(
      CameraCharacteristics.LENS_FACING_BACK,
      CameraCharacteristics.LENS_FACING_FRONT,
    )) {
      val id = manager.cameraIdList.firstOrNull { cid ->
        try {
          manager.getCameraCharacteristics(cid).get(CameraCharacteristics.LENS_FACING) == facing
        } catch (_: Throwable) {
          false
        }
      } ?: return false
      val chars = try {
        manager.getCameraCharacteristics(id)
      } catch (_: Throwable) {
        return false
      }
      val map = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        ?: return false
      val sizes = try {
        map.getOutputSizes(MediaRecorder::class.java)
      } catch (_: Throwable) {
        null
      } ?: return false
      if (!sizes.contains(target)) return false
    }
    return try {
      MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any { info ->
        if (!info.isEncoder) return@any false
        if (!info.supportedTypes.contains(MediaFormat.MIMETYPE_VIDEO_AVC)) {
          return@any false
        }
        val caps = try {
          info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
        } catch (_: Throwable) {
          null
        } ?: return@any false
        caps.videoCapabilities?.isSizeSupported(3840, 2160) ?: false
      }
    } catch (_: Throwable) {
      false
    }
  }

  private fun roundToTenth(value: Double): Double =
    (value * 10).roundToInt() / 10.0

  private fun formatRatio(ratio: Double): String {
    val tenth = (ratio * 10).roundToInt()
    return if (tenth % 10 == 0) "${tenth / 10}" else "${tenth / 10}.${tenth % 10}"
  }

  override fun dispose(callback: (Result<Unit>) -> Unit) {
    releaseSession()
    callback(Result.success(Unit))
  }

  // --- debug tuning channel (example app only) ---

  /**
   * Live geometry tuning for the example harness — rotation correction, front
   * mirror, and source-aspect override — so the front/back orientation and any
   * stretch can be dialed in on a real device without rebuilding native code.
   */
  private fun handleDebug(call: MethodCall, result: MethodChannel.Result) {
    val render = renderThread
    if (render == null) {
      result.error("not_init", "initialize() first", null)
      return
    }
    when (call.method) {
      "setRotationOffset" -> {
        val front = call.argument<Boolean>("front") ?: true
        val offset = call.argument<Int>("offset") ?: 0
        render.setRotationOffset(front, offset)
        result.success(null)
      }
      "setAspectOverride" -> {
        val front = call.argument<Boolean>("front") ?: true
        val aspect = (call.argument<Double>("aspect") ?: 0.0).toFloat()
        render.setAspectOverride(front, aspect)
        result.success(null)
      }
      "setMirrorFront" -> {
        val on = call.argument<Boolean>("on") ?: true
        currentLayout?.let {
          val updated = it.copy(mirrorFront = on)
          currentLayout = updated
          render.updateLayout(updated)
        }
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  // --- internals ---

  private fun releaseSession() {
    unregisterThermalListener()
    cameraSource?.release()
    cameraSource = null
    renderThread?.release()
    renderThread = null
    surfaceProducer?.release()
    surfaceProducer = null
    currentLayout = null
  }

  private fun <T> notYet(op: String): Result<T> =
    Result.failure(UnsupportedOperationException("$op is not available"))

  // Portrait canvas (vertical video). Width < height; the cameras are rotated
  // upright into it by the compositor using each sensor's orientation.
  private fun resolutionFor(res: DualResolution): Pair<Int, Int> = when (res) {
    DualResolution.SD480 -> 480 to 854
    DualResolution.HD720 -> 720 to 1280
    DualResolution.HD1080 -> 1080 to 1920
    DualResolution.ULTRA_HD2160 -> 2160 to 3840
  }

  private fun toCompositeLayout(layout: LayoutConfig, w: Int, h: Int): CompositeLayout {
    val primaryFront = layout.primary == CameraLens.FRONT
    val pip = layout.mode == DualLayoutMode.PICTURE_IN_PICTURE
    val splitVertical = layout.mode == DualLayoutMode.SPLIT_VERTICAL

    // Inset rect in normalized [0,1] surface coords (origin top-left).
    // insetScale is a fraction of the SHORTER side (height), so a circle inset
    // is a true square in pixels; a rect inset matches the canvas aspect.
    val insetH = layout.insetScale
    val insetW = if (layout.circleInset) layout.insetScale * h / w else layout.insetScale
    val mx = layout.margin / w
    val my = layout.margin / h
    val (l, t, r, b) = when (layout.insetCorner) {
      InsetCorner.TOP_LEFT -> arrayOf(mx, my, mx + insetW, my + insetH)
      InsetCorner.TOP_RIGHT -> arrayOf(1 - mx - insetW, my, 1 - mx, my + insetH)
      InsetCorner.BOTTOM_LEFT -> arrayOf(mx, 1 - my - insetH, mx + insetW, 1 - my)
      InsetCorner.BOTTOM_RIGHT ->
        arrayOf(1 - mx - insetW, 1 - my - insetH, 1 - mx, 1 - my)
    }
    // A circle is the rounded-rect SDF on a square rect with radius = half side.
    val insetSidePx = (insetH * h).toFloat()
    val cornerRadiusPx =
      if (layout.circleInset) insetSidePx / 2f else layout.cornerRadius.toFloat()
    return CompositeLayout(
      pictureInPicture = pip,
      primaryFront = primaryFront,
      insetLeft = l.toFloat(),
      insetTop = t.toFloat(),
      insetRight = r.toFloat(),
      insetBottom = b.toFloat(),
      cornerRadiusPx = cornerRadiusPx,
      mirrorFront = layout.mirrorFront,
      splitVertical = splitVertical,
    )
  }

  /**
   * Detect whether this device can run front + back concurrently. Mirrors
   * MASTER_PLAN.md §4.1.
   */
  private fun detectCapabilities(): CameraCapabilities {
    val ctx = context ?: return CameraCapabilities(
      isSupported = false,
      reason = UnsupportedReason.NO_CONCURRENT_CAMERA,
    )
    val manager = ctx.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
      ?: return CameraCapabilities(
        isSupported = false,
        reason = UnsupportedReason.NO_CONCURRENT_CAMERA,
      )

    val supported = try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        manager.concurrentCameraIds.any { combo -> comboHasFrontAndBack(manager, combo) }
      } else {
        ctx.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_CONCURRENT)
      }
    } catch (_: Throwable) {
      false
    }

    return if (supported) {
      CameraCapabilities(isSupported = true, maxWidth = 1280L, maxHeight = 720L)
    } else {
      CameraCapabilities(
        isSupported = false,
        reason = UnsupportedReason.NO_CONCURRENT_CAMERA,
      )
    }
  }

  private fun comboHasFrontAndBack(
    manager: CameraManager,
    combo: Set<String>,
  ): Boolean {
    var hasFront = false
    var hasBack = false
    for (id in combo) {
      val facing = try {
        manager.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING)
      } catch (_: Throwable) {
        null
      }
      when (facing) {
        CameraCharacteristics.LENS_FACING_FRONT -> hasFront = true
        CameraCharacteristics.LENS_FACING_BACK -> hasBack = true
      }
    }
    return hasFront && hasBack
  }

  private companion object {
    const val DEBUG_CHANNEL = "dual_cameras/debug"
  }
}
