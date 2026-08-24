/*
 * Conversation Detail View
 * 对话详情页面
 */

import SwiftUI

struct ConversationDetailView: View {
    let conversation: ConversationRecord
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDeletion = false

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.secondaryBackground
                    .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(conversation.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("对话详情")
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
            .safeAreaInset(edge: .bottom) {
                // Conversation info
                VStack(spacing: AppSpacing.sm) {
                    HStack {
                        Image(systemName: "clock")
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                        Text(conversation.formattedDate)
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)

                        Spacer()

                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                        Text("\(conversation.messageCount) 条消息")
                            .font(AppTypography.caption)
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
                .padding(AppSpacing.md)
                .background(AppColors.tertiaryBackground.opacity(0.95))
            }
        }
    }
}
