import Testing
@testable import EPUBUI

@Suite struct TapZonesTests {
    @Test func defaultZonesSplitAQuarterHalfQuarter() {
        let zones = TapZones.default
        #expect(zones.zone(forX: 10, width: 400) == .leading)
        #expect(zones.zone(forX: 99, width: 400) == .leading)
        #expect(zones.zone(forX: 100, width: 400) == .center)
        #expect(zones.zone(forX: 299, width: 400) == .center)
        #expect(zones.zone(forX: 300, width: 400) == .trailing)
        #expect(zones.zone(forX: 399, width: 400) == .trailing)
    }

    @Test func degenerateWidthFallsBackToCenter() {
        #expect(TapZones.default.zone(forX: 0, width: 0) == .center)
    }
}
