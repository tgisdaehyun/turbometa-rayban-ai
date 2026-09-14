public enum TranscriptionPace: String, CaseIterable, Sendable {
    case fast, medium, slow
    public static func saved(_ value: String?) -> Self { value.flatMap(Self.init(rawValue:)) ?? .fast }
    public var title: String {
        switch self { case .fast: return "빨리"; case .medium: return "중간"; case .slow: return "느리게" }
    }
    public var seconds: Int {
        switch self { case .fast: return 2; case .medium: return 5; case .slow: return 15 }
    }
}
