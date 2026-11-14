import CoreVideo
import Metal
import simd

/// Layout geometry from Dart, applied identically to preview / video / photo.
struct CompositeLayout {
    var pictureInPicture: Bool
    var primaryFront: Bool
    var insetRect: CGRect   // normalized, origin top-left
    var cornerRadiusPx: Float
    var mirrorFront: Bool
    var splitVertical: Bool
}

// Fields ordered by DESCENDING alignment (16 → 8 → 4) so Swift `simd` and
// Metal agree on the byte layout with no ambiguous internal padding — the
// struct is memcpy'd straight into the shader via setVertex/FragmentBytes.
//
// Final color-grade uniforms (v0.3.0). Field order MUST match GradeUniforms
// in Shaders.metal exactly (float4-aligned; total stride 64).
private struct GradeUniforms {
    var shadowTint: simd_float4    // RGB add in the shadows (split tone)
    var highlightTint: simd_float4 // RGB add in the highlights (split tone)
    var enabled: Float
    var exposure: Float
    var contrast: Float
    var saturation: Float
    var splitStrength: Float
    var vignette: Float
    var _pad: simd_float2 = simd_float2(0, 0)

    static let none = GradeUniforms(
        shadowTint: simd_float4(0, 0, 0, 0),
        highlightTint: simd_float4(0, 0, 0, 0),
        enabled: 0, exposure: 1, contrast: 1, saturation: 1,
        splitStrength: 0, vignette: 0)

    /// Moody v1 — dark moody wellness/vlogger grade. Starting parameters;
    /// tune by eye on a real device.
    static let moody = GradeUniforms(
        shadowTint: simd_float4(-0.020, 0.030, 0.050, 0),
        highlightTint: simd_float4(0.050, 0.025, -0.015, 0),
        enabled: 1, exposure: 0.92, contrast: 1.08, saturation: 0.70,
        splitStrength: 1.0, vignette: 0.28)

    // Issue #20 — the 7 new presets. Values mirror Android GradeParams
    // exactly (same numbers on both sides); every tuple differs from every
    // other preset on at least three knobs, so no two names share one look.
    static let hyper = GradeUniforms(
        shadowTint: simd_float4(-0.010, 0.005, 0.020, 0),
        highlightTint: simd_float4(0.030, 0.010, -0.010, 0),
        enabled: 1, exposure: 1.10, contrast: 1.15, saturation: 1.45,
        splitStrength: 0.6, vignette: 0.05)

    static let midnight = GradeUniforms(
        shadowTint: simd_float4(-0.010, 0.010, 0.060, 0),
        highlightTint: simd_float4(0.000, 0.010, 0.040, 0),
        enabled: 1, exposure: 0.88, contrast: 1.18, saturation: 0.55,
        splitStrength: 1.0, vignette: 0.35)

    static let simple = GradeUniforms(
        shadowTint: simd_float4(0.005, 0.003, 0.000, 0),
        highlightTint: simd_float4(0.010, 0.005, 0.000, 0),
        enabled: 1, exposure: 1.02, contrast: 1.02, saturation: 1.05,
        splitStrength: 0.4, vignette: 0.0)

    static let jakarta = GradeUniforms(
        shadowTint: simd_float4(0.010, 0.000, -0.020, 0),
        highlightTint: simd_float4(0.060, 0.030, -0.010, 0),
        enabled: 1, exposure: 1.06, contrast: 1.05, saturation: 1.15,
        splitStrength: 0.9, vignette: 0.12)

    static let gta = GradeUniforms(
        shadowTint: simd_float4(-0.020, 0.020, 0.040, 0),
        highlightTint: simd_float4(0.060, 0.030, -0.020, 0),
        enabled: 1, exposure: 1.04, contrast: 1.22, saturation: 1.35,
        splitStrength: 1.0, vignette: 0.18)

    static let sanAndreas = GradeUniforms(
        shadowTint: simd_float4(0.020, 0.010, -0.010, 0),
        highlightTint: simd_float4(0.050, 0.030, 0.000, 0),
        enabled: 1, exposure: 1.12, contrast: 0.94, saturation: 1.10,
        splitStrength: 0.7, vignette: 0.08)

    static let gta3 = GradeUniforms(
        shadowTint: simd_float4(-0.010, -0.005, 0.010, 0),
        highlightTint: simd_float4(0.010, 0.010, 0.020, 0),
        enabled: 1, exposure: 0.90, contrast: 1.25, saturation: 0.45,
        splitStrength: 0.8, vignette: 0.45)

    /// Map a VideoFilter to its grade. Keep in sync with Android.
    static func forFilter(_ filter: VideoFilter) -> GradeUniforms {
        switch filter {
        case .none: return .none
        case .moody: return .moody
        case .hyper: return .hyper
        case .midnight: return .midnight
        case .simple: return .simple
        case .jakarta: return .jakarta
        case .gta: return .gta
        case .sanAndreas: return .sanAndreas
        case .gta3: return .gta3
        }
    }
}

private struct QuadUniforms {
    var mvp: simd_float4x4        // align 16, size 64 — places the quad in NDC
    var yuvMatrix: simd_float3x3  // align 16, size 48 — BT.709 YCbCr->RGB
    var yuvOffset: simd_float3    // align 16, size 16
    var texXform: simd_float2x2   // align 8,  size 16 — rotate-upright + cover-crop
    var quadSizePx: simd_float2   // align 8,  size 8
    var mirror: Float             // align 4 — 1.0 -> flip x (selfie)
    var rounded: Float            // 1.0 -> rounded-corner SDF
    var cornerRadiusPx: Float
    var _pad: Float = 0
}

/// The unified Metal compositor (ARCHITECTURE.md §5.2). Zero-copy in via
/// `CVMetalTextureCache`; composes two biplanar-YUV camera buffers into one
/// BGRA/IOSurface-backed `CVPixelBuffer` from a pool — the single buffer feeds
/// both the writer and the Flutter texture.
final class MetalCompositor {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let gradePipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache!
    private var pool: CVPixelBufferPool!
    let width: Int
    let height: Int

    // Final color-grade pass (v0.3.0). The scene composites into `sceneTex`,
    // then the grade pass renders sceneTex -> the pool buffer, so preview and
    // recording share one grade, after exposure. Mutated/read on `dcr.data`.
    private var sceneTex: MTLTexture?
    private var grade: GradeUniforms = .none

    /// Switch the color-grade preset live.
    func setFilter(filter: VideoFilter) {
        grade = GradeUniforms.forFilter(filter)
    }

    // Orientation correction. Unlike Android's SurfaceTexture (which silently
    // rotates the camera buffer 90° upright before we sample), iOS hands us the
    // raw landscape `CVPixelBuffer` — so we must rotate upright ourselves, in
    // the shader, via `texXform`. These are the empirical knobs (driven live by
    // the debug channel, ARCHITECTURE.md §5.5 / IOS_HANDOFF §6); tune on device,
    // then bake the found values as defaults. Mutated/read on `dcr.data`.
    private var frontRotationDeg = 90   // bring front sensor upright (then mirror)
    private var backRotationDeg = 90    // bring back sensor upright
    private var frontAspectOverride: Float = 0  // <= 0 => use the buffer's real w/h
    private var backAspectOverride: Float = 0

    func setRotationOffset(isFront: Bool, degrees: Int) {
        let d = ((degrees % 360) + 360) % 360
        if isFront { frontRotationDeg = d } else { backRotationDeg = d }
    }

    func setAspectOverride(isFront: Bool, aspect: Float) {
        if isFront { frontAspectOverride = aspect } else { backAspectOverride = aspect }
    }

    // BT.709 limited-range YCbCr -> RGB.
    private let yuvMatrix = simd_float3x3(columns: (
        simd_float3(1.1644, 1.1644, 1.1644),
        simd_float3(0.0, -0.2132, 2.1124),
        simd_float3(1.7927, -0.5329, 0.0)
    ))
    private let yuvOffset = simd_float3(-0.0627, -0.5, -0.5)

    init?(width: Int, height: Int) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.width = width
        self.height = height

        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: MetalCompositor.self)),
              let vfn = library.makeFunction(name: "dcr_vertex"),
              let ffn = library.makeFunction(name: "dcr_fragment") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        self.pipeline = pipeline

        guard let gvfn = library.makeFunction(name: "dcr_grade_vertex"),
              let gffn = library.makeFunction(name: "dcr_grade_fragment") else { return nil }
        let gdesc = MTLRenderPipelineDescriptor()
        gdesc.vertexFunction = gvfn
        gdesc.fragmentFunction = gffn
        gdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let gradePipeline = try? device.makeRenderPipelineState(descriptor: gdesc) else { return nil }
        self.gradePipeline = gradePipeline

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    /// Compose primary (full-frame) + secondary (inset/half) into one BGRA buffer.
    func compose(
        primary: CVPixelBuffer,
        secondary: CVPixelBuffer?,
        layout: CompositeLayout
    ) -> CVPixelBuffer? {
        var outBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outBuffer)
        guard let out = outBuffer,
              let target = metalTexture(from: out, plane: 0, format: .bgra8Unorm) else {
            return nil
        }

        // Grade path (v0.3.0): composite into the intermediate scene texture,
        // then the grade pass renders scene -> the pool buffer, so preview and
        // recording share one grade, after exposure. Ungraded keeps the
        // original single pass (bit-identical to before).
        let grading = grade.enabled > 0.5
        let sceneTarget: MTLTexture
        if grading {
            if sceneTex == nil {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height,
                    mipmapped: false)
                desc.usage = [.renderTarget, .shaderRead]
                desc.storageMode = .private
                sceneTex = device.makeTexture(descriptor: desc)
            }
            guard let st = sceneTex else { return nil }
            sceneTarget = st
        } else {
            sceneTarget = target
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sceneTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(pipeline)

        let primaryIsFront = layout.primaryFront
        let canvasAspect = Float(width) / Float(height)
        // Primary fills the frame.
        drawFeed(enc, buffer: primary, isFront: primaryIsFront, mvp: matrix_identity_float4x4,
                 mirror: primaryIsFront && layout.mirrorFront, rounded: false,
                 quadPx: simd_float2(Float(width), Float(height)),
                 targetAspect: canvasAspect, radius: 0)

        if let secondary = secondary {
            let secondaryIsFront = !layout.primaryFront
            let rect = layout.pictureInPicture ? layout.insetRect : halfRect(layout)
            let mvp = mvpFor(rect: rect)
            let quadW = Float(rect.width) * Float(width)
            let quadH = Float(rect.height) * Float(height)
            drawFeed(enc, buffer: secondary, isFront: secondaryIsFront, mvp: mvp,
                     mirror: secondaryIsFront && layout.mirrorFront,
                     rounded: layout.pictureInPicture && layout.cornerRadiusPx > 0,
                     quadPx: simd_float2(quadW, quadH),
                     targetAspect: quadW / quadH, radius: layout.cornerRadiusPx)
        }

        enc.endEncoding()

        if grading {
            let gpass = MTLRenderPassDescriptor()
            gpass.colorAttachments[0].texture = target
            gpass.colorAttachments[0].loadAction = .clear
            gpass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            gpass.colorAttachments[0].storeAction = .store
            guard let genc = cmd.makeRenderCommandEncoder(descriptor: gpass) else { return nil }
            genc.setRenderPipelineState(gradePipeline)
            genc.setFragmentTexture(sceneTarget, index: 0)
            var gu = grade
            genc.setFragmentBytes(&gu, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            genc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            genc.endEncoding()
        }

        cmd.commit() // async — never waitUntilCompleted on the hot path (§9)
        return out
    }

    private func drawFeed(
        _ enc: MTLRenderCommandEncoder,
        buffer: CVPixelBuffer,
        isFront: Bool,
        mvp: simd_float4x4,
        mirror: Bool,
        rounded: Bool,
        quadPx: simd_float2,
        targetAspect: Float,
        radius: Float
    ) {
        guard let luma = metalTexture(from: buffer, plane: 0, format: .r8Unorm),
              let chroma = metalTexture(from: buffer, plane: 1, format: .rg8Unorm) else { return }
        enc.setFragmentTexture(luma, index: 0)
        enc.setFragmentTexture(chroma, index: 1)

        // Source aspect = the buffer's REAL landscape w/h (e.g. 4:3 -> 1.333),
        // unlike Android which sees the pre-rotated h/w. The rotation in
        // `texXform` is what stands it upright.
        let override = isFront ? frontAspectOverride : backAspectOverride
        let w = Float(CVPixelBufferGetWidth(buffer))
        let h = Float(CVPixelBufferGetHeight(buffer))
        let srcAspect = override > 0 ? override : (h > 0 ? w / h : 1)
        let rotationDeg = isFront ? frontRotationDeg : backRotationDeg

        var u = QuadUniforms(
            mvp: mvp, yuvMatrix: yuvMatrix, yuvOffset: yuvOffset,
            texXform: texXform(srcAspect: srcAspect, targetAspect: targetAspect, rotationDeg: rotationDeg),
            quadSizePx: quadPx, mirror: mirror ? 1 : 0, rounded: rounded ? 1 : 0,
            cornerRadiusPx: radius
        )
        enc.setVertexBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Column-major mat2 mapping target-rect normalized-centered coords to source
    /// normalized-centered coords: rotates the source upright by `rotationDeg`
    /// and cover-crops `srcAspect` into `targetAspect` without distortion. Direct
    /// port of Android `DualCompositor.texXform` (gl/DualCompositor.kt).
    private func texXform(srcAspect: Float, targetAspect: Float, rotationDeg: Int) -> simd_float2x2 {
        let s = srcAspect
        let t = targetAspect
        let rad = Float(rotationDeg) * .pi / 180
        let c = cos(rad)
        let sn = sin(rad)
        let rotHalfX = abs(c) * (s / 2) + abs(sn) * 0.5
        let rotHalfY = abs(sn) * (s / 2) + abs(c) * 0.5
        let kappa = max((t / 2) / rotHalfX, 0.5 / rotHalfY)
        let inv = 1 / kappa
        let m00 = inv * c * t / s
        let m01 = inv * sn / s
        let m10 = inv * (-sn) * t
        let m11 = inv * c
        // simd columns: col0 = (m00, m10), col1 = (m01, m11).
        return simd_float2x2(columns: (simd_float2(m00, m10), simd_float2(m01, m11)))
    }

    private func metalTexture(
        from buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat
    ) -> MTLTexture? {
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format, max(w, 1), max(h, 1), plane, &cvTex)
        guard status == kCVReturnSuccess, let cvTex = cvTex else { return nil }
        return CVMetalTextureGetTexture(cvTex)
    }

    /// Map a normalized rect (top-left origin) to an NDC scale+translate matrix.
    private func mvpFor(rect: CGRect) -> simd_float4x4 {
        let sx = Float(rect.width)
        let sy = Float(rect.height)
        let cx = Float(rect.midX) * 2 - 1
        let cy = 1 - Float(rect.midY) * 2
        var m = matrix_identity_float4x4
        m.columns.0 = simd_float4(sx, 0, 0, 0)
        m.columns.1 = simd_float4(0, sy, 0, 0)
        m.columns.3 = simd_float4(cx, cy, 0, 1)
        return m
    }

    private func halfRect(_ layout: CompositeLayout) -> CGRect {
        layout.splitVertical
            ? CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
            : CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    }
}
