import Foundation

/// The provisioning profile a sideloaded copy of Koda carries (`embedded.mobileprovision`). A
/// free Apple ID's profile lasts seven days; when it runs out iOS stops opening the app until
/// it is signed again. The file is a signed blob with a property list inside, and the list
/// holds the dates.
public struct ProvisioningProfile: Sendable, Equatable {
    public var name: String
    /// Who it was made for: the developer team, which for a free Apple ID is a personal one.
    public var teamName: String?
    public var created: Date?
    public var expires: Date
    /// The devices (UDIDs) the profile is for. A free account's profile lists the one iPhone it was
    /// made for; Koda needs that identifier to have a new profile made for the same phone.
    public var devices: [String]

    public init(name: String, teamName: String? = nil, created: Date? = nil, expires: Date, devices: [String] = []) {
        self.name = name
        self.teamName = teamName
        self.created = created
        self.expires = expires
        self.devices = devices
    }

    /// The profile of the copy that is running; nil where there is none to read (the
    /// simulator, an App Store or TestFlight build, a Mac).
    public static func current(bundle: Bundle = .main) -> ProvisioningProfile? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Reads the property list out of the signed blob: everything around it is signature.
    public static func parse(_ data: Data) -> ProvisioningProfile? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let list = try? PropertyListSerialization.propertyList(from: Data(data[start.lowerBound..<end.upperBound]), options: [], format: nil),
              let values = list as? [String: Any],
              let expires = values["ExpirationDate"] as? Date else { return nil }
        return ProvisioningProfile(name: values["Name"] as? String ?? "",
                                   teamName: values["TeamName"] as? String,
                                   created: values["CreationDate"] as? Date,
                                   expires: expires,
                                   devices: values["ProvisionedDevices"] as? [String] ?? [])
    }

    public func timeLeft(at now: Date = Date()) -> TimeInterval {
        expires.timeIntervalSince(now)
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        timeLeft(at: now) <= 0
    }

    /// Whole days left, counting a started day as one, so the last hours still read "1 day".
    public func daysLeft(at now: Date = Date()) -> Int {
        max(0, Int((timeLeft(at: now) / 86_400).rounded(.up)))
    }

    /// 1 just after signing and 0 at the end: how much of the profile's life is still ahead.
    public func fractionLeft(at now: Date = Date()) -> Double? {
        guard let created, expires > created else { return nil }
        return min(1, max(0, timeLeft(at: now) / expires.timeIntervalSince(created)))
    }
}
