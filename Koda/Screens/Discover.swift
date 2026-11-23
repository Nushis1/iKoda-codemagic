import KodaCore
import SwiftUI

/// Discover: songs to answer one at a time, from what the listener likes and from what they have
/// answered before. Right likes a song, left passes it, down keeps it in the Listen Later playlist.
///
/// Every answer teaches the next songs (see `DiscoverTaste`): songs liked here seed the radios new
/// songs are drawn from, an artist who is liked comes up more, one who is passed twice stops coming
/// up, and a song is never shown twice. The deck is made again from these a few songs before it runs out.
@MainActor
@Observable
final class DiscoverModel {
    private(set) var deck: [TasteModel.Card] = []
    private(set) var isLoading = false
    /// Nothing came back, with an empty deck: no connection, most likely.
    private(set) var failed = false

    private let music: YouTubeMusic
    private let library: Library
    @ObservationIgnored private var refilling = false
    @ObservationIgnored private var inDeck = Set<String>()
    /// Counts the times the deck was forgotten, so songs found for the last profile aren't added to the new one's.
    @ObservationIgnored private var generation = 0

    /// Songs a refill brings, and the deck length that asks for another.
    private static let batch = 12
    private static let lowWater = 6

    init(music: YouTubeMusic, library: Library) {
        self.music = music
        self.library = library
    }

    var current: TasteModel.Card? { deck.first }
    var next: TasteModel.Card? { deck.count > 1 ? deck[1] : nil }

    func start() async {
        guard deck.isEmpty else { return }
        await refill()
    }

    /// Another profile's songs aren't this one's: the deck is made again from the new profile's taste.
    func forgetDeck() {
        generation += 1
        deck = []
        inDeck = []
        failed = false
    }

    func answer(_ answer: DiscoverTaste.Answer) {
        guard let card = deck.first else { return }
        library.answerDiscover(answer, song: card.song)
        deck.removeFirst()
        if deck.count < Self.lowWater { Task { await refill() } }
    }

    /// Forgets what the swipes taught, and starts again.
    func startOver() async {
        library.clearDiscover()
        forgetDeck()
        await refill()
    }

    func refill() async {
        guard !refilling else { return }
        refilling = true
        isLoading = deck.isEmpty
        failed = false
        defer {
            refilling = false
            isLoading = false
        }
        let startedIn = generation
        let found = await candidates()
        guard startedIn == generation else { return }
        let decided = Set(library.discover.decided)
        var seen = inDeck
        var perArtist: [String: Int] = [:]
        let fresh = found.filter { card in
            let song = card.song
            guard !song.isVideo, !library.isHidden(song), !library.isLiked(song), !decided.contains(song.id),
                  !library.discover.avoids(song), seen.insert(song.id).inserted else { return false }
            // No artist more than twice in a batch, so none takes over.
            let artist = Taste.leadArtist(song)
            perArtist[artist, default: 0] += 1
            return perArtist[artist]! <= 2
        }.prefix(Self.batch)
        inDeck.formUnion(fresh.map(\.song.id))
        deck += fresh
        failed = deck.isEmpty
    }

    /// Songs from the radios of a few seeds: songs liked here first, then what the listener plays
    /// most. Songs by artists who were liked come first; with nothing to go on, charts and the
    /// genres picked in taste setup.
    private func candidates() async -> [TasteModel.Card] {
        let liked = library.discover.seeds.prefix(12).shuffled()
        let played = Taste(library: library, maxSeeds: 6).seeds.shuffled()
        var seeds: [(song: Song, liked: Bool)] = []
        var artists = Set<String>()
        for (song, isLiked) in liked.map({ ($0, true) }) + played.map({ ($0, false) }) where artists.insert(Taste.leadArtist(song)).inserted {
            seeds.append((song, isLiked))
            if seeds.count == 4 { break }
        }

        var cards: [[TasteModel.Card]] = await withTaskGroup(of: (Int, [TasteModel.Card]).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask { [music] in
                    let songs = ((try? await music.radio(for: seed.song.id))?.songs ?? []).filter { $0.id != seed.song.id }
                    let reason = seed.liked ? "Because you liked \(seed.song.title)" : "Because you play \(Taste.leadArtist(seed.song))"
                    return (index, songs.map { TasteModel.Card(song: $0, reason: reason) })
                }
            }
            var byIndex: [Int: [TasteModel.Card]] = [:]
            for await (index, list) in group { byIndex[index] = list }
            return seeds.indices.map { byIndex[$0] ?? [] }
        }
        if cards.allSatisfy(\.isEmpty) {
            // New to Koda: what the listener picked in taste setup, or what is popular.
            let genre = library.taste.genres.randomElement()
            let songs = (try? await music.search(genre.map { "\($0) songs" } ?? "top hits", filter: .songs).songs) ?? []
            cards = [songs.map { TasteModel.Card(song: $0, reason: genre ?? "Popular now") }]
        }
        // One from each radio in turn, then the liked artists ahead of the rest, with a little
        // chance in the order so the same songs don't lead every time.
        let woven = TasteModel.interleave(cards)
        let ranked = woven.map { ($0, library.discover.score(of: $0.song) + Double.random(in: 0..<1.5)) }
        return ranked.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

struct DiscoverView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var preview: TastePreview?
    @State private var drag: CGSize = .zero
    @State private var answers = 0
    @State private var confirmsStartOver = false
    /// The room the cards have, so a card is as wide as its square cover can be.
    @State private var cardArea: CGSize = .zero
    @ScaledMetric(relativeTo: .title2) private var textAllowance: CGFloat = 156

    private static let threshold: CGFloat = 110

    private var model: DiscoverModel { app.discover }

    private var cardWidth: CGFloat {
        guard cardArea != .zero else { return 0 }
        return max(160, min(cardArea.width, cardArea.height - textAllowance - 14))
    }

    private var listenLater: UserPlaylist? {
        library.userPlaylists.first { $0.name == Library.listenLaterName }
    }

    var body: some View {
        VStack(spacing: 18) {
            if let card = model.current {
                Text("Swipe right to like, left to skip, down for later")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                cards(top: card)
                    .frame(width: cardWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { cardArea = $0 }
                controls
            } else if model.failed {
                ContentUnavailableView {
                    Label("No Songs Right Now", systemImage: "wifi.slash")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try Again") { Task { await model.refill() } }
                        .buttonStyle(.glass)
                }
            } else {
                ProgressView("Finding songs for you…")
                    .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu("More", systemImage: "ellipsis") {
                    if let preview {
                        Button(preview.isMuted ? "Unmute Previews" : "Mute Previews", systemImage: preview.isMuted ? "speaker.wave.2" : "speaker.slash") {
                            preview.isMuted.toggle()
                        }
                    }
                    if let later = listenLater {
                        NavigationLink(value: Route.userPlaylist(later.id)) {
                            Label("Listen Later", systemImage: "bookmark")
                        }
                    }
                    if !library.discover.isEmpty {
                        Button("Start Over", systemImage: "arrow.counterclockwise", role: .destructive) { confirmsStartOver = true }
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ProfileToolbarButton { app.isProfilePresented = true }
            }
        }
        .confirmationDialog("Forget what Discover has learned?", isPresented: $confirmsStartOver, titleVisibility: .visible) {
            Button("Start Over", role: .destructive) { Task { await model.startOver() } }
        } message: {
            Text("Songs you liked stay liked. Discover will offer songs you passed on again.")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: answers)
        .task {
            if preview == nil { preview = TastePreview(music: app.music) }
            await model.start()
            playTop()
        }
        .onChange(of: model.current?.id) { playTop() }
        .onChange(of: app.selectedTab) { _, tab in if tab != .discover { preview?.stop() } else { playTop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preview?.stop() } }
        .onDisappear { preview?.stop() }
    }

    /// The card on top plays a few seconds of itself from a third of the way in, as in taste setup:
    /// on a player of its own, so it isn't counted as a play.
    private func playTop() {
        guard app.selectedTab == .discover, scenePhase == .active else { return }
        preview?.play(model.current?.song, pausing: player)
    }

    // MARK: Cards

    private func cards(top card: TasteModel.Card) -> some View {
        ZStack {
            if let upcoming = model.next {
                DeckCardView(card: upcoming, state: .waiting)
                    .scaleEffect(0.94)
                    .offset(y: 14)
                    .opacity(0.6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            DeckCardView(card: card, state: preview?.playingID == card.id ? (preview?.isLoading == true ? .loading : .playing) : .waiting)
                .overlay(alignment: .topLeading) { stamp("heart.fill", .pink).opacity(strength(.like)) }
                .overlay(alignment: .topTrailing) { stamp("xmark", .red).opacity(strength(.skip)) }
                .overlay(alignment: .top) { stamp("bookmark.fill", .blue).opacity(strength(.later)) }
                .offset(drag)
                .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag.width / 22)), anchor: .bottom)
                .gesture(
                    DragGesture()
                        .onChanged { drag = $0.translation }
                        .onEnded { value in
                            if let decision = decision(for: value) {
                                fly(decision)
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { drag = .zero }
                            }
                        }
                )
                .id(card.id)
                .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .identity))
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Like") { answer(.like) }
                .accessibilityAction(named: "Skip") { answer(.skip) }
                .accessibilityAction(named: "Listen Later") { answer(.later) }
        }
    }

    /// Where a drag is going: mostly sideways is a like or a skip, mostly down is for later.
    private func decision(for value: DragGesture.Value) -> DiscoverTaste.Answer? {
        let t = value.translation, p = value.predictedEndTranslation
        if abs(t.height) > abs(t.width) {
            return t.height > Self.threshold || p.height > Self.threshold * 1.4 ? .later : nil
        }
        if t.width > Self.threshold || p.width > Self.threshold * 1.4 { return .like }
        if t.width < -Self.threshold || p.width < -Self.threshold * 1.4 { return .skip }
        return nil
    }

    /// How far the card has gone toward an answer, from 0 to 1: its stamp fades in with it.
    private func strength(_ answer: DiscoverTaste.Answer) -> Double {
        let sideways = abs(drag.width) >= abs(drag.height)
        let amount: CGFloat
        switch answer {
        case .like: amount = sideways ? max(0, drag.width) : 0
        case .skip: amount = sideways ? max(0, -drag.width) : 0
        case .later: amount = sideways ? 0 : max(0, drag.height)
        }
        return Double(min(1, amount / Self.threshold))
    }

    private var controls: some View {
        HStack(spacing: 28) {
            DeckButton(systemImage: "xmark", label: "Skip", tint: .secondary) { answer(.skip) }
            DeckButton(systemImage: "bookmark.fill", label: "Listen Later", tint: .blue) { answer(.later) }
            DeckButton(systemImage: "heart.fill", label: "Like", tint: .pink, large: true) { answer(.like) }
        }
    }

    private func stamp(_ systemImage: String, _ color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(color, in: .circle)
            .padding(18)
            .accessibilityHidden(true)
    }

    /// The card follows the swipe off the screen, then the answer moves the deck on.
    private func fly(_ decision: DiscoverTaste.Answer) {
        withAnimation(.smooth(duration: 0.22)) {
            switch decision {
            case .like: drag = CGSize(width: 700, height: drag.height + 60)
            case .skip: drag = CGSize(width: -700, height: drag.height + 60)
            case .later: drag = CGSize(width: drag.width, height: 900)
            }
        } completion: {
            answer(decision)
        }
    }

    private func answer(_ answer: DiscoverTaste.Answer) {
        guard model.current != nil else { return }
        answers += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { drag = .zero }
        withAnimation(.snappy) { model.answer(answer) }
    }
}
