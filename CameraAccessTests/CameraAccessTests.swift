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

  func testStreamingTextUsesTextAndStashWithoutDuplicatingConfirmedPrefix() {
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
    XCTAssertEqual(update.turns.first?.translatedText, "你好，世界")
  }

  func testSourceAndTranslationArrivingOutOfOrderUpsertOneStableRecord() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .en, targetLanguage: .zh)

    let translationUpdate = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "assistant-1", confirmedText: "你好", pendingText: "", isFinal: true)
    )
    XCTAssertEqual(translationUpdate.recordsToUpsert.count, 1)
    let firstID = try! XCTUnwrap(translationUpdate.recordsToUpsert.first?.id)
    XCTAssertEqual(translationUpdate.recordsToUpsert.first?.originalText, "")

    let sourceUpdate = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "Hello", pendingText: "", isFinal: true)
    )
    XCTAssertEqual(sourceUpdate.recordsToUpsert.count, 1)
    XCTAssertEqual(sourceUpdate.recordsToUpsert.first?.id, firstID)
    XCTAssertEqual(sourceUpdate.recordsToUpsert.first?.originalText, "Hello")
    XCTAssertEqual(sourceUpdate.recordsToUpsert.first?.translatedText, "你好")
  }

  func testExplicitItemLinksPairInterleavedResponsesWithTheirSources() {
    var coordinator = TranslationTurnCoordinator(sourceLanguage: .en, targetLanguage: .zh)
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-1", confirmedText: "One", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveSource(
      TranslateSourceTranscriptEvent(itemID: "source-2", confirmedText: "Two", pendingText: "", isFinal: true)
    )
    _ = coordinator.receiveLink(sourceItemID: "source-2", responseItemID: "assistant-2")
    _ = coordinator.receiveLink(sourceItemID: "source-1", responseItemID: "assistant-1")

    _ = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-2", itemID: "assistant-2", confirmedText: "二", pendingText: "", isFinal: true)
    )
    let update = coordinator.receiveTranslation(
      TranslateTextEvent(responseID: "response-1", itemID: "assistant-1", confirmedText: "一", pendingText: "", isFinal: true)
    )

    XCTAssertEqual(update.recordsToUpsert.map(\.originalText), ["One", "Two"])
    XCTAssertEqual(update.recordsToUpsert.map(\.translatedText), ["一", "二"])
  }
}

final class LiveTranslateAudioQueueTests: XCTestCase {

  func testResponseAudioDoneDoesNotCompleteUntilDataPlayedBack() {
    var queue = TranslationAudioQueue()
    queue.append(Data([1, 2]), responseID: "response-a")
    queue.append(Data([3, 4]), responseID: "response-b")
    queue.markServerFinished("response-b")

    XCTAssertNil(queue.beginNextIfReady(), "The head response must wait for audio.done")

    queue.markServerFinished("response-a")
    XCTAssertEqual(queue.beginNextIfReady()?.responseID, "response-a")
    XCTAssertEqual(queue.pendingCount, 1)
    XCTAssertFalse(queue.complete("response-b"), "A later response cannot complete early")
    XCTAssertTrue(queue.complete("response-a"))
    XCTAssertEqual(queue.beginNextIfReady()?.responseID, "response-b")
  }
}

final class LiveTranslateHistoryStorageTests: XCTestCase {

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
}
