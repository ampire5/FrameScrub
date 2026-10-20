import CoreGraphics

/// The player window's content size in points (spec §8).
public enum WindowSizing {
    public enum Request: Equatable, Sendable {
        case initial          // opening a file: 100 % when it fits, else 85 % of the screen; never enlarged
        case scale(Double)    // 1 = one video pixel per physical pixel
        case fitScreen        // as large as the screen allows
        case keepHeight(Double)   // the picture changed shape: same content height in points, fitted when too wide
    }

    public struct Result: Equatable, Sendable {
        public var size: CGSize
        /// Set when the window had to be fitted: its size as a percentage of 100 %.
        public var fittedPercent: Int?
    }

    public static let initialFraction = 0.85

    /// `video` is the upright size in pixels, `available` the usable content area in points.
    public static func contentSize(for request: Request, video: CGSize, backingScale: Double, available: CGSize) -> Result {
        let natural = CGSize(width: video.width / backingScale, height: video.height / backingScale)
        func sized(_ factor: Double) -> CGSize {
            CGSize(width: (natural.width * factor).rounded(), height: (natural.height * factor).rounded())
        }
        switch request {
        case .initial:
            let fits = natural.width <= available.width && natural.height <= available.height
            let factor = fits ? 1 : min(initialFraction * available.width / natural.width,
                                        initialFraction * available.height / natural.height)
            return Result(size: sized(factor), fittedPercent: nil)
        case let .scale(wanted):
            let fit = min(1, available.width / (natural.width * wanted), available.height / (natural.height * wanted))
            return Result(size: sized(wanted * fit), fittedPercent: fit < 1 ? Int((wanted * fit * 100).rounded()) : nil)
        case let .keepHeight(height):
            let width = height * video.width / video.height
            let fit = min(1, available.width / width, available.height / height)
            return Result(size: CGSize(width: (width * fit).rounded(), height: (height * fit).rounded()), fittedPercent: nil)
        case .fitScreen:
            let factor = min(available.width / natural.width, available.height / natural.height)
            return Result(size: sized(factor), fittedPercent: Int((factor * 100).rounded()))
        }
    }
}

/// Where the player window goes (backlog item 2): centred on the remembered point and kept on the screen
/// that contains it; the middle of the main screen when there is no such screen. All rects in screen points.
public enum WindowPlacement {
    public static func origin(size: CGSize, center: CGPoint?, screens: [CGRect], main: CGRect) -> CGPoint {
        guard let center, let screen = screens.first(where: { $0.contains(center) }) else {
            return CGPoint(x: (main.midX - size.width / 2).rounded(), y: (main.midY - size.height / 2).rounded())
        }
        // Too large for the screen: keep the top-left corner (title bar) visible.
        let x = size.width > screen.width ? screen.minX : min(max(center.x - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = size.height > screen.height ? screen.maxY - size.height
            : min(max(center.y - size.height / 2, screen.minY), screen.maxY - size.height)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// The window frame at launch: the remembered one on the screen that holds its centre, cut down to that screen
    /// if it no longer fits; without one (or with its screen gone) `fallbackSize` in the middle of the main screen.
    public static func frame(saved: CGRect?, fallbackSize: CGSize, screens: [CGRect], main: CGRect) -> CGRect {
        guard let saved, let screen = screens.first(where: { $0.contains(CGPoint(x: saved.midX, y: saved.midY)) }) else {
            let size = saved?.size ?? fallbackSize
            let fitted = CGSize(width: min(size.width, main.width), height: min(size.height, main.height))
            return CGRect(origin: origin(size: fitted, center: nil, screens: screens, main: main), size: fitted)
        }
        let size = CGSize(width: min(saved.width, screen.width), height: min(saved.height, screen.height))
        let center = CGPoint(x: saved.midX, y: saved.midY)
        return CGRect(origin: origin(size: size, center: center, screens: [screen], main: main), size: size)
    }
}
