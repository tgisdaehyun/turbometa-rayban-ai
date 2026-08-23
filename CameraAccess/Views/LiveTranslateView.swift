/*
 * Live Translate View
 * 实时翻译主界面
 */

import SwiftUI

struct LiveTranslateView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = LiveTranslateViewModel()
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @State private var showSettings = false
    @State private var shouldAutoScroll = true

    var body: some View {
        ZStack {
            // 背景
            Color.black.ignoresSafeArea()

            // 视频预览（如果启用图像增强）
            if viewModel.imageEnhanceEnabled {
                videoBackground
            }

            // 主内容
            VStack(spacing: 0) {
                // Header
                headerView

                // 语言选择栏
                languageBar

                visionPrivacyBar

                // 翻译结果区域
                translationArea
            }
            // Float the microphone above the list so controls do not reduce the
            // scroll viewport. The list reserves matching bottom content space.
            .overlay(alignment: .bottom) {
                controlBar
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: [Color.black.opacity(0), Color.black.opacity(0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea(edges: .bottom)
                    )
            }
        }
        .task {
            // Entering with vision off releases a camera session left by a
            // previous feature, preserving the zero-capture privacy contract.
            if !viewModel.imageEnhanceEnabled,
               streamViewModel.streamingStatus != .stopped {
                await streamViewModel.stopSession()
            }
            guard !Task.isCancelled else { return }
            viewModel.connect()
            if viewModel.imageEnhanceEnabled {
                await streamViewModel.startSession()
            }
        }
        .onDisappear {
            viewModel.disconnect()
            stopVideoStream()
        }
        .sheet(isPresented: $showSettings) {
            LiveTranslateSettingsView(viewModel: viewModel)
        }
        .alert("livetranslate.error.title".localized, isPresented: $viewModel.showError) {
            Button("common.ok".localized, role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.imageEnhanceEnabled) { _, newValue in
            if newValue {
                startVideoStream()
            } else {
                stopVideoStream()
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            // 标题
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.title2)
                Text("livetranslate.title".localized)
                    .font(AppTypography.title2)
            }
            .foregroundColor(.white)

            Spacer()

            // 连接状态
            connectionIndicator

            // 设置按钮
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 8)

            // 关闭按钮
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var connectionIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(viewModel.isConnected ? "livetranslate.connected".localized : "livetranslate.connecting".localized)
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 16) {
            // 源语言
            languageButton(
                language: viewModel.sourceLanguage,
                label: "livetranslate.source".localized
            ) {
                // 源语言选择（通过设置页面）
                showSettings = true
            }

            // 交换按钮
            Button {
                viewModel.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Circle().fill(Color.white.opacity(0.2)))
            }

            // 目标语言
            languageButton(
                language: viewModel.targetLanguage,
                label: "livetranslate.target".localized
            ) {
                showSettings = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func languageButton(language: TranslateLanguage, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(label)
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.6))
                HStack(spacing: 6) {
                    Text(language.flag)
                        .font(.title2)
                    Text(language.displayName)
                        .font(AppTypography.body)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.1))
            )
        }
    }

    // MARK: - Translation Area

    private var translationArea: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if viewModel.currentSessionRecords.isEmpty && viewModel.activeTurns.isEmpty {
                            Text("livetranslate.placeholder".localized)
                                .font(AppTypography.body)
                                .foregroundColor(.white.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                        }

                        ForEach(viewModel.currentSessionRecords) { record in
                            translationCard(
                                id: record.id,
                                original: record.originalText,
                                translated: record.translatedText,
                                source: record.sourceLanguage,
                                target: record.targetLanguage,
                                timestamp: record.timestamp,
                                isStreaming: false
                            )
                        }

                        ForEach(viewModel.activeTurns) { turn in
                            translationCard(
                                id: turn.id,
                                original: turn.originalText,
                                translated: turn.translatedText,
                                source: viewModel.sourceLanguage,
                                target: viewModel.targetLanguage,
                                timestamp: Date(),
                                isStreaming: true
                            )
                        }

                        Color.clear.frame(height: 116).id("translation-bottom")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 10)
                }
                .simultaneousGesture(DragGesture().onChanged { _ in
                    shouldAutoScroll = false
                })
                .onChange(of: viewModel.currentSessionRecords.count) { _, _ in
                    scrollToLatestIfNeeded(proxy)
                }
                .onChange(of: viewModel.activeTurns) { _, _ in
                    scrollToLatestIfNeeded(proxy)
                }

                if !shouldAutoScroll {
                    Button {
                        shouldAutoScroll = true
                        withAnimation { proxy.scrollTo("translation-bottom", anchor: .bottom) }
                    } label: {
                        Label("livetranslate.latest".localized, systemImage: "arrow.down")
                            .font(AppTypography.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.blue))
                            .foregroundColor(.white)
                    }
                    .padding(12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.08)))
            .onAppear {
                DispatchQueue.main.async {
                    proxy.scrollTo("translation-bottom", anchor: .bottom)
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
    }

    private func translationCard(
        id: UUID,
        original: String,
        translated: String,
        source: TranslateLanguage,
        target: TranslateLanguage,
        timestamp: Date,
        isStreaming: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(source.flag) → \(target.flag)")
                Spacer()
                Text(isStreaming ? "livetranslate.translating".localized : timestamp.formatted(date: .omitted, time: .shortened))
            }
            .font(AppTypography.caption)
            .foregroundColor(.white.opacity(0.5))

            if !original.isEmpty {
                Text(original)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))
                    .lineSpacing(4)
            }
            if !translated.isEmpty {
                Text(translated)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .lineSpacing(5)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(isStreaming ? 0.14 : 0.08)))
        .id(id)
    }

    private func scrollToLatestIfNeeded(_ proxy: ScrollViewProxy) {
        guard shouldAutoScroll else { return }
        withAnimation { proxy.scrollTo("translation-bottom", anchor: .bottom) }
    }

    private var visionPrivacyBar: some View {
        Toggle(isOn: $viewModel.imageEnhanceEnabled) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.imageEnhanceEnabled ? "eye.fill" : "eye.slash.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("livetranslate.vision.title".localized)
                        .font(AppTypography.caption)
                    Text(viewModel.imageEnhanceEnabled
                         ? "livetranslate.vision.on".localized
                         : "livetranslate.vision.off".localized)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .foregroundColor(.white)
        }
        .tint(.green)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
        .padding(.horizontal, 8)
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        VStack(spacing: 8) {
            // 录音状态提示
            if viewModel.isRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("livetranslate.recording".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            if viewModel.isFinalizing {
                Label("livetranslate.finalizing".localized, systemImage: "hourglass")
                    .font(AppTypography.caption)
                    .foregroundColor(.orange)
            }

            if case .playing = viewModel.playbackState {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("livetranslate.playing".localized)
                    if viewModel.pendingPlaybackCount > 0 {
                        Text(String(format: "livetranslate.pending".localized, viewModel.pendingPlaybackCount))
                    }
                }
                .font(AppTypography.caption)
                .foregroundColor(.green)
            }

            // 录音按钮
            Button {
                viewModel.toggleRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(viewModel.isRecording ? Color.red : Color.blue)
                        .frame(width: 72, height: 72)

                    Image(systemName: viewModel.isFinalizing ? "hourglass" : (viewModel.isRecording ? "stop.fill" : "mic.fill"))
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                }
            }
            .disabled(!viewModel.isConnected || viewModel.isFinalizing)
            .opacity(viewModel.isConnected && !viewModel.isFinalizing ? 1.0 : 0.5)
        }
        .padding(.bottom, 10)
    }

    // MARK: - Video Background

    private var videoBackground: some View {
        Group {
            if let frame = streamViewModel.currentVideoFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .opacity(0.3)
            }
        }
        .onAppear {
            if let frame = streamViewModel.currentVideoFrame {
                viewModel.updateVideoFrame(frame)
            }
        }
        .onChange(of: streamViewModel.currentVideoFrame) { _, frame in
            if let frame = frame {
                viewModel.updateVideoFrame(frame)
            }
        }
    }

    // MARK: - Video Stream

    private func startVideoStream() {
        Task {
            await streamViewModel.startSession()
        }
    }

    private func stopVideoStream() {
        Task {
            await streamViewModel.stopSession()
        }
    }
}

// Preview requires WearablesInterface - use in app context
// #Preview {
//     LiveTranslateView(streamViewModel: ...)
// }
