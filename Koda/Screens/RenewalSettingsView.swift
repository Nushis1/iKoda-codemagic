import KodaCore
import KodaRenewerKit
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
    @State private var showingLogin = false
    @State private var email = UserDefaults.standard.string(forKey: "koda.renewal.appleID") ?? ""
    @State private var password = ""
    @State private var code = ""

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
            appleID
            if case .signedIn = app.appleSignIn.state { developerAccount }
            Section {
                LabeledContent("Renewal core", value: Renewer.isAvailable ? "Loaded (\(Renewer.ping()))" : "Not in this build")
            } footer: {
                Text("Koda's own renewal tool (Apple ID sign-in, certificate, signing) is being built; so far it can only sign in.")
            }
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

    private var appleID: some View {
        let signIn = app.appleSignIn
        return Section {
            switch signIn.state {
            case .signedIn(let address):
                signedInCard(address, signIn)
            case .signingIn, .needsMethod, .needsCode:
                waitingRow(signIn)
            case .signedOut, .failed:
                signedOutRow(signIn)
            }
        } header: {
            Text("Apple ID (experimental)")
        } footer: {
            Text("Koda's own renewal tool signs in to an Apple ID, which should be a separate one made for this. The session lasts until you close Koda. Nothing is renewed yet.")
        }
    }

    private func signedOutRow(_ signIn: AppleSignIn) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple ID")
                Text("Not signed in")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if case .failed(let message) = signIn.state {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Log In") { showingLogin = true }
                .buttonStyle(.borderedProminent)
                .disabled(!Renewer.isAvailable)
        }
        // Like the alert for a new playlist: the Apple ID and the password, then Log In.
        .alert("Apple ID", isPresented: $showingLogin) {
            TextField("Apple ID (e-mail)", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
            Button("Log In") {
                let id = email.trimmingCharacters(in: .whitespacesAndNewlines)
                let secret = password
                password = ""
                guard !id.isEmpty, !secret.isEmpty else {
                    signIn.report("Enter the Apple ID and the password.")
                    return
                }
                UserDefaults.standard.set(id, forKey: "koda.renewal.appleID")
                signIn.signIn(email: id, password: secret)
            }
            Button("Cancel", role: .cancel) { password = "" }
        } message: {
            Text("Use a separate Apple ID made for this, not your main one. The password isn't saved.")
        }
    }

    private func signedInCard(_ address: String, _ signIn: AppleSignIn) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.green.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(address)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Signed in to Apple")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Log Out", role: .destructive) { signIn.signOut() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    /// While Apple is being talked to. The two questions Apple has, in order, come up from here: first
    /// how the code should be sent (nothing is sent before the person chooses), then, in a window of its
    /// own, the code. They hang on different parts of the row because one view can't carry both.
    private func waitingRow(_ signIn: AppleSignIn) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .alert("Enter the Code", isPresented: Binding(get: { signIn.isAskingForCode }, set: { shown in
                    if !shown, signIn.isAskingForCode { signIn.answer(nil) }
                })) {
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                    Button("Confirm") {
                        signIn.answer(.code(code))
                        code = ""
                    }
                    Button("Change Method", role: .cancel) {
                        signIn.answer(.changeMethod)
                        code = ""
                    }
                } message: {
                    Text(signIn.request?.sms == true
                         ? "Apple sent the code by text. Type the newest one."
                         : "Apple sent the code to your trusted devices. Type the newest one.")
                }
            Text(signIn.isAskingForMethod ? "Waiting for your choice…"
                 : signIn.isAskingForCode ? "Waiting for the code…" : "Talking to Apple…")
                .foregroundStyle(.secondary)
        }
        .confirmationDialog("How should Apple send the code?",
                            isPresented: Binding(get: { signIn.isAskingForMethod }, set: { shown in
                                if !shown, signIn.isAskingForMethod { signIn.answer(nil) }
                            }),
                            titleVisibility: .visible) {
            let numbers = signIn.request?.numbers ?? []
            if numbers.isEmpty {
                // Apple didn't list the trusted numbers; its first one is number 1.
                Button("Text My Phone Number") { signIn.answer(.sms(1)) }
            } else {
                ForEach(numbers) { number in
                    Button("Text \(number.label)") { signIn.answer(.sms(number.id)) }
                }
            }
            Button("Trusted Devices") { signIn.answer(.devices) }
            Button("Cancel", role: .cancel) { signIn.answer(nil) }
        } message: {
            Text("The code is sent once you choose. Apple may already have sent one when the password was accepted; use the newest.")
        }
    }

    /// What the signed-in Apple ID has at Apple's developer service: a first read-only check that the
    /// renewal tool can talk to it, before anything is made or signed.
    private var developerAccount: some View {
        let signIn = app.appleSignIn
        return Section {
            Button {
                signIn.readDeveloperAccount()
            } label: {
                Label {
                    Text(signIn.developer == nil ? "Read Developer Account" : "Read Again")
                } icon: {
                    if signIn.isReading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
            .disabled(signIn.isReading)
            if let message = signIn.developerError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let developer = signIn.developer {
                if developer.teams.isEmpty {
                    Text("This Apple ID has no developer team yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(developer.teams) { team in teamCard(team) }
            }
        } header: {
            Text("Developer account (experimental)")
        } footer: {
            Text("Only reads what the Apple ID has at Apple's developer service. Nothing is created or changed.")
        }
    }

    private func teamCard(_ team: DeveloperInfo.Team) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(team.name ?? "Team")
                    .font(.headline)
                Text(team.teamId + (team.type.map { " · \($0)" } ?? ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            let ids = team.appIDs
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("App IDs", systemImage: "app.badge")
                    Spacer()
                    Text(ids.max.map { "\(ids.used) of \($0) used" } ?? "\(ids.used) used")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                if let max = ids.max, max > 0 {
                    ProgressView(value: Double(min(ids.used, max)), total: Double(max))
                        .tint(ids.used >= max ? .red : .accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label("Certificates", systemImage: "checkmark.seal")
                    .font(.subheadline)
                if team.certificates.isEmpty {
                    Text("None yet")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(team.certificates) { certificate in
                    HStack {
                        Text(certificate.machine ?? certificate.name ?? "Certificate")
                        Spacer()
                        Text(expiry(certificate.expires))
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// "until 20 Nov 2026" from Apple's date, or what Apple sent when it isn't one.
    private func expiry(_ text: String?) -> String {
        guard let text else { return "" }
        guard let date = ISO8601DateFormatter().date(from: text) else { return text }
        return "until " + date.formatted(date: .abbreviated, time: .omitted)
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
