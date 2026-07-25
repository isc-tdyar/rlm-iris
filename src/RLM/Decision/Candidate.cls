/// One dimension a policy considered, and the evidence it considered it on.
///
/// Sampled and Children are stored separately rather than as one "partial" flag,
/// because an evaluator needs to know how partial: 8 of 10 children and 8 of 400
/// warrant different confidence in the same score.
Class RLM.Decision.Candidate Extends %RegisteredObject
{

Property Dimension As %String;

/// Size-weighted mean of the evaluated children's metrics, "" if unavailable.
Property Score As %Numeric;

/// `token:n:metric` per evaluated child, in declaration order.
///
/// The raw figures are kept because any single scalar loses the shape of the
/// split, and "did this isolate an outlier or halve the population?" is not
/// answerable from the summary.
Property ChildMetrics As %List;

/// Children the dimension has.
Property Children As %Integer [ InitialExpression = 0 ];

/// Children actually evaluated.
Property Sampled As %Integer [ InitialExpression = 0 ];

/// Why this candidate was unavailable, "" if it was fine.
Property Error As %String;

/// True when the score rests on fewer than all the children.
Method Partial() As %Boolean
{
    Quit ..Sampled < ..Children
}

}
