import Testing
import SwiftpolisDomain

@Suite("GID")
struct GIDTests {
    @Test("accepts the 16-character hex form Persepolis stores")
    func acceptsPersepolisForm() {
        #expect(GID(rawValue: "1a2b3c4d5e6f7a8b")?.rawValue == "1a2b3c4d5e6f7a8b")
    }

    @Test("rejects anything else", arguments: [
        "", "1a2b3c4d5e6f7a8", "1a2b3c4d5e6f7a8b0", "xyzxyzxyzxyzxyzx", "1A2B3C4D5E6F7A8B",
    ])
    func rejectsInvalid(raw: String) {
        #expect(GID(rawValue: raw) == nil)
    }

    @Test("generated values are always valid, even at the bottom of the range")
    func generatedValuesAreValid() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1_000 {
            let gid = GID.generate(avoiding: [], using: &rng)
            #expect(GID(rawValue: gid.rawValue) == gid)
        }
    }

    @Test("generation skips a value that is already taken")
    func skipsExisting() {
        var first = RepeatingGenerator()
        let taken = GID.generate(avoiding: [], using: &first)

        var second = RepeatingGenerator()
        let next = GID.generate(avoiding: [taken], using: &second)

        #expect(next != taken)
    }
}

/// The same pseudo-random sequence on every run, so two instances produce the same GIDs.
private struct RepeatingGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
