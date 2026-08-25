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

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let plan, let candidate = activeCandidate {
        TVNativePlaybackView(
          plan: plan,
          title: request.contentTitle,
          candidate: candidate,
          initialPosition: request.initialPosition,
          onProgress: { position, duration, updateKind in
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
          onFailure: { message in
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
  let onFailure: @MainActor (String) -> Void

  @State private var player = AVPlayer()
  @State private var activeURLIndex = 0
  @State private var didReportReady = false
  @State private var didReportFinal = false
  @State private var lastCheckpointPosition: TimeInterval = 0

  var body: some View {
    TVPlayerControllerRepresentable(player: player)
      .ignoresSafeArea()
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
    let item = AVPlayerItem(url: url)
    player.pause()
    player.replaceCurrentItem(with: item)
    player.actionAtItemEnd = .pause

    var becameReady = false
    for _ in 0..<180 {
      guard !Task.isCancelled, player.currentItem === item else { return }
      if item.status == .failed {
        failURL(item.error?.localizedDescription ?? "The player rejected this source.")
        return
      }
      if item.status == .readyToPlay {
        becameReady = true
        break
      }
      try? await Task.sleep(for: .milliseconds(250))
    }

    guard becameReady else {
      failURL("The stream did not become ready in time.")
      return
    }

    if initialPosition >= PlaybackProgress.minimumResumePosition {
      await player.seek(
        to: CMTime(seconds: initialPosition, preferredTimescale: 600),
        toleranceBefore: .zero,
        toleranceAfter: .zero
      )
    }
    player.play()

    var startupTicks = 0
    while !Task.isCancelled, player.currentItem === item {
      if item.status == .failed {
        failURL(item.error?.localizedDescription ?? "The stream stopped unexpectedly.")
        return
      }

      let position = currentPosition
      let duration = currentDuration
      if !didReportReady,
        player.timeControlStatus == .playing || player.rate > 0,
        position >= max(initialPosition - 1, 0)
      {
        didReportReady = true
        onReady()
      }

      if didReportReady,
        position >= PlaybackProgress.minimumResumePosition,
        position - lastCheckpointPosition >= 15
      {
        lastCheckpointPosition = position
        onProgress(position, duration, .checkpoint)
      }

      if duration > 0, position >= max(duration - 0.75, 0) {
        reportFinal(position: position, duration: duration)
        return
      }

      if !didReportReady {
        startupTicks += 1
        if startupTicks >= 180 {
          failURL("The stream remained buffered for too long.")
          return
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
  }

  @MainActor
  private func failURL(_ message: String) {
    player.pause()
    if playbackURLs.indices.contains(activeURLIndex + 1) {
      activeURLIndex += 1
    } else {
      onFailure(message)
    }
  }

  @MainActor
  private func finishAndStop() {
    reportFinal(position: currentPosition, duration: currentDuration)
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
