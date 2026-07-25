/// Tests for the SQL table source.
///
/// The point of these is that the aggregates come back from IRIS over rows that
/// are never copied anywhere. A peek is a GROUP BY, so a ten-row table and a
/// ten-billion-row table cost the model the same number of tokens -- and that is
/// the claim the whole package rests on.
Class UnitTest.RLM.SourceTable Extends %UnitTest.TestCase
{

Property Source As RLM.Source;

Method OnBeforeAllTests() As %Status
{
    Quit ##class(UnitTest.RLM.Widget).Populate()
}

Method OnBeforeOneTest(testname As %String) As %Status
{
    Set ..Source = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
    Do ..Source.AddDimension("colour", "Colour")
    Do ..Source.AddDimension("size", "Size")
    Quit $$$OK
}

/// Children are discovered from the data, not declared. A hand-written token
/// list drifts from the table the moment a new value is inserted, and the model
/// is then refused for naming a slice that does exist.
Method TestDimensionChildrenComeFromTheData()
{
    Set dims = ..Source.Dimensions()
    Set tokens = ""
    Set kids = dims.%Get("colour").children.%GetIterator()
    While kids.%GetNext(, .child) {
        Set tokens = tokens_$Select(tokens="":"", 1:",")_child.token
    }
    Do $$$AssertEquals(tokens, "blue,red", "both colours discovered, ordered")
}

Method TestRootPeekCountsEveryRow()
{
    Set peek = ..Source.Peek("")
    Do $$$AssertEquals(peek.n, 10, "all ten widgets")
    Do $$$AssertEquals(peek.capped, 0, "not capped")
}

Method TestSlicePeekAggregatesOnlyThatSlice()
{
    Do ##class(RLM.Slice).Resolve(..Source, "colour:red", .pred, .label)
    Set peek = ..Source.Peek(pred)
    Do $$$AssertEquals(peek.n, 6, "six red widgets")
    Do $$$AssertEquals(peek.min, 9, "min price")
    Do $$$AssertEquals(peek.max, 12, "max price")
}

Method TestNestedSliceNarrowsFurther()
{
    Do ##class(RLM.Slice).Resolve(..Source, "colour:red/size:small", .pred, .label)
    Set peek = ..Source.Peek(pred)
    Do $$$AssertEquals(peek.n, 3, "three small red widgets")
}

/// A dimension that separates the measure must score better than one that does
/// not, or a greedy policy has nothing to be greedy about.
Method TestSplitMetricRanksTheSeparatingDimension()
{
    Set root = ..Source.SplitMetric(..Source.Peek(""))
    Do ##class(RLM.Slice).Resolve(..Source, "colour:red", .redPred)
    Do ##class(RLM.Slice).Resolve(..Source, "size:small", .smallPred)
    Set red = ..Source.SplitMetric(..Source.Peek(redPred))
    Set small = ..Source.SplitMetric(..Source.Peek(smallPred))

    Do $$$AssertTrue(red < root, "splitting on colour tightens the slice")
    Do $$$AssertTrue(red < small, "colour beats size")
}

/// The invariant from RLM.Source: no rows, ever. If a description carries row
/// values the context bound is gone.
Method TestDescribeEmitsAggregatesNotRows()
{
    Do ##class(RLM.Slice).Resolve(..Source, "colour:blue", .pred, .label)
    Set desc = ..Source.Describe(label, ..Source.Peek(pred))
    Do $$$AssertNotEquals($Find(desc, "n=4"), 0, "count is present")
    Set leak = $Find(desc, "|")
    Do $$$AssertEquals(leak, 0, "no row payload")
}

/// A capped peek must say so. A truncated count the model reads as a total
/// poisons every claim downstream of it.
Method TestVisitCapIsReportedNotHidden()
{
    Set capped = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
    Do capped.AddDimension("colour", "Colour")
    Set capped.MaxRows = 4
    Set peek = capped.Peek("")
    Do $$$AssertEquals(peek.capped, 1, "cap reported")
    Set desc = capped.Describe("all", peek)
    Do $$$AssertNotEquals($Find(desc, "at least"), 0, "and worded as a floor")
}

/// The class name is not model-supplied, but it is still interpolated into SQL,
/// so a bad one must fail at construction rather than at query time.
Method TestRefusesAnUnknownClass()
{
    Set bad = ##class(RLM.Source.Table).%New("No.Such.Class", "Price")
    Set peek = bad.Peek("")
    Do $$$AssertNotEquals(peek.error, "", "unknown table reports an error, not a count")
}

/// A dimension naming a property the table does not have would produce broken
/// SQL on every peek, so it is refused when declared.
Method TestRefusesAnUnknownProperty()
{
    Set sc = ..Source.AddDimension("nope", "NoSuchProperty")
    Do $$$AssertStatusNotOK(sc, "unknown property refused at declaration")
}

}
