import Foundation
import AppKit

var failures = 0
func check(_ ok: Bool, _ name: String) {
    if !ok { failures += 1; print("FAIL: \(name)") }
}

func segCodecRoundTrip() {
    for src in ["a\n```js\nx\n```\n\nb", "```\nx\n```", "", "t\n\n", "one\n```sh\nls\n```"] {
        check(SegCodec.serialize(SegCodec.parse(src)) == src, "segcodec round trip: \(src.debugDescription)")
    }
    check(SegCodec.parse("a\n```jsx\nx\n```").filter(\.isCode).first?.lang == "jsx", "segcodec keeps language")
}

func markdownBlocks() {
    let blocks = MDParser.parse("# T\n\n- a\n- [x] b\n\n```sh\nls\n```\n\n| h |\n|---|\n| v |")
    check(blocks.count == 4, "markdown block count \(blocks.count)")
    check(MDParser.headings("# T\ntext\n## S").map(\.level) == [1, 2], "markdown headings")
}

func readOnlyGuard() {
    check(DBQueryView.isReadOnly("SELECT 1;"), "select allowed")
    check(DBQueryView.isReadOnly("with x as (select 1) select * from x"), "with allowed")
    check(!DBQueryView.isReadOnly("DELETE FROM t"), "delete rejected")
    check(!DBQueryView.isReadOnly("select 1; drop table t"), "multi statement rejected")
}

func diffMarksChangedLine() {
    let rows = Differ.rows(old: "a\nhello world\nc", new: "a\nhello brave\nc", ignoreWhitespace: false)
    check(rows.map(\.kind) == [.same, .del, .add, .same], "diff kinds")
}

func cron() {
    check(Cron.parse("*/15 9-17 * * mon-fri") != nil, "cron valid")
    check(Cron.parse("61 * * * *") == nil, "cron invalid")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    let from = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8, minute: 59))!
    let runs = Cron.nextRuns("0 9 * * *", count: 2, from: from, calendar: cal)
    check(runs.count == 2, "cron run count")
    check(runs.count == 2 && cal.component(.hour, from: runs[0]) == 9, "cron first hour")
    check(runs.count == 2 && cal.component(.day, from: runs[1]) == 2, "cron second day")
}

func cronNL() {
    let cases: [(String, String)] = [
        ("every 5 minutes", "*/5 * * * *"),
        ("every minute", "* * * * *"),
        ("every hour", "0 * * * *"),
        ("every 2 hours", "0 */2 * * *"),
        ("every day at 9am", "0 9 * * *"),
        ("daily at midnight", "0 0 * * *"),
        ("every weekday at 8:30am", "30 8 * * 1-5"),
        ("every monday and friday at 2pm", "0 14 * * 1,5"),
        ("every monday to friday at 17:00", "0 17 * * 1-5"),
        ("1st of every month at midnight", "0 0 1 * *"),
        ("every 15 minutes between 9am and 5pm on weekdays", "*/15 9-17 * * 1-5"),
        ("every sunday at 3:30 pm in june", "30 15 * 6 0"),
        ("weekly", "0 0 * * 0"),
        ("every 3 days at noon", "0 12 */3 * *"),
    ]
    for (text, want) in cases {
        let got = CronNL.parse(text)?.expr ?? "nil"
        check(got == want, "cronNL '\(text)' -> \(got), want \(want)")
    }
    check(CronNL.parse("blah blah") == nil, "cronNL rejects gibberish")
}

func ptyPassword() {
    let r = ConnectionManager.ptyRun("printf 'Password: '; read -s x; [ \"$x\" = secret ]", password: { "secret" }, timeout: 10)
    check(r.code == 0, "pty password injected: \(r.out)")
    let w = ConnectionManager.ptyRun("printf 'Password: '; read -s x; [ \"$x\" = secret ]", password: { nil }, timeout: 2)
    check(w.code != 0, "pty without password fails")
}

func liveEditor() {
    _ = NSApplication.shared
    func make(_ s: String) -> MDTextView {
        let tv = MDTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.string = s
        tv.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
        return tv
    }
    var tv = make("- a"); tv.insertNewline(nil)
    check(tv.string == "- a\n- ", "bullet continues: \(tv.string.debugDescription)")
    tv = make("- a\n- "); tv.insertNewline(nil)
    check(tv.string == "- a\n", "empty bullet exits: \(tv.string.debugDescription)")
    tv = make("1. x"); tv.insertNewline(nil)
    check(tv.string == "1. x\n2. ", "numbered continues: \(tv.string.debugDescription)")
    tv = make("- [x] done"); tv.insertNewline(nil)
    check(tv.string == "- [x] done\n- [ ] ", "todo continues: \(tv.string.debugDescription)")
    tv = make("plain"); tv.insertNewline(nil)
    check(tv.string == "plain\n", "plain newline")
    tv = make("# Title\n**b** `c`"); tv.restyle()
    let f = tv.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    check((f?.pointSize ?? 0) > 25, "heading is large")
}

func userPath() {
    let path = UserEnv.env["PATH"] ?? ""
    check(path.contains("/opt/homebrew/bin") && path.contains(NSHomeDirectory() + "/bin"), "user PATH merged: \(path)")
    let r = shell("command -v alloydb-auth-proxy >/dev/null || [ ! -x $HOME/bin/alloydb-auth-proxy ]")
    check(r.code == 0, "shell finds ~/bin tools")
}

func hexAndSearch() {
    check(HexTool.convert("48 65 6c 6c 6f", decode: true) == "Hello", "hex decode")
    check(HexTool.convert("0x48,0x69", decode: true) == "Hi", "hex decode 0x")
    check(HexTool.convert("Hi", decode: false) == "48 69", "hex encode")
    check(HexTool.convert("e1ba", decode: true).hasPrefix("(not valid UTF-8"), "hex bad utf8")
    check(HexTool.convert("abc", decode: true).hasPrefix("Invalid"), "hex odd")
    check(OutputSearch.count("{\n  \"Name\": \"a\",\n  \"name2\": 1\n}", "name") == 2, "search count")
    let a = OutputSearch.highlight("a\nfoo\nb", term: "FOO", onlyMatches: true)
    check(String(a.characters).contains("foo") && !String(a.characters).contains("\nb"), "only matching lines")
}

func sqlFormat() {
    let out = SQLFormat.format("select a,b from t where x=1 and y=2 order by a")
    check(out == "SELECT a,\n  b\nFROM t\nWHERE x = 1\n  AND y = 2\nORDER BY a", "sql format: \(out.debugDescription)")
}

func csvAndInsert() {
    check(CSVTool.parseCSV("a,b\n\"x,1\",2").last == ["x,1", "2"], "csv quoted comma")
    let ins = CSVTool.csvToInserts("id,name\n1,O'Neil", table: "u")
    check(ins == "INSERT INTO u (id, name) VALUES (1, 'O''Neil');", "csv insert: \(ins)")
    check(CSVTool.jsonToCSV("[{\"a\":1,\"b\":\"x,y\"}]").contains("\"x,y\""), "json to csv quoting")
}

func jsonToTypeScript() {
    let ts = TSGen.generate("{\"id\":1,\"tags\":[\"a\"],\"owner\":{\"name\":\"x\"},\"opt\":null}")
    check(ts.contains("interface Root"), "ts root interface: \(ts)")
    check(ts.contains("tags: string[];"), "ts array")
    check(ts.contains("owner: Owner;"), "ts nested")
}

func objectId() {
    let id = IDGen.objectId()
    check(id.count == 24, "objectid length")
    check(IDGen.objectIdDate(id) != nil, "objectid decode")
}

func timestamp() {
    check(ToolsView.time("01-11-2026 00:00:00").contains("Unix (s):   1793466000"), "friendly date gmt+7")
    let out = ToolsView.time("1793350853000")
    check(out.contains("Unix (ms):  1793350853000"), "timestamp ms")
    check(out.contains("+07:00"), "timestamp gmt+7")
}

segCodecRoundTrip(); markdownBlocks(); readOnlyGuard(); diffMarksChangedLine(); cron()
func noteLinks() {
    check(NotesStore.wikiLinks("see [[A b]] and [[C|alias]], again [[A b]] and [[ ]]") == ["A b", "C"], "wiki links parsed, deduped")
    check(NotesStore.wordCount("one two\n three") == 3, "word count")
}

func dueDates() {
    let cal = Calendar.current
    let today = cal.startOfDay(for: Date())
    check(dueLabel(today).hasPrefix("Today"), "due: today label")
    check(dueLabel(cal.date(byAdding: .day, value: 1, to: today)!).hasPrefix("Tomorrow"), "due: tomorrow label")
    check(dueLabel(cal.date(byAdding: .day, value: -3, to: today)!).hasPrefix("3 days overdue"), "due: overdue label")
    check(!isOverdue(today), "due: date-only today is not overdue")
    let past = cal.date(byAdding: .minute, value: -5, to: Date())!
    check(!dueHasTime(today) && (!dueHasTime(past) || isOverdue(past)), "due: past timed date is overdue")
    let p = subProgress([SubDraft(title: "a", done: true), SubDraft(title: "b", done: false), SubDraft(title: "c", done: false)])
    check(p.percent == 33 && p.done == 1, "subtask progress 33%")
    check(dueBucket(nil) == .none && dueBucket(today) == .today, "bucket: none/today")
    check(dueBucket(cal.date(byAdding: .day, value: -2, to: today)!) == .overdue, "bucket: overdue")
    check(dueBucket(cal.date(byAdding: .day, value: 3, to: today)!) == .upcoming, "bucket: upcoming")
    let week = calendarDays(anchor: Date(), week: true)
    var mon = Calendar.current; mon.firstWeekday = 2
    check(week.count == 7 && mon.component(.weekday, from: week[0]) == 2, "calendar: Monday-first week")
    let month = calendarDays(anchor: Date(), week: false)
    check(month.count % 7 == 0 && month.count >= 28, "calendar: month grid is whole weeks")
}
cronNL(); noteLinks(); dueDates(); ptyPassword(); hexAndSearch(); userPath(); liveEditor(); sqlFormat(); csvAndInsert(); jsonToTypeScript(); objectId(); timestamp()
print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
