import AVFoundation
import AVKit
import SwiftUI
import WatchKit

struct WatchPlayerMediaOption: Identifiable, Equatable {
    let id: String
    let title: String
    let languageCode: String?
    let isSelected: Bool
}

@MainActor
final class WatchPlayerController: ObservableObject {
    enum Status: Equatable {
        case loading
        case ready
        case buffering
        case failed(String)

        var label: String {
            switch self {
            case .loading: "Loading"
            case .ready: "Playing on Watch"
            case .buffering: "Buffering"
            case let .failed(message): message
            }
        }
    }

    let player = AVPlayer()

    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var status: Status = .loading
    @Published private(set) var playbackRate: Double
    @Published private(set) var audioOptions: [WatchPlayerMediaOption] = []
    @Published private(set) var subtitleOptions: [WatchPlayerMediaOption] = []
    @Published private(set) var subtitlesAreOff = true
    @Published private(set) var playbackEndedCount = 0
    @Published private(set) var debugSnapshot: NativePlaybackPerformanceSnapshot?

    private let url: URL
    private let preferredAudioLanguage: String
    private let preferredSubtitleLanguage: String
    private let prefersSubtitles: Bool
    private var resumePosition: TimeInterval
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var mediaSelectionObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var audioByID: [String: AVMediaSelectionOption] = [:]
    private var subtitleByID: [String: AVMediaSelectionOption] = [:]
    private var mediaSelectionLoaded = false
    private var mediaSelectionOwner = LatestOperationOwner()
    private var mediaSelectionTask: Task<Void, Never>?
    private var performanceTracker: NativePlaybackPerformanceTracker?
    private var nextPerformanceLogAt: TimeInterval = 0
    private var lastPerformancePublishAt: TimeInterval = -.infinity
    private var notificationStallCount = 0
    private var performanceDiscontinuityPending = false

    init(
        url: URL,
        initialPosition: TimeInterval,
        playbackRate: Double,
        preferredAudioLanguage: String,
        preferredSubtitleLanguage: String,
        prefersSubtitles: Bool
    ) {
        self.url = url
        resumePosition = max(initialPosition, 0)
        self.playbackRate = playbackRate
        self.preferredAudioLanguage = preferredAudioLanguage
        self.preferredSubtitleLanguage = preferredSubtitleLanguage
        self.prefersSubtitles = prefersSubtitles
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func prepare() {
        guard player.currentItem == nil else { return }
        status = .loading
        resetMediaSelectionState()
        debugSnapshot = nil
        nextPerformanceLogAt = 0
        lastPerformancePublishAt = -.infinity
        notificationStallCount = 0
        performanceDiscontinuityPending = false
        performanceTracker = NativePlaybackPerformanceTracker(
            startedAt: ProcessInfo.processInfo.systemUptime,
            initialPosition: resumePosition
        )
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        installObservers(for: item)
        if resumePosition > 0 {
            player.seek(
                to: CMTime(seconds: resumePosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        player.playImmediately(atRate: Float(playbackRate))
        isPlaying = true
    }

    func retry() {
        resumePosition = position
        resetMediaSelectionState()
        removeObservers()
        player.replaceCurrentItem(with: nil)
        prepare()
        WKInterfaceDevice.current().play(.retry)
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.playImmediately(atRate: Float(playbackRate))
            isPlaying = true
        }
        WKInterfaceDevice.current().play(.click)
    }

    func skip(by interval: TimeInterval) {
        seek(to: position + interval)
        WKInterfaceDevice.current().play(.directionUp)
    }

    func seek(to requestedPosition: TimeInterval) {
        let upperBound = duration > 0 ? duration : max(requestedPosition, 0)
        let bounded = min(max(requestedPosition, 0), upperBound)
        position = bounded
        performanceDiscontinuityPending = true
        player.seek(
            to: CMTime(seconds: bounded, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        if isPlaying { player.playImmediately(atRate: Float(rate)) }
    }

    func cyclePlaybackRate() {
        let rates = [0.75, 1.0, 1.25, 1.5]
        let currentIndex = rates.firstIndex(of: playbackRate) ?? 1
        setPlaybackRate(rates[(currentIndex + 1) % rates.count])
        WKInterfaceDevice.current().play(.click)
    }

    @discardableResult
    func selectAudio(id: String) -> WatchPlayerMediaOption? {
        guard let item = player.currentItem,
              let group = audioGroup,
              let option = audioByID[id]
        else { return nil }
        item.select(option, in: group)
        refreshPublishedMediaSelection(for: item)
        WKInterfaceDevice.current().play(.click)
        return audioOptions.first { $0.id == id }
    }

    @discardableResult
    func selectSubtitle(id: String?) -> WatchPlayerMediaOption? {
        guard let item = player.currentItem, let group = subtitleGroup else { return nil }
        let option = id.flatMap { subtitleByID[$0] }
        item.select(option, in: group)
        refreshPublishedMediaSelection(for: item)
        WKInterfaceDevice.current().play(.click)
        return id.flatMap { selectedID in
            subtitleOptions.first { $0.id == selectedID }
        }
    }

    func stop() {
        resumePosition = position
        resetMediaSelectionState()
        player.pause()
        isPlaying = false
        removeObservers()
        player.replaceCurrentItem(with: nil)
    }

    private func installObservers(for item: AVPlayerItem) {
        periodicObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.refresh(time: time) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                isPlaying = false
                position = duration
                playbackEndedCount += 1
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[
                AVPlayerItemFailedToPlayToEndTimeErrorKey
            ] as? NSError
            let message = error?.domain == AVFoundationErrorDomain
                ? "AVPlayer could not decode this stream on Apple Watch."
                : "Playback failed. Check the stream and connection."
            Task { @MainActor [weak self] in
                guard let self else { return }
                status = .failed(message)
                isPlaying = false
            }
        }
        mediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                guard player.currentItem === item else { return }
                refreshPublishedMediaSelection(for: item)
            }
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                notificationStallCount += 1
                updatePerformanceDiagnostics()
            }
        }
    }

    private func removeObservers() {
        if let periodicObserver {
            player.removeTimeObserver(periodicObserver)
            self.periodicObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        if let mediaSelectionObserver {
            NotificationCenter.default.removeObserver(mediaSelectionObserver)
            self.mediaSelectionObserver = nil
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
    }

    private func refresh(time: CMTime) {
        let currentSeconds = time.seconds
        if currentSeconds.isFinite { position = max(currentSeconds, 0) }
        if let seconds = player.currentItem?.duration.seconds,
           seconds.isFinite,
           seconds > 0 {
            duration = seconds
        }
        if let error = player.currentItem?.error {
            status = .failed(Self.friendlyPlaybackError(error))
            isPlaying = false
            return
        }

        switch player.timeControlStatus {
        case .waitingToPlayAtSpecifiedRate:
            status = .buffering
        case .playing:
            status = .ready
            isPlaying = true
            loadMediaSelectionIfNeeded()
        case .paused:
            if status != .loading { status = .ready }
            loadMediaSelectionIfNeeded()
        @unknown default:
            status = .loading
        }
        updatePerformanceDiagnostics()
    }

    private func updatePerformanceDiagnostics() {
        guard NativePlaybackDiagnostics.isEnabled,
              var tracker = performanceTracker,
              let item = player.currentItem
        else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let event = item.accessLog()?.events.last
        let eventStalls = event.flatMap { $0.numberOfStalls >= 0 ? $0.numberOfStalls : nil }
        let discontinuity = performanceDiscontinuityPending
        performanceDiscontinuityPending = false
        let snapshot = tracker.observe(
            at: now,
            position: position,
            isPlaying: player.timeControlStatus == .playing,
            bufferSeconds: bufferedSeconds(for: item),
            stalls: max(eventStalls ?? 0, notificationStallCount),
            droppedVideoFrames: event.flatMap {
                $0.numberOfDroppedVideoFrames >= 0 ? $0.numberOfDroppedVideoFrames : nil
            },
            observedBitrate: event.flatMap { $0.observedBitrate > 0 ? $0.observedBitrate : nil },
            indicatedBitrate: event.flatMap {
                $0.indicatedBitrate > 0 ? $0.indicatedBitrate : nil
            },
            playbackRate: playbackRate,
            discontinuity: discontinuity
        )
        performanceTracker = tracker
        if now - lastPerformancePublishAt >= 1 {
            debugSnapshot = snapshot
            lastPerformancePublishAt = now
        }
        if snapshot.startupMilliseconds != nil,
           snapshot.wallDuration >= nextPerformanceLogAt {
            NSLog("WATCH_PLAYBACK_METRIC %@", snapshot.logDescription)
            nextPerformanceLogAt += 5
        }
    }

    private func bufferedSeconds(for item: AVPlayerItem) -> TimeInterval? {
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            if position >= start - 0.05, position <= end + 0.05 {
                return max(end - position, 0)
            }
        }
        return 0
    }

    private func loadMediaSelectionIfNeeded() {
        guard !mediaSelectionLoaded, let item = player.currentItem else { return }
        mediaSelectionLoaded = true
        let token = mediaSelectionOwner.begin()
        mediaSelectionTask?.cancel()
        mediaSelectionTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            let loadedAudioGroup = try? await item.asset.loadMediaSelectionGroup(
                for: .audible
            )
            guard !Task.isCancelled else { return }
            let loadedSubtitleGroup = try? await item.asset.loadMediaSelectionGroup(
                for: .legible
            )
            guard !Task.isCancelled,
                  mediaSelectionOwner.owns(token),
                  player.currentItem === item
            else { return }
            audioGroup = loadedAudioGroup
            subtitleGroup = loadedSubtitleGroup
            buildMediaOptions(for: item)
            applyPreferredMediaSelection(to: item)
            refreshPublishedMediaSelection(for: item)
        }
    }

    private func resetMediaSelectionState() {
        mediaSelectionTask?.cancel()
        mediaSelectionTask = nil
        mediaSelectionOwner.invalidate()
        mediaSelectionLoaded = false
        audioGroup = nil
        subtitleGroup = nil
        audioByID = [:]
        subtitleByID = [:]
        audioOptions = []
        subtitleOptions = []
        subtitlesAreOff = true
    }

    private func buildMediaOptions(for item: AVPlayerItem) {
        audioByID = [:]
        subtitleByID = [:]
        if let audioGroup {
            for (index, option) in audioGroup.options.enumerated() {
                audioByID["audio-\(index)"] = option
            }
        }
        if let subtitleGroup {
            for (index, option) in subtitleGroup.options.enumerated() {
                subtitleByID["subtitle-\(index)"] = option
            }
        }
        refreshPublishedMediaSelection(for: item)
    }

    private func applyPreferredMediaSelection(to item: AVPlayerItem) {
        if let audioGroup {
            let entries = audioByID.sorted { $0.key < $1.key }
            let options = entries.map {
                PlaybackLanguageOption(
                    languageTag: Self.languageCode(for: $0.value),
                    displayName: $0.value.displayName
                )
            }
            if let index = PlaybackLanguageMatcher.bestMatchIndex(
                in: options,
                preferredLanguage: preferredAudioLanguage
            ) {
                item.select(entries[index].value, in: audioGroup)
            }
        }
        guard let subtitleGroup else { return }
        guard prefersSubtitles else {
            item.select(nil, in: subtitleGroup)
            return
        }
        let entries = subtitleByID.sorted { $0.key < $1.key }
        let options = entries.map {
            PlaybackLanguageOption(
                languageTag: Self.languageCode(for: $0.value),
                displayName: $0.value.displayName
            )
        }
        if let index = PlaybackLanguageMatcher.bestMatchIndex(
            in: options,
            preferredLanguage: preferredSubtitleLanguage
        ) {
            item.select(entries[index].value, in: subtitleGroup)
        }
    }

    private func refreshPublishedMediaSelection(for item: AVPlayerItem) {
        let selection = item.currentMediaSelection
        let selectedAudio = audioGroup.flatMap { selection.selectedMediaOption(in: $0) }
        let selectedSubtitle = subtitleGroup.flatMap { selection.selectedMediaOption(in: $0) }
        audioOptions = audioByID.sorted { $0.key < $1.key }.map { id, option in
            WatchPlayerMediaOption(
                id: id,
                title: option.displayName,
                languageCode: Self.languageCode(for: option),
                isSelected: option == selectedAudio
            )
        }
        subtitleOptions = subtitleByID.sorted { $0.key < $1.key }.map { id, option in
            WatchPlayerMediaOption(
                id: id,
                title: option.displayName,
                languageCode: Self.languageCode(for: option),
                isSelected: option == selectedSubtitle
            )
        }
        subtitlesAreOff = selectedSubtitle == nil
    }

    private static func languageCode(for option: AVMediaSelectionOption) -> String? {
        option.extendedLanguageTag ?? option.locale?.identifier
    }

    private static func friendlyPlaybackError(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            return "AVPlayer could not decode this stream on Apple Watch."
        }
        return "Playback failed. Check the stream and connection."
    }
}

struct WatchPlaybackSessionView: View {
    @EnvironmentObject private var model: WatchAppModel
    @State private var request: WatchPlaybackRequest
    @State private var isResolving = false
    @State private var resolutionError: String?

    init(request: WatchPlaybackRequest) {
        _request = State(initialValue: request)
    }

    var body: some View {
        WatchPlayerView(
            request: request,
            preferredPlaybackRate: model.preferredPlaybackRate,
            preferredAudioLanguage: model.preferredAudioLanguage,
            preferredSubtitleLanguage: model.preferredSubtitleLanguage,
            prefersSubtitles: model.preferredSubtitlesEnabled,
            canTryNextSource: WatchPlaybackFallbackPolicy.nextIndex(
                after: request.fallbackIndex,
                sourceCount: request.fallbackSources.count
            ) != nil,
            hasPreviousEpisode: previousEpisode != nil,
            hasNextEpisode: nextEpisode != nil,
            onTryNextSource: { Task { await tryNextSource() } },
            onPreviousEpisode: { Task { await moveEpisode(forward: false) } },
            onNextEpisode: { Task { await moveEpisode(forward: true) } },
            onPlaybackEnded: {
                guard model.autoplayNextEpisode, nextEpisode != nil else { return }
                Task { await moveEpisode(forward: true) }
            }
        )
        .id("\(request.id)|\(request.fallbackIndex)")
        .overlay {
            if isResolving {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    ProgressView("Preparing")
                }
            }
        }
        .alert(
            "Playback",
            isPresented: Binding(
                get: { resolutionError != nil },
                set: { if !$0 { resolutionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { resolutionError = nil }
        } message: {
            Text(resolutionError ?? "Playback could not continue.")
        }
    }

    private var previousEpisode: Video? {
        guard let current = request.video else { return nil }
        return EpisodeAutoplaySelector.previousEpisode(
            before: current,
            episodes: request.episodes
        )
    }

    private var nextEpisode: Video? {
        guard let current = request.video else { return nil }
        return EpisodeAutoplaySelector.nextEpisode(
            after: current,
            episodes: request.episodes
        )
    }

    private func tryNextSource() async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            request = try await model.resolveNextFallback(after: request)
            resolutionError = nil
        } catch {
            resolutionError = error.localizedDescription
        }
    }

    private func moveEpisode(forward: Bool) async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        do {
            request = try await model.resolveAdjacentEpisode(
                from: request,
                forward: forward
            )
            resolutionError = nil
        } catch {
            resolutionError = error.localizedDescription
        }
    }
}

struct WatchPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: WatchAppModel

    let request: WatchPlaybackRequest
    let canTryNextSource: Bool
    let hasPreviousEpisode: Bool
    let hasNextEpisode: Bool
    let onTryNextSource: () -> Void
    let onPreviousEpisode: () -> Void
    let onNextEpisode: () -> Void
    let onPlaybackEnded: () -> Void

    @StateObject private var controller: WatchPlayerController
    @State private var crownPosition: Double
    @State private var showsTracks = false
    @State private var isVideoExpanded = false
    @State private var lastCheckpointBucket = 0
    @State private var didReportReady = false
    @FocusState private var timelineFocused: Bool

    init(
        request: WatchPlaybackRequest,
        preferredPlaybackRate: Double = 1,
        preferredAudioLanguage: String = "en",
        preferredSubtitleLanguage: String = "en",
        prefersSubtitles: Bool = true,
        canTryNextSource: Bool = false,
        hasPreviousEpisode: Bool = false,
        hasNextEpisode: Bool = false,
        onTryNextSource: @escaping () -> Void = {},
        onPreviousEpisode: @escaping () -> Void = {},
        onNextEpisode: @escaping () -> Void = {},
        onPlaybackEnded: @escaping () -> Void = {}
    ) {
        self.request = request
        self.canTryNextSource = canTryNextSource
        self.hasPreviousEpisode = hasPreviousEpisode
        self.hasNextEpisode = hasNextEpisode
        self.onTryNextSource = onTryNextSource
        self.onPreviousEpisode = onPreviousEpisode
        self.onNextEpisode = onNextEpisode
        self.onPlaybackEnded = onPlaybackEnded
        _controller = StateObject(
            wrappedValue: WatchPlayerController(
                url: request.playbackURL,
                initialPosition: request.initialPosition,
                playbackRate: preferredPlaybackRate,
                preferredAudioLanguage: preferredAudioLanguage,
                preferredSubtitleLanguage: preferredSubtitleLanguage,
                prefersSubtitles: prefersSubtitles
            )
        )
        _crownPosition = State(initialValue: request.initialPosition)
    }

    var body: some View {
        Group {
            if isVideoExpanded {
                expandedVideo
            } else {
                playerControls
            }
        }
        .overlay(alignment: .topLeading) {
            if NativePlaybackDiagnostics.isEnabled,
               let snapshot = controller.debugSnapshot {
                WatchPlaybackDebugOverlay(snapshot: snapshot)
                    .padding(.top, 2)
                    .padding(.leading, 2)
            }
        }
        .sheet(isPresented: $showsTracks) {
            WatchPlayerMediaSelectionView(controller: controller)
                .environmentObject(model)
        }
        .onAppear {
            controller.prepare()
        }
        .onChange(of: controller.position) { _, newPosition in
            if !timelineFocused { crownPosition = newPosition }
            let bucket = Int(newPosition / 15)
            guard bucket > 0, bucket != lastCheckpointBucket else { return }
            lastCheckpointBucket = bucket
            let duration = controller.duration
            Task {
                await model.recordPlayback(
                    request,
                    position: newPosition,
                    duration: duration
                )
            }
        }
        .onChange(of: crownPosition) { _, newPosition in
            if timelineFocused { controller.seek(to: newPosition) }
        }
        .onChange(of: controller.playbackRate) { _, rate in
            model.preferredPlaybackRate = rate
        }
        .onChange(of: controller.status) { _, status in
            guard status == .ready, !didReportReady else { return }
            didReportReady = true
            model.recordSuccessfulPlayback(request)
        }
        .onChange(of: controller.playbackEndedCount) { _, _ in onPlaybackEnded() }
        .onDisappear {
            let position = controller.position
            let duration = controller.duration
            controller.stop()
            Task { await model.recordPlayback(request, position: position, duration: duration) }
        }
    }

    private var playerControls: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    VideoPlayer(player: controller.player)
                        .allowsHitTesting(false)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityLabel("Video")
                        .accessibilityHint("Triple-tap to expand the video")
                        .overlay {
                            tripleTapTarget(expanded: true)
                        }

                    VStack(spacing: 2) {
                        Text(request.title).font(.headline).lineLimit(1)
                        if let subtitle = request.subtitle {
                            Text(subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    primaryControls
                    timeline

                    if let introSegment = request.stream.introSkipSegment,
                       IntroSkipPolicy.shouldOfferSkip(
                        for: introSegment,
                        position: controller.position
                       ),
                       let target = IntroSkipPolicy.targetPosition(for: introSegment) {
                        Button {
                            controller.seek(to: target)
                        } label: {
                            Label("Skip Intro", systemImage: "forward.end.fill")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if hasPreviousEpisode || hasNextEpisode {
                        HStack(spacing: 8) {
                            Button(action: onPreviousEpisode) {
                                Label("Previous", systemImage: "backward.end.fill")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(!hasPreviousEpisode)
                            .accessibilityLabel("Previous episode")
                            Button(action: onNextEpisode) {
                                Label("Next", systemImage: "forward.end.fill")
                                    .labelStyle(.iconOnly)
                            }
                            .disabled(!hasNextEpisode)
                            .accessibilityLabel("Next episode")
                        }
                        .buttonStyle(.bordered)
                    }

                    if !controller.audioOptions.isEmpty || !controller.subtitleOptions.isEmpty {
                        Button { showsTracks = true } label: {
                            Label("Audio & Captions", systemImage: "captions.bubble")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }

                    if case .failed = controller.status { failureControls }

                    Text("Tap the timeline, then turn the Digital Crown to seek.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 4)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var expandedVideo: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VideoPlayer(player: controller.player)
                .allowsHitTesting(false)
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()

            tripleTapTarget(expanded: false)
        }
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Expanded video")
        .accessibilityHint("Triple-tap to return to player controls")
        .accessibilityAction(named: Text("Show Player Controls")) {
            setVideoExpanded(false)
        }
    }

    private func tripleTapTarget(expanded: Bool) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.001))
            .onTapGesture(count: 3) {
                setVideoExpanded(expanded)
            }
            .accessibilityHidden(true)
    }

    private func setVideoExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isVideoExpanded = expanded
        }
    }

    private var primaryControls: some View {
        HStack(spacing: 10) {
            controlButton(symbol: "gobackward.15", label: "Back 15 seconds") {
                controller.skip(by: -15)
            }
            Button { controller.togglePlayback() } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.bold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
            controlButton(symbol: "goforward.30", label: "Forward 30 seconds") {
                controller.skip(by: 30)
            }
        }
    }

    private var timeline: some View {
        HStack(spacing: 10) {
            Gauge(value: crownPosition, in: 0...max(controller.duration, 1)) {
                Image(systemName: "digitalcrown.arrow.clockwise")
            } currentValueLabel: {
                Text(WatchTimeFormatter.compact(crownPosition))
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .frame(width: 46, height: 46)
            .focusable()
            .focused($timelineFocused)
            .digitalCrownRotation(
                $crownPosition,
                from: 0,
                through: max(controller.duration, 1),
                by: 5,
                sensitivity: .medium,
                isContinuous: true,
                isHapticFeedbackEnabled: true
            )
            .accessibilityLabel("Playback timeline")
            .accessibilityHint("Turn the Digital Crown to seek")

            VStack(alignment: .leading, spacing: 3) {
                Text(controller.status.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                Text("\(WatchTimeFormatter.compact(controller.position)) / \(WatchTimeFormatter.compact(controller.duration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { controller.cyclePlaybackRate() } label: {
                    Label("\(controller.playbackRate.formatted())×", systemImage: "speedometer")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Cycles through playback speeds")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var failureControls: some View {
        VStack(spacing: 6) {
            Button { controller.retry() } label: {
                Label("Retry Stream", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            if canTryNextSource {
                Button(action: onTryNextSource) {
                    Label("Try Next Source", systemImage: "forward.end")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .failed: .orange
        case .buffering, .loading: .secondary
        case .ready: WatchTheme.playable
        }
    }

    private func controlButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

private struct WatchPlaybackDebugOverlay: View {
    let snapshot: NativePlaybackPerformanceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Circle().fill(healthColor).frame(width: 5, height: 5)
                Text(snapshot.health == .good ? "GOOD" : "PERF")
            }
            Text("start \(milliseconds(snapshot.startupMilliseconds))")
            Text("clock \(ratio(snapshot.clockRatio))")
            Text("stall \(snapshot.stalls) · buf \(seconds(snapshot.bufferSeconds))")
        }
        .font(.system(size: 7, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(4)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(healthColor.opacity(0.9), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch-player-debug-overlay")
    }

    private var healthColor: Color {
        switch snapshot.health {
        case .warmingUp: .yellow
        case .good: .green
        case .attention: .orange
        }
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { String(format: "%.0fms", $0) } ?? "—"
    }

    private func seconds(_ value: Double?) -> String {
        value.map { String(format: "%.1fs", $0) } ?? "—"
    }

    private func ratio(_ value: Double?) -> String {
        value.map { String(format: "%.2fx", $0) } ?? "—"
    }
}

private struct WatchPlayerMediaSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: WatchAppModel
    @ObservedObject var controller: WatchPlayerController

    var body: some View {
        NavigationStack {
            List {
                if !controller.audioOptions.isEmpty {
                    Section("Audio") {
                        ForEach(controller.audioOptions) { option in
                            Button {
                                if let selected = controller.selectAudio(id: option.id) {
                                    model.preferredAudioLanguage = normalizedLanguage(selected)
                                }
                            } label: {
                                selectionLabel(option.title, selected: option.isSelected)
                            }
                        }
                    }
                }
                if !controller.subtitleOptions.isEmpty {
                    Section("Captions") {
                        Button {
                            controller.selectSubtitle(id: nil)
                            model.preferredSubtitlesEnabled = false
                        } label: {
                            selectionLabel("Off", selected: controller.subtitlesAreOff)
                        }
                        ForEach(controller.subtitleOptions) { option in
                            Button {
                                if let selected = controller.selectSubtitle(id: option.id) {
                                    model.preferredSubtitleLanguage = normalizedLanguage(selected)
                                    model.preferredSubtitlesEnabled = true
                                }
                            } label: {
                                selectionLabel(option.title, selected: option.isSelected)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tracks")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func selectionLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark") }
        }
    }

    private func normalizedLanguage(_ option: WatchPlayerMediaOption) -> String {
        PlaybackLanguageMatcher.normalizedIdentifier(
            languageTag: option.languageCode,
            displayName: option.title
        ) ?? option.languageCode ?? "en"
    }
}
