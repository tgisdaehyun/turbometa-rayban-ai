import SwiftUI
import UIKit
import MeetingCore

struct MeetingView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var meta: MetaConnection
    @AppStorage("transcriptionPace") private var transcriptionPace = "fast"
    @AppStorage("readTranslations") private var readTranslations = false
    @AppStorage("metaStreamingEnabled") private var metaStreamingEnabled = false
    @AppStorage("preferGlasses") private var preferGlasses = true
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("viewMode") private var viewMode = "korean"
    @AppStorage("translationFontSize") private var fontSize = 32.0
    @AppStorage("keepScreenAwake") private var keepAwake = true
    @State private var settings = false
    @State private var history = false
    @State private var follow = true
    @State private var export: ExportFile?
    private var utteranceCount: Int { store.selected?.chunks.reduce(0) { $0 + $1.utterances.count } ?? 0 }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                if preferGlasses && !meta.registered {
                    Button { Task { await meta.connect() } } label: {
                        Label(meta.connecting ? "Meta 앱 승인 대기 중" : "Meta 앱에서 안경 연결", systemImage: "eyeglasses")
                    }.disabled(meta.connecting).font(.subheadline).padding(.bottom, 12)
                }
                if let meeting = store.selected, !meeting.chunks.flatMap(\.utterances).isEmpty {
                    transcript(meeting)
                } else {
                    Spacer()
                    VStack(alignment: .leading, spacing: 18) {
                        Text(store.activeID != nil ? "듣고 있습니다." : "회의 내용을\n한국어로.")
                            .font(.system(size: 36, weight: .medium)).lineSpacing(9)
                        Text(store.activeID != nil ? "음성을 저장하고 있습니다.\n선택한 속도로 음성을 모아 번역합니다." : "Meta 안경을 연결하고\n아래 버튼을 한 번 누르세요.")
                            .font(.body).foregroundStyle(.secondary).lineSpacing(5)
                        if store.isPreview { Text("미리보기 · 실제 녹음 아님").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28)
                    Spacer()
                }
                if let meeting = store.selected, meeting.pending > 0 {
                    HStack {
                        Text(store.processing ? "전사 중 · \(meeting.pending)개 구간" : "미전사 음성 \(meeting.pending)개 보관됨").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !store.processing { Button("다시 전사") { store.retry(meeting.id) }.font(.caption.bold()) }
                    }.padding(.horizontal, 24).padding(.vertical, 10)
                }
                if store.lastAPISeconds != nil, store.activeID != nil {
                    Text("\(TranscriptionPace.saved(transcriptionPace).title) 모드 · 전사 중").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 24)
                }
                if readTranslations { SpeechStatusView(speaker: store.speaker).padding(.horizontal, 24) }
                controls
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("MetaMeet").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { history = true } label: { Image(systemName: "clock") }.accessibilityLabel("지난 회의") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let meeting = store.selected {
                        Button { exportMeeting(meeting) } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("원문과 번역 내보내기")
                    }
                    Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("설정")
                }
            }
            .sheet(isPresented: $settings) { SettingsView().environmentObject(store).environmentObject(meta) }
            .sheet(isPresented: $history) { HistoryView().environmentObject(store) }
            .sheet(item: $export) { ActivityView(items: [$0.url]) }
            .alert("확인이 필요합니다", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("확인") { store.error = nil } } message: { Text(store.error ?? "") }
            .onChange(of: meta.error) { _, message in if let message { store.error = message; meta.error = nil } }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.foreground() }
                UIApplication.shared.isIdleTimerDisabled = phase == .active && keepAwake && store.activeID != nil
            }
            .onChange(of: store.activeID) { _, id in
                UIApplication.shared.isIdleTimerDisabled = keepAwake && id != nil
                if id == nil { meta.stopStreaming() }
            }
            .onChange(of: keepAwake) { _, value in UIApplication.shared.isIdleTimerDisabled = value && store.activeID != nil }
        }
    }
    private var statusBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(store.activeID == nil ? Color.gray : (store.paused ? Color.orange : Color.green)).frame(width: 6, height: 6)
                Text(store.activeID != nil ? (store.paused ? "녹음 일시 중단" : "녹음 중") : (store.isPreview ? "미리보기" : "준비"))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Meeting.timestamp(store.active.map { context.date.timeIntervalSince($0.created) } ?? store.selected?.duration ?? 0)).monospacedDigit()
                }
            }.font(.caption).foregroundStyle(.secondary)
            HStack {
                Image(systemName: store.bluetooth ? "eyeglasses" : "mic")
                Text(store.inputName).lineLimit(1)
                Spacer(minLength: 8)
                if store.activeID != nil {
                    GeometryReader { geo in
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Color.white).frame(width: max(2, geo.size.width * CGFloat(store.level)))
                    }.frame(width: 44, height: 3).accessibilityLabel("마이크 입력 레벨")
                }
            }.font(.caption).foregroundStyle(store.bluetooth ? Color.white : Color.gray)
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private func transcript(_ meeting: Meeting) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Text(viewMode == "korean" ? "한국어 크게 보기" : "중국어 원문 · 한국어 번역").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !follow { Button("최신으로") { follow = true; withAnimation { proxy.scrollTo("end", anchor: .bottom) } }.font(.caption) }
                    }
                    ForEach(meeting.chunks.sorted { $0.id < $1.id }) { chunk in
                        ForEach(Array(chunk.utterances.enumerated()), id: \.offset) { index, line in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(Meeting.timestamp(chunk.start + line.start)).font(.caption2.monospacedDigit()).foregroundStyle(.gray)
                                if viewMode == "bilingual" { Text(line.original).font(.system(size: 18)).foregroundStyle(.secondary).textSelection(.enabled) }
                                Text(line.korean).font(.system(size: CGFloat(viewMode == "korean" ? fontSize : max(22, fontSize - 6)), weight: .regular))
                                    .lineSpacing(7).foregroundStyle(.white).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, alignment: .leading).id("\(chunk.id)-\(index)")
                        }
                    }
                    Color.clear.frame(height: 4).id("end")
                }.padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 24)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in follow = false })
            .onChange(of: utteranceCount) { _, _ in if follow { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("end", anchor: .bottom) } } }
            .onChange(of: store.selectedID) { _, _ in follow = true; proxy.scrollTo("end", anchor: .bottom) }
        }
    }
    private var controls: some View {
        VStack(spacing: 12) {
            if store.paused { Button("녹음 재개") { store.resume() }.font(.body.bold()).padding(.bottom, 6) }
            Button {
                if store.activeID != nil { store.stop(); meta.stopStreaming() }
                else if !store.hasKey { settings = true }
                else { Task {
                    if metaStreamingEnabled && meta.registered { await meta.startStreaming() }
                    await store.start()
                } }
            } label: {
                HStack(spacing: 10) {
                    if store.starting { ProgressView().tint(.black) }
                    else { Image(systemName: store.activeID == nil ? "mic.fill" : "stop.fill") }
                    Text(store.starting ? "마이크 연결 중" : (store.activeID == nil ? "회의 시작" : "회의 종료"))
                }.font(.system(size: 18, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 58)
                    .foregroundStyle(.black).background(.white, in: RoundedRectangle(cornerRadius: 14))
            }.disabled(store.starting || meta.streamStarting || store.isPreview).accessibilityIdentifier("recordButton")
            Text(store.activeID != nil ? "음성은 iPhone에 저장 · 번역은 순서대로 표시" : "중국어 원문과 한국어 번역을 함께 보관합니다")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 14).background(.black)
    }
    private func exportMeeting(_ meeting: Meeting) {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MetaMeet-\(meeting.id.uuidString.prefix(8)).md")
            try Data(meeting.markdown.utf8).write(to: url, options: .atomic); export = ExportFile(url: url)
        } catch { store.error = "회의록을 내보내지 못했습니다." }
    }
}
struct ExportFile: Identifiable { let id = UUID(); let url: URL }
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct SpeechStatusView: View {
    @ObservedObject var speaker: TranslationSpeaker
    var body: some View { Text(speaker.status).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
}
