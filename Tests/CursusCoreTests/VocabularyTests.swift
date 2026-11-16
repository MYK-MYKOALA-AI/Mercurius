import Testing
@testable import CursusCore

@Test func newUsersStartWithoutSomeoneElsesDictionary() {
    #expect(Vocabulary.seed.isEmpty)
    #expect(Vocabulary.seedReplacements.isEmpty)
}

@Test func termsAreTrimmedDedupedAndCappedToDictionaryLimit() {
    let long = String(repeating: "x", count: Vocabulary.maxTermLength + 1)
    let many = (0..<(Vocabulary.maxTerms + 50)).map { "term\($0)" }
    let vocabulary = Vocabulary(terms: ["  Supabase ", "supabase", "", long, "Grok"] + many)
    #expect(vocabulary.terms.count == Vocabulary.maxTerms)
    #expect(Array(vocabulary.terms.prefix(2)) == ["Supabase", "Grok"])
    #expect(!vocabulary.terms.contains(long))
}

@Test func replacementsAreWholeWordCaseInsensitiveLongestFirst() {
    let vocabulary = Vocabulary(terms: [], replacements: [
        "superbase": "Supabase", "super base": "Supabase", "cursor's box": "CursusVox", "grok": "Grok"
    ])
    #expect(vocabulary.apply("Deploy the Super Base migration") == "Deploy the Supabase migration")
    #expect(vocabulary.apply("superbase and superbases") == "Supabase and superbases")
    #expect(vocabulary.apply("Open Cursor's box now") == "Open CursusVox now")
    #expect(vocabulary.apply("groks grok") == "groks Grok")
    #expect(Vocabulary(terms: []).apply("unchanged $1 text") == "unchanged $1 text")
    // Quoted and backticked literals stay exactly as spoken (PLAN 21).
    #expect(vocabulary.apply("run echo \"super base\" now") == "run echo \"super base\" now")
    #expect(vocabulary.apply("type `super base` then super base") == "type `super base` then Supabase")
    #expect(vocabulary.apply("say “super base” aloud, super base") == "say “super base” aloud, Supabase")
    // A triple-backtick fence is one span, and a stray quote protects nothing.
    #expect(vocabulary.apply("```super base``` then super base") == "```super base``` then Supabase")
    #expect(vocabulary.apply("a \" stray quote and super base") == "a \" stray quote and Supabase")
}

@Test func autoReplacementsSplitCompoundTermsAndMatchCurlyApostrophes() {
    let auto = Vocabulary.autoReplacements(for: ["CursusVox", "FastAPI", "PostHog", "Grok"])
    #expect(auto["cursus vox"] == "CursusVox")
    #expect(auto["fast api"] == "FastAPI")
    #expect(auto["post hog"] == "PostHog")
    #expect(auto["grok"] == nil)

    let vocabulary = Vocabulary(terms: ["CursusVox"], replacements: ["cursor's box": "CursusVox"])
    #expect(vocabulary.apply("Open Cursor\u{2019}s box now") == "Open CursusVox now")
}

@Test func smartJudgeAllowsSoundAlikeInitialsCurlyApostrophesAndTakenBackDictionaryTerms() {
    let vocabulary = Vocabulary(terms: ["CursusVox", "GitHub", "GitLab"], takeBacks: TakeBack.defaults)
    #expect(TranscriptCleanup.judgeSmart(
        raw: "We launched Kursus Vox today",
        output: "We launched CursusVox today.",
        vocabulary: vocabulary
    ) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(
        raw: "It\u{2019}s working well",
        output: "It's working well.",
        vocabulary: vocabulary
    ) == .accepted)
    #expect(TranscriptCleanup.judgeSmart(
        raw: "Push to GitHub, no wait, GitLab",
        output: "Push to GitLab.",
        vocabulary: vocabulary
    ) == .accepted)
}
