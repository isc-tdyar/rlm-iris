/// The recursion.
///
/// One run is three kinds of model call and nothing else:
///
///   plan       -- given the root peek and the menu of legal splits, name slices
///   subcall    -- given one slice's peek, say what is true of that slice
///   synthesis  -- given the sub-call notes, answer the question
///
/// The engine depends on RLM.Source, RLM.LLM, RLM.Budget, RLM.Trace and
/// RLM.Report. It contains no reference to %AI.*, no HTTP client and no SQL, so
/// the portable module compiles on an IRIS with no AI Hub. Swapping the AI Hub
/// provider in changes one constructor argument.
///
/// The model never authors a predicate and never receives store contents. It
/// names slices from an enumerated menu; RLM.Slice refuses anything else; and
/// what comes back is aggregates. That is what bounds the context by the number
/// of slices inspected rather than by the size of the store.
Class RLM.Engine Extends %RegisteredObject
{

Property Source As RLM.Source;

Property LLM As RLM.LLM;

Property Budget As RLM.Budget;

/// How the split is chosen. Defaults to RLM.Policy.LLM, which is the behaviour
/// the engine had before policies existed, so existing callers are unaffected.
Property Policy As RLM.Policy;

/// Write the trace to ^RLM.Trace rather than the process-private global.
Property DurableTrace As %Boolean [ InitialExpression = 0 ];

Method %OnNew(
	source As RLM.Source,
	llm As RLM.LLM,
	budget As RLM.Budget = "",
	policy As RLM.Policy = "") As %Status
{
    Set ..Source = source
    Set ..LLM = llm
    Set ..Budget = $Select($IsObject(budget):budget, 1:##class(RLM.Budget).%New())
    If $IsObject(policy) {
        Set ..Policy = policy
    } Else {
        Set ..Policy = ##class(RLM.Policy.LLM).%New(llm)
    }
    Quit $$$OK
}

/// Run one decomposition. Returns the report text; `traceId` identifies the
/// trace rows written for this run.
Method Run(
	question As %String,
	Output traceId As %Integer) As %String
{
    Set trace = ##class(RLM.Trace).%New(..DurableTrace)
    Set traceId = trace.RunId
    Set report = ##class(RLM.Report).%New()
    Set caveats = ""

    // Characterize the whole store first. This is the only unconditional peek:
    // without it the model has nothing to choose a split from.
    Set rootPeek = ..Source.Peek("")
    Set rootLabel = ..Source.Name
    Set rootDesc = ..Source.Describe(rootLabel, rootPeek)
    If ..Capped(rootPeek) {
        Set caveats = caveats_$ListBuild("The store-wide count stopped at a limit, so it is a floor and not a total.")
    }

    Do report.Heading("Question")
    Do report.Add(question)
    Do report.AddBlank()
    Do report.Heading("Store")
    Do report.Add(rootDesc)

    // --- how to divide it ---
    // The engine decides which dimensions are *eligible*; the policy decides
    // which of them to use. Eligibility is computed here rather than in the
    // policy because a policy deriving its own candidate set could derive a
    // different one, and then two policies over the same store are not
    // comparable -- which is the whole reason the seam exists.
    Set candidates = ..Candidates("")
    Set decision = ..Policy.ChooseSplit(..Source, rootPeek, candidates, ..Budget)
    Do trace.AddDecision(decision, 0, $ClassName(..Source), "")
    If decision.Capped {
        Set caveats = caveats_$ListBuild("The split decision was limited by a cap, so it rests on partial evidence.")
    }
    If 'decision.Chose() {
        Set caveats = caveats_$ListBuild("Not decomposed: "_decision.Reason_".")
    }

    Set plan = ..Expand(decision)

    // --- sub-calls ---
    Set notes = "", asked = 0, refused = 0, wanted = 0
    Set nlines = $Length(plan, $Char(10))
    For i = 1:1:nlines {
        Set path = $ZStrip($Piece(plan, $Char(10), i), "<>WC")
        Continue:path=""
        Set wanted = wanted + 1

        Set rsc = ##class(RLM.Slice).Resolve(..Source, path, .predicate, .label)
        If $$$ISERR(rsc) {
            Set refused = refused + 1
            Do trace.Add("refused", 1, path, $ClassName(..Source), , , , ..LLM.Model, 0,
                $System.Status.GetErrorText(rsc))
            Continue
        }

        If '..Budget.CanSpend(1) {
            Do trace.Add("capped", 1, path, $ClassName(..Source), , , , ..LLM.Model, 1,
                "budget exhausted before this slice")
            Continue
        }

        Set peek = ..Source.Peek(predicate)
        If ..Capped(peek) {
            Set caveats = caveats_$ListBuild("The count for '"_label_"' stopped at a limit, so it is a floor.")
        }
        Set desc = ..Source.Describe(label, peek)
        Set metric = ..Source.SplitMetric(peek)

        Set note = ..Ask("subcall", ..SubcallInstructions(),
            ..SubcallPrompt(question, desc), trace, 1, path, .ssc, metric)
        Set asked = asked + 1
        If $$$ISERR(ssc) {
            Set caveats = caveats_$ListBuild("The sub-call for '"_label_"' failed; that slice is described by its statistics only.")
            Set note = "(no analysis: sub-call failed)"
        }
        Set notes = notes_$ListBuild(label_" ["_desc_"] "_note)
    }

    Do report.AddBlank()
    Do report.Heading("Slices examined")
    If $ListLength(notes) = 0 {
        Do report.Add("(none)")
    } Else {
        Set ptr = 0
        While $ListNext(notes, ptr, n) { Do report.Add("- "_n) }
    }

    // --- synthesis ---
    // Always runs. A decomposition that explores and then has nothing left to
    // answer with is worse than a coarse answer, which is why the budget holds a
    // slot back for exactly this call.
    Set answer = ..Synthesize(question, rootDesc, notes, trace)

    Do report.AddBlank()
    Do report.Heading("Answer")
    Do report.Add(answer)

    // Disclosure. Every one of these is a case where the report would otherwise
    // read as more complete than it is.
    If refused > 0 {
        Set caveats = caveats_$ListBuild(refused_" requested slice(s) were refused as not offered by this store, and were not examined.")
    }
    If (wanted - refused) > asked {
        Set caveats = caveats_$ListBuild(((wanted - refused) - asked)_" slice(s) were dropped because the call budget ran out before them.")
    }
    Set caveats = caveats_$ListBuild("Spent "_..Budget.Describe()_".")
    Do report.Caveats(caveats)

    Quit report.Text
}

/// Dimensions eligible for splitting the slice at `path`.
///
/// A dimension qualifies when the store declares it, it is not already used on
/// this path (splitting twice on one dimension narrows nothing), and it has at
/// least two children (FR-011: one child yields a slice identical to its parent).
Method Candidates(path As %String = "") As %List
{
    Set out = ""
    Set dims = ..Source.Dimensions()
    If '$IsObject(dims) { Quit "" }

    Set used = ""
    For i = 1:1:$Length(path, "/") {
        Set comp = $Piece(path, "/", i)
        Continue:comp=""
        Set used = used_$ListBuild($Piece(comp, ":", 1))
    }

    Set it = dims.%GetIterator()
    While it.%GetNext(.dim, .spec) {
        Continue:$ListFind(used, dim)
        Continue:'$IsObject(spec)
        Continue:'$IsObject(spec.children)
        Continue:spec.children.%Size()<2
        Set out = out_$ListBuild(dim)
    }
    Quit out
}

/// Turn a chosen dimension into one slice name per child.
///
/// This is the step the model used to perform by naming slices, and moving it
/// here is what separates "how should this be divided" from "which pieces are
/// worth looking at". The names are generated from the store's own children, so
/// every one of them resolves by construction.
Method Expand(decision As RLM.Decision) As %String
{
    If 'decision.Chose() { Quit "" }
    Set kids = ##class(RLM.Policy).Children(..Source, decision.Dimension, .sc)
    If $$$ISERR(sc) { Quit "" }
    Set out = "", ptr = 0
    While $ListNext(kids, ptr, token) {
        Set out = out_$Select(out="":"", 1:$Char(10))_decision.Dimension_":"_token
    }
    Quit out
}

/// One model call, charged and traced. Returns "" on failure with `sc` set --
/// the caller decides whether that ends the run.
Method Ask(
	role As %String,
	instructions As %String,
	prompt As %String,
	trace As RLM.Trace,
	depth As %Integer,
	sliceKey As %String,
	Output sc As %Status,
	metric As %Numeric = "") As %String
{
    Set sc = ..Budget.Charge(1)
    If $$$ISERR(sc) { Quit "" }
    Set out = ..LLM.Complete(instructions, prompt, .sc)
    Do trace.Add(role, depth, sliceKey, $ClassName(..Source), metric,
        $Length(prompt), $Length(out), ..LLM.Model, 0,
        $Select($$$ISERR(sc):$System.Status.GetErrorText(sc), 1:""))
    Quit out
}

/// The terminal call, drawing on the reserved slot.
Method Synthesize(
	question As %String,
	rootDesc As %String,
	notes As %List,
	trace As RLM.Trace) As %String
{
    Set sc = ..Budget.ChargeSynthesis()
    If $$$ISERR(sc) { Quit "(no answer: the call budget was exhausted before synthesis)" }

    Set body = "Question: "_question_$Char(10)_"Whole store: "_rootDesc_$Char(10)
    If $ListLength(notes) = 0 {
        Set body = body_$Char(10)_"No slices were examined."
    } Else {
        Set body = body_$Char(10)_"Slice findings:"_$Char(10)
        Set ptr = 0
        While $ListNext(notes, ptr, n) { Set body = body_"- "_n_$Char(10) }
    }
    Set out = ..LLM.Complete(..SynthesisInstructions(), body, .ssc)
    Do trace.Add("synthesis", 0, "", $ClassName(..Source), , $Length(body),
        $Length(out), ..LLM.Model, 0,
        $Select($$$ISERR(ssc):$System.Status.GetErrorText(ssc), 1:""))
    If $$$ISERR(ssc) { Quit "(no answer: "_$System.Status.GetErrorText(ssc)_")" }
    Quit out
}

/// Whether a peek reported a truncated count. A store that forgets to set this
/// is treated as not capped, so the property is the store's to get right.
ClassMethod Capped(peek As %DynamicObject) As %Boolean
{
    If '$IsObject(peek) { Quit 0 }
    Quit ''peek.capped
}

Method PlanInstructions() As %String
{
    Quit "You are planning how to decompose a data store you cannot see. "
        _"You will be shown aggregate statistics for the whole store and the "
        _"complete list of ways it may be split. Reply with one slice name per "
        _"line and nothing else -- no numbering, no commentary. Name only "
        _"slices from the list; anything else will be refused and wasted. "
        _"Name fewer slices if fewer will answer the question."
}

Method PlanPrompt(
	question As %String,
	rootDesc As %String) As %String
{
    Quit "Question: "_question_$Char(10)_$Char(10)
        _"Whole store: "_rootDesc_$Char(10)_$Char(10)
        _##class(RLM.Slice).Menu(..Source)
}

Method SubcallInstructions() As %String
{
    Quit "You are describing one slice of a data store from its aggregate "
        _"statistics alone. Quote figures under the exact names you were given "
        _"them under. State what the statistics support and nothing further. "
        _"Two or three sentences."
}

Method SubcallPrompt(
	question As %String,
	desc As %String) As %String
{
    Quit "Question: "_question_$Char(10)_$Char(10)_"This slice: "_desc
}

Method SynthesisInstructions() As %String
{
    Quit "Answer the question from the slice findings below. Every claim must "
        _"be traceable to a figure you were given. If the findings do not "
        _"support an answer, say which slice would settle it rather than "
        _"guessing."
}

}
