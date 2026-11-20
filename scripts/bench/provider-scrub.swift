import AppKit
import Combine
import QuartzCore

@main struct ScrubBench {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments.filter { $0 != "--assert" }
        let target = Double(args[2])!
        let rounds = args.count > 3 ? Int(args[3])! : 3
        let frameRate = args.count > 4 ? Double(args[4])! : 30
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: args[1]))
        let service = EnginePlayerService()
        let view = PictureView()
        let subscription = service.$image.dropFirst().sink { image in
            guard let image else { return }
            let time = service.position
            DispatchQueue.main.async {
                let media = service.mediaID, frame = service.submission
                if view.show(image, mediaID: media, submission: frame) {
                    service.didSubmit(media: media, frame: frame, time: time)
                }
            }
        }
        let status = await withCheckedContinuation { c in service.open(file) { c.resume(returning: $0) } }
        guard status == "ready" else { fatalError(status) }
        var overBudget = 0
        for round in 1...rounds {
            let seekStart = CACurrentMediaTime()
            let seek = await withCheckedContinuation { c in service.seek(target) { c.resume(returning: $0) } }
            guard seek.hasPrefix("FrameScrub time=") else { fatalError(seek) }
            let seekWall = CACurrentMediaTime() - seekStart
            let start = service.position
            var wall: [Double] = []
            for step in Array(repeating: -1, count: 20) + Array(repeating: 1, count: 20) + Array(repeating: -1, count: 20) {
                let current = service.position
                let begin = CACurrentMediaTime()
                let reply = await withCheckedContinuation { c in service.step(step) { c.resume(returning: $0) } }
                wall.append((CACurrentMediaTime() - begin) * 1000)
                guard reply.hasPrefix("FrameScrub time="),
                      abs((service.position - current) - Double(step) / frameRate) < 1e-6 else { fatalError(reply) }
            }
            let sorted = wall.sorted()
            let exceeded = wall.filter { $0 > 50 }.count
            overBudget += exceeded
            print(String(format: "round %d: anchor=%.3f seek=%.2f ms steps=%d over50ms=%d p50=%.2f ms p95=%.2f ms max=%.2f ms",
                         round, start, seekWall * 1000, wall.count, exceeded, sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted.last!))
        }
        service.close()
        _ = subscription
        if CommandLine.arguments.contains("--assert") && overBudget > rounds * 4 { exit(1) }
    }
}
