/// A table whose SQL names are not its ObjectScript names.
///
/// UnitTest.RLM.Widget is the easy case: every property is spelled in SQL exactly
/// as it is in the class, and the schema falls out of the package name. A table
/// created by DDL -- which is how every store this library is pointed at in
/// practice arrives -- is the hard case: `reject_fraction` is the column and
/// `rejectfraction` is the property, and the two are not interchangeable in either
/// direction. A source declared with the column name fails property validation; one
/// declared with the property name compiles and then produces SQL naming a column
/// that does not exist.
///
/// So the fixture is deliberately hostile in both places at once: an overridden
/// SqlTableName that does not match the class name, and a SqlFieldName per property
/// that does not match the property.
Class UnitTest.RLM.WidgetSql Extends %Persistent [ SqlTableName = widget_sql ]
{

Property Colour As %String [ SqlFieldName = colour_name ];

Property Price As %Numeric [ SqlFieldName = unit_price ];

/// Nullable, for the same reason Widget.Rating is: the rows in no bucket are what
/// the null disclosure exists to count.
Property Rating As %Numeric [ SqlFieldName = rating_score ];

/// The same population as Widget, so a test may compare the two sources and
/// expect identical numbers -- which is the whole claim: SQL naming is a
/// transport detail and must not change a single count.
ClassMethod Populate() As %Status
{
    Do ..%KillExtent()
    Set rows = $ListBuild(
        "red|10|1", "red|11|3", "red|12|5", "red|9|7", "red|10|", "red|11|9",
        "blue|100|2", "blue|104|", "blue|96|7", "blue|100|8")
    Set ptr = 0
    While $ListNext(rows, ptr, row) {
        Set w = ..%New()
        Set w.Colour = $Piece(row, "|", 1)
        Set w.Price = $Piece(row, "|", 2)
        Set w.Rating = $Piece(row, "|", 3)
        Set sc = w.%Save()
        If $$$ISERR(sc) { Quit }
    }
    Quit $Get(sc, $$$OK)
}

Storage Default
{
<Data name="WidgetSqlDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>Colour</Value>
</Value>
<Value name="3">
<Value>Price</Value>
</Value>
<Value name="4">
<Value>Rating</Value>
</Value>
</Data>
<DataLocation>^UnitTest.RLM.WidgetSqlD</DataLocation>
<DefaultData>WidgetSqlDefaultData</DefaultData>
<IdLocation>^UnitTest.RLM.WidgetSqlD</IdLocation>
<IndexLocation>^UnitTest.RLM.WidgetSqlI</IndexLocation>
<StreamLocation>^UnitTest.RLM.WidgetSqlS</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
