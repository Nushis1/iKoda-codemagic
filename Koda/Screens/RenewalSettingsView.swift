import KodaCore
import SwiftUI
import UserNotifications

/// Reminders for the end of the signature, from the profile's own date. A renewal moves that
/// date, so they are planned again each time Koda opens.
enum RenewalReminders {
    private static let identifiers = ["koda.renewal.2d", "koda.renewal.1d", "koda.renewal.0"]

    private static func isAllowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Asks the first time, and says whether notifications are allowed.
    static func requestIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return isAllowed(status)
    }

    /// Replaces the planned reminders with ones for the profile's current end.
    static func refresh(enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        guard enabled, let profile = ProvisioningProfile.current(),
              isAllowed(await center.notificationSettings().authorizationStatus) else { return }
        let calendar = Calendar.current
        func morning(daysBefore days: Double) -> Date? {
            calendar.date(bySettingHour: 10, minute: 0, second: 0, of: profile.expires.addingTimeInterval(-days * 86_400))
        }
        let plans: [(id: String, date: Date?, title: String)] = [
            (identifiers[0], morning(daysBefore: 2), "Koda expires in 2 days"),
            (identifiers[1], morning(daysBefore: 1), "Koda expires tomorrow"),
            (identifiers[2], profile.expires, "Koda has expired"),
        ]
        for plan in plans {
            guard let date = plan.date, date.timeIntervalSinceNow > 5 else { continue }
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.id == identifiers[2]
                ? "Sign it again to open it. Your library is kept."
                : "Renew it in SideStore, AltStore or Sideloadly before it stops opening."
            content.sound = .default
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: plan.id, content: content, trigger: trigger))
        }
    }
}

/// How long the app's signature lasts, and the ways to renew it. Koda can't renew itself: signing
/// needs an Apple ID and an installer, which is a computer or an app like SideStore.
struct RenewalSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var profile = ProvisioningProfile.current()
    @State private var now = Date()
    @State private var notice: String?
    @AppStorage("koda.renewal.shortcut") private var shortcutName = "Refresh Apps"

    var body: some View {
        Form {
            if let profile {
                countdown(profile)
            } else {
                Section {
                    Text("Koda can't find a signature to read. It has one only when it was installed with Sideloadly, AltStore or SideStore. A build from Xcode, the simulator and the App Store don't count down this way.")
                        .foregroundStyle(.secondary)
                }
            }
            renew
            reminders
        }
        .navigationTitle("Renewal")
        .task {
            profile = ProvisioningProfile.current()
            now = Date()
            // Asked here, where the reason is plain, and not at launch.
            if app.settings.remindsToRenew { _ = await RenewalReminders.requestIfNeeded() }
            await RenewalReminders.refresh(enabled: app.settings.remindsToRenew)
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func color(_ profile: ProvisioningProfile) -> Color {
        let days = profile.daysLeft(at: now)
        if profile.isExpired(at: now) || days <= 1 { return .red }
        return days <= 3 ? .orange : .green
    }

    private func countdown(_ profile: ProvisioningProfile) -> some View {
        Section {
            VStack(spacing: 6) {
                if profile.isExpired(at: now) {
                    Text("Expired")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(color(profile))
                    Text("Koda won't open until it is signed again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    let days = profile.daysLeft(at: now)
                    Text("\(days)")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(color(profile))
                        .contentTransition(.numericText())
                    Text(days == 1 ? "day left" : "days left")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let fraction = profile.fractionLeft(at: now) {
                    ProgressView(value: fraction)
                        .tint(color(profile))
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            LabeledContent("Expires", value: profile.expires.formatted(date: .abbreviated, time: .shortened))
            if let team = profile.teamName, !team.isEmpty {
                LabeledContent("Signed for", value: team)
            }
        } footer: {
            Text("Read from the signature Koda was installed with. Installing over the app again keeps your library and settings.")
        }
    }

    private var renew: some View {
        Section {
            Button {
                open("sidestore://", missing: "SideStore")
            } label: {
                Label("Open SideStore", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                open("altstore://", missing: "AltStore")
            } label: {
                Label("Open AltStore", systemImage: "arrow.triangle.2.circlepath")
            }
            TextField("Shortcut name", text: $shortcutName)
                .autocorrectionDisabled()
            Button {
                let name = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), !name.isEmpty else { return }
                open("shortcuts://run-shortcut?name=\(encoded)", missing: "Shortcuts")
            } label: {
                Label("Run Shortcut", systemImage: "bolt.fill")
            }
        } header: {
            Text("Renew")
        } footer: {
            Text("Koda can't sign itself: that takes your Apple ID and an installer. SideStore and AltStore refresh apps from the phone (SideStore needs a pairing file and a VPN profile, and its Shortcuts action \"Refresh All Apps\" can be run from here by naming the shortcut). With Sideloadly, connect the iPhone to your computer, open Sideloadly and install Koda again with the same Apple ID.")
        }
    }

    private var reminders: some View {
        Section {
            Toggle(isOn: Binding(get: { app.settings.remindsToRenew }, set: { on in
                app.settings.remindsToRenew = on
                Task {
                    if on, await !RenewalReminders.requestIfNeeded() {
                        notice = "Notifications are off for Koda. Turn them on in the iPhone's Settings to get reminders."
                    }
                    await RenewalReminders.refresh(enabled: on)
                }
            })) {
                Label("Remind Me Before It Expires", systemImage: "bell.badge.fill")
            }
        } footer: {
            Text("A notification at 10:00 two days before and one day before, and one when it expires.")
        }
    }

    private func open(_ address: String, missing name: String) {
        guard let url = URL(string: address) else { return }
        Task {
            if await !UIApplication.shared.open(url) { notice = "\(name) couldn't be opened. Is it installed?" }
        }
    }
}
