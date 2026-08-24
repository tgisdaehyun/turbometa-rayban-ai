/*
 * Records View
 * 记录页面 - 包含各类记录的 Tab
 */

import SwiftUI

enum RecordCategory: Int, CaseIterable, Identifiable {
    case liveAI
    case translation
    case audioNote
    case leanEat
    case wordLearn
    case quickVision

    var id: Self { self }

    var title: String {
        switch self {
        case .liveAI:
            return "Live AI"
        case .translation:
            return "livetranslate.title".localized
        case .audioNote:
            return "audioNote.records.tab".localized
        case .leanEat:
            return "LeanEat"
        case .wordLearn:
            return "WordLearn"
        case .quickVision:
            return "quickvision.tab".localized
        }
    }
}

struct RecordBatchDeleteRequest {
    let category: RecordCategory
    let ids: Set<UUID>
}

struct RecordSelectAllRequest {
    let category: RecordCategory
}

enum RecordsLayout {
    static let categoryBarHeight: CGFloat = 56
    static let listTopInset = categoryBarHeight + AppSpacing.md
    static let bottomContentPadding: CGFloat = 96
}

extension View {
    /// Applies the top spacing needed for a records list below the floating category bar.
    func recordsListTopSpacing() -> some View {
        self
            .safeAreaPadding(.top, RecordsLayout.listTopInset)
            .padding(.top, RecordsLayout.listTopInset)
    }
}

struct RecordListScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct RecordListScrollMarker: View {
    let category: RecordCategory

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .preference(
                    key: RecordListScrollOffsetPreferenceKey.self,
                    value: [
                        category.rawValue:
                            geometry.frame(in: .named("recordsContent")).minY
                            - RecordsLayout.categoryBarHeight
                    ]
                )
        }
        .frame(height: 0)
    }
}

extension Notification.Name {
    static let recordsBatchDeleteRequested = Notification.Name("recordsBatchDeleteRequested")
    static let recordsSelectAllRequested = Notification.Name("recordsSelectAllRequested")
}

struct RecordsView: View {
    // Keep the TabView selection as a stable integer. SwiftUI's page-style
    // TabView can otherwise briefly resolve enum tags to the adjacent page
    // during the first programmatic selection.
    @State private var selectedCategoryIndex = RecordCategory.liveAI.rawValue
    @State private var isSelectionMode = false
    @State private var selectedRecordIDs = Set<UUID>()
    @State private var showsBatchDeleteConfirmation = false
    @State private var recordsScrollOffset: CGFloat = 0

    private var selectedCategory: RecordCategory {
        RecordCategory(rawValue: selectedCategoryIndex) ?? .liveAI
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                TabView(selection: $selectedCategoryIndex) {

                    LiveAIRecordsView(
                        isSelectionMode: $isSelectionMode,
                        selectedIDs: $selectedRecordIDs
                    )
                        .tag(RecordCategory.liveAI.rawValue)

                    TranslationRecordsView(
                        isSelectionMode: $isSelectionMode,
                        selectedIDs: $selectedRecordIDs
                    )
                        .tag(RecordCategory.translation.rawValue)

                    AudioNoteRecordsView(
                        isSelectionMode: $isSelectionMode,
                        selectedIDs: $selectedRecordIDs
                    )
                        .tag(RecordCategory.audioNote.rawValue)

                    LeanEatRecordsView()
                        .tag(RecordCategory.leanEat.rawValue)

                    WordLearnRecordsView()
                        .tag(RecordCategory.wordLearn.rawValue)

                    QuickVisionRecordsView(
                        isSelectionMode: $isSelectionMode,
                        selectedIDs: $selectedRecordIDs
                    )
                        .tag(RecordCategory.quickVision.rawValue)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea(edges: .all)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            GlassEffectContainer(spacing: AppSpacing.sm) {
                                HStack(spacing: AppSpacing.sm) {
                                    ForEach(RecordCategory.allCases) { category in
                                        RecordTabButton(
                                            title: category.title,
                                            isSelected: selectedCategory == category
                                        ) {
                                            selectedCategoryIndex = category.rawValue
                                        }
                                        .id(category.rawValue)
                                    }
                                }
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.vertical, AppSpacing.sm)

                        }
                        .frame(height: RecordsLayout.categoryBarHeight)
                        .onChange(of: selectedCategoryIndex) { _, rawValue in
                            guard let category = RecordCategory(rawValue: rawValue) else { return }
                            withAnimation(.snappy) {
                                proxy.scrollTo(category.rawValue, anchor: .center)
                            }
                        }
//                        .background {
//                            if recordsScrollOffset < RecordsLayout.categoryBarHeight + AppSpacing.md {
//                                Rectangle()
//                                    .fill(.linearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
//                            } else {
//                                Color.clear
//                            }
//                        }
//                        .overlay {
//                            if recordsScrollOffset < RecordsLayout.categoryBarHeight + AppSpacing.md {
//                                Rectangle()
//                                    .fill(Color.white.opacity(0.08))
//                                    .frame(height: 0.5)
//                                    .frame(maxHeight: .infinity, alignment: .bottom)
//                            }
//                        }
                    }

                }
                .coordinateSpace(name: "recordsContent")
                .onPreferenceChange(RecordListScrollOffsetPreferenceKey.self) { offsets in
                    recordsScrollOffset = offsets[selectedCategoryIndex] ?? 0
                }
            }
            .navigationTitle("records.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelectionMode {
                        Button {
                            NotificationCenter.default.post(
                                name: .recordsSelectAllRequested,
                                object: RecordSelectAllRequest(category: selectedCategory)
                            )
                        } label: {
                            Label("records.selectAll".localized, systemImage: "checkmark.circle")
                        }

                        Button(role: .destructive) {
                            showsBatchDeleteConfirmation = true
                        } label: {
                            Label("common.delete".localized, systemImage: "trash")
                        }
                        .disabled(selectedRecordIDs.isEmpty)

                        Button("common.done".localized) {
                            endSelectionMode()
                        }
                    } else {
                        Button {
                            isSelectionMode = true
                        } label: {
                            Label("records.select".localized, systemImage: "checkmark.circle")
                        }
                    }
                }
            }
            .confirmationDialog(
                "records.batchDelete.title".localized,
                isPresented: $showsBatchDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("records.delete.confirm".localized, role: .destructive) {
                    deleteSelectedRecords()
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("records.batchDelete.message".localized)
            }
            .onChange(of: selectedCategoryIndex) { _, _ in
                endSelectionMode()
            }
        }
    }

    private func endSelectionMode() {
        isSelectionMode = false
        selectedRecordIDs.removeAll()
    }

    private func deleteSelectedRecords() {
        guard !selectedRecordIDs.isEmpty else { return }
        NotificationCenter.default.post(
            name: .recordsBatchDeleteRequested,
            object: RecordBatchDeleteRequest(
                category: selectedCategory,
                ids: selectedRecordIDs
            )
        )
        endSelectionMode()
    }
}

// MARK: - Record Tab Button

struct RecordTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? AppColors.primary : AppColors.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, AppSpacing.sm)
//                .frame(minHeight: 40)
        }
        .buttonStyle(
            .glass(
                Glass.regular
                    .tint(isSelected ? AppColors.primary.opacity(0.2) : nil)
                    .interactive()
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Shared Record Card

struct RecordCardMetadata: Identifiable {
    let icon: String
    let text: String

    var id: String { "\(icon)-\(text)" }
}

struct RecordCardBadge {
    let text: String
    let color: Color
}

/// Shared visual language for the three implemented record categories.
struct UnifiedRecordCard: View {
    let icon: String
    let tint: Color
    let title: String
    let summary: String
    let metadata: [RecordCardMetadata]
    var badge: RecordCardBadge?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: icon)
                    .foregroundColor(tint)
                    .font(AppTypography.headline)

                Text(title)
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: AppSpacing.sm)

                if let badge {
                    Text(badge.text)
                        .font(AppTypography.caption)
                        .foregroundColor(badge.color)
                        .padding(.horizontal, AppSpacing.sm)
                        .padding(.vertical, AppSpacing.xs)
                        .background(badge.color.opacity(0.13), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundColor(AppColors.textTertiary)
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: AppSpacing.md) {
                ForEach(metadata) { item in
                    Label(item.text, systemImage: item.icon)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
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
}

// MARK: - Live AI Records

struct LiveAIRecordsView: View {
    @Binding var isSelectionMode: Bool
    @Binding var selectedIDs: Set<UUID>
    @StateObject private var viewModel = ConversationListViewModel()
    @State private var selectedConversation: ConversationRecord?
    @State private var conversationPendingDeletion: ConversationRecord?
    @State private var showsDeleteConfirmation = false

    var body: some View {
        ZStack {
            Color.black
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
                        RecordListScrollMarker(category: .liveAI)

                        ForEach(viewModel.conversations) { conversation in
                            HStack(spacing: AppSpacing.sm) {
                                if isSelectionMode {
                                    RecordSelectionIndicator(isSelected: selectedIDs.contains(conversation.id))
                                }

                                ConversationCell(conversation: conversation)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelectionMode {
                                    toggleSelection(for: conversation.id)
                                } else {
                                    selectedConversation = conversation
                                }
                            }
                            .contextMenu {
                                if !isSelectionMode {
                                    Button(role: .destructive) {
                                        conversationPendingDeletion = conversation
                                        showsDeleteConfirmation = true
                                    } label: {
                                        Label("common.delete".localized, systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.bottom, RecordsLayout.bottomContentPadding)
                }
                .recordsListTopSpacing()

                .refreshable {
                    viewModel.loadConversations()
                }
            }
        }
//        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            viewModel.loadConversations()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordsBatchDeleteRequested)) { notification in
            guard let request = notification.object as? RecordBatchDeleteRequest,
                  request.category == .liveAI else { return }
            viewModel.deleteConversations(ids: request.ids)
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordsSelectAllRequested)) { notification in
            guard let request = notification.object as? RecordSelectAllRequest,
                  request.category == .liveAI else { return }
            selectedIDs.formUnion(viewModel.conversations.map(\.id))
        }
        .confirmationDialog(
            "records.delete.title".localized,
            isPresented: $showsDeleteConfirmation
        ) {
            Button("records.delete.confirm".localized, role: .destructive) {
                guard let conversationPendingDeletion else { return }
                viewModel.deleteConversation(conversationPendingDeletion.id)
                self.conversationPendingDeletion = nil
            }
            Button("common.cancel".localized, role: .cancel) {
                conversationPendingDeletion = nil
            }
        } message: {
            Text("records.delete.message".localized)
        }
        .sheet(item: $selectedConversation) { conversation in
            ConversationDetailView(conversation: conversation) {
                viewModel.deleteConversation(conversation.id)
                selectedConversation = nil
            }
        }
    }

    private func toggleSelection(for id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
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

    func deleteConversations(ids: Set<UUID>) {
        ids.forEach { ConversationStorage.shared.deleteConversation($0) }
        loadConversations()
    }
}

// MARK: - Conversation Cell

struct ConversationCell: View {
    let conversation: ConversationRecord

    var body: some View {
        UnifiedRecordCard(
            icon: "brain.head.profile",
            tint: AppColors.liveAI,
            title: conversation.title,
            summary: conversation.summary,
            metadata: [
                RecordCardMetadata(icon: "clock", text: conversation.formattedDate),
                RecordCardMetadata(
                    icon: "bubble.left.and.bubble.right",
                    text: String(format: "records.liveAI.messageCount".localized, conversation.messageCount)
                )
            ]
        )
    }
}

struct RecordSelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? AppColors.primary : AppColors.textTertiary)
            .frame(width: 28)
    }
}

// MARK: - Translation Records

struct TranslationRecordsView: View {
    @Binding var isSelectionMode: Bool
    @Binding var selectedIDs: Set<UUID>
    @StateObject private var viewModel = TranslationHistoryViewModel()
    @State private var selectedSession: TranslationSession?
    @State private var sessionPendingDeletion: TranslationSession?
    @State private var showsDeleteConfirmation = false

    var body: some View {
        Group {
            if viewModel.sessions.isEmpty {
                translationEmptyState
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        RecordListScrollMarker(category: .translation)

                        ForEach(viewModel.sessions) { session in
                            HStack(spacing: AppSpacing.sm) {
                                if isSelectionMode {
                                    RecordSelectionIndicator(isSelected: selectedIDs.contains(session.id))
                                }

                                TranslationSessionCell(session: session)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelectionMode {
                                    toggleSelection(for: session.id)
                                } else {
                                    selectedSession = session
                                }
                            }
                            .contextMenu {
                                if !isSelectionMode {
                                    Button(role: .destructive) {
                                        sessionPendingDeletion = session
                                        showsDeleteConfirmation = true
                                    } label: {
                                        Label("common.delete".localized, systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.bottom, RecordsLayout.bottomContentPadding)
                }
            }
        }
        .recordsListTopSpacing()

        .background(Color.black.ignoresSafeArea())
//        .ignoresSafeArea(edges: .bottom)
        .refreshable {
            viewModel.load()
        }
        .onAppear {
            viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .liveTranslateHistoryDidChange)) { _ in
            viewModel.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordsBatchDeleteRequested)) { notification in
            guard let request = notification.object as? RecordBatchDeleteRequest,
                  request.category == .translation else { return }
            viewModel.deleteSessions(ids: request.ids)
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordsSelectAllRequested)) { notification in
            guard let request = notification.object as? RecordSelectAllRequest,
                  request.category == .translation else { return }
            selectedIDs.formUnion(viewModel.sessions.map(\.id))
        }
        .confirmationDialog(
            "records.delete.title".localized,
            isPresented: $showsDeleteConfirmation
        ) {
            Button("records.delete.confirm".localized, role: .destructive) {
                guard let sessionPendingDeletion else { return }
                viewModel.delete(session: sessionPendingDeletion)
                self.sessionPendingDeletion = nil
            }
            Button("common.cancel".localized, role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: {
            Text("records.delete.message".localized)
        }
        .sheet(item: $selectedSession) { session in
            TranslationSessionDetailView(session: session) {
                viewModel.delete(session: session)
                selectedSession = nil
            }
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

    private func toggleSelection(for id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
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

    func deleteSessions(ids: Set<UUID>) {
        let recordIDs = sessions
            .filter { ids.contains($0.id) }
            .flatMap { $0.records.map(\.id) }
        _ = storage.deleteRecords(ids: recordIDs)
        load()
    }
}

// MARK: - Translation Session Cell

struct TranslationSessionCell: View {
    let session: TranslationSession

    var body: some View {
        UnifiedRecordCard(
            icon: "text.bubble.fill",
            tint: AppColors.translate,
            title: directionText,
            summary: session.previewText,
            metadata: [
                RecordCardMetadata(
                    icon: "clock",
                    text: session.startDate.formatted(date: .abbreviated, time: .shortened)
                ),
                RecordCardMetadata(
                    icon: "text.quote",
                    text: String(format: "records.translation.turnCount".localized, session.turnCount)
                )
            ]
        )
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
    let onDelete: () -> Void
    @State private var confirmsDeletion = false

    var body: some View {
        NavigationStack {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                }
            }
            .confirmationDialog(
                "records.delete.title".localized,
                isPresented: $confirmsDeletion
            ) {
                Button("records.delete.confirm".localized, role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("common.cancel".localized, role: .cancel) {}
            } message: {
                Text("records.delete.message".localized)
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
            Color.black
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
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - WordLearn Records

struct WordLearnRecordsView: View {
    var body: some View {
        ZStack {
            Color.black
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
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - Quick Vision Records

struct QuickVisionRecordsView: View {
    @Binding var isSelectionMode: Bool
    @Binding var selectedIDs: Set<UUID>
    @State private var records: [QuickVisionRecord] = []
    @State private var selectedRecord: QuickVisionRecord?

    var body: some View {
        ZStack {
            Color.black
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
                        RecordListScrollMarker(category: .quickVision)

                        ForEach(records) { record in
                            HStack(spacing: AppSpacing.sm) {
                                if isSelectionMode {
                                    RecordSelectionIndicator(isSelected: selectedIDs.contains(record.id))
                                }

                                QuickVisionRecordCell(record: record)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isSelectionMode {
                                    toggleSelection(for: record.id)
                                } else {
                                    selectedRecord = record
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.bottom, RecordsLayout.bottomContentPadding)
                }
                .refreshable {
                    loadRecords()
                }
            }
        }
        .recordsListTopSpacing()

        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            loadRecords()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordsBatchDeleteRequested)) { notification in
            guard let request = notification.object as? RecordBatchDeleteRequest,
                  request.category == .quickVision else { return }
            request.ids.forEach { QuickVisionStorage.shared.deleteRecord($0) }
            loadRecords()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordsSelectAllRequested)) { notification in
            guard let request = notification.object as? RecordSelectAllRequest,
                  request.category == .quickVision else { return }
            selectedIDs.formUnion(records.map(\.id))
        }
        .sheet(item: $selectedRecord) { record in
            QuickVisionRecordDetailView(record: record)
        }
    }

    private func loadRecords() {
        records = QuickVisionStorage.shared.loadAllRecords()
    }

    private func toggleSelection(for id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
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
