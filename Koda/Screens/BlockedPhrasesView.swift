import KodaCore
import SwiftUI

/// Words or phrases the listener never wants in suggestions: a song whose title contains one
/// stays out of Home, mixes, radio and autoplay (`NotInterested.phrases`). Songs picked by hand play.
struct BlockedPhrasesView: View {
    @Environment(Library.self) private var library
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextField("Word or phrase in a title", text: $text)
                    .submitLabel(.done)
                    .onSubmit(add)
                Button("Block", action: add)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                Text("Songs with this in their title are kept out of Home, mixes, radio and autoplay. Case doesn't matter, accents do (ą is not a). Songs you pick yourself still play.")
            }
            let phrases = library.notInterested.phrases
            if !phrases.isEmpty {
                Section("Blocked") {
                    ForEach(phrases, id: \.self) { phrase in
                        Text(phrase)
                            .swipeActions {
                                Button("Unblock", systemImage: "trash", role: .destructive) {
                                    withAnimation { library.unblock(phrase: phrase) }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Blocked Phrases")
    }

    private func add() {
        if library.block(phrase: text) { text = "" }
    }
}

/// The Mac's Settings list of the same, in the History & Privacy pane.
struct MacBlockedPhrasesGroup: View {
    @Environment(Library.self) private var library
    @State private var text = ""

    var body: some View {
        MacSettingsGroup(title: "Blocked phrases",
                         footer: "Songs with this in their title are kept out of Home, mixes, radio and autoplay. Songs you pick yourself still play.") {
            MacSettingsRow(title: "Add") {
                HStack {
                    TextField("Word or phrase", text: $text)
                        .frame(width: 180)
                        .onSubmit(add)
                    Button("Block", action: add)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            ForEach(library.notInterested.phrases, id: \.self) { phrase in
                MacSettingsRow(title: phrase) {
                    Button("Unblock") { library.unblock(phrase: phrase) }
                }
            }
        }
    }

    private func add() {
        if library.block(phrase: text) { text = "" }
    }
}
