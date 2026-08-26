/*
 * Live AI View
 * 实时 AI 对话界面 - 会话由 LiveAIManager 唯一持有，本视图只观察状态与转发用户操作
 */

import SwiftUI

struct LiveAIView: View {
    @ObservedObject var streamViewModel: StreamSessionViewModel
    @ObservedObject private var liveAIManager = LiveAIManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showConversation = true // 控制对话内容显示/隐藏

    init(streamViewModel: StreamSessionViewModel) {
        self.streamViewModel = streamViewModel
    }

    var body: some View {
        ZStack {
            // Black background
            Color.black
                .ignoresSafeArea()

            // 未连接设备提醒
            if !streamViewModel.hasActiveDevice {
                deviceNotConnectedView
            } else {
                // Video is rendered only after the user explicitly opts into
                // visual mode. Voice mode has no DAT camera session or frame.
                if liveAIManager.inputMode == .vision, let videoFrame = streamViewModel.currentVideoFrame {
                    GeometryReader { geometry in
                        Image(uiImage: videoFrame)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .ignoresSafeArea()
                }

                VStack(spacing: 0) {
                // Header (紧贴状态栏)
                headerView
                    .padding(.top, 8) // 状态栏下方一点点

                inputModeView

                // Conversation history (可隐藏)
                if showConversation {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(liveAIManager.conversationHistory) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                }

                                // Current AI response (streaming)
                                if !liveAIManager.currentTranscript.isEmpty {
                                    MessageBubble(
                                        message: ConversationMessage(
                                            role: .assistant,
                                            content: liveAIManager.currentTranscript
                                        )
                                    )
                                    .id("current")
                                }
                            }
                            .padding()
                        }
                        .onChange(of: liveAIManager.conversationHistory.count) { _, _ in
                            if let lastMessage = liveAIManager.conversationHistory.last {
                                withAnimation {
                                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: liveAIManager.currentTranscript) { _, _ in
                            withAnimation {
                                proxy.scrollTo("current", anchor: .bottom)
                            }
                        }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Spacer()
                }

                // Status and stop button
                controlsView
                }
            }
        }
        .task {
            // 会话唯一启动点。设备校验由 LiveAIManager 统一负责：
            // 未连接眼镜时经 failFatal 走错误弹窗 + TTS，而不是静默返回。
            if !liveAIManager.isRunning {
                // A previous feature may have left a DAT camera session active.
                // Live AI always enters voice-only, so release that session
                // before connecting the realtime audio service.
                if streamViewModel.streamingStatus != .stopped {
                    await streamViewModel.stopSession()
                }
                guard !Task.isCancelled else { return }
                await liveAIManager.startLiveAISession()
            }
        }
        .onDisappear {
            // 关闭界面即结束会话
            print("🎥 LiveAIView: 停止 AI 对话和视频流")
            Task { @MainActor in
                await liveAIManager.stopSession()
            }
        }
        .onChange(of: liveAIManager.isRunning) { _, isRunning in
            // 仅"正常停止"（StopLiveAIIntent 或用户操作）自动关闭页面；
            // 失败时保留页面等待用户确认错误弹窗
            if !isRunning && liveAIManager.stopReason == .stopped {
                dismiss()
            }
        }
        .alert("error".localized, isPresented: $liveAIManager.showError) {
            Button("ok".localized) {
                liveAIManager.dismissError()
                // 会话已因失败终止时，确认错误后关闭页面
                if !liveAIManager.isRunning {
                    dismiss()
                }
            }
        } message: {
            if let error = liveAIManager.errorMessage {
                Text(error)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("liveai.title".localized)
                .font(AppTypography.headline)
                .foregroundColor(.white)

            Spacer()

            // Hide/show conversation button
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showConversation.toggle()
                }
            } label: {
                Image(systemName: showConversation ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
            }

            // Connection status
            HStack(spacing: AppSpacing.xs) {
                Circle()
                    .fill(liveAIManager.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(liveAIManager.isConnected ? "liveai.connected".localized : "liveai.connecting".localized)
                    .font(AppTypography.caption)
                    .foregroundColor(.white)
            }

            // Speaking indicator
            if liveAIManager.isSpeaking {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                    Text("liveai.speaking".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(Color.black.opacity(0.7))
    }

    // MARK: - Controls

    private var controlsView: some View {
        VStack(spacing: AppSpacing.md) {
            if liveAIManager.responseState != .idle {
                HStack(spacing: AppSpacing.sm) {
                    Circle()
                        .fill(liveAIManager.responseState == .failed ? Color.red : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(liveAIManager.responseState.displayName)
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(Color.black.opacity(0.6))
                .cornerRadius(AppCornerRadius.xl)
            }

            // Recording status
            HStack(spacing: AppSpacing.sm) {
                if liveAIManager.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("liveai.listening".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                } else {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("liveai.stop".localized)
                        .font(AppTypography.caption)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, AppSpacing.sm)
            .background(Color.black.opacity(0.6))
            .cornerRadius(AppCornerRadius.xl)

            // Stop button (only button)
            Button {
                // 只负责停止会话；stopSession 会先发布 stopReason = .stopped，
                // 再由 onChange(isRunning) 统一关闭页面，避免手动 dismiss
                // 与 onDisappear 各自触发一次清理造成并发重复执行
                Task { @MainActor in
                    await liveAIManager.stopSession()
                }
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                    Text("liveai.stop".localized)
                        .font(AppTypography.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(AppCornerRadius.lg)
            }
            .padding(.horizontal, AppSpacing.lg)
        }
        .padding(.bottom, AppSpacing.lg)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var inputModeView: some View {
        VStack(spacing: AppSpacing.xs) {
            Picker("liveai.input.mode".localized, selection: Binding(
                get: { liveAIManager.inputMode },
                set: { mode in
                    Task { await liveAIManager.switchInputMode(to: mode) }
                })) {
                ForEach(LiveAIInputMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.icon)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(liveAIManager.isSwitchingInputMode)

            HStack(spacing: AppSpacing.xs) {
                Image(systemName: liveAIManager.inputMode.icon)
                Text(liveAIManager.inputMode.privacyDescription)
                if liveAIManager.inputMode == .vision {
                    Text("· " + String(format: "liveai.input.vision.count".localized, liveAIManager.sentImageCount))
                }
            }
            .font(AppTypography.caption)
            .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.sm)
        .background(Color.black.opacity(0.65))
    }

    // MARK: - Device Not Connected View

    private var deviceNotConnectedView: some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer()

            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 80))
                    .foregroundColor(AppColors.liveAI.opacity(0.6))

                Text("liveai.device.notconnected.title".localized)
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text("liveai.device.notconnected.message".localized)
                    .font(AppTypography.body)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xl)
            }

            Spacer()

            // Back button
            Button {
                dismiss()
            } label: {
                HStack(spacing: AppSpacing.sm) {
                    Image(systemName: "chevron.left")
                    Text("liveai.device.backtohome".localized)
                        .font(AppTypography.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.md)
                .background(AppColors.primary)
                .foregroundColor(.white)
                .cornerRadius(AppCornerRadius.lg)
            }
            .padding(.horizontal, AppSpacing.xl)
            .padding(.bottom, AppSpacing.xl)
        }
    }
}
