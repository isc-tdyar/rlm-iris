/// A real SQL table for the Table source tests.
///
/// The Fixture source proves the grammar; this proves the contract holds over an
/// actual store, where counts come from the engine that owns the rows rather
/// than from a literal list.
Class UnitTest.RLM.Widget Extends %Persistent
{

Property Colour As %String;

Property Size As %String;

Property Price As %Numeric;

/// A third dimension that separates nothing. Two non-separating dimensions
/// rather than one, so a policy that ranks candidates is distinguishable from
/// one that merely rejects the last place-getter.
Property Weight As %String;

/// A continuous column with holes in it, for the bucketed dimension.
///
/// Nullable on purpose: a bucket set covers the values it was given breakpoints
/// for and nothing else, so the children of a bucketed dimension do not sum to
/// their parent. That gap is the thing the engine has to disclose, and a column
/// with no nulls in it cannot test the disclosure.
Property Rating As %Numeric;

/// Deterministic population: Colour separates Price sharply; Size and Weight
/// both leave a spread as wide as the whole store. Same shape as the fixture,
/// so a test can compare a Table run against a Fixture run and expect the same
/// decomposition to be chosen.
///
/// Rating is laid out against breakpoints 3 and 7: two rows below 3, two in
/// [3,7), four at or above 7, two null. Two of the values sit exactly on a
/// breakpoint, which is where a half-open boundary is decided one way or the
/// other.
ClassMethod Populate() As %Status
{
    Do ..%KillExtent()
    Set rows = $ListBuild(
        "red|small|10|light|1", "red|small|11|heavy|3", "red|large|12|light|5",
        "red|large|9|heavy|7", "red|small|10|light|", "red|large|11|heavy|9",
        "blue|small|100|light|2", "blue|large|104|heavy|",
        "blue|small|96|light|7", "blue|large|100|heavy|8")
    Set ptr = 0
    While $ListNext(rows, ptr, row) {
        Set w = ..%New()
        Set w.Colour = $Piece(row, "|", 1)
        Set w.Size = $Piece(row, "|", 2)
        Set w.Price = $Piece(row, "|", 3)
        Set w.Weight = $Piece(row, "|", 4)
        Set w.Rating = $Piece(row, "|", 5)
        Set sc = w.%Save()
        If $$$ISERR(sc) { Quit }
    }
    Quit $Get(sc, $$$OK)
}

Storage Default
{
<Data name="WidgetDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>Colour</Value>
</Value>
<Value name="3">
<Value>Size</Value>
</Value>
<Value name="4">
<Value>Price</Value>
</Value>
<Value name="5">
<Value>Weight</Value>
</Value>
<Value name="6">
<Value>Rating</Value>
</Value>
</Data>
<DataLocation>^UnitTest.RLM.WidgetD</DataLocation>
<DefaultData>WidgetDefaultData</DefaultData>
<IdLocation>^UnitTest.RLM.WidgetD</IdLocation>
<IndexLocation>^UnitTest.RLM.WidgetI</IndexLocation>
<StreamLocation>^UnitTest.RLM.WidgetS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
