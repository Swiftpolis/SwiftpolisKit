import Testing
@testable import SwiftpolisEngines

@Suite("Part plan")
struct PartPlanTests {
    private let mib: Int64 = 1_048_576

    @Test("a file of 64 MiB or more gets 64 equal Parts, and the last takes the remainder")
    func largeFile() {
        let plan = PartPlan.make(fileSize: 128 * mib + 5, supportsRanges: true, connections: 64)
        #expect(plan.parts.count == 64)
        #expect(plan.connections == 64)
        #expect(plan.parts[0].start == 0)
        #expect(plan.parts[1].start == 2 * mib)
        #expect(plan.parts[0].length == 2 * mib)
        #expect(plan.parts[63].start == 126 * mib)
        #expect(plan.parts[63].length == 2 * mib + 5)
    }

    @Test("a smaller file gets one Part per started MiB", arguments: [
        (Int64(10 * 1_048_576), 10),
        (Int64(10 * 1_048_576 + 1), 11),
        (Int64(1), 1),
        (Int64(1_048_576), 1),
    ])
    func smallFile(size: Int64, parts: Int) {
        let plan = PartPlan.make(fileSize: size, supportsRanges: true, connections: 64)
        #expect(plan.parts.count == parts)
        #expect(plan.parts.reduce(0) { $0 + ($1.length ?? 0) } == size)
    }

    @Test("Connections never exceed what was asked for (fixes D4)")
    func fewerConnections() {
        let plan = PartPlan.make(fileSize: 10 * mib, supportsRanges: true, connections: 4)
        #expect(plan.parts.count == 10)
        #expect(plan.connections == 4)
    }

    @Test("Connections never exceed the Parts")
    func fewerParts() {
        let plan = PartPlan.make(fileSize: 3 * mib, supportsRanges: true, connections: 64)
        #expect(plan.connections == 3)
    }

    @Test("an unknown size is one open-ended Part")
    func unknownSize() {
        let plan = PartPlan.make(fileSize: nil, supportsRanges: true, connections: 64)
        #expect(plan.connections == 1)
        #expect(plan.parts.count == 1)
        #expect(plan.parts[0].length == nil)
    }

    @Test("no range support is one whole-file Part (fixes D13)")
    func noRanges() {
        let plan = PartPlan.make(fileSize: 100 * mib, supportsRanges: false, connections: 64)
        #expect(plan.connections == 1)
        #expect(plan.parts.count == 1)
        #expect(plan.parts[0].length == 100 * mib)
    }

    @Test("new Parts are pending, with Persepolis's retry count of -1")
    func newPartState() {
        let part = PartPlan.make(fileSize: mib, supportsRanges: true, connections: 1).parts[0]
        #expect(part.status == .pending)
        #expect(part.downloaded == 0)
        #expect(part.retryCount == -1)
    }
}
