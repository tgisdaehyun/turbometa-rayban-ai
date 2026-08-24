import Foundation

enum AudioNoteStatus: String, Codable, CaseIterable {
    case recording
    case saved
    case uploading
    case transcribing
    case organizing
    case completed
    case failed

    var isProcessing: Bool {
        [.uploading, .transcribing, .organizing].contains(self)
    }
}

enum AudioNoteInput: String, Codable, CaseIterable, Identifiable {
    case glasses
    case iPhone

    var id: String { rawValue }
}

struct AudioTranscriptWord: Codable, Hashable {
    let beginTimeMs: Int
    let endTimeMs: Int
    let text: String
}

struct AudioTranscriptSegment: Codable, Identifiable, Hashable {
    let id: UUID
    let beginTimeMs: Int
    let endTimeMs: Int
    let originalText: String
    var editedText: String
    let speakerID: Int?
    let words: [AudioTranscriptWord]

    init(
        id: UUID = UUID(),
        beginTimeMs: Int,
        endTimeMs: Int,
        originalText: String,
        editedText: String? = nil,
        speakerID: Int?,
        words: [AudioTranscriptWord] = []
    ) {
        self.id = id
        self.beginTimeMs = beginTimeMs
        self.endTimeMs = endTimeMs
        self.originalText = originalText
        self.editedText = editedText ?? originalText
        self.speakerID = speakerID
        self.words = words
    }
}

struct AudioNote: Codable, Identifiable {
    let id: UUID
    var title: String
    let createdAt: Date
    var updatedAt: Date
    var duration: TimeInterval
    let audioRelativePath: String
    var input: AudioNoteInput
    var languageHints: [String]
    var diarizationEnabled: Bool
    var status: AudioNoteStatus
    var taskID: String?
    var remoteURL: String?
    var segments: [AudioTranscriptSegment]
    var speakerNames: [String: String]
    var errorMessage: String?

    var transcript: String {
        segments.map(\.editedText).joined(separator: "\n")
    }

    var speakerCount: Int {
        Set(segments.compactMap(\.speakerID)).count
    }
}

struct AudioNotePreferences {
    static let defaultInputKey = "audio_note_default_input"
    static let diarizationKey = "audio_note_diarization"
    static let languageKey = "audio_note_language"

    static var defaultInput: AudioNoteInput {
        get { AudioNoteInput(rawValue: UserDefaults.standard.string(forKey: defaultInputKey) ?? "glasses") ?? .glasses }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultInputKey) }
    }

    static var diarizationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: diarizationKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: diarizationKey) }
    }

    static var languageHint: String {
        get { UserDefaults.standard.string(forKey: languageKey) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: languageKey) }
    }
}
