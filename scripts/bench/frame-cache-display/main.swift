import AppKit
import CoreImage
import Darwin
import IOSurface
import Metal
import QuartzCore

private let mebibyte = 1 << 20

private func footprint() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.stride)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    return Int(info.phys_footprint)
}

private struct Sample {
    let forward: Bool
    let requestedAt: CFTimeInterval
    var cpuMilliseconds: Double = 0
    var restoreCPU: Double = 0
    var presentedAt: CFTimeInterval?
    var gpuMilliseconds: Double?
    var completedAt: CFTimeInterval?
}

@MainActor
private final class DisplayBench {
    enum Output {
        case screen(NSWindow, CAMetalLayer)
        case textures([MTLTexture])
    }

    let output: Output
    var offscreen: Bool {
        if case .textures = output { return true }
        return false
    }
    let queue: MTLCommandQueue
    let context: CIContext
    let color = CGColorSpace(name: CGColorSpace.sRGB)!
    let size = CGSize(width: 1280, height: 720)
    let cache = FrameCache(budgetBytes: 256 * mebibyte)
    let rate: Double
    var timer: DispatchSourceTimer?
    var samples: [Sample] = []
    var nextStep = 0
    var availableSlots = [1, 0]
    var inFlight: Int { 2 - availableSlots.count }
#if NV12_CODECS
    var nv12Source: NV12DisplaySource?
#endif
    var pendingPresentations = 0
    var occludedSteps = 0
    var skippedPool = 0
    var skippedDrawable = 0
    var outputIndex = 0

    init(rate: Double, offscreen: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw BenchError("A Metal GPU is required")
        }
        self.rate = rate
        self.queue = queue
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        if offscreen {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1280,
                                                                       height: 720, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let first = device.makeTexture(descriptor: descriptor),
                  let second = device.makeTexture(descriptor: descriptor) else {
                throw BenchError("Could not allocate benchmark target textures")
            }
            output = .textures([first, second])
            print("gpu=\(device.name) unified=\(device.hasUnifiedMemory) offscreen=1280x720")
            return
        }
        guard let screen = NSScreen.main else { throw BenchError("An onscreen display is required") }
        let bounds = CGRect(origin: .zero, size: size)
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = color
        layer.framebufferOnly = false
        layer.drawableSize = size
        layer.displaySyncEnabled = true
        layer.maximumDrawableCount = 3
        let points = CGRect(origin: .zero,
                            size: CGSize(width: size.width / screen.backingScaleFactor,
                                         height: size.height / screen.backingScaleFactor))
        let window = NSWindow(contentRect: points, styleMask: [.titled], backing: .buffered, defer: false)
        output = .screen(window, layer)
        window.title = "Frame cache display benchmark"
        let view = NSView(frame: points)
        view.wantsLayer = true
        view.layer = layer
        layer.frame = CGRect(origin: .zero, size: points.size)
        layer.contentsScale = screen.backingScaleFactor
        layer.drawableSize = bounds.size
        window.contentView = view
        window.center()
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        print("gpu=\(device.name) unified=\(device.hasUnifiedMemory) display_max_hz=\(screen.maximumFramesPerSecond) drawable=1280x720")
    }

    private func nextTarget() -> (MTLTexture, CAMetalDrawable?)? {
        switch output {
        case let .screen(_, layer):
            return layer.nextDrawable().map { ($0.texture, $0) }
        case let .textures(textures):
            let texture = textures[outputIndex]
            outputIndex = (outputIndex + 1) % textures.count
            return (texture, nil)
        }
    }

    private var visible: Bool {
        if case let .screen(window, _) = output { return window.occlusionState.contains(.visible) }
        return true
    }

    private func encode(_ buffer: CVPixelBuffer, to texture: MTLTexture, command: MTLCommandBuffer) {
        let image = CIImage(cvPixelBuffer: buffer)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: size.width / image.extent.width,
                                                              y: size.height / image.extent.height))
        context.render(scaled, to: texture, commandBuffer: command,
                       bounds: CGRect(origin: .zero, size: size), colorSpace: color)
    }

    private func warm(_ buffer: CVPixelBuffer) async throws {
        guard let (texture, drawable) = nextTarget(), let command = queue.makeCommandBuffer() else {
            throw BenchError("Could not acquire warmup target")
        }
        encode(buffer, to: texture, command: command)
        if let drawable { command.present(drawable) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                if let error = completed.error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            command.commit()
        }
    }

    func warmRenderer(format: OSType = p010Format) async throws {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                          kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, 3840, 2160, format, attributes, &pixelBuffer) == 0,
              let pixelBuffer else { throw BenchError("Could not allocate warmup frame") }
        guard visible else { throw BenchError("Benchmark window is occluded; the display must be unlocked and visible") }
        for _ in 0..<4 { try await warm(pixelBuffer) }
    }

    func fill(url: URL, format: OSType) async throws {
        let baseline = footprint()
        let frames = try await decode(url, format: format, packets: 20)
        var ids = Set<IOSurfaceID>()
        for (pts, pixelBuffer) in frames {
            guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
                throw BenchError("Decoder returned a buffer without IOSurface")
            }
            guard ids.insert(IOSurfaceGetID(surface)).inserted else { throw BenchError("Repeated IOSurface ID") }
            let bytes = IOSurfaceGetAllocSize(surface)
            guard cache.usedBytes + bytes <= cache.budgetBytes else { break }
            cache.insert(DecodedFrame(number: cache.count, pts: pts.value, pixelBuffer: pixelBuffer,
                                      dynamicRange: .sdr, byteSize: bytes))
        }
        guard cache.count >= 8, cache.count < frames.count,
              let frame = cache.frame(0) else { throw BenchError("Could not fill 256 MiB budget or trace window") }
        print(String(format: "cache_frames=%d surface_bytes_per_frame=%d cache_surfaces_MiB=%.3f",
                     cache.count, frame.byteSize, Double(cache.usedBytes) / Double(mebibyte)))
        // The retained frame allocation is reported separately since the decoder service can own it.
        print(String(format: "app_footprint_delta_fill_MiB=%.3f",
                     Double(footprint() - baseline) / Double(mebibyte)))
    }

    private func warmupBuffer(_ number: Int) async -> CVPixelBuffer? {
#if NV12_CODECS
        if let nv12Source {
            return await withCheckedContinuation { continuation in
                nv12Source.fetch(number, slot: 0) { lease, _ in continuation.resume(returning: lease?.buffer) }
            }
        }
#endif
        return cache.frame(number)?.pixelBuffer
    }

    func run() async throws {
        // Warm this format's Core Image pipeline before starting the identical trace.
        for n in 0..<8 {
            let buffer = await warmupBuffer(n)
            guard let buffer else { throw BenchError("Format warmup failed") }
            try await warm(buffer)
        }
        if !offscreen { try await Task.sleep(nanoseconds: 50_000_000) }

        let count = 26 * 14
        samples.reserveCapacity(count)
        let processStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let wallStart = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int((1e9 / rate).rounded())),
                       leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.step(count: count) }
        timer.resume()
        while nextStep < count {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let processEnd = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
        let wallEnd = CACurrentMediaTime()
        var grace = 20
        while (inFlight > 0 || pendingPresentations > 0) && grace > 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
            grace -= 1
        }
        guard occludedSteps == 0 else { throw BenchError("Benchmark window occluded during \(occludedSteps) steps") }
        try report(forward: true)
        try report(forward: false)
        print(String(format: "endpoint=%@ app_process_cpu_pct=%.3f pool_skips=%d drawable_skips=%d window_occlusion=%d effective_hz=%.3f",
                     offscreen ? "gpu_complete" : "presented", Double(processEnd - processStart) / 1e7 / (wallEnd - wallStart),
                     skippedPool, skippedDrawable, occludedSteps, Double(count) / (wallEnd - wallStart)))
    }

    private func step(count: Int) {
        guard nextStep < count else { return }
        let slot = nextStep % 14
        nextStep += 1
        if nextStep == count { timer?.cancel() }
        let forward = slot < 7
        let number = forward ? slot + 1 : 13 - slot
        guard visible else { occludedSteps += 1; return }
        let requestedAt = CACurrentMediaTime()
        let index = samples.count
        samples.append(Sample(forward: forward, requestedAt: requestedAt))
        guard let outputSlot = availableSlots.popLast() else { skippedPool += 1; return }
#if NV12_CODECS
        if let nv12Source {
            nv12Source.fetch(number, slot: outputSlot) { [weak self] lease, restoreCPU in
                DispatchQueue.main.async {
                    self?.samples[index].restoreCPU = restoreCPU
                    self?.submit(lease?.buffer, at: index, outputSlot: outputSlot)
                }
            }
            return
        }
#endif
        submit(cache.frame(number)?.pixelBuffer, at: index, outputSlot: outputSlot)
    }

    private func submit(_ pixelBuffer: CVPixelBuffer?, at index: Int, outputSlot: Int) {
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        guard let pixelBuffer, let (texture, drawable) = nextTarget(),
              let command = queue.makeCommandBuffer() else {
            skippedDrawable += 1
            availableSlots.append(outputSlot)
            return
        }
        encode(pixelBuffer, to: texture, command: command)
        if let drawable {
            pendingPresentations += 1
            drawable.addPresentedHandler { [weak self] drawable in
                let time = drawable.presentedTime
                DispatchQueue.main.async {
                    self?.samples[index].presentedAt = time
                    self?.pendingPresentations -= 1
                }
            }
        }
        command.addCompletedHandler { [weak self] command in
            let completedAt = CACurrentMediaTime()
            let duration = (command.gpuEndTime - command.gpuStartTime) * 1_000
            DispatchQueue.main.async {
                if command.status == .completed {
                    self?.samples[index].gpuMilliseconds = duration
                    self?.samples[index].completedAt = completedAt
                }
                self?.availableSlots.append(outputSlot)
            }
        }
        if let drawable { command.present(drawable) }
        command.commit()
        samples[index].cpuMilliseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6
    }

    private func report(forward: Bool) throws {
        let selected = samples.filter { $0.forward == forward }
        let presented = selected.compactMap { sample -> Double? in
            guard let time = offscreen ? sample.completedAt : sample.presentedAt, time >= sample.requestedAt else { return nil }
            return (time - sample.requestedAt) * 1_000
        }.sorted()
        guard presented.count >= 160 else { throw BenchError("Too few samples at measured endpoint: \(presented.count)") }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            values[Int(ceil(Double(values.count) * fraction)) - 1]
        }
        let gpu = selected.compactMap(\.gpuMilliseconds).sorted()
        guard !gpu.isEmpty else { throw BenchError("Missing GPU timing") }
        let cpu = selected.reduce(0) { $0 + $1.cpuMilliseconds } / Double(selected.count)
        let restoreCPU = selected.reduce(0) { $0 + $1.restoreCPU } / Double(selected.count)
        print(String(format: "%@ n=%d observed=%d dropped=%d p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f main_cpu_ms=%.3f main_core_pct=%.3f gpu_p95_ms=%.3f restore_cpu_ms=%.3f",
                     forward ? "forward" : "backward", selected.count, presented.count,
                     selected.count - presented.count, percentile(presented, 0.5),
                     percentile(presented, 0.95), percentile(presented, 0.99),
                     cpu, cpu * rate / 10, percentile(gpu, 0.95), restoreCPU))
    }
}

@main
private enum Main {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard (3...5).contains(args.count) else { fail("Usage: frame-cache-display probe|x420|packed Jellyfish.mp4 [request Hz] [--offscreen]") }
        let url = URL(fileURLWithPath: args[2])
        if args[1] == "probe" {
            Task { @MainActor in
                do {
                    print("supported &xv0=\(CVIsCompressedPixelFormatAvailable(packedFormat))")
                    let standard = try await decode(url, format: p010Format, packets: 16)
                    let packed = try await decode(url, format: packedFormat, packets: 16)
                    guard standard.count >= 16, standard.count == packed.count else {
                        throw BenchError("Incomplete probe")
                    }
                    let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.cacheIntermediates: false])
                    for index in [0, 6, 12] {
                        guard standard[index].0 == packed[index].0 else { throw BenchError("Mismatched PTS") }
                        try checkRendering(reference: standard[index].1, packed: packed[index].1, context: context)
                    }
                    print("render=rgba16f verified_frames=3 decoder_frames=\(standard.count) x420_surface_bytes=\(surfaceSize(standard[0].1)) packed_surface_bytes=\(surfaceSize(packed[0].1))")
                    do {
                        try checkExactSamples(reference: standard[0].1, packed: packed[0].1)
                        print("pixel_transfer=exact")
                    } catch {
                        print("pixel_transfer_diagnostic=\(error.localizedDescription)")
                    }
                    exit(0)
                } catch { fail(error.localizedDescription) }
            }
            dispatchMain()
        }
        let offscreen = args.last == "--offscreen"
        let settings = args.dropFirst(3).filter { $0 != "--offscreen" }
        guard settings.count <= 1, let rate = Double(settings.first ?? "60"),
              (24...120).contains(rate) else { fail("Invalid display request rate") }
        let format = args[1] == "packed" ? packedFormat : p010Format
#if NV12_CODECS
        let mixed = args[1].hasPrefix("nv12-mixed-")
        let prefix = mixed ? "nv12-mixed-" : "nv12-"
        let nv12Mode = args[1].hasPrefix(prefix) ? Mode(rawValue: String(args[1].dropFirst(prefix.count))) : nil
        guard ["x420", "packed"].contains(args[1]) || (nv12Mode?.supports(depth: 8) ?? false) else {
            fail("Invalid display mode")
        }
#else
        guard ["x420", "packed"].contains(args[1]) else { fail("Invalid display mode") }
#endif
        if !offscreen {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.finishLaunching()
        }
        Task { @MainActor in
            do {
                let bench = try DisplayBench(rate: rate, offscreen: offscreen)
                try await Task.sleep(nanoseconds: 500_000_000)
#if NV12_CODECS
                if let nv12Mode {
                    try await bench.warmRenderer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                    let baseline = footprint()
                    bench.nv12Source = try await Task.detached(priority: .utility) {
                        try NV12DisplaySource(url: url, mode: nv12Mode, mixed: mixed)
                    }.value
                    print(String(format: "app_footprint_delta_fill_MiB=%.3f",
                                 Double(footprint() - baseline) / Double(mebibyte)))
                } else {
                    try await bench.warmRenderer()
                    try await bench.fill(url: url, format: format)
                }
#else
                try await bench.warmRenderer()
                try await bench.fill(url: url, format: format)
#endif
                try await bench.run()
                exit(0)
            } catch { fail(error.localizedDescription) }
        }
        if offscreen { dispatchMain() }
        NSApplication.shared.run()
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
