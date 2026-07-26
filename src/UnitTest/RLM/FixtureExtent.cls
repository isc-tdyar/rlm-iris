/// A persistent class with a known row distribution, for the RLM.Source.Extent
/// tests.
///
/// A real table rather than a declarative fixture, because what Extent does is
/// write SQL: the dimension declaration reads the dictionary, the predicate becomes
/// a WHERE clause, and the peek is a GROUP BY. A fixture that answered from a class
/// method would exercise none of that and would pass with the SQL broken.
///
/// Every expectation is a class method returning a number worked out by hand. A
/// fixture that computed its own expectations would agree with any bug in the code
/// under test.
///
/// The planted distribution, 12 rows:
///
/// ```text
/// region  channel  amount
/// ------  -------  ------
/// north   web      10
/// north   web      20
/// north   web      30
/// north   store    40
/// north   <null>   50
/// south   web      60
/// south   store    70
/// south   store    80
/// east    web      90
/// east    web      100
/// east    store    110
/// east    <null>   120
/// ```
///
/// Chosen so that: `region` has three children of sizes 5, 3, 4 (uneven, so a
/// metric returning a constant fails); `channel` has two non-null values plus two
/// null rows, so a child sum over it misses its parent by exactly 2 and NullCount
/// is what closes the gap; and `amount` is strictly increasing, so a min/max/mean
/// assertion cannot pass by coincidence.
Class UnitTest.RLM.FixtureExtent Extends %Persistent
{

Property Region As %String;

Property Channel As %String;

Property Amount As %Integer;

/// A marker string in a column no source may read, so a leak test has something to
/// look for.
Property Secret As %String;

/// Total rows.
ClassMethod Total() As %Integer
{
    Quit 12
}

/// Rows whose Channel is null, and which therefore appear in none of `channel`'s
/// children.
ClassMethod ChannelNulls() As %Integer
{
    Quit 2
}

/// `region`'s children, as `token|n`.
ClassMethod RegionChildren() As %List
{
    Quit $ListBuild("north|5", "south|3", "east|4")
}

/// The marker planted in Secret.
ClassMethod Marker() As %String
{
    Quit "SECRET-EXTENT-7f3a"
}

/// Delete every row and plant the distribution above.
ClassMethod Build() As %Status
{
    Do ..Wipe()
    Set rows = $ListBuild(
        "north|web|10", "north|web|20", "north|web|30",
        "north|store|40", "north||50",
        "south|web|60", "south|store|70", "south|store|80",
        "east|web|90", "east|web|100", "east|store|110", "east||120")
    Set ptr = 0
    While $ListNext(rows, ptr, row) {
        Set r = ..%New()
        Set r.Region = $Piece(row, "|", 1)
        // "" rather than a literal null keyword: an empty %String property stores
        // as null in SQL, which is the case NullCount exists for.
        Set r.Channel = $Piece(row, "|", 2)
        Set r.Amount = $Piece(row, "|", 3)
        Set r.Secret = ..Marker()
        Set sc = r.%Save()
        If $$$ISERR(sc) { Quit }
    }
    Quit $Get(sc, $$$OK)
}

ClassMethod Wipe()
{
    Do ..%KillExtent()
}

Storage Default
{
<Data name="FixtureExtentDefaultData">
<Value name="1">
<Value>%%CLASSNAME</Value>
</Value>
<Value name="2">
<Value>Region</Value>
</Value>
<Value name="3">
<Value>Channel</Value>
</Value>
<Value name="4">
<Value>Amount</Value>
</Value>
<Value name="5">
<Value>Secret</Value>
</Value>
</Data>
<DataLocation>^UnitTest.RLM.FixtureE9D9D</DataLocation>
<DefaultData>FixtureExtentDefaultData</DefaultData>
<IdLocation>^UnitTest.RLM.FixtureE9D9D</IdLocation>
<IndexLocation>^UnitTest.RLM.FixtureE9D9I</IndexLocation>
<StreamLocation>^UnitTest.RLM.FixtureE9D9S</StreamLocation>
<Type>%Storage.Persistent</Type>
}

}
