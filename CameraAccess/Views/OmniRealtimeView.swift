/*
 * Omni Realtime View
 * Real-time multimodal conversation interface
 */

import SwiftUI

struct OmniRealtimeView: View {
    @StateObject private var viewModel: OmniRealtimeViewModel
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var frameTimer: Timer?

    init(streamViewModel: StreamSessionViewModel, apiKey: String) {
        self.streamViewModel = streamViewModel
        self._viewModel = StateObject(wrappedValue: OmniRealtimeViewModel(apiKey: apiKey, streamViewModel: streamViewModel))
    }

    var body: some View {
        ZStack {
            // Video background from glasses
            if viewModel.inputMode == .vision, let videoFrame = streamViewModel.currentVideoFrame {
                Image(uiImage: videoFrame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .opacity(0.3)
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // Header
                headerView

                inputModeView

                // Conversation history
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.conversationHistory) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }

                            // Current AI response (streaming)
                            if !viewModel.currentTranscript.isEmpty {
                                MessageBubble(
                                    message: ConversationMessage(
                                        role: .assistant,
                                        content: viewModel.currentTranscript
                                    )
                                )
                                .id("current")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.conversationHistory.count) { _, _ in
                        if let lastMessage = viewModel.conversationHistory.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: viewModel.currentTranscript) { _, _ in
                        withAnimation {
                            proxy.scrollTo("current", anchor: .bottom)
                        }
                    }
                }

                // Status and controls
                controlsView
            }
        }
        .task {
            // The realtime screen enters voice-only even when it was
            // opened from the regular streaming screen.
            if streamViewModel.streamingStatus != .stopped {
                await streamViewModel.stopSession()
            }
            guard !Task.isCancelled else { return }
            viewModel.connect()
        }
        .onDisappear {
            stopFrameUpdates()
            viewModel.disconnect()
        }
        .onChange(of: viewModel.inputMode) { _, mode in
            if mode == .vision {
                startFrameUpdates()
            } else {
                stopFrameUpdates()
            }
        }
        .onChange(of: streamViewModel.streamingStatus) { _, status in
            guard viewModel.inputMode == .vision, status != .streaming else { return }
            viewModel.handleVisionStreamFailure()
        }
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定") {
                viewModel.dismissError()
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }

    private func startFrameUpdates() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                guard viewModel.inputMode == .vision,
                      let frame = streamViewModel.currentVideoFrame else { return }
                viewModel.updateVideoFrame(frame)
            }
        }
    }

    private func stopFrameUpdates() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("AI 实时对话")
                .font(.headline)
                .foregroundColor(.white)

            Spacer()

            // Connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.isConnected ? "已连接" : "未连接")
                    .font(.caption)
                    .foregroundColor(.white)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .font(.title2)
            }
        }
        .padding()
        .background(Color.black.opacity(0.7))
    }

    // MARK: - Controls

    private var controlsView: some View {
        VStack(spacing: 12) {
            // Speaking indicator
            if viewModel.isSpeaking {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                    Text("正在说话...")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.2))
                .cornerRadius(20)
            }

            // Recording status
            HStack(spacing: 8) {
                if viewModel.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("录音中")
                        .font(.caption)
                        .foregroundColor(.white)
                } else {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("未录音")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6))
            .cornerRadius(20)

            // Control buttons
            HStack(spacing: 20) {
                // Start/Stop Recording
                Button {
                    if viewModel.isRecording {
                        viewModel.stopRecording()
                    } else {
                        viewModel.startRecording()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: viewModel.isRecording ? "mic.fill" : "mic.slash.fill")
                            .font(.title)
                        Text(viewModel.isRecording ? "停止" : "开始")
                            .font(.caption)
                    }
                    .frame(width: 80, height: 80)
                    .background(viewModel.isRecording ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                }
                .disabled(!viewModel.isConnected)
            }
            .padding()
        }
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var inputModeView: some View {
        VStack(spacing: 8) {
            Picker("liveai.input.mode".localized, selection: Binding(
                get: { viewModel.inputMode },
                set: { mode in
                    Task { await viewModel.setInputMode(mode) }
                })) {
                ForEach(LiveAIInputMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isSwitchingInputMode)

            HStack(spacing: 6) {
                Image(systemName: viewModel.inputMode.icon)
                Text(viewModel.inputMode.privacyDescription)
                if viewModel.inputMode == .vision {
                    Text("· " + String(format: "liveai.input.vision.count".localized, viewModel.sentImageCount))
                }
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.65))
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ConversationMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(message.role == .user ? Color.blue : Color.gray.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(18)

                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 4)
            }

            if message.role == .assistant {
                Spacer()
            }
        }
    }
}

// MARK: - Preview
// Preview requires real wearables instance
