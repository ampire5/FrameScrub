import Foundation
import FrameScrubCore
import Testing

@MainActor @Suite struct FolderFavoritesTests {
    @Test func keepsUniquePathsAndManualOrderAcrossReload() throws {
        let suite = "framescrub-favorites-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = FolderFavorites(defaults: defaults)
        let first = folder("/Volumes/Offline/Clips")
        let second = folder("/tmp/Clips")
        let third = folder("/tmp/Clips/Nested")
        favorites.add(first)
        favorites.add(second)
        favorites.add(third)
        favorites.add(folder("/tmp/Clips/../Clips"))
        favorites.move(third, before: first)
        favorites.move(first, before: nil)
        let reopened = FolderFavorites(defaults: defaults)
        #expect(reopened.folders.map(\.path) == ["/tmp/Clips/Nested", "/tmp/Clips", "/Volumes/Offline/Clips"])
    }

    @Test func renameFollowsDescendantsAndRemovesDuplicateDestination() throws {
        let suite = "framescrub-favorites-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = FolderFavorites(defaults: defaults)
        for path in ["/tmp/Before/Child", "/tmp/BeforeElse", "/tmp/After/Child", "/tmp/Before"] {
            favorites.add(folder(path))
        }
        favorites.rename(folder("/tmp/Before"), to: folder("/tmp/After"))
        #expect(favorites.folders.map(\.path) == ["/tmp/After/Child", "/tmp/BeforeElse", "/tmp/After"])
        favorites.remove(folder("/tmp/After/Child"))
        #expect(FolderFavorites(defaults: defaults).folders.map(\.path) == ["/tmp/BeforeElse", "/tmp/After"])
    }

    @Test func renameKeepsTheSourcePositionWhenDestinationWasAlreadySaved() throws {
        let suite = "framescrub-favorites-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = FolderFavorites(defaults: defaults)
        let source = folder("/tmp/Source")
        let destination = folder("/tmp/Destination")
        favorites.add(destination)
        favorites.add(folder("/tmp/Other"))
        favorites.add(source)
        favorites.rename(source, to: destination)
        #expect(favorites.folders.map(\.path) == ["/tmp/Other", "/tmp/Destination"])
    }

    private func folder(_ path: String) -> URL { URL(filePath: path, directoryHint: .isDirectory) }
}
