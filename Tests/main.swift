import Foundation

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
    let out = ToolsView.time("1793350853000")
    check(out.contains("Unix (ms):  1793350853000"), "timestamp ms")
    check(out.contains("+07:00"), "timestamp gmt+7")
}

segCodecRoundTrip(); markdownBlocks(); readOnlyGuard(); diffMarksChangedLine(); cron()
sqlFormat(); csvAndInsert(); jsonToTypeScript(); objectId(); timestamp()
print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
