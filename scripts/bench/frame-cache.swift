import CoreVideo
import Darwin
import Foundation
import IOSurface

private let mib = 1 << 20

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

private func surfaceBytes(_ buffer: CVPixelBuffer) -> Int {
    IOSurfaceGetAllocSize(CVPixelBufferGetIOSurface(buffer)!.takeUnretainedValue())
}

private struct Distribution {
    var wall: [Double] = []
    var cpu: [Double] = []
    var late = 0

    func summary(at rate: Double) -> String {
        let sorted = wall.sorted()
        func percentile(_ p: Double) -> Double { sorted[Int(ceil(p * Double(sorted.count))) - 1] }
        let cpuMean = cpu.reduce(0, +) / Double(cpu.count)
        return String(format: "n=%d p50_ms=%.6f p95_ms=%.6f p99_ms=%.6f cpu_ms=%.6f core_pct=%.3f late=%d",
                      cpu.count, percentile(0.50), percentile(0.95), percentile(0.99),
                      cpuMean, rate * cpuMean / 10, late)
    }
}

private func nanos(_ clock: clockid_t) -> UInt64 { clock_gettime_nsec_np(clock) }

private func measure(windows: Int, frames: Int, access: (Int) -> CVPixelBuffer) {
    // Identical local ping-pong, alternating direction at each end. Pace absolute deadlines.
    let rate = 60.0
    let period = UInt64(1e9 / rate)
    var forward = Distribution()
    var backward = Distribution()
    let start = nanos(CLOCK_UPTIME_RAW)
    var index: UInt64 = 0
    var checksum = 0
    for _ in 0..<windows {
        for step in 0..<(2 * (frames - 1)) {
            let ascending = step < frames - 1
            let target = ascending ? step + 1 : 2 * (frames - 1) - step - 1
            let deadline = start + index * period
            let before = nanos(CLOCK_UPTIME_RAW)
            if deadline > before { usleep(useconds_t((deadline - before) / 1000)) }
            let wallStart = nanos(CLOCK_UPTIME_RAW)
            let cpuStart = nanos(CLOCK_THREAD_CPUTIME_ID)
            let buffer = access(target)
            checksum += CVPixelBufferGetWidth(buffer)
            let cpuEnd = nanos(CLOCK_THREAD_CPUTIME_ID)
            let wallEnd = nanos(CLOCK_UPTIME_RAW)
            let wall = Double(wallEnd - wallStart) / 1e6
            let cpu = Double(cpuEnd - cpuStart) / 1e6
            if ascending {
                forward.wall.append(wall)
                forward.cpu.append(cpu)
                if wallEnd > deadline + period { forward.late += 1 }
            } else {
                backward.wall.append(wall)
                backward.cpu.append(cpu)
                if wallEnd > deadline + period { backward.late += 1 }
            }
            index += 1
        }
    }
    print("forward \(forward.summary(at: rate))")
    print("backward \(backward.summary(at: rate))")
    precondition(checksum > 0)
}

@main
private enum FrameCacheBench {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard (6...7).contains(args.count), let mode = Mode(rawValue: args[0]),
              let width = Int(args[1]), (4...8192).contains(width), width.isMultiple(of: 4),
              let height = Int(args[2]), (2...4320).contains(height), height.isMultiple(of: 2),
              let depth = Int(args[3]), [8, 10].contains(depth),
              let budgetMiB = Int(args[4]), (32...512).contains(budgetMiB),
              let frames = Int(args[5]), (2...64).contains(frames),
              let windows = Int(args.dropFirst(6).first ?? "26"), (1...100).contains(windows),
              mode.supports(depth: depth) else {
            fatalError("Usage: frame-cache \(Mode.allCases.map(\.rawValue).joined(separator: "|")) WIDTH HEIGHT 8|10 BUDGET_MiB TRACE_FRAMES [WINDOWS] < rawvideo")
        }

        let format = Format(width: width, height: height, tenBit: depth == 10)
        let codec = Codec(format: format, mode: mode)
        let budget = budgetMiB * mib
        let input = malloc(format.frameBytes)!
        let scratch = malloc(format.frameBytes)!
        let workBytes = codec.workBufferSize
        let work = malloc(workBytes)!
        precondition(fread(input, 1, format.frameBytes, stdin) == format.frameBytes, "No complete input frame")
        memset(scratch, 0, format.frameBytes)
        memset(work, 0, workBytes)
        defer { free(input); free(scratch); free(work) }

        // Warm the system codecs and IOSurface once before taking the cache-only footprint baseline.
        autoreleasepool {
            let warmup = format.makeBuffer()
            format.copy(input, to: warmup)
            if mode != .current {
                let payload = codec.encode(input, into: scratch, work: work)
                codec.restore(payload, to: warmup, scratch: scratch, work: work)
                format.verify(warmup, against: input)
            }
        }

        let cache = FrameCache(budgetBytes: budget)
        var payloads: [Payload] = []
        let baseline = footprint()
        let output = mode == .current ? nil : format.makeBuffer()
        if let output { format.copy(input, to: output) }
        var used = output.map(surfaceBytes) ?? 0
        // The fallback for padded surface rows needs a reusable Y-sized decode buffer.
        // The fill scratch already serves this role and is reserved in every mode.
        var count = 0
        var inputFrames = 0
        var encodeCPU: UInt64 = 0
        var full = false
        repeat {
            inputFrames += 1
            if !full {
                autoreleasepool {
                    if let output {
                        let start = nanos(CLOCK_THREAD_CPUTIME_ID)
                        let payload = codec.encode(input, into: scratch, work: work)
                        let elapsed = nanos(CLOCK_THREAD_CPUTIME_ID) - start
                        let bytes = payload.allocation
                        guard used + bytes <= budget else { full = true; return }
                        codec.restore(payload, to: output, scratch: scratch, work: work)
                        format.verify(output, against: input)
                        payloads.append(payload)
                        used += bytes
                        encodeCPU += elapsed
                    } else {
                        let buffer = format.makeBuffer()
                        let bytes = surfaceBytes(buffer)
                        guard used + bytes <= budget else { full = true; return }
                        format.copy(input, to: buffer)
                        cache.insert(DecodedFrame(number: count, pts: Int64(count), pixelBuffer: buffer,
                                                  dynamicRange: .sdr, byteSize: bytes))
                        used += bytes
                    }
                    count += 1
                }
            }
            // When at capacity, read only enough to prove coverage for the wider trace.
            if full && inputFrames >= 32 { break }
        } while fread(input, 1, format.frameBytes, stdin) == format.frameBytes

        precondition(count >= frames, "Trace exceeds the number of retained frames")
        precondition(mode != .current || cache.count == count)
        print(String(format: "mode=%@ frames=%d full=%@ charged_MiB=%.2f footprint_delta_MiB=%.2f wide=%d/%d encode_cpu_ms=%.3f",
                     mode.rawValue, count, full ? "yes" : "no", Double(used) / Double(mib),
                     Double(footprint() - baseline) / Double(mib), min(32, count), min(32, inputFrames),
                     Double(encodeCPU) / Double(count) / 1e6))
        measure(windows: windows, frames: frames) { number in
            if let output {
                codec.restore(payloads[number], to: output, scratch: scratch, work: work)
                return output
            }
            return cache.frame(number)!.pixelBuffer
        }
    }
}
