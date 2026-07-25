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

/// Deterministic population: Colour separates Price sharply; Size and Weight
/// both leave a spread as wide as the whole store. Same shape as the fixture,
/// so a test can compare a Table run against a Fixture run and expect the same
/// decomposition to be chosen.
ClassMethod Populate() As %Status
{
    Do ..%KillExtent()
    Set rows = $ListBuild(
        "red|small|10|light", "red|small|11|heavy", "red|large|12|light",
        "red|large|9|heavy", "red|small|10|light", "red|large|11|heavy",
        "blue|small|100|light", "blue|large|104|heavy",
        "blue|small|96|light", "blue|large|100|heavy")
    Set ptr = 0
    While $ListNext(rows, ptr, row) {
        Set w = ..%New()
        Set w.Colour = $Piece(row, "|", 1)
        Set w.Size = $Piece(row, "|", 2)
        Set w.Price = $Piece(row, "|", 3)
        Set w.Weight = $Piece(row, "|", 4)
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
</Data>
<DataLocation>^UnitTest.RLM.WidgetD</DataLocation>
<DefaultData>WidgetDefaultData</DefaultData>
<IdLocation>^UnitTest.RLM.WidgetD</IdLocation>
<IndexLocation>^UnitTest.RLM.WidgetI</IndexLocation>
<StreamLocation>^UnitTest.RLM.WidgetS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
