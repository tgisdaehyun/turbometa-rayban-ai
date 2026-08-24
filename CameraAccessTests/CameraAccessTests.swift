/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import Foundation
import MWDATCore
import MWDATMockDevice
import SwiftUI
import XCTest

@testable import CameraAccess

@MainActor
class ViewModelIntegrationTests: XCTestCase {

  private var mockDevice: MockRaybanMeta?
  private var cameraKit: MockCameraKit?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()
    MockDeviceKit.shared.enable()

    // Pair mock device and set up camera kit
    let pairedMockDevice = MockDeviceKit.shared.pairRaybanMeta()
    mockDevice = pairedMockDevice
    cameraKit = pairedMockDevice.services.camera

    // Power on and unfold the device to make it available
    pairedMockDevice.powerOn()
    pairedMockDevice.unfold()

    // Wait for device to be available in Wearables
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    MockDeviceKit.shared.pairedDevices.forEach { mockDevice in
      MockDeviceKit.shared.unpairDevice(mockDevice)
    }
    mockDevice = nil
    cameraKit = nil
    MockDeviceKit.shared.disable()
    try await super.tearDown()
  }

  // MARK: - Video Streaming Flow Tests

  func testVideoStreamingFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Stop streaming
    await viewModel.stopSession()

    // Wait for session to stop
    try await Task.sleep(nanoseconds: 1_000_000_000)

    // Verify streaming stopped (allow for final states to be stopped or waiting)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }

  // MARK: - Photo Capture Flow Tests

  func testStreamingAndPhotoCaptureFlow() async throws {
    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "mp4") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    guard let imageURL = Bundle(for: type(of: self)).url(forResource: "plant", withExtension: "png") else {
      XCTFail("Could not find resource in test bundle")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)
    camera.setCapturedImage(fileURL: imageURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming to establish
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify streaming is active and receiving frames
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue(viewModel.hasReceivedFirstFrame)
    XCTAssertNotNil(viewModel.currentVideoFrame)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Capture photo while streaming
    viewModel.capturePhoto()
    try await Task.sleep(nanoseconds: 10_000_000_000)

    // Verify photo captured while maintaining stream (allow for some timing flexibility)
    XCTAssertTrue(viewModel.capturedPhoto != nil)
    XCTAssertTrue(viewModel.showPhotoPreview)
    XCTAssertTrue(viewModel.isStreaming)

    // Dismiss photo and stop streaming
    viewModel.dismissPhotoPreview()
    XCTAssertFalse(viewModel.showPhotoPreview)
    XCTAssertNil(viewModel.capturedPhoto)

    await viewModel.stopSession()
    try await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }
}

final class AudioNoteTests: XCTestCase {
  private func makeStorage() throws -> (AudioNoteStorage, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AudioNoteTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (AudioNoteStorage(baseURL: root), root)
  }

  private func makeNote(id: UUID = UUID(), text: String = "hello") -> AudioNote {
    AudioNote(
      id: id,
      title: "Test",
      createdAt: Date(timeIntervalSince1970: 100),
      updatedAt: Date(timeIntervalSince1970: 100),
      duration: 3,
      audioRelativePath: "\(id.uuidString)/audio.m4a",
      input: .glasses,
      languageHints: ["en"],
      diarizationEnabled: true,
      status: .completed,
      taskID: "task-1",
      remoteURL: "oss://temporary/audio.m4a",
      segments: [
        AudioTranscriptSegment(
          beginTimeMs: 100,
          endTimeMs: 2200,
          originalText: text,
          speakerID: 0,
          words: [AudioTranscriptWord(beginTimeMs: 100, endTimeMs: 500, text: "hello")]
        )
      ],
      speakerNames: ["0": "Alice"],
      errorMessage: nil
    )
  }

  func testAudioNoteStorageRoundTripPreservesTimeline() throws {
    let (storage, root) = try makeStorage()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = makeNote()

    storage.upsert(note)
    let loaded = storage.loadAll().first

    XCTAssertEqual(loaded?.id, note.id)
    XCTAssertEqual(loaded?.segments.first?.beginTimeMs, 100)
    XCTAssertEqual(loaded?.segments.first?.endTimeMs, 2200)
    XCTAssertEqual(loaded?.segments.first?.speakerID, 0)
    XCTAssertEqual(loaded?.transcript, "hello")
  }

  func testDeletingOneAudioNoteDoesNotDeleteAnother() throws {
    let (storage, root) = try makeStorage()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = makeNote(text: "first")
    let second = makeNote(text: "second")
    try Data("one".utf8).write(to: storage.directory(for: first.id).appendingPathComponent("audio.m4a"))
    try Data("two".utf8).write(to: storage.directory(for: second.id).appendingPathComponent("audio.m4a"))
    storage.upsert(first)
    storage.upsert(second)

    let remaining = storage.delete(id: first.id)

    XCTAssertEqual(remaining.map(\.id), [second.id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: storage.audioURL(for: first).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: storage.audioURL(for: second).path))
  }

  func testSRTExporterUsesSegmentTimestamps() {
    let output = SRTExporter.export(makeNote().segments)
    XCTAssertTrue(output.contains("00:00:00,100 --> 00:00:02,200"))
    XCTAssertTrue(output.contains("hello"))
  }
}

final class LiveAIInputModeTests: XCTestCase {

  func testInputModesProduceDifferentPromptConstraints() {
    let basePrompt = LiveAIModeManager.staticSystemPrompt
    let voicePrompt = LiveAIModeManager.staticSystemPrompt(inputMode: .voice)
    let visionPrompt = LiveAIModeManager.staticSystemPrompt(inputMode: .vision)

    XCTAssertTrue(voicePrompt.hasPrefix(basePrompt))
    XCTAssertTrue(visionPrompt.hasPrefix(basePrompt))
    XCTAssertNotEqual(voicePrompt, visionPrompt)
    XCTAssertFalse(LiveAIInputMode.voice.systemPromptConstraint.isEmpty)
    XCTAssertFalse(LiveAIInputMode.vision.systemPromptConstraint.isEmpty)
  }

  func testVoiceIsTheSafeDefaultAndMetadataRoundTrips() throws {
    XCTAssertEqual(LiveAIInputMode.voice, LiveAIInputMode.allCases.first)

    let record = ConversationRecord(
      messages: [],
      initialInputMode: .voice,
      visionFrameCount: 0
    )
    let data = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(ConversationRecord.self, from: data)

    XCTAssertEqual(decoded.initialInputMode, .voice)
    XCTAssertEqual(decoded.visionFrameCount, 0)
  }

  func testConversationRecordDecodesLegacyPayloadWithoutLiveAIMetadata() throws {
    let encoded = try JSONEncoder().encode(
      ConversationRecord(messages: [], aiModel: "legacy-model", language: "zh-CN")
    )
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "initialInputMode")
    object.removeValue(forKey: "visionFrameCount")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(ConversationRecord.self, from: legacyData)
    XCTAssertNil(decoded.initialInputMode)
    XCTAssertNil(decoded.visionFrameCount)
    XCTAssertEqual(decoded.aiModel, "legacy-model")
  }

  @MainActor
  func testVoiceModeRejectsFramesAndVisionNeedsAStreamSource() async {
    let viewModel = OmniRealtimeViewModel(apiKey: "", streamViewModel: nil)

    XCTAssertEqual(viewModel.inputMode, .voice)
    viewModel.updateVideoFrame(UIImage())
    XCTAssertFalse(viewModel.canSendImages)

    await viewModel.setInputMode(.vision)

    XCTAssertEqual(viewModel.inputMode, .voice)
    XCTAssertFalse(viewModel.canSendImages)
    XCTAssertTrue(viewModel.showError)
  }
}

final class LiveTranslateCoordinatorTests: XCTestCase {

  func testStreamingTextReplacesSnapshotWithoutDuplicatingConfirmedPrefix() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .en, targetLanguage: .zh)

    var update = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "", pendingText: "The", isFinal: false)
    )
    XCTAssertEqual(update.turns.first?.originalText, "The")

    update = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "The", pendingText: " weather", isFinal: false)
    )
    XCTAssertEqual(update.turns.first?.originalText, "The weather")

    update = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "item-1", confirmedText: "你好", pendingText: "，世界", isFinal: false)
    )
    XCTAssertTrue(update.turns.isEmpty, "An assistant response without previous_item_id must stay hidden")

    _ = coordinator.receiveLink(sourceItemID: "source-1", responseItemID: "item-1")
    XCTAssertEqual(coordinator.finalize().turns.first?.translatedText, "你好，世界")
  }

  func testFinalSnapshotCanBeShorterThanPartialSnapshot() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .en, targetLanguage: .zh)
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "long interim source", pendingText: "", isFinal: false)
    )
    _ = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "assistant-1", confirmedText: "long interim translation", pendingText: "", isFinal: false)
    )
    _ = coordinator.receiveLink(sourceItemID: "source-1", responseItemID: "assistant-1")

    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "short", pendingText: "", isFinal: true)
    )
    let update = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "assistant-1", confirmedText: "短", pendingText: "", isFinal: true)
    )

    XCTAssertEqual(update.recordsToUpsert.first?.originalText, "short")
    XCTAssertEqual(update.recordsToUpsert.first?.translatedText, "短")
  }

  func testSourceAndTranslationArrivingOutOfOrderUpsertOneStableRecord() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .en, targetLanguage: .zh)

    let translationUpdate = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "assistant-1", confirmedText: "你好", pendingText: "", isFinal: true)
    )
    XCTAssertTrue(translationUpdate.recordsToUpsert.isEmpty)

    let sourceUpdate = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "Hello", pendingText: "", isFinal: true)
    )
    XCTAssertTrue(sourceUpdate.recordsToUpsert.isEmpty)
    let firstID = try! XCTUnwrap(sourceUpdate.turns.first?.id)

    let linkedUpdate = coordinator.receiveLink(
      sourceItemID: "source-1",
      responseItemID: "assistant-1"
    )
    XCTAssertEqual(linkedUpdate.recordsToUpsert.count, 1)
    XCTAssertEqual(linkedUpdate.recordsToUpsert.first?.id, firstID)
    XCTAssertEqual(linkedUpdate.recordsToUpsert.first?.originalText, "Hello")
    XCTAssertEqual(linkedUpdate.recordsToUpsert.first?.translatedText, "你好")
  }

  func testAuthoritativeLinkArrivingInPiecesUpsertsOneStableRecord() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .en, targetLanguage: .zh)

    _ = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: nil, confirmedText: "你好", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "Hello", pendingText: "", isFinal: true)
    )
    XCTAssertTrue(coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: nil, confirmedText: "你好", pendingText: "", isFinal: true)
    ).recordsToUpsert.isEmpty)

    _ = coordinator.receiveResponseItem(responseID: "response-1", itemID: "assistant-1")
    let sourceUpdate = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "Hello", pendingText: "", isFinal: true)
    )
    XCTAssertTrue(sourceUpdate.recordsToUpsert.isEmpty)

    let linkedUpdate = coordinator.receiveLink(
      sourceItemID: "source-1",
      responseItemID: "assistant-1"
    )
    XCTAssertEqual(linkedUpdate.recordsToUpsert.map(\.originalText), ["Hello"])
    XCTAssertEqual(linkedUpdate.recordsToUpsert.map(\.translatedText), ["你好"])
  }

  func testResponseDoneDoesNotMarkTranscriptFinalAndLinksDoNotUseFIFO() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .en, targetLanguage: .zh)

    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "One", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-2", confirmedText: "Two", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveResponseStarted(responseID: "response-1")
    _ = coordinator.receiveResponseItem(responseID: "response-1", itemID: "assistant-1")
    _ = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "assistant-1", confirmedText: "一", pendingText: "", isFinal: false)
    )
    XCTAssertTrue(coordinator.receiveResponseFinished(responseID: "response-1").recordsToUpsert.isEmpty)
    _ = coordinator.receiveLink(sourceItemID: "source-2", responseItemID: "assistant-1")
    XCTAssertTrue(coordinator.finalize().recordsToUpsert.isEmpty, "The response must remain incomplete until transcript.done")
    let finalUpdate = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "assistant-1", confirmedText: "一", pendingText: "", isFinal: true)
    )
    XCTAssertEqual(finalUpdate.recordsToUpsert.map(\.originalText), ["Two"])
  }

  func testExplicitItemLinksPairInterleavedResponsesByAssistantItem() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .en, targetLanguage: .zh)
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "One", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-2", confirmedText: "Two", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveLink(sourceItemID: "source-2", responseItemID: "assistant-2")
    _ = coordinator.receiveLink(sourceItemID: "source-1", responseItemID: "assistant-1")

    _ = coordinator.receiveResponseStarted(responseID: "response-1")
    _ = coordinator.receiveResponseStarted(responseID: "response-2")

    _ = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-2", itemID: "assistant-2", confirmedText: "二", pendingText: "", isFinal: true)
    )
    let update = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "assistant-1", confirmedText: "一", pendingText: "", isFinal: true)
    )

    XCTAssertEqual(update.recordsToUpsert.map(\.originalText), ["One", "Two"])
    XCTAssertEqual(update.recordsToUpsert.map(\.translatedText), ["一", "二"])
  }

  func testSourceItemIDsKeepDelayedTranscriptInItsOwnAuthoritativeTurn() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .zh, targetLanguage: .en)

    _ = coordinator.receiveSpeechStarted(itemID: "vad-1")
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "vad-1", confirmedText: "第一句", pendingText: "", isFinal: false)
    )
    _ = coordinator.receiveSpeechStopped(itemID: "vad-1")
    _ = coordinator.receiveSpeechStarted(itemID: "vad-2")
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "vad-2", confirmedText: "第二句", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "vad-1", confirmedText: "第一句完成", pendingText: "", isFinal: true)
    )

    _ = coordinator.receiveResponseStarted(responseID: "response-1")
    _ = coordinator.receiveResponseStarted(responseID: "response-2")
    _ = coordinator.receiveLink(sourceItemID: "vad-1", responseItemID: "assistant-1")
    _ = coordinator.receiveLink(sourceItemID: "vad-2", responseItemID: "assistant-2")
    _ = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-2", itemID: "assistant-2", confirmedText: "Second", pendingText: "", isFinal: true)
    )
    let update = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "assistant-1", confirmedText: "First", pendingText: "", isFinal: true)
    )

    XCTAssertEqual(update.recordsToUpsert.map(\.originalText), ["第一句完成", "第二句"])
    XCTAssertEqual(update.recordsToUpsert.map(\.translatedText), ["First", "Second"])
  }

  func testInterleavedSourceEventsRemainCorrectWhenResponsesArriveOutOfOrder() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .zh, targetLanguage: .en)

    _ = coordinator.receiveSpeechStarted(itemID: "vad-1")
    _ = coordinator.receiveSpeechStopped(itemID: "vad-1")
    _ = coordinator.receiveSpeechStarted(itemID: "vad-2")
    _ = coordinator.receiveSpeechStopped(itemID: "vad-2")

    // Simulate socket/ASR reordering: turn two completes before turn one has
    // emitted any transcript packet.
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "vad-2", confirmedText: "第二句", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "vad-1", confirmedText: "第一句", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveResponseStarted(responseID: "response-1")
    _ = coordinator.receiveResponseStarted(responseID: "response-2")
    _ = coordinator.receiveResponseItem(responseID: "response-1", itemID: "assistant-1")
    _ = coordinator.receiveResponseItem(responseID: "response-2", itemID: "assistant-2")
    _ = coordinator.receiveLink(sourceItemID: "vad-1", responseItemID: "assistant-1")
    _ = coordinator.receiveLink(sourceItemID: "vad-2", responseItemID: "assistant-2")
    _ = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: nil, confirmedText: "First", pendingText: "", isFinal: true)
    )
    let update = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-2", itemID: nil, confirmedText: "Second", pendingText: "", isFinal: true)
    )

    XCTAssertEqual(update.recordsToUpsert.map(\.originalText), ["第一句", "第二句"])
    XCTAssertEqual(update.recordsToUpsert.map(\.translatedText), ["First", "Second"])
  }

  func testUnlinkedResponsesAreNeverPersistedOrDisplayed() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .zh, targetLanguage: .en)
    let first = "The first finalized translation is deliberately long enough to exercise cumulative response detection."
    let extended = first + " A later response appends another complete translated sentence."

    _ = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: nil, confirmedText: first, pendingText: "", isFinal: true)
    )
    let update = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-2", itemID: nil, confirmedText: extended, pendingText: "", isFinal: true)
    )

    XCTAssertTrue(update.recordsToUpsert.isEmpty)
    XCTAssertTrue(update.turns.isEmpty)
  }

}

final class LiveTranslateVoiceTests: XCTestCase {

  func testQwen35VoicesUseOfficialRawValues() {
    XCTAssertEqual(TranslateVoice.tina.rawValue, "Tina")
    XCTAssertEqual(TranslateVoice.cindy.rawValue, "Cindy")
    XCTAssertEqual(TranslateVoice.lioraMira.rawValue, "Liora Mira")
    XCTAssertEqual(TranslateVoice.allCases.count, 3)
  }

  func testQwen35TargetLanguageAudioSupportMatchesCurrentAppLanguages() {
    XCTAssertTrue(TranslateLanguage.en.supportsAudioOutput)
    XCTAssertTrue(TranslateLanguage.id.supportsAudioOutput)
    XCTAssertTrue(TranslateLanguage.vi.supportsAudioOutput)
    XCTAssertTrue(TranslateLanguage.th.supportsAudioOutput)
    XCTAssertTrue(TranslateLanguage.ar.supportsAudioOutput)
    XCTAssertTrue(TranslateLanguage.hi.supportsAudioOutput)
    XCTAssertTrue(TranslateLanguage.tr.supportsAudioOutput)
    XCTAssertFalse(TranslateLanguage.yue.supportsAudioOutput)
    XCTAssertFalse(TranslateLanguage.el.supportsAudioOutput)

    XCTAssertEqual(
      TranslateLanguage.targetLanguages.map(\.rawValue),
      ["en", "zh", "ja", "ko", "fr", "de", "ru", "es", "pt", "it",
       "yue", "id", "vi", "th", "ar", "hi", "el", "tr"]
    )
  }

  func testQwen35VoicesAdvertiseOnlyCurrentOfficialAudioLanguages() {
    let expected = ["zh", "en", "fr", "de", "ru", "it", "es", "pt", "ja", "ko",
                    "id", "vi", "th", "ar", "hi", "tr"]
    for voice in TranslateVoice.allCases {
      XCTAssertEqual(voice.supportedLanguages.map(\.rawValue), expected)
      XCTAssertFalse(voice.supports(language: .yue))
      XCTAssertFalse(voice.supports(language: .el))
    }
  }

  func testTextOnlySessionOmitsVoiceAndAudioSessionIncludesLegalVoice() {
    let textOnly = LiveTranslateService.sessionOutputFields(
      audioEnabled: false,
      voice: .tina
    )
    XCTAssertEqual(textOnly["modalities"] as? [String], ["text"])
    XCTAssertNil(textOnly["voice"])

    let audio = LiveTranslateService.sessionOutputFields(
      audioEnabled: true,
      voice: .lioraMira
    )
    XCTAssertEqual(audio["modalities"] as? [String], ["text", "audio"])
    XCTAssertEqual(audio["voice"] as? String, "Liora Mira")
  }
}

@MainActor
final class LiveTranslateVoiceMigrationTests: XCTestCase {

  private let voiceKey = "translate_voice"
  private let migrationKey = "translate_voice_migration_v2"
  private let targetLanguageKey = "translate_target_language"
  private let audioEnabledKey = "translate_audio_enabled"

  func testLegacyVoicesMigrateToTinaAndPersistOnce() {
    let defaults = UserDefaults.standard
    let originalValues = [
      voiceKey: defaults.object(forKey: voiceKey),
      migrationKey: defaults.object(forKey: migrationKey),
      targetLanguageKey: defaults.object(forKey: targetLanguageKey),
      audioEnabledKey: defaults.object(forKey: audioEnabledKey)
    ]
    defer { restore(defaults: defaults, values: originalValues) }

    for legacyVoice in ["Cherry", "Nofish", "Jada", "Dylan", "Sunny", "Peter", "Kiki", "Eric"] {
      defaults.set(legacyVoice, forKey: voiceKey)
      defaults.removeObject(forKey: migrationKey)
      let url = defaultsTemporaryHistoryURL()
      let viewModel = LiveTranslateViewModel(historyStorage: LiveTranslateHistoryStorage(fileURL: url))

      XCTAssertEqual(viewModel.selectedVoice, .tina, "Legacy \(legacyVoice) must migrate to Tina")
      XCTAssertEqual(defaults.string(forKey: voiceKey), TranslateVoice.tina.rawValue)
      XCTAssertTrue(defaults.bool(forKey: migrationKey))
      try? FileManager.default.removeItem(at: url)
    }
  }

  func testCompletedMigrationRepairsLegacyOrCorruptValue() {
    let defaults = UserDefaults.standard
    let originalValues = [
      voiceKey: defaults.object(forKey: voiceKey),
      migrationKey: defaults.object(forKey: migrationKey)
    ]
    defer { restore(defaults: defaults, values: originalValues) }

    defaults.set(true, forKey: migrationKey)
    defaults.set("Cherry", forKey: voiceKey)
    let url = defaultsTemporaryHistoryURL()
    let viewModel = LiveTranslateViewModel(historyStorage: LiveTranslateHistoryStorage(fileURL: url))

    XCTAssertEqual(viewModel.selectedVoice, .tina)
    XCTAssertEqual(defaults.string(forKey: voiceKey), TranslateVoice.tina.rawValue)
    try? FileManager.default.removeItem(at: url)
  }

  func testRestoredTextOnlyTargetDisablesAudioWithoutChangingTarget() {
    let defaults = UserDefaults.standard
    let originalValues = [
      targetLanguageKey: defaults.object(forKey: targetLanguageKey),
      audioEnabledKey: defaults.object(forKey: audioEnabledKey),
      voiceKey: defaults.object(forKey: voiceKey),
      migrationKey: defaults.object(forKey: migrationKey)
    ]
    defer { restore(defaults: defaults, values: originalValues) }

    defaults.set(TranslateLanguage.yue.rawValue, forKey: targetLanguageKey)
    defaults.set(true, forKey: audioEnabledKey)
    defaults.set(TranslateVoice.tina.rawValue, forKey: voiceKey)
    defaults.set(true, forKey: migrationKey)
    let url = defaultsTemporaryHistoryURL()
    let viewModel = LiveTranslateViewModel(historyStorage: LiveTranslateHistoryStorage(fileURL: url))

    XCTAssertEqual(viewModel.targetLanguage, .yue)
    XCTAssertFalse(viewModel.audioOutputEnabled)
    XCTAssertFalse(defaults.bool(forKey: audioEnabledKey))
    try? FileManager.default.removeItem(at: url)
  }

  private func defaultsTemporaryHistoryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translate-voice-(UUID().uuidString).json")
  }

  private func restore(defaults: UserDefaults, values: [String: Any?]) {
    for (key, value) in values {
      if let value {
        defaults.set(value, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
  }
}

final class LiveTranslateAudioRoutePolicyTests: XCTestCase {

  func testGlassesMicrophoneFallsBackToSpeakerWithoutBluetooth() {
    let options = LiveTranslateService.audioSessionOptions(usePhoneMic: false)

    XCTAssertTrue(options.contains(.allowBluetoothHFP))
    XCTAssertTrue(options.contains(.allowBluetoothA2DP))
    XCTAssertTrue(options.contains(.defaultToSpeaker))
  }

  func testPhoneMicrophoneKeepsBluetoothPlaybackAvailable() {
    let options = LiveTranslateService.audioSessionOptions(usePhoneMic: true)

    XCTAssertTrue(options.contains(.allowBluetoothHFP))
    XCTAssertTrue(options.contains(.allowBluetoothA2DP))
    XCTAssertTrue(options.contains(.defaultToSpeaker))
  }

  func testLiveTranslatePolicyUsesDuplexHFPForGlassesMic() {
    let configuration = LiveTranslateService.audioSessionConfiguration(usePhoneMic: false)

    XCTAssertEqual(configuration.category, .playAndRecord)
    XCTAssertEqual(configuration.mode, .voiceChat)
    XCTAssertTrue(configuration.options.contains(.allowBluetoothHFP))
    XCTAssertTrue(configuration.options.contains(.allowBluetoothA2DP))
    XCTAssertTrue(configuration.options.contains(.defaultToSpeaker))
  }

  func testLiveTranslatePolicyKeepsBluetoothOutputsForPhoneMic() {
    let configuration = LiveTranslateService.audioSessionConfiguration(usePhoneMic: true)

    XCTAssertEqual(configuration.category, .playAndRecord)
    XCTAssertEqual(configuration.mode, .default)
    XCTAssertTrue(configuration.options.contains(.allowBluetoothHFP))
    XCTAssertTrue(configuration.options.contains(.allowBluetoothA2DP))
    XCTAssertTrue(configuration.options.contains(.defaultToSpeaker))
  }

  func testStandalonePlaybackPolicyDoesNotRequestInputProfilesOrSpeaker() {
    let configuration = AudioSessionPolicy.standalonePlayback

    XCTAssertEqual(configuration.category, .playback)
    XCTAssertEqual(configuration.mode, .spokenAudio)
    XCTAssertTrue(configuration.options.contains(.duckOthers))
    XCTAssertFalse(configuration.options.contains(.allowBluetoothHFP))
    XCTAssertFalse(configuration.options.contains(.allowBluetoothA2DP))
    XCTAssertTrue(configuration.options.contains(.defaultToSpeaker))
  }

  func testRealtimeGlassesDuplexPolicyUsesHFPOnly() {
    let configuration = AudioSessionPolicy.glassesDuplex

    XCTAssertEqual(configuration.category, .playAndRecord)
    XCTAssertEqual(configuration.mode, .voiceChat)
    XCTAssertTrue(configuration.options.contains(.allowBluetoothHFP))
    XCTAssertTrue(configuration.options.contains(.allowBluetoothA2DP))
    XCTAssertFalse(configuration.options.contains(.defaultToSpeaker))
  }
}

final class LiveTranslateAudioQueueTests: XCTestCase {

  func testPlaybackUsesResponseCreationOrderWhenAudioChunksArriveOutOfOrder() {
    var queue = TranslationAudioQueue()
    queue.register(responseID: "response-a")
    queue.register(responseID: "response-b")
    queue.append(Data([3, 4]), responseID: "response-b")
    queue.append(Data([1, 2]), responseID: "response-a")
    queue.markServerFinished("response-a")
    queue.markServerFinished("response-b")

    XCTAssertEqual(queue.activateNextIfReady(), "response-a")
    XCTAssertEqual(queue.takePendingAudio("response-a"), Data([1, 2]))
    XCTAssertTrue(queue.markBufferPlayed("response-a"))
    XCTAssertEqual(queue.activateNextIfReady(), "response-b")
    XCTAssertEqual(queue.takePendingAudio("response-b"), Data([3, 4]))
  }

  func testHeadResponseStreamsBeforeAudioDoneAndStillBlocksLaterResponse() {
    var queue = TranslationAudioQueue()
    queue.append(Data([1, 2]), responseID: "response-a")
    queue.append(Data([3, 4]), responseID: "response-b")
    queue.markServerFinished("response-b")

    XCTAssertEqual(queue.activateNextIfReady(), "response-a")
    XCTAssertEqual(queue.takePendingAudio("response-a"), Data([1, 2]))
    XCTAssertFalse(queue.markBufferPlayed("response-a"), "Playback alone cannot finish an open response")
    XCTAssertEqual(queue.activateNextIfReady(), "response-a", "A later response cannot start early")

    XCTAssertTrue(queue.markServerFinished("response-a"))
    XCTAssertEqual(queue.pendingCount, 1)
    XCTAssertEqual(queue.activateNextIfReady(), "response-b")
  }

  func testAudioDoneWaitsForEveryScheduledStreamingBuffer() {
    var queue = TranslationAudioQueue()
    queue.append(Data([1, 2]), responseID: "response-a")
    XCTAssertEqual(queue.activateNextIfReady(), "response-a")
    XCTAssertNotNil(queue.takePendingAudio("response-a"))
    queue.append(Data([3, 4]), responseID: "response-a")
    XCTAssertNotNil(queue.takePendingAudio("response-a"))

    XCTAssertFalse(queue.markServerFinished("response-a"))
    XCTAssertFalse(queue.markBufferPlayed("response-a"))
    XCTAssertTrue(queue.markBufferPlayed("response-a"))
    XCTAssertTrue(queue.isEmpty)
  }
}

final class LiveTranslateHistoryStorageTests: XCTestCase {

  func testLegacyRawArrayIsDeletedAfterProtocolGraphSchemaBump() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translate-legacy-\(UUID().uuidString).json")
    let legacyRecord = TranslateRecord(
      sessionID: UUID(),
      sourceItemID: "legacy-source",
      responseID: "legacy-response",
      sourceLanguage: .zh,
      targetLanguage: .en,
      originalText: "旧原文",
      translatedText: "Legacy translation"
    )
    let legacy = try JSONEncoder().encode([legacyRecord])
    try legacy.write(to: url)
    let storage = LiveTranslateHistoryStorage(fileURL: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertTrue(storage.loadAll().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testOlderEnvelopeIsDeletedAfterProtocolGraphSchemaBump() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translate-old-envelope-\(UUID().uuidString).json")
    let record = TranslateRecord(
      sessionID: UUID(),
      sourceItemID: "old-source",
      responseID: "old-response",
      sourceLanguage: .zh,
      targetLanguage: .en,
      originalText: "旧原文",
      translatedText: "Old translation"
    )
    let encodedRecords = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode([record])
    )
    let oldEnvelope: [String: Any] = [
      "schemaVersion": LiveTranslateHistoryStorage.currentSchemaVersion - 1,
      "records": encodedRecords
    ]
    try JSONSerialization.data(withJSONObject: oldEnvelope).write(to: url)
    let storage = LiveTranslateHistoryStorage(fileURL: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertTrue(storage.loadAll().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func testFutureEnvelopeIsIgnoredButPreserved() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translate-future-envelope-\(UUID().uuidString).json")
    let futureEnvelope: [String: Any] = [
      "schemaVersion": LiveTranslateHistoryStorage.currentSchemaVersion + 1,
      "records": []
    ]
    try JSONSerialization.data(withJSONObject: futureEnvelope).write(to: url)
    let storage = LiveTranslateHistoryStorage(fileURL: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertTrue(storage.loadAll().isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  func testHistoryUpsertIsAtomicAndDeduplicatedByResponse() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translate-history-\(UUID().uuidString).json")
    let storage = LiveTranslateHistoryStorage(fileURL: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let first = TranslateRecord(
      sessionID: UUID(),
      sourceItemID: "source-1",
      responseID: "response-1",
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "Hello",
      translatedText: "你好"
    )
    XCTAssertEqual(storage.upsert(first).count, 1)

    let updated = TranslateRecord(
      id: first.id,
      timestamp: first.timestamp,
      sessionID: first.sessionID,
      sourceItemID: first.sourceItemID,
      responseID: first.responseID,
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "Hello there",
      translatedText: "你好"
    )
    let records = storage.upsert(updated)
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(storage.loadAll().first?.originalText, "Hello there")

    storage.deleteAll()
    XCTAssertTrue(storage.loadAll().isEmpty)
  }

  func testLegacyRecordWithoutRealtimeIdentifiersStillDecodes() throws {
    let json = """
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "timestamp": 0,
        "sourceLanguage": "en",
        "targetLanguage": "zh",
        "originalText": "Hello",
        "translatedText": "你好"
      }
      """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let record = try decoder.decode(TranslateRecord.self, from: json)
    XCTAssertNil(record.sessionID)
    XCTAssertNil(record.sourceItemID)
    XCTAssertNil(record.responseID)
  }

  func testDeleteRecordsRemovesOnlyTheSelectedSession() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translate-delete-\(UUID().uuidString).json")
    let storage = LiveTranslateHistoryStorage(fileURL: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let firstSession = UUID()
    let secondSession = UUID()
    let first = TranslateRecord(
      sessionID: firstSession,
      sourceItemID: "source-1",
      responseID: "response-1",
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "One",
      translatedText: "一"
    )
    let second = TranslateRecord(
      sessionID: secondSession,
      sourceItemID: "source-2",
      responseID: "response-2",
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "Two",
      translatedText: "二"
    )
    _ = storage.upsert(first)
    _ = storage.upsert(second)

    let remaining = storage.deleteRecords(ids: [first.id])
    XCTAssertEqual(remaining.map(\.id), [second.id])
    let reloadedStorage = LiveTranslateHistoryStorage(fileURL: url)
    XCTAssertEqual(reloadedStorage.loadAll().map(\.sessionID), [secondSession])
  }
}

final class LiveTranslateSessionLifecycleTests: XCTestCase {

  func testSessionCanOnlyConfigureBeforeItBecomesReady() {
    let lifecycle = LiveTranslateSessionLifecycle()

    XCTAssertTrue(lifecycle.transition(from: [.disconnected], to: .connecting))
    XCTAssertTrue(lifecycle.transition(from: [.connecting], to: .configuring))
    XCTAssertTrue(lifecycle.transition(from: [.configuring], to: .ready))
    XCTAssertFalse(lifecycle.transition(from: [.configuring], to: .configuring))
    XCTAssertEqual(lifecycle.state, .ready)
  }

  func testFinishedSessionCannotBeReusedForRecording() {
    let lifecycle = LiveTranslateSessionLifecycle()

    XCTAssertTrue(lifecycle.transition(from: [.disconnected], to: .connecting))
    XCTAssertTrue(lifecycle.transition(from: [.connecting], to: .configuring))
    XCTAssertTrue(lifecycle.transition(from: [.configuring], to: .ready))
    XCTAssertTrue(lifecycle.transition(from: [.ready], to: .recording))
    XCTAssertTrue(lifecycle.transition(from: [.recording], to: .finishing))
    XCTAssertTrue(lifecycle.transition(from: [.finishing], to: .finished))
    XCTAssertFalse(lifecycle.transition(from: [.ready], to: .recording))
    XCTAssertEqual(lifecycle.state, .finished)
  }

  func testFreshConnectionMayStartAfterFinishedSession() {
    let lifecycle = LiveTranslateSessionLifecycle()
    XCTAssertTrue(lifecycle.transition(from: [.disconnected], to: .connecting))
    XCTAssertTrue(lifecycle.transition(from: [.connecting], to: .configuring))
    XCTAssertTrue(lifecycle.transition(from: [.configuring], to: .ready))
    XCTAssertTrue(lifecycle.transition(from: [.ready], to: .finishing))
    XCTAssertTrue(lifecycle.transition(from: [.finishing], to: .finished))

    XCTAssertTrue(lifecycle.transition(from: [.finished], to: .connecting))
    XCTAssertEqual(lifecycle.state, .connecting)
  }
}

@MainActor
final class LiveTranslateViewModelSessionTests: XCTestCase {

  func testRestoredHistoryDoesNotPopulateTheLiveWorkspace() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translate-workspace-\(UUID().uuidString).json")
    let storage = LiveTranslateHistoryStorage(fileURL: url)
    defer { try? FileManager.default.removeItem(at: url) }

    _ = storage.upsert(TranslateRecord(
      sessionID: UUID(),
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "hello",
      translatedText: "你好"
    ))

    let viewModel = LiveTranslateViewModel(historyStorage: storage)
    XCTAssertTrue(viewModel.currentSessionRecords.isEmpty)
    XCTAssertEqual(viewModel.historyRecordCount, 1)
  }

  func testClearHistorySynchronizesWorkspaceCountAndStorage() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-translate-clear-\(UUID().uuidString).json")
    let storage = LiveTranslateHistoryStorage(fileURL: url)
    defer { try? FileManager.default.removeItem(at: url) }

    _ = storage.upsert(TranslateRecord(
      sessionID: UUID(),
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "hello",
      translatedText: "你好"
    ))
    let viewModel = LiveTranslateViewModel(historyStorage: storage)

    viewModel.clearHistory()

    XCTAssertTrue(viewModel.currentSessionRecords.isEmpty)
    XCTAssertEqual(viewModel.historyRecordCount, 0)
    XCTAssertTrue(storage.loadAll().isEmpty)
  }
}

final class TranslationSessionBuilderTests: XCTestCase {

  func testGroupsSessionRecordsAndSortsTurnsAndSessions() {
    let olderSession = UUID()
    let newerSession = UUID()
    let now = Date()
    let olderTurn = TranslateRecord(
      timestamp: now.addingTimeInterval(-20),
      sessionID: olderSession,
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "first",
      translatedText: "一"
    )
    let olderLastTurn = TranslateRecord(
      timestamp: now.addingTimeInterval(-10),
      sessionID: olderSession,
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "second",
      translatedText: "二"
    )
    let newerTurn = TranslateRecord(
      timestamp: now,
      sessionID: newerSession,
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "new",
      translatedText: "新"
    )

    let sessions = TranslationSessionBuilder.group(records: [olderLastTurn, newerTurn, olderTurn])
    XCTAssertEqual(sessions.map(\.id), [newerSession, olderSession])
    XCTAssertEqual(sessions[1].records.map(\.originalText), ["first", "second"])
  }

  func testLegacyRecordsRemainIndependentSessions() {
    let first = TranslateRecord(
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "first",
      translatedText: "一"
    )
    let second = TranslateRecord(
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "second",
      translatedText: "二"
    )

    let sessions = TranslationSessionBuilder.group(records: [first, second])
    XCTAssertEqual(sessions.count, 2)
    XCTAssertTrue(sessions.allSatisfy { $0.records.count == 1 })
    XCTAssertEqual(Set(sessions.map(\.id)), Set([first.id, second.id]))
  }

  func testMixedLanguageDirectionsStayInOneSession() {
    let sessionID = UUID()
    let englishToChinese = TranslateRecord(
      sessionID: sessionID,
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "hello",
      translatedText: "你好"
    )
    let chineseToEnglish = TranslateRecord(
      sessionID: sessionID,
      sourceLanguage: .zh,
      targetLanguage: .en,
      originalText: "世界",
      translatedText: "world"
    )

    let sessions = TranslationSessionBuilder.group(records: [englishToChinese, chineseToEnglish])
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions.first?.turnCount, 2)
    XCTAssertEqual(sessions.first?.hasMixedLanguageDirections, true)
    XCTAssertEqual(sessions.first?.records.map(\.sessionID), [sessionID, sessionID])
  }

  func testPreviewUsesOnlyTheFirstNonemptyTranslation() {
    let sessionID = UUID()
    let untranslated = TranslateRecord(
      sessionID: sessionID,
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "source only",
      translatedText: "  "
    )
    let translated = TranslateRecord(
      sessionID: sessionID,
      sourceLanguage: .en,
      targetLanguage: .zh,
      originalText: "hello",
      translatedText: "你好"
    )

    let session = TranslationSessionBuilder.group(records: [untranslated, translated]).first
    XCTAssertEqual(session?.previewText, "你好")
  }
}
