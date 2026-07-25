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

/// Deterministic population: Colour separates Price sharply, Size does not.
/// Same shape as the fixture, so a test can compare a Table run against a
/// Fixture run and expect the same decomposition to be chosen.
ClassMethod Populate() As %Status
{
    Do ..%KillExtent()
    Set rows = $ListBuild(
        "red|small|10", "red|small|11", "red|large|12", "red|large|9",
        "red|small|10", "red|large|11",
        "blue|small|100", "blue|large|104", "blue|small|96", "blue|large|100")
    Set ptr = 0
    While $ListNext(rows, ptr, row) {
        Set w = ..%New()
        Set w.Colour = $Piece(row, "|", 1)
        Set w.Size = $Piece(row, "|", 2)
        Set w.Price = $Piece(row, "|", 3)
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
</Data>
<DataLocation>^UnitTest.RLM.WidgetD</DataLocation>
<DefaultData>WidgetDefaultData</DefaultData>
<IdLocation>^UnitTest.RLM.WidgetD</IdLocation>
<IndexLocation>^UnitTest.RLM.WidgetI</IndexLocation>
<StreamLocation>^UnitTest.RLM.WidgetS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
