import Testing
import SwiftpolisDomain

@Suite("Category rules")
struct CategoryRulesTests {
    private let existing = ["All Downloads", "Single Downloads", "Scheduled Downloads", "Movies"]

    @Test("the built-in Categories, in side panel order")
    func builtIns() {
        #expect(CategoryKind.builtInNames == ["All Downloads", "Single Downloads", "Scheduled Downloads"])
    }

    @Test("kinds", arguments: [
        ("All Downloads", CategoryKind.allDownloads),
        ("Single Downloads", .singleDownloads),
        ("Scheduled Downloads", .queue),
        ("Movies", .queue),
    ])
    func kinds(name: String, kind: CategoryKind) {
        #expect(CategoryKind(categoryName: name) == kind)
    }

    @Test("a new name is accepted")
    func acceptsNewName() throws {
        try CategoryKind.validateNewQueueName("Music", existing: existing)
    }

    @Test("an empty name is rejected")
    func rejectsEmpty() {
        #expect(throws: QueueNameError.empty) {
            try CategoryKind.validateNewQueueName("", existing: existing)
        }
    }

    @Test("a taken name is rejected, including every built-in", arguments: [
        "All Downloads", "Single Downloads", "Scheduled Downloads", "Movies",
    ])
    func rejectsTaken(name: String) {
        #expect(throws: QueueNameError.alreadyExists) {
            try CategoryKind.validateNewQueueName(name, existing: existing)
        }
    }

    @Test("only user-created Queues can be removed", arguments: [
        ("All Downloads", false),
        ("Single Downloads", false),
        ("Scheduled Downloads", false),
        ("Movies", true),
    ])
    func removal(name: String, canRemove: Bool) {
        #expect(CategoryKind.canRemove(categoryNamed: name) == canRemove)
    }
}
