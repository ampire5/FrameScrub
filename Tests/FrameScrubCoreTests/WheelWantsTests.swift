import LogiHIDPP
import Testing
@testable import FrameScrubCore

@Suite struct WheelWantsTests {
    @Test func outsideThePlayerNothingIsWanted() {
        for precision in [false, true] {
            for freeSpin in [false, true] {
                for overVideo in [false, true] {
                    let wants = WheelWants(precision: precision, freeSpin: freeSpin, playerInFront: false, overVideo: overVideo)
                    #expect(wants.wheelMode == nil)
                    #expect(wants.highResolution == false)
                }
            }
        }
    }

    @Test func freeSpinGivesPrecisionScrollOverTheVideoOnly() {
        let over = WheelWants(precision: true, freeSpin: true, playerInFront: true, overVideo: true)
        #expect(over.wheelMode == .freeSpin)
        #expect(over.highResolution == true)
        let elsewhere = WheelWants(precision: true, freeSpin: true, playerInFront: true, overVideo: false)
        #expect(elsewhere.wheelMode == .freeSpin)
        #expect(elsewhere.highResolution == false)
    }

    @Test func ratchetNeverGivesPrecisionScroll() {
        for overVideo in [false, true] {
            let wants = WheelWants(precision: true, freeSpin: false, playerInFront: true, overVideo: overVideo)
            #expect(wants.wheelMode == .ratchet)
            #expect(wants.highResolution == false)
        }
    }

    @Test func wheelPrecisionNoTurnsBothOff() {
        for freeSpin in [false, true] {
            for overVideo in [false, true] {
                let wants = WheelWants(precision: false, freeSpin: freeSpin, playerInFront: true, overVideo: overVideo)
                #expect(wants.wheelMode == nil)
                #expect(wants.highResolution == false)
            }
        }
    }
}
