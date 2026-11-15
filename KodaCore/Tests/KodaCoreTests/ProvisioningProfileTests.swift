import Foundation
import Testing
@testable import KodaCore

@Suite struct ProvisioningProfileTests {
    private func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    /// A profile as iOS stores it: signature bytes, the property list, more signature bytes.
    private var blob: Data {
        let list = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Name</key><string>iOS Team Provisioning Profile: ivors.Koda</string>
        <key>TeamName</key><string>Jan Kowalski</string>
        <key>CreationDate</key><date>2026-11-10T08:00:00Z</date>
        <key>ExpirationDate</key><date>2026-11-17T08:00:00Z</date>
        </dict></plist>
        """
        var data = Data([0x30, 0x82, 0x0B, 0x4F, 0x06, 0x09, 0xFF, 0xFE])
        data.append(Data(list.utf8))
        data.append(Data([0x00, 0xA1, 0x02, 0x80]))
        return data
    }

    @Test func theDatesAreReadFromInsideTheSignedBlob() throws {
        let profile = try #require(ProvisioningProfile.parse(blob))
        #expect(profile.name == "iOS Team Provisioning Profile: ivors.Koda")
        #expect(profile.teamName == "Jan Kowalski")
        #expect(profile.created == (try date("2026-11-10T08:00:00Z")))
        #expect(profile.expires == (try date("2026-11-17T08:00:00Z")))
    }

    @Test func somethingThatIsNotAProfileIsRefused() {
        #expect(ProvisioningProfile.parse(Data()) == nil)
        #expect(ProvisioningProfile.parse(Data("no list in here".utf8)) == nil)
        #expect(ProvisioningProfile.parse(Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict></dict></plist>".utf8)) == nil)
    }

    @Test func daysLeftCountAStartedDayAsOne() throws {
        let profile = try #require(ProvisioningProfile.parse(blob))
        #expect(profile.daysLeft(at: try date("2026-11-14T08:00:00Z")) == 3)
        #expect(profile.daysLeft(at: try date("2026-11-14T09:00:00Z")) == 3)
        #expect(profile.daysLeft(at: try date("2026-11-16T09:00:00Z")) == 1)
        #expect(profile.daysLeft(at: try date("2026-11-17T07:00:00Z")) == 1)
        #expect(profile.isExpired(at: try date("2026-11-17T07:00:00Z")) == false)
    }

    @Test func anExpiredProfileHasNoDaysLeft() throws {
        let profile = try #require(ProvisioningProfile.parse(blob))
        let later = try date("2026-11-20T08:00:00Z")
        #expect(profile.isExpired(at: later))
        #expect(profile.daysLeft(at: later) == 0)
        #expect(profile.fractionLeft(at: later) == 0)
    }

    @Test func theFractionLeftRunsFromOneToZero() throws {
        let profile = try #require(ProvisioningProfile.parse(blob))
        #expect(profile.fractionLeft(at: try date("2026-11-10T08:00:00Z")) == 1)
        let part = try #require(profile.fractionLeft(at: try date("2026-11-13T20:00:00Z")))
        #expect(abs(part - 108.0 / 168.0) < 0.0001)
        #expect(ProvisioningProfile(name: "x", expires: Date()).fractionLeft() == nil)
    }
}
