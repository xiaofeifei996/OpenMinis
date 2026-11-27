// Typecheck-only dependency signature. Not linked into the executable fixtures.
// The real provider returns [LLMModel], whose element type is also Sendable.
enum TodayProvider {
    static func fetchModels(sessionCookie: String) async throws -> [String] { [] }
}
