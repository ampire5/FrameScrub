import ExtensionFoundation
import ExtensionKit
import SwiftUI

@main
struct PlaybackExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "local.loupe", name: "Playback")
    }

    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(scene)
    }

    private var scene: some AppExtensionScene {
        let service = EnginePlayerService()
        return PrimitiveAppExtensionScene(id: sceneID) {
            EnginePlaybackView(service: service)
        } onConnection: { connection in
            connection.exportedInterface = NSXPCInterface(with: PlaybackService.self)
            connection.exportedObject = service
            connection.invalidationHandler = { service.close() }
            connection.interruptionHandler = { service.close() }
            connection.resume()
            return true
        }
    }
}
