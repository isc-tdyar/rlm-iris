/// Call accounting for one decomposition, with a slot reserved for synthesis.
///
/// A run that spends its final call on one more peek has no calls left to write
/// an answer with, and a report that stops mid-decomposition is worse than a
/// coarser report that finishes. So exploration is charged against Total-1 and
/// only ChargeSynthesis may draw on the last slot.
Class RLM.Budget Extends %RegisteredObject
{

/// Total model calls this run may make, synthesis included.
Property Total As %Integer [ InitialExpression = 8 ];

/// Calls made so far.
Property Used As %Integer [ InitialExpression = 0 ];

/// Calls held back for the terminal synthesis step.
Property Reserved As %Integer [ InitialExpression = 1 ];

Method %OnNew(
	total As %Integer = 8,
	reserved As %Integer = 1) As %Status
{
    Set ..Total = total
    Set ..Reserved = reserved
    Quit $$$OK
}

/// Exploration calls still affordable, never below zero.
Method Remaining() As %Integer
{
    Quit $Select(..Total - ..Reserved - ..Used < 0:0, 1:..Total - ..Reserved - ..Used)
}

/// Whether `n` exploration calls are affordable. Asking costs nothing, which is
/// what lets a policy size a batch before committing to it.
Method CanSpend(n As %Integer = 1) As %Boolean
{
    Quit ..Remaining() >= n
}

/// Charge `n` exploration calls. Refused as a unit: a partially-funded batch
/// leaves the caller deciding which of its slices to drop, and that decision
/// belongs to the policy, not to the accountant.
Method Charge(n As %Integer = 1) As %Status
{
    If 'n { Quit $$$OK }
    If '..CanSpend(n) {
        Set msg = "call budget exhausted: "_..Used_" of "_..Total_" used, "
            _..Reserved_" reserved for synthesis"
        Quit $$$ERROR($$$GeneralError, msg)
    }
    Set ..Used = ..Used + n
    Quit $$$OK
}

/// Charge the terminal synthesis call, which may use the reserve.
Method ChargeSynthesis() As %Status
{
    If ..Used >= ..Total {
        Quit $$$ERROR($$$GeneralError, "call budget fully spent: "_..Used_" of "_..Total)
    }
    Set ..Used = ..Used + 1
    Quit $$$OK
}

/// One line for the report, so a reader can tell a budget-limited decomposition
/// from a complete one. An exhausted budget that goes unmentioned reads as
/// "this is all there was to find".
Method Describe() As %String
{
    Quit ..Used_"/"_..Total_" model calls"
}

}
