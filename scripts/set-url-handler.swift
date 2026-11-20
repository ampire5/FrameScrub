import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/set-url-handler.swift /path/to/FrameScrub.app\n", stderr)
    exit(2)
}

let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
let workspace = NSWorkspace.shared
let link = URL(string: "framescrub://open")!

func handlesLinks() -> Bool {
    workspace.urlForApplication(toOpen: link)?.standardizedFileURL.path == app.path
}

do {
    if !handlesLinks() {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.setDefaultApplication(at: app, toOpenURLsWithScheme: "framescrub") { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
    guard handlesLinks() else {
        fputs("macOS selected a different handler for framescrub://.\n", stderr)
        exit(1)
    }
    print("framescrub:// opens \(app.path)")
} catch {
    fputs("Could not set the framescrub:// handler: \(error.localizedDescription)\n", stderr)
    exit(1)
}
