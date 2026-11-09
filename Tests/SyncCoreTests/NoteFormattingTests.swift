import Testing
@testable import SyncCore

@Suite struct NoteFormattingTests {
    @Test func splitsTrailingURLLine() {
        let (body, url) = NoteFormatting.splitTrailingURL("Read before Friday.\n\nhttps://github.com/a/b/blob/main/x.ipynb\n")
        #expect(body == "Read before Friday.")
        #expect(url == "https://github.com/a/b/blob/main/x.ipynb")
    }

    @Test func notesThatAreOnlyAURL() {
        let (body, url) = NoteFormatting.splitTrailingURL("https://example.com/a?b=1")
        #expect(body == "")
        #expect(url == "https://example.com/a?b=1")
    }

    @Test func inlineAndMarkdownLinksAreNotTrailingLinks() {
        for notes in ["See https://example.com for details", "[Docs](https://example.com)", "Done.\nhttps://a.com and more"] {
            #expect(NoteFormatting.splitTrailingURL(notes).url == nil)
            #expect(NoteFormatting.splitTrailingURL(notes).body == notes)
        }
    }

    @Test func appLinksCountButBareWordsDoNot() {
        #expect(NoteFormatting.isLinkURL("obsidian://open?vault=Notes&file=x"))
        #expect(NoteFormatting.isLinkURL("things:///show?id=abc"))
        #expect(!NoteFormatting.isLinkURL("Note:"))
        #expect(!NoteFormatting.isLinkURL("https://"))
        #expect(!NoteFormatting.isLinkURL("example.com"))
    }

    @Test func appendRoundTripsWithSplit() {
        let notes = NoteFormatting.appendingURL("https://example.com/x", to: "Body text\n")
        #expect(notes == "Body text\n\nhttps://example.com/x")
        let (body, url) = NoteFormatting.splitTrailingURL(notes)
        #expect(body == "Body text")
        #expect(url == "https://example.com/x")
        #expect(NoteFormatting.appendingURL("https://example.com/x", to: "") == "https://example.com/x")
    }

    @Test func appendDoesNotDuplicateALinkAlreadyInTheNotes() {
        let notes = "See [the doc](https://example.com/x) first."
        #expect(NoteFormatting.appendingURL("https://example.com/x", to: notes) == notes)
    }

    @Test func rendersMarkdownAsPlainText() {
        let md = """
        # Plan
        **Call** the *office* about ~~Tuesday~~ Wednesday.
        - Bring `form_2026.pdf` and the [checklist](https://example.com/c)
        - Link: [https://example.com](https://example.com)
        """
        #expect(NoteFormatting.plainText(fromMarkdown: md) == """
        Plan
        Call the office about Tuesday Wednesday.
        - Bring form_2026.pdf and the checklist (https://example.com/c)
        - Link: https://example.com
        """)
    }

    @Test func leavesTextThatOnlyLooksLikeMarkdownAlone() {
        for s in ["2 * 3 * 4 = 24", "file_name_here and snake_case", "https://example.com/a_b_c", "Price: $5 *each"] {
            #expect(NoteFormatting.plainText(fromMarkdown: s) == s)
        }
    }
}
