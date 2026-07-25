/// Ask the model which dimension to split on.
///
/// This is the behaviour the engine had before policies existed, expressed as one
/// policy among several. It exists so that swapping in `Greedy` is a change of
/// policy rather than a change of engine, and so the two can be compared on the
/// same store with the same budget.
///
/// The model's answer is a dimension name, checked against the candidate set
/// before it is used. That is a narrower surface than the slice paths the engine
/// used to accept: a dimension name has no structure to smuggle anything through,
/// and an unrecognised one is a decline rather than a refusal the run has to
/// recover from. Constitution II, tightened.
Class RLM.Policy.LLM Extends RLM.Policy
{

Property LLM As RLM.LLM;

Method %OnNew(llm As RLM.LLM) As %Status
{
    Set ..LLM = llm
    Quit $$$OK
}

Method ChooseSplit(
	source As RLM.Source,
	peek As %DynamicObject,
	candidates As %List,
	budget As RLM.Budget,
	path As %String = "") As RLM.Decision
{
    Set before = source.SplitMetric(peek)
    Set d = ##class(RLM.Decision).%New($ClassName(), before)

    If $ListLength(candidates) = 0 {
        Do d.Decline("no dimension was available to split on")
        Quit d
    }
    Set ptr = 0
    While $ListNext(candidates, ptr, dim) {
        Do d.AddCandidate(dim)
    }

    Set sc = budget.Charge(1)
    If $$$ISERR(sc) {
        Set d.Capped = 1
        Do d.Decline("no model call was affordable to choose a split: "
            _$System.Status.GetErrorText(sc))
        Quit d
    }

    Set desc = source.Describe(source.Name, peek)
    Set answer = ..LLM.Complete(..Instructions(), ..Prompt(desc, candidates), .lsc)
    If $$$ISERR(lsc) {
        Do d.Decline("the model call choosing a split failed: "
            _$System.Status.GetErrorText(lsc))
        Quit d
    }

    // First non-empty line, stripped. Anything more forgiving than this starts
    // parsing the model's prose, and parsing prose is how a validated choice
    // turns back into an authored input.
    Set named = ""
    For i = 1:1:$Length(answer, $Char(10)) {
        Set named = $ZStrip($Piece(answer, $Char(10), i), "<>WC")
        Quit:named'=""
    }

    If '$ListFind(candidates, named) {
        Do d.Decline("the model named '"_named_"', which is not a dimension this "
            _"store offers here; no split was made")
        Quit d
    }

    // No after-metric: this policy did not measure anything, and reporting the
    // parent's metric as the child's would make an unmeasured choice look scored.
    Do d.Choose(named, "", "the model chose '"_named_"' from "
        _$ListLength(candidates)_" candidate(s)")
    Quit d
}

Method Instructions() As %String
{
    Quit "You are choosing how to divide a data store you cannot see. You will "
        _"be shown aggregate statistics for the current slice and the complete "
        _"list of ways it may be divided. Reply with exactly one name from that "
        _"list and nothing else -- no numbering, no commentary, no explanation. "
        _"Choose the division most likely to separate what the question asks "
        _"about. If none of them would, reply with the single word: none."
}

Method Prompt(
	desc As %String,
	candidates As %List) As %String
{
    Set out = "This slice: "_desc_$Char(10)_$Char(10)_"Ways to divide it:"_$Char(10)
    Set ptr = 0
    While $ListNext(candidates, ptr, dim) { Set out = out_"  "_dim_$Char(10) }
    Quit out
}

}
