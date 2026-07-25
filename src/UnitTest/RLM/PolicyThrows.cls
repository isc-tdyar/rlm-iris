/// A policy that throws instead of deciding.
///
/// Obligation 7 on RLM.Policy is "never throw", and this class exists because that
/// obligation is on the implementation and therefore not enforceable. A policy is
/// the most likely of the three to be third-party code -- it is the seam the
/// package invites people to write against -- so the engine has to survive one
/// that breaks its contract.
Class UnitTest.RLM.PolicyThrows Extends RLM.Policy
{

Method ChooseSplit(
	source As RLM.Source,
	peek As %DynamicObject,
	candidates As %List,
	budget As RLM.Budget,
	path As %String = "") As RLM.Decision
{
    Throw ##class(%Exception.General).%New("PolicyThrows", 5001, ,
        "the policy divided by zero scoring '"_path_"'")
}

}
