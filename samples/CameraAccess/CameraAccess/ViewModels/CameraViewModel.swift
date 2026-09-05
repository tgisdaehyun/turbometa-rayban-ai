/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import AVFoundation
import MWDATCamera
import MWDATCore
import Observation
import Photos
import SwiftUI
import UIKit

extension TimeInterval {
  /// Formats a duration as `mm:ss`.
  var formattedRecordingTime: String {
    let minutes = Int(self) / 60
    let seconds = Int(self) % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }
}

/// A capture awaiting preview/share — a still photo or a recorded video file.
/// Drives a single `.sheet(item:)` so photo and video share one presentation.
enum CapturePreview: Identifiable {
  case photo(UIImage)
  case video(URL)

  var id: String {
    switch self {
    case .photo: return "photo"
    case .video(let url): return "video:\(url.absoluteString)"
    }
  }
}

/// Drives the camera screen by exercising the SDK's camera lifecycle as explicit
/// steps: create/start a `DeviceSession`, add and start a `Stream`, capture or
/// record, stop the stream, end the session. Owns the screen-scoped pieces —
/// active-device monitoring, the `DeviceSession`, and its `Stream`. The UI binds to
/// the SDK's own `DeviceSessionState` / `StreamState` so the sample shows the real
/// state machine.
@Observable
@MainActor
final class CameraViewModel {
  // MARK: - Device

  /// Whether an eligible device is currently active. Drives the "Put on your
  /// glasses" placeholder. Sourced from the auto device selector.
  private(set) var hasActiveDevice: Bool = false

  // MARK: - Session state (bound directly to the SDK)

  /// The device session's state, mirrored from `DeviceSession.statePublisher`.
  /// `.idle`/`.stopped` mean no live session.
  var sessionState: DeviceSessionState = .idle

  // MARK: - Preview

  /// The latest decoded preview frame. Read only by the isolated `LivePreviewView`
  /// so the ~24fps updates don't re-render the whole screen.
  var currentVideoFrame: UIImage?
  var hasReceivedFirstFrame: Bool = false

  /// The stream's state, mirrored from `Stream.statePublisher`. `.stopped` means
  /// no live stream.
  var streamState: StreamState = .stopped

  // MARK: - Capture preview

  /// The capture currently shown in the preview/share sheet (photo or video).
  var activePreview: CapturePreview?
  var isCapturingPhoto: Bool = false

  // MARK: - Video recording

  var isRecording: Bool = false
  /// Wall-clock start of the active recording (first written frame), mirrored from the
  /// recorder. Drives the isolated `RecordingTimerLabel`'s `TimelineView`, so the timer
  /// counts continuously — including through a stream pause. `nil` when not recording.
  var recordingStartDate: Date?
  /// Whether to record microphone audio into videos (sound-in-video). The source
  /// is the glasses mic when the glasses are connected for audio, else the phone's.
  /// Toggled from the mic button shown while streaming.
  var includeAudioInStream: Bool = true
  /// Mic denied — iOS won't re-prompt. Drives the toggle's disabled look + tap-to-Settings.
  var micDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }

  // MARK: - One-tap recording

  /// True while the one-tap flow is bringing up the session/stream before the
  /// recorder starts (or while a finished clip is being saved to Photos).
  var isOneTapBusy: Bool = false
  /// Short status line under the one-tap button ("Saved to Photos", ...).
  var oneTapStatus: String?

  // MARK: - Errors

  /// Drives the single error alert. Uses the SDK's own `localizedDescription`
  /// rather than an app-maintained error map.
  var showError: Bool = false
  var errorMessage: String = ""

  /// Drives the confirm prompt shown before the camera-permission redirect to the
  /// Meta AI app — surfaced only when permission isn't already granted.
  var showCameraPermissionRedirectConfirm: Bool = false

  // MARK: - Derived session state

  var isSessionStarting: Bool { sessionState == .starting }
  var isSessionActive: Bool { sessionState == .started }
  /// A session exists and is connected (or connecting); a stream can be started.
  var hasSession: Bool {
    switch sessionState {
    case .starting, .started, .paused, .stopping: return true
    case .idle, .stopped: return false
    }
  }

  /// Human-readable session state for the status line.
  var sessionStateText: String { sessionState.description }

  // MARK: - Derived stream state

  var isStreaming: Bool { streamState == .streaming }
  /// A stream is attached (in any non-terminal state).
  var hasStream: Bool { streamState != .stopped }

  /// A session or stream start/stop is in flight. The UI shows a spinner and
  /// disables the controls until the SDK settles on a stable state, so transient
  /// states never need their own controls or labels.
  var isBusy: Bool {
    isSessionStarting || sessionState == .stopping
      || streamState == .starting || streamState == .waitingForDevice || streamState == .stopping
  }

  /// Human-readable stream state for the status line. `StreamState` has no
  /// `description`, so map it here.
  var streamStateText: String {
    switch streamState {
    case .streaming: return "streaming"
    case .starting: return "starting"
    case .waitingForDevice: return "waiting for device"
    case .stopping: return "stopping"
    case .stopped: return "stopped"
    case .paused: return "paused"
    }
  }

  /// The stream is paused (device-initiated, e.g. a single cap-touch tap). The
  /// last frame is retained, so the preview can stay on screen frozen.
  var isPaused: Bool { streamState == .paused }

  /// The preview surface (live frames, or the last held frame) should fill the
  /// screen: while streaming, while paused (frozen on the last frame), or while
  /// tearing down with a last frame so the stop loader overlays the preview.
  var showsLivePreview: Bool {
    isStreaming
      || ((streamState == .paused || streamState == .stopping) && currentVideoFrame != nil)
  }

  // MARK: - Private

  @ObservationIgnored private let wearables: WearablesInterface
  @ObservationIgnored private let deviceSelector: AutoDeviceSelector
  @ObservationIgnored private var deviceSession: DeviceSession?
  @ObservationIgnored private var stream: MWDATCamera.Stream?
  @ObservationIgnored private var isStoppingForBackground: Bool = false
  @ObservationIgnored private var backgroundStopSuppressionTask: Task<Void, Never>?

  @ObservationIgnored private let videoRecorder = VideoRecorder()
  // Decodes compressed hvc1 frames for on-screen preview. Not required for
  // recording — the passthrough writer handles compressed frames directly.
  @ObservationIgnored private let videoFrameDecoder = VideoFrameDecoder()

  @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
  @ObservationIgnored private var appLifecycleTask: Task<Void, Never>?
  @ObservationIgnored private let sessionTokenBag = ListenerTokenBag()
  @ObservationIgnored private let streamTokenBag = ListenerTokenBag()

  @ObservationIgnored private let photoCaptureFailureMessage =
    "Couldn't capture photo. There may not be enough storage, or another capture is in progress. Try again in a few moments."
  @ObservationIgnored private let backgroundStopErrorSuppressionTimeout: Duration

  // MARK: - Init

  init(
    wearables: WearablesInterface,
    backgroundStopErrorSuppressionTimeout: Duration = .seconds(5)
  ) {
    self.wearables = wearables
    self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    self.backgroundStopErrorSuppressionTimeout = backgroundStopErrorSuppressionTimeout
    startDeviceMonitoring()
    startAppLifecycleMonitoring()
  }

  isolated deinit {
    deviceMonitorTask?.cancel()
    appLifecycleTask?.cancel()
    backgroundStopSuppressionTask?.cancel()
    deviceSession?.stop()
  }

  // MARK: - Lifecycle step 1: session

  /// Creates and starts a `DeviceSession` (no stream yet). This is the first
  /// explicit step — a session can stay connected with no active stream. The
  /// state observer drives `sessionState`; we only seed an optimistic
  /// `.starting` so the UI reflects the in-flight request immediately.
  func startSession() {
    guard !hasSession else { return }
    DiagnosticsLog.shared.add("startSession: activeDevice=\(deviceSelector.activeDevice ?? "nil") hasActiveDevice=\(hasActiveDevice)")
    do throws(DeviceSessionError) {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      DiagnosticsLog.shared.add("createSession OK, calling start()")
      deviceSession = session
      // Subscribe before start() so no initial state transitions are missed.
      observeSession(session)
      // Reflect the in-flight request immediately; the observer drives it onward.
      sessionState = .starting
      try session.start()
    } catch {
      handleSessionError(error)
      sessionState = .idle
      cleanupSession()
    }
  }

  /// Stops the stream (if any) and ends the device session. `stop()` is terminal;
  /// the SDK cascades the stop to the stream and the state observers clean up
  /// when `.stopped` arrives.
  func endSession() {
    guard let session = deviceSession else { return }
    // Reflect the in-flight stop immediately so the controls disable at once; the
    // state observer drives it onward to `.stopped`.
    sessionState = .stopping
    session.stop()
  }

  // MARK: - Lifecycle step 2: stream

  /// Adds a `Stream` to the started session and starts it. Requires a session in
  /// `.started`. Camera permission is checked first (a query, no redirect); if it
  /// isn't already granted, the actual request — which redirects to the Meta AI
  /// app — is deferred to `confirmCameraPermissionRedirect()` so the app-switch is
  /// confirmed, not a surprise.
  func startStreaming() async {
    guard let session = deviceSession, session.state == .started else {
      showError("Start a session before previewing.")
      return
    }
    guard stream == nil else { return }

    do {
      let status = try await wearables.checkPermissionStatus(.camera)
      DiagnosticsLog.shared.add("camera permission status: \(status)")
      if status == .granted {
        beginStream(on: session)
      } else {
        showCameraPermissionRedirectConfirm = true
      }
    } catch {
      DiagnosticsLog.shared.add("checkPermissionStatus failed: \(describeError(error))")
      showError(describeError(error))
    }
  }

  /// Confirmed from the permission prompt: requests camera access — this opens the
  /// Meta AI app and resumes when the user returns — then starts the stream if
  /// access was granted.
  func confirmCameraPermissionRedirect() async {
    showCameraPermissionRedirectConfirm = false
    guard let session = deviceSession, session.state == .started, stream == nil else { return }
    do {
      let status = try await wearables.requestPermission(.camera)
      DiagnosticsLog.shared.add("requestPermission(.camera) -> \(status)")
      guard status == .granted else {
        showError("Camera permission denied (\(status))")
        return
      }
    } catch {
      DiagnosticsLog.shared.add("requestPermission failed: \(describeError(error))")
      showError(describeError(error))
      return
    }
    beginStream(on: session)
  }

  /// Creates the camera `Stream` on the started session and starts it. Callers
  /// must have ensured camera permission is granted first.
  private func beginStream(on session: DeviceSession) {
    guard stream == nil else { return }
    // hvc1 (compressed HEVC) so frames can be written to file in passthrough mode.
    // Sound-in-video is captured app-side by AudioCaptureHandler, from the glasses
    // mic when available and the phone mic otherwise,
    // so the SDK stream needs only the public video config (no audio codec).
    let config = StreamConfiguration(
      videoCodec: VideoCodec.hvc1,
      resolution: StreamingResolution.high,
      frameRate: 24
    )

    DiagnosticsLog.shared.add("beginStream: codec=\(config.videoCodec) resolution=\(config.resolution) fps=\(config.frameRate) sessionState=\(session.state)")
    do {
      // SDK 0.8.0: the stream is added to the session directly (no `Camera` wrapper).
      guard let newStream = try session.addStream(config: config) else {
        DiagnosticsLog.shared.add("addStream returned nil")
        showError("Couldn't create the camera. Try again.")
        return
      }
      stream = newStream
      // Subscribe before start() so no initial state transitions are missed.
      setupStreamListeners(for: newStream)
      // Reflect the in-flight request immediately; the observer drives it onward.
      streamState = .starting
      newStream.start()
    } catch {
      DiagnosticsLog.shared.add("addStream threw: \(describeError(error))")
      stream = nil
      showError(describeError(error))
    }
  }

  /// Stops the camera stream but keeps the `DeviceSession` connected, so
  /// streaming can be started again without re-creating the session. The stream
  /// `.stopped` observer performs the teardown — we don't eagerly reset here.
  func stopStreaming() {
    guard let activeStream = stream else { return }
    videoRecorder.prepareToStop()
    // Reflect the in-flight request immediately; the observer drives it onward.
    streamState = .stopping
    // Stopping the camera cascades to its stream child and detaches the camera from the
    // session, so streaming can be started again with a fresh `addCamera()`.
    activeStream.stop()
  }

  // MARK: - Capture

  func capturePhoto() {
    guard !isCapturingPhoto, isStreaming else {
      showError(photoCaptureFailureMessage)
      return
    }
    isCapturingPhoto = true
    let success = stream?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showError(photoCaptureFailureMessage)
    }
  }

  func toggleRecording() {
    if isRecording {
      Task { await stopVideoRecording() }
    } else {
      startVideoRecording()
    }
  }

  func startVideoRecording() {
    guard isStreaming, !isRecording else { return }
    // Flip the intent flag synchronously so the toggle and UI don't lag the
    // frame-driven recorder; the file starts on the next frame.
    isRecording = true
    videoRecorder.prepareToStart(includeAudio: includeAudioInStream)
  }

  func stopVideoRecording() async {
    guard isRecording else { return }
    isRecording = false
    recordingStartDate = nil
    // The writer starts on the first frame after the shutter opens. If stop lands
    // before that frame arrives, wait briefly (shutter still open) so even a quick
    // recording finalizes to a file and reliably opens the preview.
    var elapsedNanos: UInt64 = 0
    while !videoRecorder.isRecording, elapsedNanos < 500_000_000 {
      try? await Task.sleep(nanoseconds: 25_000_000)
      elapsedNanos += 25_000_000
    }
    // Show a preview/share sheet (mirrors the photo flow) for the finalized file.
    switch await videoRecorder.stopRecording() {
    case .completed(let url):
      await saveToPhotos(url)
    case .noRecording:
      // Reached only after the intent guard + start wait, so while streaming this
      // means the recording never started (e.g. the writer failed to start).
      showError("Couldn't start recording. Try again.")
    case .failed:
      showError("Recording couldn't be saved. Try again.")
    }
  }

  // MARK: - One-tap record

  /// Single button: brings up the session and the stream as needed, then starts
  /// recording; tapping again stops and saves the clip to Photos.
  func oneTapToggle() async {
    if isRecording {
      await stopVideoRecording()
      return
    }
    guard !isOneTapBusy else { return }
    isOneTapBusy = true
    oneTapStatus = nil
    defer { isOneTapBusy = false }

    if !hasSession {
      guard hasActiveDevice else {
        showError("No glasses connected. Connect them in the Meta AI app first.")
        return
      }
      oneTapStatus = "Starting session…"
      startSession()
    }
    guard await waitUntil(seconds: 20, { self.sessionState == .started }, abortIf: { self.sessionState == .stopped || self.sessionState == .idle }) else {
      if sessionState != .started { showError("Couldn't start the session (state: \(sessionState)).") }
      return
    }

    if !isStreaming {
      oneTapStatus = "Starting camera…"
      await startStreaming()
      // The camera permission alert may now be up; the user's Continue in that alert
      // starts the stream. Wait for it to come alive, bail if it dies or is cancelled.
      let streaming = await waitUntil(seconds: 150, { self.isStreaming }) {
        !self.hasSession
          || (self.stream == nil && !self.showCameraPermissionRedirectConfirm)
      }
      guard streaming else {
        oneTapStatus = nil
        return
      }
    }

    oneTapStatus = nil
    startVideoRecording()
  }

  /// Polls a main-actor condition until it holds, the abort condition holds, or the
  /// timeout elapses. Returns true only when the condition held.
  private func waitUntil(seconds: Double, _ condition: () -> Bool, abortIf: () -> Bool = { false }) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return true }
      if abortIf() { return false }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
  }

  /// Saves a finished clip to the Photos library and deletes the temp file.
  private func saveToPhotos(_ url: URL) async {
    isOneTapBusy = true
    oneTapStatus = "Saving to Photos…"
    defer { isOneTapBusy = false }
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
      DiagnosticsLog.shared.add("Photos add-only permission: \(status.rawValue)")
      // Keep the clip reachable through the share sheet instead of losing it.
      oneTapStatus = nil
      activePreview = .video(url)
      showError("Photos access is off. Allow it in Settings, or share the clip from the preview.")
      return
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      }
      try? FileManager.default.removeItem(at: url)
      DiagnosticsLog.shared.add("saved recording to Photos: \(url.lastPathComponent)")
      oneTapStatus = "Saved to Photos"
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        if self?.oneTapStatus == "Saved to Photos" { self?.oneTapStatus = nil }
      }
    } catch {
      DiagnosticsLog.shared.add("Photos save failed: \(describeError(error))")
      oneTapStatus = nil
      activePreview = .video(url)
      showError("Couldn't save to Photos: \(error.localizedDescription). You can share it from the preview.")
    }
  }

  // MARK: - Dismissers

  func dismissError() {
    showError = false
  }

  func dismissCapturePreview() {
    guard let preview = activePreview else { return }
    activePreview = nil
    discardPreview(preview)
  }

  /// Deletes a finished video capture's temporary file. Photos are held in
  /// memory, so there's nothing on disk to remove for them.
  func discardPreview(_ preview: CapturePreview) {
    if case .video(let url) = preview {
      try? FileManager.default.removeItem(at: url)
    }
  }

  // MARK: - Device monitoring

  /// Monitors device availability only — does NOT create sessions. Session
  /// creation is deferred to `startSession()` to avoid races.
  private func startDeviceMonitoring() {
    deviceMonitorTask = Task { [weak self] in
      guard let self else { return }
      for await deviceId in deviceSelector.activeDeviceStream() {
        DiagnosticsLog.shared.add("activeDevice -> \(deviceId ?? "nil")")
        hasActiveDevice = deviceId != nil
      }
    }
  }

  private func startAppLifecycleMonitoring() {
    appLifecycleTask = Task { [weak self] in
      guard let self else { return }
      for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
        self.handleDidEnterBackground()
      }
    }
  }

  private func handleDidEnterBackground() {
    guard hasSession, hasStream, sessionState != .stopping else { return }

    beginBackgroundStopErrorSuppression()
    endSession()
  }

  private func beginBackgroundStopErrorSuppression() {
    isStoppingForBackground = true
    backgroundStopSuppressionTask?.cancel()
    let timeout = backgroundStopErrorSuppressionTimeout
    backgroundStopSuppressionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: timeout)
      guard let self, !Task.isCancelled else { return }
      // Bound the suppression window so a stalled teardown cannot hide
      // unrelated later errors indefinitely.
      self.isStoppingForBackground = false
      self.backgroundStopSuppressionTask = nil
    }
  }

  private func endBackgroundStopErrorSuppression() {
    backgroundStopSuppressionTask?.cancel()
    backgroundStopSuppressionTask = nil
    isStoppingForBackground = false
  }

  // MARK: - Session observation

  private func observeSession(_ session: DeviceSession) {
    session.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleSessionStateChange(state) }
    }.store(in: sessionTokenBag)
    session.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleSessionError(error) }
    }.store(in: sessionTokenBag)
  }

  private func handleSessionStateChange(_ state: DeviceSessionState) {
    DiagnosticsLog.shared.add("session state -> \(state)")
    sessionState = state
    if state == .stopped {
      endBackgroundStopErrorSuppression()
      cleanupSession()
    }
  }

  private func handleSessionError(_ error: DeviceSessionError) {
    DiagnosticsLog.shared.add("session error: \(describeError(error)) (stoppingForBackground=\(isStoppingForBackground))")
    // Backgrounding the app intentionally ends the preview session; the SDK can
    // still emit teardown errors while that stop converges, and surfacing those
    // would show a false "something went wrong" alert on return.
    guard !isStoppingForBackground else { return }
    // All session errors surface through the single alert, including
    // `datAppOnTheGlassesUpdateRequired`, which the SDK delivers as a one-shot event.
    showError(describeError(error))
  }

  /// Terminal session cleanup — drop the reference and observers so the next
  /// `startSession()` creates a fresh session.
  private func cleanupSession() {
    sessionTokenBag.clear()
    deviceSession = nil
  }

  // MARK: - Stream observation

  private func setupStreamListeners(for stream: MWDATCamera.Stream) {
    stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStreamStateChange(state) }
    }.store(in: streamTokenBag)

    stream.videoFramePublisher.listen { [weak self] frame in
      guard let self else { return }

      // Append to the recorder (no-op unless recording) off the main actor so it
      // keeps writing while the app is backgrounded.
      self.appendVideoFrame(frame)

      // Decode the compressed hvc1 frame for preview off the main actor.
      let previewImage = self.videoFrameDecoder.decode(frame.sampleBuffer)

      Task { @MainActor [weak self] in
        guard let self else { return }
        // Keep the live surface stable while a capture preview is onscreen.
        if UIApplication.shared.applicationState != .background,
          activePreview == nil,
          !isCapturingPhoto,
          let image = previewImage
        {
          self.currentVideoFrame = image
          if !self.hasReceivedFirstFrame {
            self.hasReceivedFirstFrame = true
          }
        }
        // Capture the actual recording start (first written frame) once, so the timer
        // anchors to the clip's start and matches its duration.
        if self.isRecording, self.recordingStartDate == nil {
          self.recordingStartDate = self.videoRecorder.recordingStartDate
        }
      }
    }.store(in: streamTokenBag)

    stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleStreamError(error) }
    }.store(in: streamTokenBag)

    stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }.store(in: streamTokenBag)
  }

  private func handleStreamStateChange(_ state: StreamState) {
    DiagnosticsLog.shared.add("stream state -> \(state)")
    streamState = state
    if state == .stopped {
      // Terminal — finalize any recording, then converge teardown. Covers both
      // user-initiated stop and SDK auto-stop (disconnect, error, session end).
      Task { await stopVideoRecording() }
      clearStreamResources()
    }
  }

  /// Single stream-teardown convergence point.
  private func clearStreamResources() {
    streamTokenBag.clear()
    // Detach the camera (idempotent) so a subsequent addCamera() can register a new one. On the
    // user-stop and session-end paths the camera is already stopped, so this is a no-op; it is
    // load-bearing only when the stream terminates on its own (a stream-level error while the
    // session stays connected), since teardown cascades parent->child but not child->parent.
    stream?.stop()
    stream = nil
    streamState = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
  }

  /// Appends a frame to the recorder. `nonisolated` so it keeps writing while the
  /// app is backgrounded (the recorder is thread-safe).
  nonisolated private func appendVideoFrame(_ frame: VideoFrame) {
    videoRecorder.appendVideoFrame(frame.sampleBuffer)
  }

  private func handleStreamError(_ error: StreamError) {
    DiagnosticsLog.shared.add("stream error: \(describeError(error)) (stoppingForBackground=\(isStoppingForBackground))")
    // Same bounded suppression window as `handleSessionError`: hide only the
    // expected teardown noise from an intentional background-driven stop.
    guard !isStoppingForBackground else { return }
    showError(describeError(error))
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      activePreview = .photo(image)
    }
  }

  private func showError(_ message: String) {
    DiagnosticsLog.shared.add("ALERT: \(message)")
    errorMessage = message
    showError = true
  }
}
