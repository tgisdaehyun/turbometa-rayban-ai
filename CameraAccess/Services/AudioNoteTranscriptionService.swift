import Foundation

protocol RecordingUploadProvider {
    func upload(fileURL: URL, apiKey: String, endpoint: AlibabaEndpoint) async throws -> String
}

struct DashScopeTemporaryUploadProvider: RecordingUploadProvider {
    private let model = "qwen-audio-3.0-asr-flash-filetrans"

    func upload(fileURL: URL, apiKey: String, endpoint: AlibabaEndpoint) async throws -> String {
        let base = endpoint == .beijing ? "https://dashscope.aliyuncs.com" : "https://dashscope-intl.aliyuncs.com"
        var components = URLComponents(string: "\(base)/api/v1/uploads")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "getPolicy"),
            URLQueryItem(name: "model", value: model)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (policyData, policyResponse) = try await URLSession.shared.data(for: request)
        try Self.validate(policyResponse, data: policyData)
        guard let root = try JSONSerialization.jsonObject(with: policyData) as? [String: Any],
              let policy = root["data"] as? [String: Any],
              let host = policy["upload_host"] as? String,
              let hostURL = URL(string: host),
              let directory = policy["upload_dir"] as? String else {
            throw AudioNoteTranscriptionError.invalidResponse
        }

        let key = "\(directory)/\(UUID().uuidString)-\(fileURL.lastPathComponent)"
        let fields: [(String, String)] = [
            ("OSSAccessKeyId", policy["oss_access_key_id"] as? String ?? ""),
            ("Signature", policy["signature"] as? String ?? ""),
            ("policy", policy["policy"] as? String ?? ""),
            ("x-oss-object-acl", policy["x_oss_object_acl"] as? String ?? ""),
            ("x-oss-forbid-overwrite", policy["x_oss_forbid_overwrite"] as? String ?? ""),
            ("key", key),
            ("success_action_status", "200")
        ]
        let boundary = "TurboMeta-\(UUID().uuidString)"
        let body = try Self.multipartBody(boundary: boundary, fields: fields, fileURL: fileURL)
        var uploadRequest = URLRequest(url: hostURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = body
        let (uploadData, uploadResponse) = try await URLSession.shared.data(for: uploadRequest)
        try Self.validate(uploadResponse, data: uploadData)
        return "oss://\(key)"
    }

    private static func multipartBody(
        boundary: String,
        fields: [(String, String)],
        fileURL: URL
    ) throws -> Data {
        var data = Data()
        for (name, value) in fields {
            data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        data.append(try Data(contentsOf: fileURL))
        data.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw AudioNoteTranscriptionError.server(message)
        }
    }
}

final class AudioNoteTranscriptionService {
    typealias Progress = @MainActor (AudioNoteStatus, String?, String?) -> Void

    private let uploader: RecordingUploadProvider
    private let model = "qwen-audio-3.0-asr-flash-filetrans"

    init(uploader: RecordingUploadProvider = DashScopeTemporaryUploadProvider()) {
        self.uploader = uploader
    }

    func transcribe(
        audioURL: URL,
        endpoint: AlibabaEndpoint,
        diarization: Bool,
        languageHints: [String],
        existingTaskID: String? = nil,
        existingRemoteURL: String? = nil,
        progress: @escaping Progress
    ) async throws -> (taskID: String, segments: [AudioTranscriptSegment]) {
        guard let apiKey = APIKeyManager.shared.getAPIKey(for: .alibaba, endpoint: endpoint), !apiKey.isEmpty else {
            throw AudioNoteTranscriptionError.missingAPIKey
        }

        var taskID = existingTaskID
        var remoteURL = existingRemoteURL
        if taskID == nil {
            await progress(.uploading, nil, remoteURL)
            if remoteURL == nil {
                remoteURL = try await uploader.upload(fileURL: audioURL, apiKey: apiKey, endpoint: endpoint)
            }
            taskID = try await submit(
                remoteURL: remoteURL!,
                apiKey: apiKey,
                endpoint: endpoint,
                diarization: diarization,
                languageHints: languageHints
            )
        }
        guard let taskID else { throw AudioNoteTranscriptionError.invalidResponse }
        await progress(.transcribing, taskID, remoteURL)
        let resultURL = try await poll(taskID: taskID, apiKey: apiKey, endpoint: endpoint)
        await progress(.organizing, taskID, remoteURL)
        let segments = try await fetchSegments(resultURL: resultURL)
        return (taskID, segments)
    }

    private func submit(
        remoteURL: String,
        apiKey: String,
        endpoint: AlibabaEndpoint,
        diarization: Bool,
        languageHints: [String]
    ) async throws -> String {
        let base = endpoint == .beijing ? "https://dashscope.aliyuncs.com" : "https://dashscope-intl.aliyuncs.com"
        var parameters: [String: Any] = [
            "channel_id": [0],
            "diarization_enabled": diarization
        ]
        if !languageHints.isEmpty { parameters["language_hints"] = Array(languageHints.prefix(4)) }
        let payload: [String: Any] = [
            "model": model,
            "input": ["file_urls": [remoteURL]],
            "parameters": parameters
        ]
        var request = URLRequest(url: URL(string: "\(base)/api/v1/services/audio/asr/transcription")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [String: Any],
              let taskID = output["task_id"] as? String else {
            throw AudioNoteTranscriptionError.invalidResponse
        }
        return taskID
    }

    private func poll(taskID: String, apiKey: String, endpoint: AlibabaEndpoint) async throws -> URL {
        let base = endpoint == .beijing ? "https://dashscope.aliyuncs.com" : "https://dashscope-intl.aliyuncs.com"
        var delay: UInt64 = 3
        for _ in 0..<180 {
            var request = URLRequest(url: URL(string: "\(base)/api/v1/tasks/\(taskID)")!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response, data: data)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let output = json["output"] as? [String: Any] else {
                throw AudioNoteTranscriptionError.invalidResponse
            }
            let status = (output["task_status"] as? String ?? "").uppercased()
            if status == "SUCCEEDED" {
                if let results = output["results"] as? [[String: Any]],
                   let value = results.first?["transcription_url"] as? String,
                   let url = URL(string: value) { return url }
                throw AudioNoteTranscriptionError.invalidResponse
            }
            if ["FAILED", "CANCELED", "UNKNOWN"].contains(status) {
                let message = output["message"] as? String ?? output["code"] as? String ?? status
                throw AudioNoteTranscriptionError.server(message)
            }
            try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay + 1, 8)
        }
        throw AudioNoteTranscriptionError.timeout
    }

    private func fetchSegments(resultURL: URL) async throws -> [AudioTranscriptSegment] {
        let (data, response) = try await URLSession.shared.data(from: resultURL)
        try validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioNoteTranscriptionError.invalidResponse
        }
        let transcripts = json["transcripts"] as? [[String: Any]] ?? []
        let sentences = transcripts.flatMap { $0["sentences"] as? [[String: Any]] ?? [] }
        return sentences.compactMap { sentence in
            guard let text = sentence["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let words = (sentence["words"] as? [[String: Any]] ?? []).compactMap { word -> AudioTranscriptWord? in
                guard let text = word["text"] as? String else { return nil }
                return AudioTranscriptWord(
                    beginTimeMs: Self.int(word["begin_time"]),
                    endTimeMs: Self.int(word["end_time"]),
                    text: text
                )
            }
            return AudioTranscriptSegment(
                beginTimeMs: Self.int(sentence["begin_time"]),
                endTimeMs: Self.int(sentence["end_time"]),
                originalText: text,
                speakerID: Self.optionalInt(sentence["speaker_id"]),
                words: words
            )
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw AudioNoteTranscriptionError.server(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
    }

    private static func int(_ value: Any?) -> Int {
        optionalInt(value) ?? 0
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

enum AudioNoteTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case timeout
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "audioNote.error.missingAPIKey".localized
        case .invalidResponse: return "audioNote.error.invalidResponse".localized
        case .timeout: return "audioNote.error.timeout".localized
        case .server(let message): return message
        }
    }
}
