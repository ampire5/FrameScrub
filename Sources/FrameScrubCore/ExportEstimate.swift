import CoreGraphics
import Foundation

/// A rough time for the neural network part of an export (the Export sheet shows it).
public enum ExportEstimate {
    /// Seconds per megapixel of source per frame. Measured on one Mac (8 frames x4 of 1080p in 6.6 s, decoding included).
    public static let secondsPerMegapixel = 0.4

    /// Nil when the network is not used for this export.
    public static func mlSeconds(frames: Int, source: CGSize, output: OutputSize, screen: CGSize?,
                                 upscaler: Upscaler, hdr: Bool) -> Double? {
        guard frames > 0, upscaler == .ml, !hdr,
              MLUpscaler.fits(width: Int(source.width.rounded()), height: Int(source.height.rounded())),
              let target = output.targetSize(source: source, screen: screen),
              target.width / source.width >= FrameUpscaler.minimumNetworkRatio else { return nil }
        return Double(frames) * source.width * source.height / 1_000_000 * secondsPerMegapixel
    }

    public static func text(seconds: Double) -> String {
        if seconds < 1 { return "under 1 s" }
        if seconds < 59.5 { return "about \(Int(seconds.rounded())) s" }
        if seconds < 3570 { return "about \(Int((seconds / 60).rounded())) min" }
        return "about \(Int((seconds / 3600).rounded())) h"
    }
}
