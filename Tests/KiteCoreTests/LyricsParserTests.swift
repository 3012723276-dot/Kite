import Foundation
import Testing

@testable import KiteCore

// What the parser hands the karaoke wipe: a line's words joined are its text
// (one opacity per character), every line has an end, and a song without
// word timing of its own still gets words to light.
@Suite struct LyricsParserTests {

    private func response(lrc: String? = nil, yrc: String? = nil, tlyric: String? = nil) -> LyricResponse {
        func body(_ text: String?) -> LyricResponse.LyricBody? {
            text.map { LyricResponse.LyricBody(lyric: $0) }
        }
        return LyricResponse(
            lrc: body(lrc), tlyric: body(tlyric), romalrc: nil, yrc: body(yrc), ytlrc: nil,
            yromalrc: nil, lyricUser: nil, transUser: nil, nolyric: nil, uncollected: nil)
    }

    @Test func verbatimLinesKeepTheirEndAndFoldGapsIntoWords() {
        let yrc = """
        {"t":0,"c":[{"tx":"作词: 某人"}]}
        [1000,2000](1000,500,0)我(1500,500,0) (2000,1000,0)爱你
        [4000,1500](4000,700,0)Hello(4700,100,0) (4800,700,0)world
        """
        let lines = LyricsParser.parseYRC(yrc)
        #expect(lines.count == 2)
        #expect(lines[0].time == 1)
        #expect(lines[0].end == 3)
        #expect(lines[0].text == "我 爱你")
        #expect(lines[0].words?.map(\.text) == ["我 ", "爱你"])
        #expect(lines[1].text == "Hello world")
        #expect(lines[1].words?.map(\.text) == ["Hello ", "world"])
        #expect(lines[1].end == 5.5)
        for line in lines {
            #expect(line.words?.map(\.text).joined() == line.text)
        }
    }

    @Test func plainLinesGetTheirTimeSpreadAcrossTheirCharacters() throws {
        let lrc = "[00:10.00]我爱你 hello world\n[00:14.00]第二行\n[00:30.00]最后"
        let parsed = LyricsParser.parse(response(lrc: lrc))
        #expect(parsed.lines.count == 3)
        let first = parsed.lines[0]
        #expect(first.end == 14)
        let words = try #require(first.words)
        #expect(words.map(\.text) == ["我", "爱", "你 ", "hello ", "world"])
        #expect(words.map(\.text).joined() == first.text)
        // 85 % of the four seconds, shared out by letter count (3 + 5 + 5).
        let span = 4 * 0.85
        #expect(abs(words[0].duration - span / 13) < 1e-9)
        #expect(abs(words[3].duration - span * 5 / 13) < 1e-9)
        #expect(abs(words[4].end - (10 + span)) < 1e-9)
        // A line before a long break, and the last line, are sung for six seconds.
        #expect(parsed.lines[1].end == 20)
        #expect(parsed.lines[2].end == 36)
    }

    @Test func verbatimLyricsDoNotNeedAnLrcBody() {
        let parsed = LyricsParser.parse(response(yrc: "[1000,2000](1000,1000,0)你(2000,1000,0)好"))
        #expect(parsed.lines.map(\.text) == ["你好"])
        #expect(parsed.lines.first?.words?.count == 2)
    }

    @Test func translationsPairWithTheirNearestLineOnce() {
        // The verbatim lines start a few hundred ms off the lrc grid the
        // translation follows; the orphan has no line of its own.
        let yrc = """
        [10400,2000](10400,2000,0)一
        [14300,2000](14300,2000,0)二
        [18000,2000](18000,2000,0)三
        """
        let tlyric = "[00:10.00]one\n[00:14.00]two\n[00:16.00]orphan\n[00:18.00]three"
        let parsed = LyricsParser.parse(
            response(lrc: "[00:10.00]一\n[00:14.00]二\n[00:18.00]三", yrc: yrc, tlyric: tlyric))
        #expect(parsed.lines.map(\.translation) == ["one", "two", "three"])
    }

    @Test func punctuationAndSpacesLightWithTheLetterBeforeThem() {
        let words = [
            LyricWord(text: "爱，", start: 0, duration: 1),
            LyricWord(text: " 你", start: 1, duration: 1),
        ]
        let line = LyricLine(id: 0, time: 0, end: 2, text: "爱， 你", words: words)
        let halfway = LyricMainText.alphas(for: line, words: words, at: 0.5)
        #expect(halfway.count == 4)
        #expect(halfway[1] == halfway[0])
        #expect(halfway[2] == halfway[0])
        #expect(halfway[3] == 0.28)
        let sung = LyricMainText.alphas(for: line, words: words, at: 1)
        #expect(sung.prefix(3).allSatisfy { abs($0 - 1) < 1e-9 })
    }
}
