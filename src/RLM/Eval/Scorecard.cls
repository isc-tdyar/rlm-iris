/// Run the same question over the same store under several policies, and report
/// what each one cost and how well it divided.
///
/// This is the answer to the question SPEC §5 leaves open -- "does asking the model
/// how to split beat reading the statistics?" -- produced offline, from a scripted
/// provider, with no network. The comparison is only meaningful because
/// `RLM.Policy` is a seam: the engine computes the candidate set, so two policies
/// over one store are choosing from the same menu and their scores are about the
/// same population.
///
/// Every row is an ordinary `RLM.Engine.Run` with `DurableTrace` set. There is no
/// evaluation-only code path, which is what keeps a scorecard honest: the thing
/// measured is the thing a caller gets.
///
/// Cost and quality stay in separate columns and are never combined into a ranking.
/// A single number would have to weigh a call against a metric point, and nobody
/// has chosen those weights -- Constitution III applied to the evaluation output.
Class RLM.Eval.Scorecard Extends %RegisteredObject
{

/// Score each policy in `policies` on one store and one question.
///
/// `policies` is a `$LIST` of class names. A class taking an LLM in its
/// constructor gets one; a class that does not, does not. A row that could not be
/// scored carries `error` and no `objective` and does not take the card down with
/// it, because a caller comparing four policies must not lose three of them to one
/// typo.
ClassMethod Score(
	source As RLM.Source,
	question As %String,
	policies As %List,
	llm As RLM.LLM,
	maxDepth As %Integer = 1,
	callBudget As %Integer = 16) As %DynamicObject
{
    Set card = {"question": (question), "source": ($ClassName(source)),
        "maxDepth": (maxDepth), "rows": []}
    Set ptr = 0
    While $ListNext(policies, ptr, cls) {
        Do card.rows.%Push(..Row(source, question, cls, llm, maxDepth, callBudget))
    }
    Quit card
}

/// One policy's row. Never throws: a policy is the seam third-party code lives
/// on, so a broken one is this row's `error`.
ClassMethod Row(
	source As RLM.Source,
	question As %String,
	cls As %String,
	llm As RLM.LLM,
	maxDepth As %Integer,
	callBudget As %Integer) As %DynamicObject [ Private ]
{
    Set row = {"policy": (cls), "runId": "", "calls": 0, "peeks": 0, "slices": 0,
        "objective": "", "chose": "", "error": ""}
    Try {
        If '##class(%Dictionary.CompiledClass).%ExistsId(cls) {
            Set row.error = "'"_cls_"' is not a compiled class"
            Quit
        }
        Set policy = ..Instantiate(cls, llm)
        Set budget = ##class(RLM.Budget).%New(callBudget)
        Set engine = ##class(RLM.Engine).%New(source, llm, budget, policy)
        Set engine.DurableTrace = 1
        Set engine.MaxDepth = maxDepth
        Do engine.Run(question, .runId)

        Set row.runId = runId
        Set row.calls = budget.Used
        Set row.peeks = budget.PeeksUsed
        Set row.slices = ..Slices(runId)

        Set decisions = ##class(RLM.Trace).Decisions(runId, 1)
        If decisions.Count() > 0, decisions.GetAt(1).Chose() {
            Set row.chose = decisions.GetAt(1).Dimension
        }

        // FR-010. A run that lost a slice to a failed call or an exhausted budget
        // examined a different population than it set out to, and an objective
        // computed from what survived would sit in the table looking exactly like
        // one that had not.
        Set partial = ..Partial(runId)
        If partial '= "" {
            Set row.error = partial
            Quit
        }
        Set obj = ..Objective(source, runId, .oerr)
        If obj = "" {
            Set row.error = oerr
            Quit
        }
        Set row.objective = obj
    } Catch e {
        // Assigned rather than returned: `Quit <value>` is #1043 inside a Catch.
        Set row.error = $ZStrip(e.Name_" "_e.Data, "<>W")
    }
    Quit row
}

/// Build a policy, giving it the LLM only if it takes one.
///
/// Decided from the class's own definition rather than by catching a failed `%New`:
/// a policy whose constructor legitimately fails would otherwise be silently retried
/// without its provider and scored as if it had one.
ClassMethod Instantiate(
	cls As %String,
	llm As RLM.LLM) As RLM.Policy [ Private ]
{
    If ##class(%Dictionary.CompiledProperty).%ExistsId(cls_"||LLM") {
        Quit $ClassMethod(cls, "%New", llm)
    }
    Quit $ClassMethod(cls, "%New")
}

/// How many leaf slices the run examined.
///
/// `RLM.Trace.Count` is an instance method over a live trace object; a scorecard
/// has a run id and a global, which is the same reason `Decisions` and
/// `RenderTrace` are class methods.
ClassMethod Slices(runId As %Integer) As %Integer [ Private ]
{
    Set n = 0, seq = ""
    For  {
        Set seq = $Order(^RLM.Trace(runId, seq), 1, row)
        Quit:seq=""
        Quit:seq'?1.N
        If $List(row, 1) = "subcall" { Set n = n + 1 }
    }
    Quit n
}

/// Why this run cannot be scored, or "" if it can.
///
/// Reads the trace rather than the report text: a caveat is prose meant for a
/// reader, and matching on it would make the scorecard's correctness depend on the
/// wording of a sentence.
ClassMethod Partial(runId As %Integer) As %String [ Private ]
{
    Set why = "", seq = ""
    For  {
        Set seq = $Order(^RLM.Trace(runId, seq), 1, row)
        Quit:seq=""
        // Metadata subscripts collate after the numeric rows and hold plain
        // strings, so $List over one of them returns junk.
        Quit:seq'?1.N
        Set role = $List(row, 1), note = $List(row, 10)
        If role = "capped" {
            Set why = "the call budget ran out before a slice this run meant to "
                _"examine"
            Quit
        }
        If ((role = "subcall") || (role = "synthesis")), note '= "" {
            Set why = "a "_role_" call failed: "_note
            Quit
        }
    }
    Quit why
}

/// How mixed the run was left holding: the mean split metric of the leaf slices it
/// examined. Lower is better.
///
/// Read from the trace's own `subcall` rows, so the figure is the store's
/// measurement of the slices the run actually reached and not a re-derivation that
/// could disagree with them. Reads the store's class name and never the model.
///
/// "" with `reason` set when there is nothing to average. 0 is a legitimate
/// objective meaning "every leaf was one population", so an unscorable run must not
/// borrow it.
ClassMethod Objective(
	source As RLM.Source,
	runId As %Integer,
	Output reason As %String) As %Numeric
{
    Set reason = ""
    If '$Data(^RLM.Trace(runId)) {
        Set reason = "no durable trace exists for run "_runId
        Quit ""
    }
    Set want = $ClassName(source), sum = 0, n = 0, seq = ""
    For  {
        Set seq = $Order(^RLM.Trace(runId, seq), 1, row)
        Quit:seq=""
        Quit:seq'?1.N
        Set cls = $List(row, 3)
        If (cls '= ""), (cls '= want) {
            // Two stores are two populations. A mean over one store's slices
            // presented as a score for another is a plausible number about the
            // wrong thing, which is worse than a refusal.
            Set reason = "run "_runId_" was recorded against '"_cls
                _"', not '"_want_"'"
            // Argumentless: `Quit <value>` is not allowed inside a For.
            Quit
        }
        Continue:$List(row, 1)'="subcall"
        Set m = $List(row, 5)
        Continue:m=""
        Set sum = sum + m, n = n + 1
    }
    Quit:reason'="" ""
    If n = 0 {
        Set reason = "run "_runId_" examined no slice, so there is nothing to average"
        Quit ""
    }
    Quit sum / n
}

/// The card as a fixed-width table.
///
/// Deterministic byte for byte over an unchanged store, which SC-003 asserts by
/// comparing two renderings -- so the run ids, which differ between two scorings of
/// the same store, are on the data and not in the table.
ClassMethod Render(card As %DynamicObject) As %String
{
    Set out = ..Line("policy", "calls", "peeks", "slices", "objective", "chose",
        "note")
    Set out = out_$Char(10)_..Line($Translate($Justify("", 34), " ", "-"),
        "-----", "-----", "------", "---------", "----------", "----")
    For i = 0:1:card.rows.%Size() - 1 {
        Set r = card.rows.%Get(i)
        Set out = out_$Char(10)_..Line(r.policy, r.calls, r.peeks, r.slices,
            $Select(r.objective="":"--", 1:$FNumber(r.objective, "", 3)),
            $Select(r.chose="":"(declined)", 1:r.chose),
            $Select(r.error="":"", 1:r.error))
    }
    Quit out
}

/// One row, padded by hand.
///
/// $Justify has no left-aligning form -- its second argument is a width and its
/// third a decimal count, so $Justify(s, -10) returns s unchanged and the column
/// silently never appears.
ClassMethod Line(
	policy As %String,
	calls As %String,
	peeks As %String,
	slices As %String,
	objective As %String,
	chose As %String,
	note As %String) As %String [ Private ]
{
    Set out = ..Pad(policy, 34)_" "_$Justify(calls, 5)_" "_$Justify(peeks, 5)
        _" "_$Justify(slices, 6)_" "_$Justify(objective, 9)_"  "_..Pad(chose, 10)
    If note '= "" { Set out = out_"  "_note }
    Quit out
}

ClassMethod Pad(
	text As %String,
	width As %Integer) As %String [ Private ]
{
    If $Length(text) >= width { Quit text }
    Quit text_$Justify("", width - $Length(text))
}

}
