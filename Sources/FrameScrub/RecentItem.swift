import CoreGraphics
import Foundation

/// A recently opened file on the start screen: its picture (if one was saved or made) and where it was left.
struct RecentItem {
    let url: URL
    var thumbnail: CGImage?
    /// Seconds; nil when no position is remembered.
    var position: Double?
    /// Seconds; nil until the file's length is known.
    var duration: Double?
    /// The file cannot be reached now (a share that is not mounted, a deleted file): the card shows faint.
    var isDimmed = false
}
