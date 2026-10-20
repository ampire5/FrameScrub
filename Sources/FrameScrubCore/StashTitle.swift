import StashKit

/// The title the OSD shows for a scene Stash knows: `Title — Studio · 2024-05-01`.
public enum StashTitle {
    /// The title (or the file name, when Stash has none), then ` — studio` and ` · date` for whichever of them exist.
    public static func text(details: StashSceneDetails?, fileName: String) -> String {
        guard let details else { return fileName }
        var text = details.title ?? fileName
        if let studio = details.studio { text += " — " + studio }
        if let date = details.date { text += " · " + date }
        return text
    }
}
