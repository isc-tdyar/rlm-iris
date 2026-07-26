/// The recursion.
///
/// One run is three kinds of model call and nothing else:
///
///   decision   -- given a slice's peek and the menu of legal splits, name one
///                 dimension (or, under RLM.Policy.Greedy, no call at all)
///   subcall    -- given one slice's peek, say what is true of that slice
///   synthesis  -- given the sub-call notes, answer the question
///
/// The engine depends on RLM.Source, RLM.LLM, RLM.Budget, RLM.Trace and
/// RLM.Report. It contains no reference to %AI.*, no HTTP client and no SQL, so
/// the portable module compiles on an IRIS with no AI Hub. Swapping the AI Hub
/// provider in changes one constructor argument.
///
/// The model never authors a predicate and never receives store contents. It names
/// a dimension from an enumerated menu; the engine expands that dimension into one
/// slice per child from the store's own children, so every name resolves by
/// construction; and what comes back is aggregates. That is what bounds the context
/// by the number of slices inspected rather than by the size of the store.
///
/// ## The frontier
///
/// Traversal is depth-first pre-order over an explicit stack of `(path, depth)`
/// pairs, children pushed in reverse declaration order so they pop in it.
///
/// A stack rather than a recursive `Descend()` because `Run` holds the report, the
/// trace, the budget, the caveats and the notes. Recursion would need all five
/// threaded through a signature or promoted to properties, and promoting them is
/// how a second run inherits the first run's caveats.
///
/// Pre-order because it makes three orders coincide -- the report's reading order,
/// the trace's row order, and the order budget is spent in. That is what makes "the
/// run reached these slices and then stopped" a statement about a prefix of the
/// document rather than about a scatter through it.
///
/// `depth` counts from `rootPath`, so a scoped run's own root is depth 0. The
/// grammar depth is the path's component count and it is that which
/// RLM.Slice.MAXDEPTH bounds; the two differ by the scope's length.
///
/// ## Obligations
///
/// 1. `MaxDepth` = 1 reproduces the pre-feature traversal exactly: one root
///    decision, children examined flat, no second decision.
/// 2. `MaxDepth` = n visits a slice at depth d < n, decides it, and visits its
///    children at d+1.
/// 3. `rootPath` is resolved before any model call. On refusal `Run` returns a
///    report stating the refusal and makes no call.
/// 4. Never throws. Any exception from a source, policy or provider becomes a
///    report whose caveats name the failure.
/// 5. Aborts before any model call, and before any peek, if `..Source.Ready()` is
///    false, returning the reason the store gave.
/// 6. Never chooses a split it cannot fund at least one child of.
/// 7. Consults `..Source.ShouldSplit(peek)` before spending a decision on a slice.
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

/// How many levels below the run's starting point to decompose. 1 is the
/// behaviour the engine had before recursion existed: decide once at the root,
/// then describe each child. Raise the budget along with this.
Property MaxDepth As %Integer [ InitialExpression = 1 ];

/// Passed through to the RLM.Report this engine builds. It exists because the
/// engine owns that object, so a caller has no other way to reach it; it carries
/// no logic of its own.
Property ReportStyle As %String [ InitialExpression = "plain" ];

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
///
/// `rootPath` scopes the run to one slice. It is a slice name in the ordinary
/// grammar, not a WHERE clause: the traversal already threads paths, resolves
/// them through RLM.Slice and excludes their dimensions from candidates, so
/// starting it at `colour:red` rather than at `""` is the whole of scoping. A
/// string property holding raw SQL would deliver the same four behaviours while
/// creating exactly the authoring surface Constitution II exists to deny.
/// Nothing that happens below this method reaches the caller as an exception. A
/// Source, a Policy and an LLM are all told not to throw, but the contract is on
/// the implementation and therefore unenforceable -- and the caller asked for a
/// document, so a document is what it gets, with the failure written into it.
///
/// The body lives in Execute because `Quit <value>` is not allowed inside a Catch
/// block: the alternative is a result variable threaded through every early return
/// in a 150-line method, and a missed one there returns "" silently. A wrapper has
/// exactly one exit.
///
/// The report is built here rather than in Execute so the Catch still holds
/// whatever was written before the failure. A mid-run failure that discarded the
/// store's statistics would be indistinguishable from a store that could not be
/// read at all.
Method Run(
	question As %String,
	Output traceId As %Integer,
	rootPath As %String = "") As %String
{
    Set traceId = ""
    Set report = ##class(RLM.Report).%New()
    Set report.Style = ..ReportStyle
    Set out = ""
    Try {
        Set out = ..Execute(question, .traceId, rootPath, report)
    } Catch e {
        // e.Name alone is a code and e.Data alone is a fragment; a reader needs
        // both to tell "<UNDEFINED> peek" from a store's own message.
        Set detail = $ZStrip(e.Name_" "_e.Data, "<>W")
        Do report.Caveats($ListBuild("The analysis stopped early: "_detail_"."))
        Set out = report.Text
    }
    Quit out
}

/// The run itself. Private because `report` is Run's object and the Catch depends
/// on it: a caller passing its own would get a document Run cannot complete.
Method Execute(
	question As %String,
	Output traceId As %Integer,
	rootPath As %String,
	report As RLM.Report) As %String [ Private ]
{
    Set trace = ##class(RLM.Trace).%New(..DurableTrace)
    Set traceId = trace.RunId
    Set caveats = ""

    // Readiness first, before the peek and before any call. A store mid-load is
    // most likely to fail on exactly the peek this skips, and a refusal that has
    // already spent a call is a refusal that can exhaust a budget.
    If '..Source.Ready(.notReady) {
        Do report.Heading("Question")
        Do report.Add(question)
        Do report.AddBlank()
        Do report.Add("The analysis was not run: "
            _$Select(notReady="":"the store reports it is not ready", 1:notReady))
        Quit report.Text
    }

    // The scope is checked before anything is spent, for the same reason.
    Set rsc = ##class(RLM.Slice).Resolve(..Source, rootPath, .rootPredicate, .rootLabel)
    If $$$ISERR(rsc) {
        Do report.Heading("Question")
        Do report.Add(question)
        Do report.AddBlank()
        Do report.Add("The analysis was not run: "
            _$Piece($System.Status.GetErrorText(rsc), $Char(10), 1))
        Quit report.Text
    }

    // Characterize the starting slice first. This is the only unconditional peek:
    // without it the model has nothing to choose a split from.
    Set rootPeek = ..Source.Peek(rootPredicate)
    Set rootDesc = ..Source.Describe(rootLabel, rootPeek)
    If ..Capped(rootPeek) {
        Set caveats = caveats_$ListBuild("The store-wide count stopped at a limit, so it is a floor and not a total.")
    }

    Do report.Heading("Question")
    Do report.Add(question)
    Do report.AddBlank()
    Do report.Heading("Store")
    Do report.Add(rootDesc)

    // --- the traversal ---
    // Depth-first, pre-order, over an explicit stack of (path, depth) pairs. See
    // "The frontier" in the class comment for why it is a stack and why pre-order.
    Set notes = "", depths = "", asked = 0, refused = 0, wanted = 0
    Set top = 1, frontier(1) = $ListBuild(rootPath, 0)

    While top > 0 {
        Set node = frontier(top)
        Kill frontier(top)
        Set top = top - 1
        Set path = $List(node, 1), depth = $List(node, 2)
        Set isRoot = (depth = 0)

        If isRoot {
            Set predicate = rootPredicate, label = rootLabel, peek = rootPeek
        } Else {
            Set nsc = ##class(RLM.Slice).Resolve(..Source, path, .predicate, .label)
            If $$$ISERR(nsc) {
                Set refused = refused + 1
                Do trace.Add("refused", depth, path, $ClassName(..Source), , , ,
                    ..LLM.Model, 0, $System.Status.GetErrorText(nsc))
                Continue
            }
            Set peek = ..Source.Peek(predicate)
            If ..Capped(peek) {
                Set caveats = caveats_$ListBuild("The count for '"_label_"' stopped at a limit, so it is a floor.")
            }
        }

        // --- decide whether to divide this slice ---
        // The engine decides which dimensions are *eligible*; the policy decides
        // which of them to use. Eligibility is computed here rather than in the
        // policy because a policy deriving its own candidate set could derive a
        // different one, and then two policies over the same store are not
        // comparable -- which is the whole reason the seam exists.
        Set decision = ""
        If depth < ..MaxDepth {
            If isRoot {
                // The root is decided unconditionally, as it always was: the run
                // exists to divide the thing it was pointed at.
                Set decision = ..Decide(rootPeek, rootPath, depth, trace, .caveats)
            } ElseIf '..Source.ShouldSplit(peek) {
                // FR-003. Asking the policy would answer the same question having
                // paid a peek per child to do it, and the store already knows.
                // Still recorded: a slice left alone and a slice never reached
                // look identical in a report, and only one is unremarkable.
                Set decision = ##class(RLM.Decision).%New($ClassName(..Policy),
                    ..Source.SplitMetric(peek))
                Do decision.Decline("the store reports this slice is already one population")
                Do trace.AddDecision(decision, depth, $ClassName(..Source), path)
            } ElseIf '..Budget.CanSpend(1) {
                // FR-004. A split whose children cannot be funded buys nothing but
                // a wider report of unexamined names.
                Set decision = ""
            } Else {
                Set decision = ..Decide(peek, path, depth, trace, .caveats)
            }
        }

        If $IsObject(decision), decision.Chose() {
            // The children of a dimension whose values can be missing do not sum to
            // their parent. Undisclosed, that reads as arithmetic that does not
            // close; disclosed, it is a known population the split cannot see.
            Set gap = ..Source.NullCount(predicate, decision.Dimension)
            If gap > 0 {
                Set caveats = caveats_$ListBuild(gap_" row(s) of '"_label
                    _"' fall in no bucket of '"_decision.Dimension
                    _"' and are counted in none of its children.")
            }
            Set kids = ##class(RLM.Policy).Children(..Source, decision.Dimension, .ksc, path)
            Set pushed = 0
            If $$$ISOK(ksc) {
                // Reversed, so the pop order is the store's declaration order.
                For i = $ListLength(kids):-1:1 {
                    Set childPath = path_$Select(path="":"", 1:"/")
                        _decision.Dimension_":"_$ListGet(kids, i)
                    // The ceiling is enforced here rather than left to
                    // RLM.Slice.Resolve, because a refusal arriving from the
                    // grammar reads as a store that does not offer a slice it does.
                    If $Length(childPath, "/") > ##class(RLM.Slice).#MAXDEPTH { Continue }
                    Set top = top + 1
                    Set frontier(top) = $ListBuild(childPath, depth + 1)
                    Set pushed = pushed + 1
                }
            }
            // A split that expanded to nothing leaves the slice undescribed, which
            // is worse than describing it undivided.
            If pushed { Continue }
        }

        // --- this slice is a leaf: describe it ---
        // The root is never sub-called. Its statistics are already in the report
        // under "Store", and synthesis is given them separately.
        If isRoot { Continue }

        Set wanted = wanted + 1
        If '..Budget.CanSpend(1) {
            Do trace.Add("capped", depth, path, $ClassName(..Source), , , ,
                ..LLM.Model, 1, "budget exhausted before this slice")
            Continue
        }

        Set desc = ..Source.Describe(label, peek)
        Set metric = ..Source.SplitMetric(peek)
        Set note = ..Ask("subcall", ..SubcallInstructions(),
            ..SubcallPrompt(question, desc), trace, depth, path, .ssc, metric)
        Set asked = asked + 1
        If $$$ISERR(ssc) {
            Set caveats = caveats_$ListBuild("The sub-call for '"_label_"' failed; that slice is described by its statistics only.")
            Set note = "(no analysis: sub-call failed)"
        }
        Set notes = notes_$ListBuild(label_" ["_desc_"] "_note)
        Set depths = depths_$ListBuild(depth)
    }

    Do report.AddBlank()
    Do report.Heading("Slices examined")
    If $ListLength(notes) = 0 {
        Do report.Add("(none)")
    } Else {
        // Indented by the slice's own depth, so a depth-2 finding sits under the
        // finding of the slice it came out of. `depths` is accumulated alongside
        // `notes` in the traversal, and pre-order is what makes the two lists line
        // up as a tree rather than as a scatter. Depth 1 indents by 1 -- and a
        // depth-1 run's findings are all depth 1, so its output is unchanged.
        Set ptr = 0, dptr = 0
        While $ListNext(notes, ptr, n) {
            Set has = $ListNext(depths, dptr, d)
            Do report.Bullet(n, $Select(has:d - 1, 1:0))
        }
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
    If wanted > asked {
        Set caveats = caveats_$ListBuild((wanted - asked)_" slice(s) were dropped because the call budget ran out before them.")
    }
    Set caveats = caveats_$ListBuild("Spent "_..Budget.Describe()_".")
    Do report.Caveats(caveats)

    Quit report.Text
}

/// Ask the policy how to divide one slice, trace the answer, and disclose what
/// limited it.
///
/// Factored out of the traversal because it is called from two places -- the root,
/// which is decided unconditionally, and every other slice, which is decided only
/// once the store has said it is still mixed -- and the tracing and disclosure
/// must be identical in both.
Method Decide(
	peek As %DynamicObject,
	path As %String,
	depth As %Integer,
	trace As RLM.Trace,
	ByRef caveats As %List) As RLM.Decision
{
    Set candidates = ..Candidates(path)
    Set decision = ..Policy.ChooseSplit(..Source, peek, candidates, ..Budget, path)
    Do trace.AddDecision(decision, depth, $ClassName(..Source), path)
    If decision.Capped {
        Set caveats = caveats_$ListBuild("The split decision was limited by a cap, so it rests on partial evidence.")
    }
    If 'decision.Chose(), depth = 0 {
        Set caveats = caveats_$ListBuild("Not decomposed: "_decision.Reason_".")
    }
    Quit decision
}

/// Dimensions eligible for splitting the slice at `path`.
///
/// A dimension qualifies when the store declares it, it is not already used on
/// this path (splitting twice on one dimension narrows nothing), and it has at
/// least two children (FR-011: one child yields a slice identical to its parent).
Method Candidates(path As %String = "") As %List
{
    Set out = ""
    Set dims = ..Source.Dimensions(path)
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
Method Expand(
	decision As RLM.Decision,
	path As %String = "") As %String
{
    If 'decision.Chose() { Quit "" }
    Set kids = ##class(RLM.Policy).Children(..Source, decision.Dimension, .sc, path)
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
