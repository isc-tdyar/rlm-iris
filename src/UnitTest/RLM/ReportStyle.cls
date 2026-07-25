/// Report styles, and the rendered trace.
///
/// The whole of US3 rests on one claim: a style changes how a run is presented and
/// nothing about what it says. So plain style is asserted against literal strings
/// captured before styles existed -- SC-002 at the primitive level -- and the
/// Markdown assertions are about punctuation only.
///
/// Every assertion macro is on one source line: $$$macro(...) cannot span lines in
/// ObjectScript, and a wrapped call is a syntax error that %UnitTest reports as a
/// silently skipped class.
Class UnitTest.RLM.ReportStyle Extends %UnitTest.TestCase
{

/// The pre-feature heading, held as a literal. A re-derivation would agree with a
/// broken implementation.
Method TestPlainHeadingIsUnchanged()
{
    Set r = ##class(RLM.Report).%New()
    Do r.Heading("Store")
    Do $$$AssertEquals(r.Text, "Store"_$Char(10)_"-----", "text then a rule of dashes")
}

Method TestMarkdownHeadingUsesHashes()
{
    Set r = ##class(RLM.Report).%New()
    Set r.Style = "markdown"
    Do r.Heading("Store")
    Do $$$AssertEquals(r.Text, "## Store", "one line, no rule")
    Do $$$AssertEquals($Find(r.Text, "-----"), 0, "and nothing left of the rule")
}

/// FR-012. A depth-2 finding indented under its parent is the only thing in the
/// report that says which slice it came out of.
Method TestBulletIndentsByDepth()
{
    Set r = ##class(RLM.Report).%New()
    Do r.Bullet("root", 0)
    Do r.Bullet("child", 1)
    Do r.Bullet("grandchild", 2)
    Set want = "- root"_$Char(10)_"  - child"_$Char(10)_"    - grandchild"
    Do $$$AssertEquals(r.Text, want, "two spaces per level, in both styles")
}

/// A depth-0 bullet must be byte-identical to the `"- "_text` the engine used to
/// concatenate itself, or SC-002 fails on any report with a finding in it.
Method TestBulletAtDepthZeroMatchesOldOutput()
{
    Set r = ##class(RLM.Report).%New()
    Do r.Bullet("red [red: n=600] tight")
    Do $$$AssertEquals(r.Text, "- red [red: n=600] tight", "the old line exactly")
}

/// Content passes through unaltered in both styles: a fenced block exists to hold
/// something a reader will compare against a file, and a report that reflows it is
/// worse than one that omits it.
Method TestFencedPassesContentThrough()
{
    Set lines = $ListBuild("decision 0 -", "subcall 1 color:red")
    Set md = ##class(RLM.Report).%New()
    Set md.Style = "markdown"
    Do md.Fenced(lines, "text")
    Set plain = ##class(RLM.Report).%New()
    Do plain.Fenced(lines)

    Do $$$AssertNotEquals($Find(md.Text, "```text"), 0, "markdown opens a fence")
    Do $$$AssertEquals($Length(md.Text, "```"), 3, "and closes it")
    Do $$$AssertNotEquals($Find(md.Text, "subcall 1 color:red"), 0, "content intact")
    Do $$$AssertEquals($Find(plain.Text, "```"), 0, "plain style fences nothing")
    Do $$$AssertNotEquals($Find(plain.Text, "  subcall 1 color:red"), 0, "indents")
}

/// FR-011. One line per trace row, naming what happened. This is the artifact a
/// human reads when the report's answer is surprising, so a row that produced no
/// model call must appear too -- a declined decision and a row that failed to
/// write are otherwise indistinguishable.
Method TestRenderTraceNamesEveryRow()
{
    Set source = ##class(UnitTest.RLM.FixtureNested).%New()
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "c", "answer"))
    Set engine = ##class(RLM.Engine).%New(source, llm, ##class(RLM.Budget).%New(16),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("q", .traceId)

    Set lines = ##class(RLM.Report).RenderTrace(traceId)
    Set rows = ##class(RLM.Trace).RowCount(traceId)
    Do $$$AssertEquals($ListLength(lines), rows, "one line per row, none dropped")
    Set joined = $ListToString(lines, $Char(10))
    Do $$$AssertNotEquals($Find(joined, "color:red/size:small"), 0, "deep slice named")
    Do $$$AssertNotEquals($Find(joined, "decision"), 0, "roles named")
    Do $$$AssertNotEquals($Find(joined, "split on color"), 0, "outcomes named")
}

/// The depth marker starts at the same column on every line.
///
/// This is the point of rendering a trace at all: a reader scans the depth column to
/// see the shape of the run, and a column that moves with the length of the role
/// name is a list, not a table. It is asserted because the obvious way to write it
/// -- $Justify(role, -10) -- silently does nothing: $Justify's third argument is a
/// decimal count and there is no left-aligning form, so the roles come back
/// unpadded and the defect is invisible in a passing test that only greps for text.
Method TestRenderTraceAlignsTheDepthColumn()
{
    Set source = ##class(UnitTest.RLM.FixtureNested).%New()
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "c", "answer"))
    Set engine = ##class(RLM.Engine).%New(source, llm, ##class(RLM.Budget).%New(16),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("q", .traceId)

    // Roles of different lengths in one run -- "decision", "subcall", "synthesis"
    // -- which is what makes the column either hold or not. The marker is read at a
    // fixed offset rather than searched for: $Find(line, " d") would match the space
    // before "decision" and pass on exactly the output this test exists to reject.
    Set lines = ##class(RLM.Report).RenderTrace(traceId)
    Set roles = "", markers = "", ptr = 0
    While $ListNext(lines, ptr, line) {
        Set roles = roles_$Select(roles="":"", 1:",")_$ZStrip($Extract(line, 6, 15), "<>W")
        Set markers = markers_$Select(markers="":"", 1:",")_$Extract(line, 16, 17)
    }
    Do $$$AssertNotEquals($ListFind($ListFromString(roles), "subcall"), 0, "short role")
    Do $$$AssertNotEquals($ListFind($ListFromString(roles), "synthesis"), 0, "long one")
    Do $$$AssertEquals($Translate(markers, ", d", ""), "", "every ' d' at column 16")
}

/// A decline carries the reason it declined, which is the one thing a reader of a
/// short report actually wants.
Method TestRenderTraceIncludesDeclineReason()
{
    Set flat = ##class(UnitTest.RLM.FixtureFlat).%New()
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("answer"))
    Set engine = ##class(RLM.Engine).%New(flat, llm, ,
        ##class(RLM.Policy.Greedy).%New())
    Do engine.Run("q", .traceId)

    Set joined = $ListToString(##class(RLM.Report).RenderTrace(traceId), $Char(10))
    Do $$$AssertNotEquals($Find(joined, "not decomposed"), 0, "the decline is there")
    Set why = $Find(joined, "no dimension reduced the metric")
    Do $$$AssertNotEquals(why, 0, "with the policy's reason attached")
}

/// The reader this exists for has a run id and a database, not a live engine, so
/// the depth of each row has to come back off the trace rather than out of a
/// caller's bookkeeping.
Method TestRenderTraceCarriesDepth()
{
    Set source = ##class(UnitTest.RLM.FixtureNested).%New()
    Set llm = ##class(RLM.LLM.Null).%New($ListBuild("a", "b", "c", "answer"))
    Set engine = ##class(RLM.Engine).%New(source, llm, ##class(RLM.Budget).%New(16),
        ##class(RLM.Policy.Greedy).%New())
    Set engine.MaxDepth = 2
    Do engine.Run("q", .traceId)

    Set lines = ##class(RLM.Report).RenderTrace(traceId)
    Set deep = ""
    Set ptr = 0
    While $ListNext(lines, ptr, line) {
        If $Find(line, "size:small") { Set deep = line }
    }
    Do $$$AssertNotEquals(deep, "", "the depth-2 row is rendered")
    Do $$$AssertNotEquals($Find(deep, "2"), 0, "and says it is at depth 2")
}

/// FR-014, and the defect the gaia port exposed. `Engine.Run` returns report text
/// and keeps the Report object private to the run, so a caller who wants the
/// report on disk cannot reach the instance method at all. Every consumer would
/// re-implement it, and the first to forget the translate table gets a file whose
/// em dashes are question marks -- indistinguishable from a wrong report.
Method TestWriteTextToFileRoundTripsUTF8()
{
    Set path = "/tmp/rlm_writetext_"_$Job_".md"
    Set text = "Store -- 74,998 sources"_$Char(10)_"sigma = 0.04"
    Set sc = ##class(RLM.Report).WriteTextToFile(text, path)
    Do $$$AssertStatusOK(sc, "the text is written")

    Set f = ##class(%Stream.FileCharacter).%New()
    Set f.TranslateTable = "UTF8"
    Do f.LinkToFile(path)
    Set got = f.Read(4000)
    Do $$$AssertEquals(got, text, "and reads back byte for byte")
    Do ##class(%File).Delete(path)
}

/// An em dash specifically: it is what the report's own prose uses, so a missing
/// translate table corrupts every real report rather than an edge case.
Method TestWriteTextToFileKeepsEmDash()
{
    Set path = "/tmp/rlm_writetext_dash_"_$Job_".md"
    Set text = "the limits "_$Char(8212)_" named, not hidden"
    Do ##class(RLM.Report).WriteTextToFile(text, path)

    Set f = ##class(%Stream.FileCharacter).%New()
    Set f.TranslateTable = "UTF8"
    Do f.LinkToFile(path)
    Set got = f.Read(4000)
    Do $$$AssertEquals($Ascii(got, $Length("the limits ") + 1), 8212, "still an em dash")
    Do ##class(%File).Delete(path)
}

/// A bad path is a status, not an exception. The gaia contract is that the report
/// is a bonus deliverable whose absence must not disturb the timed pipeline, and a
/// throw here would propagate out of a caller that only wanted a file.
Method TestWriteTextToFileRefusesBadPathWithoutThrowing()
{
    Set threw = 0
    Set sc = $$$OK
    Try {
        Set sc = ##class(RLM.Report).WriteTextToFile("x", "/nonexistent-dir-xyz/r.md")
    } Catch e {
        Set threw = 1
    }
    Do $$$AssertEquals(threw, 0, "no exception escapes")
    Do $$$AssertStatusNotOK(sc, "and the failure comes back as a status")
}

/// The instance method keeps working, and now delegates. Asserted because the
/// engine calls it on every run and a refactor that broke it would show up only in
/// a file nobody reads until later.
Method TestWriteToFileStillWritesTheReport()
{
    Set path = "/tmp/rlm_writefile_"_$Job_".md"
    Set r = ##class(RLM.Report).%New()
    Do r.Heading("Store")
    Set sc = r.WriteToFile(path)
    Do $$$AssertStatusOK(sc, "the instance method still writes")

    Set f = ##class(%Stream.FileCharacter).%New()
    Set f.TranslateTable = "UTF8"
    Do f.LinkToFile(path)
    Do $$$AssertEquals(f.Read(4000), r.Text, "the same text the report holds")
    Do ##class(%File).Delete(path)
}

}
