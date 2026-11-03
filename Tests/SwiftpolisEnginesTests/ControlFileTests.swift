import Foundation
import Testing
@testable import SwiftpolisEngines

@Suite("Control file")
struct ControlFileTests {
    /// A shape recorded from a real Persepolis run, shortened to 3 of its 64 entries.
    private let persepolisJSON = """
    {
      "ETag": "\\"v-1\\"",
      "file_name": "file.bin",
      "file_size": 3145728,
      "number_of_parts": 2,
      "download_infromation_list": [
        [0, 1048576, "complete", 0],
        [1048576, 500, "downloading", 2],
        [3145727, 0, "complete", -1]
      ]
    }
    """

    @Test("reads a file Persepolis wrote, using only the real Parts")
    func readsPersepolis() throws {
        let file = try ControlFile.decode(Data(persepolisJSON.utf8))
        #expect(file.etag == "\"v-1\"")
        #expect(file.fileName == "file.bin")
        #expect(file.fileSize == 3_145_728)
        #expect(file.parts.count == 2)
        #expect(file.parts[1].start == 1_048_576)
        #expect(file.parts[1].downloaded == 500)
    }

    @Test("unfinished Parts become pending again, and complete ones stay")
    func resetsForResume() throws {
        let file = try ControlFile.decode(Data(persepolisJSON.utf8))
        #expect(file.parts[0].status == .complete)
        #expect(file.parts[1].status == .pending)
        #expect(file.parts[1].retryCount == -1)
    }

    @Test("Part lengths are rebuilt from the starts and the file size")
    func rebuildsLengths() throws {
        let file = try ControlFile.decode(Data(persepolisJSON.utf8))
        #expect(file.parts[0].length == 1_048_576)
        #expect(file.parts[1].length == 2_097_152)
    }

    @Test("writes what Persepolis writes: its keys, its spelling and 64 entries")
    func writesPersepolisShape() throws {
        let plan = PartPlan.make(fileSize: 3_145_728, supportsRanges: true, connections: 1)
        let file = ControlFile(etag: nil, fileName: "a.bin", fileSize: 3_145_728, parts: plan.parts)

        let json = try #require(JSONSerialization.jsonObject(with: file.encoded()) as? [String: Any])

        #expect(Set(json.keys) == ["ETag", "file_name", "file_size", "number_of_parts", "download_infromation_list"])
        #expect(json["ETag"] is NSNull)
        #expect(json["number_of_parts"] as? Int == 3)
        let entries = try #require(json["download_infromation_list"] as? [[Any]])
        #expect(entries.count == 64)
        #expect(entries[1][0] as? Int == 1_048_576)
        #expect(entries[1][2] as? String == "pending")
        #expect(entries[63][2] as? String == "complete")
    }

    @Test("what it writes, it can read back")
    func roundTrip() throws {
        var plan = PartPlan.make(fileSize: 3_145_728, supportsRanges: true, connections: 1)
        plan.parts[0].downloaded = 1_048_576
        plan.parts[0].status = .complete
        plan.parts[1].downloaded = 7
        let file = ControlFile(etag: "e", fileName: "a.bin", fileSize: 3_145_728, parts: plan.parts)

        let read = try ControlFile.decode(file.encoded())

        #expect(read.etag == "e")
        #expect(read.parts.map(\.downloaded) == [1_048_576, 7, 0])
        #expect(read.parts.map(\.status) == [.complete, .pending, .pending])
    }

    @Test("an unknown size reads back as an open-ended Part")
    func unknownSize() throws {
        let plan = PartPlan.make(fileSize: nil, supportsRanges: true, connections: 1)
        let file = ControlFile(etag: nil, fileName: "a", fileSize: nil, parts: plan.parts)
        let read = try ControlFile.decode(file.encoded())
        #expect(read.fileSize == nil)
        #expect(read.parts.count == 1)
        #expect(read.parts[0].length == nil)
    }

    @Test("an empty file is unreadable, which is what D21 leaves behind")
    func emptyFile() {
        #expect(throws: (any Error).self) { try ControlFile.decode(Data()) }
    }
}

@Suite("Resume decision")
struct ResumeDecisionTests {
    private func control(etag: String?, size: Int64?) -> ControlFile {
        ControlFile(etag: etag, fileName: "a", fileSize: size, parts: [])
    }

    private func decide(
        _ control: ControlFile?,
        etag: String? = nil,
        size: Int64? = 100,
        ranges: Bool = true,
        fileExists: Bool = true
    ) -> ResumeDecision {
        ResumeDecision.decide(
            control: control, etag: etag, fileSize: size, supportsRanges: ranges, fileExists: fileExists
        )
    }

    @Test("no readable control file means starting fresh, in place")
    func noControl() {
        #expect(decide(nil) == .startFresh)
    }

    @Test("a matching ETag resumes")
    func matchingETag() {
        #expect(decide(control(etag: "a", size: 100), etag: "a") == .resume)
    }

    @Test("a changed ETag starts again under a new name, as observed")
    func changedETag() {
        #expect(decide(control(etag: "a", size: 100), etag: "b") == .renameAndStartFresh)
    }

    @Test("with no ETag on either side, matching sizes resume")
    func matchingSize() {
        #expect(decide(control(etag: nil, size: 100)) == .resume)
    }

    @Test("with no ETag on either side, a changed size doesn't resume (fixes D22)")
    func changedSize() {
        #expect(decide(control(etag: nil, size: 40), size: 30) == .renameAndStartFresh)
    }

    @Test("an ETag on only one side falls back to the sizes")
    func oneSidedETag() {
        #expect(decide(control(etag: "a", size: 100), etag: nil, size: 100) == .resume)
        #expect(decide(control(etag: nil, size: 100), etag: "a", size: 90) == .renameAndStartFresh)
    }

    @Test("nothing to compare can't be trusted")
    func nothingToCompare() {
        #expect(decide(control(etag: nil, size: nil), size: nil) == .renameAndStartFresh)
    }

    @Test("a mismatch with no partial file just overwrites the control file")
    func mismatchWithoutFile() {
        #expect(decide(control(etag: "a", size: 100), etag: "b", fileExists: false) == .startFresh)
    }

    @Test("a match with no partial file starts fresh")
    func matchWithoutFile() {
        #expect(decide(control(etag: "a", size: 100), etag: "a", fileExists: false) == .startFresh)
    }

    @Test("a match on a server without ranges starts fresh, in place")
    func matchWithoutRanges() {
        #expect(decide(control(etag: "a", size: 100), etag: "a", ranges: false) == .startFresh)
    }
}
