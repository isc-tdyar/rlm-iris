/// One policy invocation, in full: what was chosen, what else was considered, and
/// on what evidence.
///
/// This is a class rather than a handful of output parameters because three
/// readers consume it -- the engine acts on the chosen dimension, the trace
/// records the whole thing, and the report discloses the caps -- and a decision
/// that reaches only one of them is a decision that cannot be evaluated later.
///
/// Reason is never empty, including on success. A record that explains only its
/// failures has to be reverse-engineered on every other read.
Class RLM.Decision Extends %RegisteredObject
{

/// The dimension to split on, or "" for a declined split.
Property Dimension As %String;

/// Why this dimension won, or why nothing did. Always populated.
Property Reason As %String;

/// Split metric of the slice being divided.
Property MetricBefore As %Numeric;

/// Score of the chosen dimension, "" when declined.
Property MetricAfter As %Numeric;

/// Which policy decided. Two runs differing only in policy are not comparable,
/// so the comparison has to be able to notice.
Property PolicyClass As %String;

/// Peeks consumed reaching this decision.
Property PeeksSpent As %Integer [ InitialExpression = 0 ];

/// 1 if a cap limited what was evaluated.
Property Capped As %Boolean [ InitialExpression = 0 ];

/// Every dimension considered, in declaration order.
Property Candidates As list Of RLM.Decision.Candidate;

Method %OnNew(policyClass As %String = "", metricBefore As %Numeric = "") As %Status
{
    Set ..PolicyClass = policyClass
    Set ..MetricBefore = metricBefore
    Quit $$$OK
}

/// Record a chosen dimension.
Method Choose(
	dimension As %String,
	metricAfter As %Numeric,
	reason As %String)
{
    Set ..Dimension = dimension
    Set ..MetricAfter = metricAfter
    Set ..Reason = reason
}

/// Record that nothing was worth splitting on. The reason is mandatory: a
/// decline with no explanation is indistinguishable from a policy that crashed.
Method Decline(reason As %String)
{
    Set ..Dimension = ""
    Set ..MetricAfter = ""
    Set ..Reason = reason
}

Method Chose() As %Boolean
{
    Quit ..Dimension '= ""
}

/// Append a candidate and hand it back, so the caller can fill in child metrics
/// or an error without looking it up again.
Method AddCandidate(
	dimension As %String,
	score As %Numeric = "",
	children As %Integer = 0,
	sampled As %Integer = 0) As RLM.Decision.Candidate
{
    Set c = ##class(RLM.Decision.Candidate).%New()
    Set c.Dimension = dimension
    Set c.Score = score
    Set c.Children = children
    Set c.Sampled = sampled
    Do ..Candidates.Insert(c)
    Quit c
}

}
