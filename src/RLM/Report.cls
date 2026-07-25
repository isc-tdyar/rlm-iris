/// Assembles the report text.
///
/// Separate from the engine because the two change for different reasons: the
/// engine changes when the recursion changes, the report changes whenever a
/// human reads one and finds it unclear.
///
/// The disclosure rules are the reason this is a class and not string
/// concatenation inside the engine. A report that omits a refused slice, a
/// capped count or an exhausted budget reads as complete, and a reader acting on
/// it has no way to know otherwise.
Class RLM.Report Extends %RegisteredObject
{

/// "plain" or "markdown". Plain is byte-identical to the output this class
/// produced before styles existed, which is what makes the Markdown style a
/// rendering change and not a rewrite.
Property Style As %String [ InitialExpression = "plain" ];

Property Lines As %Integer [ InitialExpression = 0 ];

Property Text As %String(MAXLEN = "");

Method Add(
	line As %String = "",
	indent As %Integer = 0) As %Status
{
    Set ..Text = ..Text_$Select(..Lines:$Char(10), 1:"")_$Justify("", indent * 2)_line
    Set ..Lines = ..Lines + 1
    Quit $$$OK
}

Method AddBlank() As %Status
{
    Quit ..Add("")
}

Method Heading(text As %String) As %Status
{
    If ..Style = "markdown" { Quit ..Add("## "_text) }
    Do ..Add(text)
    Quit ..Add($Translate($Justify("", $Length(text)), " ", "-"))
}

/// One finding, indented under its parent.
///
/// The same in both styles, because "- " at two spaces per level is already how
/// Markdown nests a list and is also what the engine concatenated by hand before
/// this method existed. A style that changed the marker would break SC-002 for no
/// reader's benefit.
Method Bullet(
	text As %String,
	depth As %Integer = 0) As %Status
{
    Quit ..Add("- "_text, depth)
}

/// A block a reader will compare against something else -- a trace, a query, a
/// file. Fenced in Markdown, indented in plain, and in neither case reflowed:
/// content that has been re-wrapped cannot be compared, which is the only reason
/// to put it in a block.
Method Fenced(
	lines As %List,
	language As %String = "") As %Status
{
    Set markdown = (..Style = "markdown")
    If markdown { Do ..Add("```"_language) }
    Set ptr = 0
    While $ListNext(lines, ptr, line) {
        Do ..Add($Select(markdown:line, 1:"  "_line))
    }
    If markdown { Do ..Add("```") }
    Quit $$$OK
}

/// A run's trace as one line per row: role, depth, slice, and what happened.
///
/// A class method over a run id rather than an instance method, because the reader
/// this is for has a run id and a database and no live engine -- the same reason
/// RLM.Trace.Decisions is a class method. Returns a %List so a caller can fence it,
/// file it, or diff two runs without re-splitting text.
ClassMethod RenderTrace(
	runId As %Integer,
	durable As %Boolean = 0) As %List
{
    Set out = "", seq = ""
    For  {
        If durable { Set seq = $Order(^RLM.Trace(runId, seq), 1, row) }
        Else { Set seq = $Order(^||RLM.Trace(runId, seq), 1, row) }
        Quit:seq=""
        Set role = $List(row, 1), depth = $List(row, 2)
        Set slice = $List(row, 4), note = $List(row, 10)
        // Padded by hand: $Justify's second argument is a width and its third is a
        // decimal count, so there is no left-aligning form of it -- $Justify(role,
        // -10) returns the role unchanged and the column silently never appears.
        Set line = $Justify(seq, 3)_"  "_role_$Justify("", 10 - $Length(role))
            _" d"_depth_"  "_$Select(slice="":"(whole store)", 1:slice)
        If note '= "" { Set line = line_"  -- "_note }
        // A decision's own words live in the sidecar, not in the row's note, and
        // "not decomposed" without the reason is the least useful line a trace can
        // produce -- it is the row a reader of a short report came looking for.
        If durable { Set side = $Get(^RLM.Trace(runId, seq, "d")) }
        Else { Set side = $Get(^||RLM.Trace(runId, seq, "d")) }
        If side '= "", $List(side, 2) '= "" {
            Set line = line_" ("_$List(side, 2)_")"
        }
        If $List(row, 6) { Set line = line_"  [capped]" }
        Set out = out_$ListBuild(line)
    }
    Quit out
}

/// Caveats belong at the end under their own heading, where a reader looking for
/// the limits of what they just read will actually find them.
Method Caveats(caveats As %List) As %Status
{
    If $ListLength(caveats) = 0 { Quit $$$OK }
    Do ..AddBlank()
    Do ..Heading("Limits of this analysis")
    Set ptr = 0
    While $ListNext(caveats, ptr, c) {
        Do ..Add("- "_c)
    }
    Quit $$$OK
}

/// Write the report to a file. UTF-8 explicitly: without the translate table an
/// em dash or a Greek letter becomes a question mark, and a corrupted report is
/// indistinguishable from a wrong one at a glance.
Method WriteToFile(path As %String) As %Status
{
    Set f = ##class(%Stream.FileCharacter).%New()
    Set f.TranslateTable = "UTF8"
    Set sc = f.LinkToFile(path)
    If $$$ISERR(sc) { Quit sc }
    Do f.Write(..Text)
    Quit f.%Save()
}

}
