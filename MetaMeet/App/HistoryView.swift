import SwiftUI
import MeetingCore

struct HistoryView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var toDelete: Meeting?
    var body: some View {
        NavigationStack {
            List {
                if store.meetings.isEmpty { Text("저장된 회의가 없습니다.").foregroundStyle(.secondary) }
                ForEach(store.meetings) { meeting in
                    Button {
                        store.selectedID = meeting.id; dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(meeting.title).font(.body).foregroundStyle(.white)
                            HStack {
                                Text(meeting.created, style: .date)
                                Text(Meeting.timestamp(meeting.duration))
                                if meeting.pending > 0 { Text("미전사 \(meeting.pending)") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }.disabled(store.activeID != nil && store.activeID != meeting.id)
                    .swipeActions {
                        if store.activeID != meeting.id && !store.processing {
                            Button("삭제", role: .destructive) { toDelete = meeting }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(.black)
            .navigationTitle("지난 회의").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
            .confirmationDialog("회의의 녹음과 전사 기록을 삭제할까요?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }), titleVisibility: .visible) {
                if let meeting = toDelete { Button("회의 삭제", role: .destructive) { store.delete(meeting.id); toDelete = nil } }
            }
        }.preferredColorScheme(.dark).tint(.white)
    }
}
