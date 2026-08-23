/*
 * Records View
 * 记录页面 - 包含各类记录的 Tab
 */

import SwiftUI

struct RecordsView: View {
    @State private var selectedTab = 0

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Custom Tab Bar
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.lg) {
                        RecordTabButton(title: "Live AI", isSelected: selectedTab == 0) {
                            selectedTab = 0
                        }

                        RecordTabButton(title: "实时翻译", isSelected: selectedTab == 1) {
                            selectedTab = 1
                        }

                        RecordTabButton(title: "LeanEat", isSelected: selectedTab == 2) {
                            selectedTab = 2
                        }

                        RecordTabButton(title: "WordLearn", isSelected: selectedTab == 3) {
                            selectedTab = 3
                        }

                        RecordTabButton(title: "quickvision.tab".localized, isSelected: selectedTab == 4) {
                            selectedTab = 4
                        }
                    }
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.vertical, AppSpacing.md)
                }
                .background(AppColors.tertiaryBackground)

                // Content
                TabView(selection: $selectedTab) {
                    LiveAIRecordsView()
                        .tag(0)

                    TranslationRecordsView()
                        .tag(1)

                    LeanEatRecordsView()
                        .tag(2)

                    WordLearnRecordsView()
                        .tag(3)

                    QuickVisionRecordsView()
                        .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("记录")
        }
    }
}

// MARK: - Record Tab Button

struct RecordTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: AppSpacing.sm) {
                Text(title)
                    .font(AppTypography.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? AppColors.primary : AppColors.textSecondary)

                if isSelected {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [AppColors.primary, AppColors.secondary],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 3)
                        .cornerRadius(1.5)
                } else {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(height: 3)
                }
            }
        }
    }
}

// MARK: - Live AI Records

struct LiveAIRecordsView: View {
    @StateObject private var viewModel = ConversationListViewModel()
    @State private var selectedConversation: ConversationRecord?
    @State private var showDetail = false

    var body: some View {
        ZStack {
            AppColors.secondaryBackground
                .ignoresSafeArea()

            if viewModel.conversations.isEmpty {
                // Empty state
                VStack(spacing: AppSpacing.lg) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 64))
                        .foregroundColor(AppColors.liveAI.opacity(0.6))

                    Text("暂无 Live AI 对话记录")
                        .font(AppTypography.title2)
                        .foregroundColor(AppColors.textPrimary)

                    Text("使用 Live AI 功能后记录将显示在这里")
                        .font(AppTypography.subheadline)
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xl)
                }
            } else {
                // Conversation list
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(viewModel.conversations) { conversation in
                            ConversationCell(conversation: conversation)
                                .onTapGesture {
                                    selectedConversation = conversation
                                    showDetail = true
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        viewModel.deleteConversation(conversation.id)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding(AppSpacing.md)
                }
                .refreshable {
                    viewModel.loadConversations()
                }
            }
        }
        .onAppear {
            viewModel.loadConversations()
        }
        .sheet(isPresented: $showDetail) {
            if let conversation = selectedConversation {
                ConversationDetailView(conversation: conversation)
            }
        }
    }
}

// MARK: - Conversation List ViewModel

@MainActor
class ConversationListViewModel: ObservableObject {
    @Published var conversations: [ConversationRecord] = []

    func loadConversations() {
        conversations = ConversationStorage.shared.loadAllConversations()
        print("📱 [RecordsView] 加载对话: \(conversations.count) 条")
    }

    func deleteConversation(_ id: UUID) {
        ConversationStorage.shared.deleteConversation(id)
        loadConversations()
    }
}

// MARK: - Conversation Cell

struct ConversationCell: View {
    let conversation: ConversationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(AppColors.liveAI)
                    .font(AppTypography.headline)

                Text(conversation.title)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }

            // Summary
            if !conversation.summary.isEmpty {
                Text(conversation.summary)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(2)
            }

            // Footer
            HStack(spacing: AppSpacing.md) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "clock")
                        .font(AppTypography.caption)
                    Text(conversation.formattedDate)
                        .font(AppTypography.caption)
                }
                .foregroundColor(AppColors.textSecondary)

                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(AppTypography.caption)
                    Text("\(conversation.messageCount) 条消息")
                        .font(AppTypography.caption)
                }
                .foregroundColor(AppColors.textSecondary)

                Spacer()
            }
        }
        .padding(AppSpacing.md)
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Translation Records

struct TranslationRecordsView: View {
    @StateObject private var viewModel = TranslationHistoryViewModel()
    @State private var selectedSession: TranslationSession?

    var body: some View {
        Group {
            if viewModel.sessions.isEmpty {
                translationEmptyState
                    .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(viewModel.sessions) { session in
                        TranslationSessionCell(session: session)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedSession = session
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    viewModel.delete(session: session)
                                } label: {
                                    Label("records.translation.delete".localized, systemImage: "trash")
                                }
                            }
                            .listRowInsets(EdgeInsets(
                                top: AppSpacing.sm,
                                leading: AppSpacing.md,
                                bottom: AppSpacing.sm,
                                trailing: AppSpacing.md
                            ))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(AppColors.secondaryBackground.ignoresSafeArea())
        .refreshable {
            viewModel.load()
        }
        .onAppear {
            viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveTranslateHistoryDidChange)) { _ in
            viewModel.load()
        }
        .sheet(item: $selectedSession) { session in
            TranslationSessionDetailView(session: session)
        }
    }

    private var translationEmptyState: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "text.bubble")
                .font(.system(size: 64))
                .foregroundColor(AppColors.translate.opacity(0.6))

            Text("records.translation.empty".localized)
                .font(AppTypography.title2)
                .foregroundColor(AppColors.textPrimary)

            Text("records.translation.empty.hint".localized)
                .font(AppTypography.subheadline)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xl)
        }
    }
}

// MARK: - Translation History View Model

@MainActor
final class TranslationHistoryViewModel: ObservableObject {
    @Published private(set) var sessions: [TranslationSession] = []

    private let storage: LiveTranslateHistoryStorage

    init(storage: LiveTranslateHistoryStorage = .shared) {
        self.storage = storage
    }

    func load() {
        sessions = TranslationSessionBuilder.group(records: storage.loadAll())
    }

    func delete(session: TranslationSession) {
        _ = storage.deleteRecords(ids: session.records.map(\.id))
        load()
    }
}

// MARK: - Translation Session Cell

struct TranslationSessionCell: View {
    let session: TranslationSession

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                Image(systemName: "text.bubble.fill")
                    .foregroundColor(AppColors.translate)
                    .font(AppTypography.headline)

                Text(directionText)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }

            if !session.previewText.isEmpty {
                Text(session.previewText)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: AppSpacing.md) {
                Label(session.startDate.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                Label(
                    String(format: "records.translation.turnCount".localized, session.turnCount),
                    systemImage: "text.quote"
                )
            }
            .font(AppTypography.caption)
            .foregroundColor(AppColors.textSecondary)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }

    private var directionText: String {
        if session.hasMixedLanguageDirections {
            return "records.translation.mixedDirection".localized
        }
        let directions = session.records.map {
            "\($0.sourceLanguage.flag) \($0.sourceLanguage.displayName) → \($0.targetLanguage.flag) \($0.targetLanguage.displayName)"
        }
        return directions.first ?? ""
    }
}

// MARK: - Translation Session Detail

struct TranslationSessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let session: TranslationSession

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    sessionSummary

                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(session.records) { record in
                            TranslationTurnDetailCell(record: record)
                        }
                    }
                }
                .padding(AppSpacing.md)
            }
            .background(AppColors.secondaryBackground.ignoresSafeArea())
            .navigationTitle("records.translation.detail.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done".localized) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(directionText)
                .font(AppTypography.headline)
                .foregroundColor(AppColors.textPrimary)

            Text(String(
                format: "records.translation.detail.timeRange".localized,
                session.startDate.formatted(date: .abbreviated, time: .shortened),
                session.endDate.formatted(date: .abbreviated, time: .shortened)
            ))
            .font(AppTypography.caption)
            .foregroundColor(AppColors.textSecondary)

            Text(String(format: "records.translation.turnCount".localized, session.turnCount))
                .font(AppTypography.caption)
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
    }

    private var directionText: String {
        if session.hasMixedLanguageDirections {
            return "records.translation.mixedDirection".localized
        }
        let directions = session.records.map {
            "\($0.sourceLanguage.flag) \($0.sourceLanguage.displayName) → \($0.targetLanguage.flag) \($0.targetLanguage.displayName)"
        }
        return directions.first ?? ""
    }
}

private struct TranslationTurnDetailCell: View {
    let record: TranslateRecord

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Text("\(record.sourceLanguage.flag) → \(record.targetLanguage.flag)")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textSecondary)
                Spacer()
                Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }

            if !record.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(record.originalText)
                    .font(AppTypography.body)
                    .foregroundColor(AppColors.textSecondary)
            }

            if !record.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(record.translatedText)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
            }
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
    }
}

// MARK: - LeanEat Records

struct LeanEatRecordsView: View {
    var body: some View {
        ZStack {
            AppColors.secondaryBackground
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 64))
                    .foregroundColor(AppColors.leanEat.opacity(0.6))

                Text("暂无卡路里识别记录")
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text("功能即将上线")
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }
}

// MARK: - WordLearn Records

struct WordLearnRecordsView: View {
    var body: some View {
        ZStack {
            AppColors.secondaryBackground
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 64))
                    .foregroundColor(AppColors.wordLearn.opacity(0.6))

                Text("暂无单词学习记录")
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)

                Text("功能即将上线")
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
    }
}

// MARK: - Quick Vision Records

struct QuickVisionRecordsView: View {
    @State private var records: [QuickVisionRecord] = []
    @State private var selectedRecord: QuickVisionRecord?

    var body: some View {
        ZStack {
            AppColors.secondaryBackground
                .ignoresSafeArea()

            if records.isEmpty {
                // Empty state
                VStack(spacing: AppSpacing.lg) {
                    Image(systemName: "eye.circle")
                        .font(.system(size: 64))
                        .foregroundColor(AppColors.quickVision.opacity(0.6))

                    Text("quickvision.records.empty".localized)
                        .font(AppTypography.title2)
                        .foregroundColor(AppColors.textPrimary)

                    Text("quickvision.records.empty.hint".localized)
                        .font(AppTypography.subheadline)
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xl)
                }
            } else {
                // Records list
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(records) { record in
                            QuickVisionRecordCell(record: record)
                                .onTapGesture {
                                    selectedRecord = record
                                }
                        }
                    }
                    .padding(AppSpacing.md)
                }
                .refreshable {
                    loadRecords()
                }
            }
        }
        .onAppear {
            loadRecords()
        }
        .sheet(item: $selectedRecord) { record in
            QuickVisionRecordDetailView(record: record)
        }
    }

    private func loadRecords() {
        records = QuickVisionStorage.shared.loadAllRecords()
    }
}

// MARK: - Quick Vision Record Cell

struct QuickVisionRecordCell: View {
    let record: QuickVisionRecord

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            // Thumbnail
            if let thumbnail = record.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.md))
            } else {
                RoundedRectangle(cornerRadius: AppCornerRadius.md)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 70, height: 70)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    }
            }

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                // Header
                HStack {
                    Image(systemName: record.mode.icon)
                        .foregroundColor(AppColors.quickVision)
                        .font(AppTypography.subheadline)

                    Text(record.mode.displayName)
                        .font(AppTypography.headline)
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundColor(AppColors.textTertiary)
                }

                // Result summary
                Text(record.summary)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(2)

                // Footer
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "clock")
                        .font(AppTypography.caption)
                    Text(record.formattedDate)
                        .font(AppTypography.caption)
                }
                .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(AppSpacing.md)
        .background(AppColors.tertiaryBackground)
        .cornerRadius(AppCornerRadius.lg)
        .shadow(color: AppShadow.small(), radius: 4, x: 0, y: 2)
    }
}
