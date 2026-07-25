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
    Do ..Add(text)
    Quit ..Add($Translate($Justify("", $Length(text)), " ", "-"))
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
