import Foundation
import Testing
@testable import FrameScrubCore

/// FrameScrub's zoom: never below Fit, up to `ceiling`, with Fill and 100 % as stops.
private func video(_ picture: CGSize = CGSize(width: 1920, height: 1080),
                   view: CGSize = CGSize(width: 2880, height: 1800)) -> ViewTransform {
    var t = ViewTransform(imageSize: picture, viewSize: view)
    t.floorAtFit = true
    t.ceiling = 32
    t.offCentre = true
    return t
}

@Test func theLowerLimitIsFit() {
    let t = video()
    #expect(t.scaleLimits == t.fitScale...32)
    #expect(t.zoomed(toScale: t.fitScale / 4, anchor: .zero).scale == t.fitScale)
    #expect(t.zoomedStep(-3).scale == t.fitScale)
}

@Test func aTinyVideoAboveTheCeilingStaysAtFit() {
    let t = video(CGSize(width: 64, height: 36))
    #expect(t.fitScale == 45 && t.scaleLimits == 45...45 && t.zoomedStep(2).scale == 45)
}

@Test func everyOperationKeepsTheFloorAndCeiling() {
    let t = video()
    let a = CGPoint(x: 300, y: 200)
    for u in [t.zoomed(toScale: 3, anchor: a), t.panned(by: CGVector(dx: 5, dy: 5)), t.withMode(.fill),
              t.withImageSize(CGSize(width: 100, height: 100)), t.withViewSize(CGSize(width: 10, height: 10)),
              t.withStretch(ZoomStretch(factor: 1.1, anchor: a)), t.reoriented(to: CGSize(width: 1080, height: 1920))] {
        #expect(u.floorAtFit && u.ceiling == 32)
    }
}

@Test func aPinchInAtFitStretchesAndComesBackToFit() {
    let t = video()
    var g = ZoomStopGesture(transform: t, stops: [.fill, .percent(100)], rubber: true)
    let r = g.constrain(t.fitScale * 0.7)
    #expect(r.scale == t.fitScale && g.stretch < 1 && g.stretch > 1 / RubberBand.zoomMaxFactor)
}

@Test func aPinchOutHaltsAtFillThenAt100() {
    // 16:9 in 16:10: Fill is 1800 / 1080 = 1.667 > Fit 1.5; 100 % is below Fit and dropped.
    let t = video()
    let fill = t.withMode(.fill).scale
    #expect(ZoomStops.scales(of: [.fill, .percent(100)], for: t).map(\.stop) == [.fill])
    var g = ZoomStopGesture(transform: t, stops: [.fill, .percent(100)], rubber: true)
    #expect(g.constrain(fill * 1.2).hitStop == .fill)
    // A 720p video in the same view: 100 % is below Fit, Fill is the only stop; a 4K one has both above...
    let k4 = video(CGSize(width: 3840, height: 2160))
    #expect(ZoomStops.scales(of: [.fill, .percent(100)], for: k4).map(\.stop) == [.fill, .percent(100)])
}

@Test func theZoomedPictureCanBeDraggedAndItsCentreIsKeptInside() {
    let t = video().zoomed(toScale: 3, anchor: CGPoint(x: 1440, y: 900))
    #expect(t.canPan)
    let far = t.panned(by: CGVector(dx: 100_000, dy: -100_000))
    #expect(far.visibleRect.minX == 0 && abs(far.visibleRect.maxY - 1080) < 1e-6)
}
