@preconcurrency import AVFoundation
@preconcurrency import AVKit
import SwiftUI
import UIKit

struct TVResolvingPlayerView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  let request: TVPlaybackRequest

  @State private var activeCandidateIndex = 0
  @State private var resolutionRevision = 0
  @State private var plan: PlaybackPlan?
  @State private var isResolving = true
  @State private var terminalError: String?
  @State private var attemptedSources: [String] = []
  @State private var candidateResumePosition: TimeInterval?

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let plan, let candidate = activeCandidate {
        TVNativePlaybackView(
          plan: plan,
          title: request.contentTitle,
          candidate: candidate,
          initialPosition: candidateResumePosition ?? request.initialPosition,
          onProgress: { position, duration, updateKind in
            if position.isFinite {
              candidateResumePosition = max(position, 0)
            }
            model.recordPlaybackProgress(
              contentIdentifier: request.contentIdentifier,
              contentTitle: request.contentTitle,
              stream: candidate.stream,
              providerName: candidate.providerName,
              position: position,
              duration: duration,
              mediaMetadata: request.mediaMetadata,
              updateKind: updateKind
            )
          },
          onReady: {
            guard let identity = request.contentIdentity,
              let key = candidate.preferenceKey
            else { return }
            LastSuccessfulPlaybackPreferenceStore.shared.recordSuccess(
              identity: identity,
              key: key
            )
          },
          onFailure: { message, resumePosition in
            candidateResumePosition = resumePosition
            failCurrentCandidate(message)
          }
        )
        .id(candidate.id)
      } else if isResolving, let candidate = activeCandidate {
        VStack(spacing: 26) {
          ProgressView()
            .controlSize(.large)
          Text(candidate.stream.isTorrent ? "Preparing torrent…" : "Preparing stream…")
            .font(.largeTitle.bold())
          Text(
            "\(candidate.providerName) · Source \(activeCandidateIndex + 1) of \(request.candidates.count)"
          )
          .font(.title3)
          .foregroundStyle(.secondary)
        }
      } else {
        VStack(spacing: 26) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 72))
            .foregroundStyle(TVTheme.accent)
          Text("Playback Failed")
            .font(.largeTitle.bold())
          Text(terminalError ?? "Every available source failed.")
            .font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 820)
          if !attemptedSources.isEmpty {
            Text("Tried: \(attemptedSources.joined(separator: " · "))")
              .font(.headline)
              .foregroundStyle(.tertiary)
              .lineLimit(2)
          }
          HStack(spacing: 22) {
            Button("Try Again") {
              terminalError = nil
              attemptedSources = []
              activeCandidateIndex = 0
              resolutionRevision += 1
              isResolving = true
            }
            .buttonStyle(.borderedProminent)
            Button("Close") { dismiss() }
              .buttonStyle(.bordered)
          }
        }
      }
    }
    .task(id: "\(activeCandidateIndex):\(resolutionRevision)") {
      await resolveActiveCandidate()
    }
    .onExitCommand { dismiss() }
    .accessibilityIdentifier("tvos-player")
  }

  private var activeCandidate: TVPlaybackCandidate? {
    guard request.candidates.indices.contains(activeCandidateIndex) else { return nil }
    return request.candidates[activeCandidateIndex]
  }

  @MainActor
  private func resolveActiveCandidate() async {
    guard terminalError == nil, let candidate = activeCandidate else { return }
    let candidateID = candidate.id
    isResolving = true
    plan = nil
    do {
      let resolved = try await model.playbackPlan(
        for: candidate.stream,
        providerName: candidate.providerName
      )
      guard !Task.isCancelled, activeCandidate?.id == candidateID else { return }
      plan = resolved
      isResolving = false
    } catch {
      guard !Task.isCancelled, activeCandidate?.id == candidateID else { return }
      failCurrentCandidate(error.localizedDescription)
    }
  }

  @MainActor
  private func failCurrentCandidate(_ message: String) {
    guard let candidate = activeCandidate else { return }
    attemptedSources.append(candidate.providerName)
    plan = nil
    if request.candidates.indices.contains(activeCandidateIndex + 1) {
      activeCandidateIndex += 1
      isResolving = true
    } else {
      terminalError = message
      isResolving = false
    }
  }
}

private struct TVNativePlaybackView: View {
  let plan: PlaybackPlan
  let title: String
  let candidate: TVPlaybackCandidate
  let initialPosition: TimeInterval
  let onProgress:
    @MainActor (
      TimeInterval,
      TimeInterval,
      PlaybackProgressUpdateKind
    ) -> Void
  let onReady: @MainActor () -> Void
  let onFailure: @MainActor (String, TimeInterval) -> Void

  @State private var player = AVPlayer()
  @State private var activeURLIndex = 0
  @State private var didReportReady = false
  @State private var didReportFinal = false
  @State private var fallbackResumePosition: TimeInterval?
  @State private var latestProgressPosition: TimeInterval = 0
  @State private var latestProgressDuration: TimeInterval = 0
  @State private var currentAttemptDidBecomeReady = false
  @State private var suppressFinalOnDisappear = false
  @State private var diagnosticSnapshot: NativePlaybackPerformanceSnapshot?

  var body: some View {
    ZStack(alignment: .topLeading) {
      TVPlayerControllerRepresentable(player: player)
        .ignoresSafeArea()

      if NativePlaybackDiagnostics.isEnabled, let diagnosticSnapshot {
        TVPlaybackDebugOverlay(snapshot: diagnosticSnapshot)
          .padding(44)
      }
    }
      .task(id: activeURLIndex) {
        guard playbackURLs.indices.contains(activeURLIndex) else { return }
        await play(playbackURLs[activeURLIndex])
      }
      .onDisappear { finishAndStop() }
      .accessibilityLabel("Playing \(title)")
  }

  private var playbackURLs: [URL] {
    var urls = [plan.primaryURL]
    if let fallback = plan.fallbackURL, fallback != plan.primaryURL {
      urls.append(fallback)
    }
    return urls
  }

  @MainActor
  private func play(_ url: URL) async {
    didReportFinal = false
    currentAttemptDidBecomeReady = false
    suppressFinalOnDisappear = false
    diagnosticSnapshot = nil
    let requestedInitialPosition = activeURLIndex == 0
      ? initialPosition
      : fallbackResumePosition ?? initialPosition
    let diagnosticStartedAt = ProcessInfo.processInfo.systemUptime
    let item = AVPlayerItem(url: url)
    player.pause()
    player.automaticallyWaitsToMinimizeStalling = true
    player.replaceCurrentItem(with: item)
    player.actionAtItemEnd = .pause

    var becameReady = false
    for _ in 0..<180 {
      guard !Task.isCancelled, player.currentItem === item else { return }
      if item.status == .failed {
        failURL(
          item.error?.localizedDescription ?? "The player rejected this source.",
          attemptDidBecomeReady: false,
          attemptedResumePosition: requestedInitialPosition,
          latestObservedPosition: requestedInitialPosition,
          latestDuration: currentDuration
        )
        return
      }
      if item.status == .readyToPlay {
        becameReady = true
        break
      }
      try? await Task.sleep(for: .milliseconds(250))
    }

    guard becameReady else {
      failURL(
        "The stream did not become ready in time.",
        attemptDidBecomeReady: false,
        attemptedResumePosition: requestedInitialPosition,
        latestObservedPosition: requestedInitialPosition,
        latestDuration: currentDuration
      )
      return
    }

    let assetDuration = try? await item.asset.load(.duration)
    guard !Task.isCancelled, player.currentItem === item else { return }
    let loadedDuration = assetDuration.map(CMTimeGetSeconds) ?? currentDuration
    let resolvedDuration = loadedDuration.isFinite && loadedDuration > 0
      ? loadedDuration
      : currentDuration
    let attemptInitialPosition = TVPlaybackResumePolicy.clampedPosition(
      requestedInitialPosition,
      duration: resolvedDuration
    )
    latestProgressPosition = attemptInitialPosition
    latestProgressDuration = resolvedDuration
    var monitor = TVPlaybackMonitorState(resumePosition: attemptInitialPosition)
    var diagnosticTracker = NativePlaybackPerformanceTracker(
      startedAt: diagnosticStartedAt,
      initialPosition: attemptInitialPosition
    )
    var nextDiagnosticLogAt: TimeInterval = 0
    var lastDiagnosticPublishAt: TimeInterval = -.infinity

    if attemptInitialPosition >= PlaybackProgress.minimumResumePosition {
      await player.seek(
        to: CMTime(seconds: attemptInitialPosition, preferredTimescale: 600),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
    }
    player.play()

    var startupTicks = 0
    while !Task.isCancelled, player.currentItem === item {
      if item.status == .failed {
        let failedPosition = max(monitor.latestPosition, currentPosition)
        let failedDuration = max(monitor.latestDuration, currentDuration)
        failURL(
          item.error?.localizedDescription ?? "The stream stopped unexpectedly.",
          attemptDidBecomeReady: monitor.didBecomeReady,
          attemptedResumePosition: attemptInitialPosition,
          latestObservedPosition: failedPosition,
          latestDuration: failedDuration
        )
        return
      }

      let position = currentPosition
      let duration = currentDuration
      let timestamp = ProcessInfo.processInfo.systemUptime
      let accessEvent = item.accessLog()?.events.last
      let snapshot = diagnosticTracker.observe(
        at: timestamp,
        position: position,
        isPlaying: player.timeControlStatus == .playing,
        bufferSeconds: bufferedSeconds(for: item),
        stalls: accessEvent.flatMap { $0.numberOfStalls >= 0 ? $0.numberOfStalls : nil },
        droppedVideoFrames: accessEvent.flatMap {
          $0.numberOfDroppedVideoFrames >= 0 ? $0.numberOfDroppedVideoFrames : nil
        },
        observedBitrate: accessEvent.flatMap { $0.observedBitrate > 0 ? $0.observedBitrate : nil },
        indicatedBitrate: accessEvent.flatMap {
          $0.indicatedBitrate > 0 ? $0.indicatedBitrate : nil
        },
        playbackRate: player.rate > 0 ? Double(player.rate) : 1
      )
      if NativePlaybackDiagnostics.isEnabled,
        timestamp - lastDiagnosticPublishAt >= 1
      {
        diagnosticSnapshot = snapshot
        lastDiagnosticPublishAt = timestamp
      }
      if NativePlaybackDiagnostics.isEnabled,
        snapshot.startupMilliseconds != nil,
        snapshot.wallDuration >= nextDiagnosticLogAt
      {
        NSLog(
          "TV_PLAYBACK_METRIC url_index=%ld %@",
          activeURLIndex + 1,
          snapshot.logDescription
        )
        nextDiagnosticLogAt += 5
      }
      let isPlaying = player.timeControlStatus == .playing || player.rate > 0
      let events = monitor.observe(
        position: position,
        duration: duration,
        isPlaying: isPlaying
      )
      latestProgressPosition = monitor.latestPosition
      latestProgressDuration = monitor.latestDuration
      currentAttemptDidBecomeReady = monitor.didBecomeReady
      for event in events {
        switch event {
        case .ready:
          if !didReportReady {
            didReportReady = true
            onReady()
          }
        case .replayBegan:
          didReportFinal = false
        case let .checkpoint(position, duration):
          onProgress(position, duration, .checkpoint)
        case let .final(position, duration):
          reportFinal(position: position, duration: duration)
        }
      }

      if !monitor.didBecomeReady {
        startupTicks += 1
        if startupTicks >= 180 {
          failURL(
            "The stream remained buffered for too long.",
            attemptDidBecomeReady: monitor.didBecomeReady,
            attemptedResumePosition: attemptInitialPosition,
            latestObservedPosition: monitor.latestPosition,
            latestDuration: monitor.latestDuration
          )
          return
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
  }

  @MainActor
  private func failURL(
    _ message: String,
    attemptDidBecomeReady: Bool,
    attemptedResumePosition: TimeInterval,
    latestObservedPosition: TimeInterval,
    latestDuration: TimeInterval
  ) {
    let resumePosition = TVPlaybackResumePolicy.failureResumePosition(
      requestedPosition: attemptedResumePosition,
      latestObservedPosition: latestObservedPosition,
      attemptDidBecomeReady: attemptDidBecomeReady,
      duration: latestDuration
    )
    latestProgressPosition = resumePosition
    latestProgressDuration = max(latestDuration, 0)
    player.pause()
    if attemptDidBecomeReady {
      onProgress(resumePosition, latestProgressDuration, .checkpoint)
    }
    if playbackURLs.indices.contains(activeURLIndex + 1) {
      fallbackResumePosition = resumePosition
      activeURLIndex += 1
    } else {
      suppressFinalOnDisappear = true
      onFailure(message, resumePosition)
    }
  }

  @MainActor
  private func finishAndStop() {
    if !suppressFinalOnDisappear, currentAttemptDidBecomeReady {
      let position = currentPosition > 0 ? currentPosition : latestProgressPosition
      let duration = currentDuration > 0 ? currentDuration : latestProgressDuration
      reportFinal(position: position, duration: duration)
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
  }

  @MainActor
  private func reportFinal(position: TimeInterval, duration: TimeInterval) {
    guard !didReportFinal else { return }
    didReportFinal = true
    onProgress(position, duration, .final)
  }

  private var currentPosition: TimeInterval {
    let value = CMTimeGetSeconds(player.currentTime())
    return value.isFinite ? max(value, 0) : 0
  }

  private var currentDuration: TimeInterval {
    guard let item = player.currentItem else { return 0 }
    let value = CMTimeGetSeconds(item.duration)
    return value.isFinite ? max(value, 0) : 0
  }

  private func bufferedSeconds(for item: AVPlayerItem) -> TimeInterval? {
    let position = currentPosition
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
}

private struct TVPlaybackDebugOverlay: View {
  let snapshot: NativePlaybackPerformanceSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 9) {
        Circle()
          .fill(healthColor)
          .frame(width: 12, height: 12)
        Text("Bunny AVKit")
          .fontWeight(.bold)
        Text(snapshot.health.rawValue.replacingOccurrences(of: "_", with: " ").uppercased())
          .foregroundStyle(.secondary)
      }
      metric("Startup", milliseconds(snapshot.startupMilliseconds))
      metric("Clock", ratio(snapshot.clockRatio))
      metric("Buffer", seconds(snapshot.bufferSeconds))
      metric("Stalls", String(snapshot.stalls))
      metric("Dropped", snapshot.droppedVideoFrames.map(String.init) ?? "—")
      metric("Bitrate", bitrate(snapshot.observedBitrate))
    }
    .font(.headline.monospacedDigit())
    .foregroundStyle(.white)
    .padding(.horizontal, 22)
    .padding(.vertical, 18)
    .frame(width: 420, alignment: .leading)
    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .stroke(healthColor.opacity(0.9), lineWidth: 2)
    }
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("tvos-player-debug-overlay")
  }

  private var healthColor: Color {
    switch snapshot.health {
    case .warmingUp: .yellow
    case .good: .green
    case .attention: .orange
    }
  }

  private func metric(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).foregroundStyle(.secondary)
      Spacer()
      Text(value)
    }
  }

  private func milliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "—"
  }

  private func seconds(_ value: Double?) -> String {
    value.map { String(format: "%.1f s", $0) } ?? "—"
  }

  private func ratio(_ value: Double?) -> String {
    value.map { String(format: "%.3fx", $0) } ?? "—"
  }

  private func bitrate(_ value: Double?) -> String {
    value.map { String(format: "%.1f Mbps", $0 / 1_000_000) } ?? "—"
  }
}

private struct TVPlayerControllerRepresentable: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = true
    controller.playbackControlsIncludeTransportBar = true
    controller.playbackControlsIncludeInfoViews = true
    controller.transportBarIncludesTitleView = true
    controller.appliesPreferredDisplayCriteriaAutomatically = true
    controller.videoGravity = .resizeAspect
    return controller
  }

  func updateUIViewController(
    _ controller: AVPlayerViewController,
    context: Context
  ) {
    if controller.player !== player {
      controller.player = player
    }
  }

  static func dismantleUIViewController(
    _ controller: AVPlayerViewController,
    coordinator: Void
  ) {
    controller.player = nil
  }
}
