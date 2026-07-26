/// A minimal concrete RLM.Source.Extent, so the abstract base's SQL plumbing can be
/// tested without either real source.
///
/// The probe methods exist because what is being asserted is internal by design:
/// `Where`, `Distribution`, `SQLTable` and the row count are private to the base
/// because a caller has no business assembling a WHERE clause. Testing them through
/// a peek instead would mean a failure in the encoder and a failure in the peek look
/// the same, and the whole reason the decoder is shared is that two of them would
/// disagree about which rows a predicate names.
///
/// The peek and the metric are the two things Extent deliberately does not define,
/// so this class gives the thinnest ones that satisfy the contract.
Class UnitTest.RLM.ExtentProbe Extends RLM.Source.Extent
{

Method Peek(predicate As %String = "") As %DynamicObject
{
    Set n = ..CountProbe(predicate, .capped)
    Quit {"n": (n), "capped": (capped)}
}

Method Describe(
	label As %String,
	peek As %DynamicObject) As %String
{
    Quit label_": n="_$Select(peek.capped:"at least "_peek.n, 1:peek.n)
}

Method SplitMetric(peek As %DynamicObject) As %Numeric
{
    Quit 0
}

Method WhereProbe(
	predicate As %String,
	Output args As %List) As %String
{
    Quit ..Where(predicate, .args)
}

Method DistributionProbe(
	predicate As %String,
	columns As %List,
	topK As %Integer,
	Output total As %Integer) As %DynamicArray
{
    Quit ..Distribution(predicate, columns, topK, .total)
}

Method SQLTableProbe() As %String
{
    Quit ..SQLTable()
}

Method CountProbe(
	predicate As %String = "",
	Output capped As %Boolean) As %Integer
{
    Quit ..Count(predicate, .capped)
}

}
