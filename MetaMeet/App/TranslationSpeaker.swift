import AVFoundation
import SwiftUI

/// Uses the app's HFP audio session, so speech stays on the glasses while recording.
@MainActor
final class TranslationSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var status = "읽어주기 꺼짐"
    private let synth = AVSpeechSynthesizer()
    private var pending: [String] = []
    override init() {
        super.init(); synth.delegate = self; synth.usesApplicationAudioSession = true
    }
    func enqueue(_ text: String) {
        guard UserDefaults.standard.bool(forKey: "readTranslations"), !text.isEmpty else { return }
        pending.append(text)
        // Keep the newest three utterances; never create a minutes-long spoken backlog.
        if pending.count > 3 { pending.removeFirst(pending.count - 3) }
        next()
    }
    func stop() { pending.removeAll(); synth.stopSpeaking(at: .immediate); status = "읽어주기 대기" }
    private func next() {
        guard !synth.isSpeaking, !pending.isEmpty else { return }
        guard UserDefaults.standard.bool(forKey: "readTranslations") else { stop(); return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard outputs.contains(where: { $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP }) else {
            pending.removeAll(); status = "Bluetooth 오디오 출력이 없어 읽기를 보류했습니다"; return
        }
        guard let voice = AVSpeechSynthesisVoice(language: "ko-KR") else { pending.removeAll(); status = "iPhone의 한국어 음성을 사용할 수 없습니다"; return }
        let utterance = AVSpeechUtterance(string: pending.removeFirst())
        utterance.voice = voice
        utterance.rate = Float(UserDefaults.standard.object(forKey: "speechRate") as? Double ?? 0.5)
        utterance.postUtteranceDelay = 0.15
        status = "번역 읽는 중 · \(outputs.map(\.portName).joined(separator: ", "))"
        synth.speak(utterance)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.status = "읽어주기 대기"; self?.next() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.status = "읽어주기 대기" }
    }
}
