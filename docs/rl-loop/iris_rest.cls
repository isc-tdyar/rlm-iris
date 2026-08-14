/// The IRIS side of the RL loop: a REST surface over decomposition and scoring.
///
/// Two halves, and they are worth separating because they cost different things.
///
/// The rollout half (/run, /moves, /split, /read, /note, /answer) is what the
/// agent drives during an episode. Each call is one aggregate the database
/// answers, or a capped read.
///
/// The scoring half (/run/{id}/score) is what the trainer calls after the episode
/// is over. Every figure it returns is computed from ^RLM.Trace and the store
/// with **zero model calls** -- that is the whole reason this is a cheap RL
/// environment. Most environments need a judge model or a human label here.
///
/// Illustrative, in docs/ rather than src/ so nothing compiles it. Companion to
/// docs/rl-loop/README.md.
Class Wanted.RLM.REST Extends %CSP.REST
{

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/ready"            Method="GET"  Call="Ready"/>
  <Route Url="/resolve"          Method="GET"  Call="Resolve"/>
  <Route Url="/run"              Method="POST" Call="Open"/>
  <Route Url="/moves"            Method="POST" Call="Moves"/>
  <Route Url="/split"            Method="POST" Call="Split"/>
  <Route Url="/read"             Method="POST" Call="Read"/>
  <Route Url="/note"             Method="POST" Call="Note"/>
  <Route Url="/answer"           Method="POST" Call="Answer"/>
  <Route Url="/run/:runId/score" Method="GET"  Call="Score"/>
</Routes>
}

/// The reward, computed after the episode. Zero model calls on every path.
///
/// This is the method the whole RL story rests on, so what each figure means:
///
///   objective  RLM.Eval.Scorecard.Objective -- mean split metric of the leaf
///              slices reached. 0-1, lower better. The episode return.
///
///   arms       RLM.Eval.Arms.Enumerate -- every dimension the run did *not*
///              choose, at every decision, re-scored by peeking it. Dense
///              feedback over the action set, and answerable only because the
///              model picked from an enumerated menu rather than composing a
///              predicate. Each entry carries the regret against the arm taken.
///
///   cited /    Of the figures the answer quotes, how many appear in a peek this
///   supported  run was actually served. A grounding check, done as string
///              matching against the trace rather than as a judgement.
///
///   partial    True when the run lost a slice to an exhausted budget or a failed
///              call. Scorecard refuses to score those, and the trainer should
///              treat the episode as unscored rather than as a bad one -- it
///              examined a different population than it set out to.
ClassMethod Score(runId As %String) As %Status
{
    Set out = {}
    Set source = ##class(RLM.Trace).SourceOf(runId)

    Set out.partial = (##class(RLM.Eval.Scorecard).Partial(runId) '= "")
    Set obj = ##class(RLM.Eval.Scorecard).Objective(source, runId, .reason)
    Set out.objective = $Select(obj = "": 1, 1: obj)
    Set out.reason = reason

    // Counterfactuals. peekBudget bounds it: a wide store has many arms and the
    // trainer is calling this once per rollout.
    Set arms = ##class(RLM.Eval.Arms).Enumerate(source, runId, 128)
    Set out.arms = ..Regrets(arms)

    Do ..Grounding(runId, .cited, .supported)
    Set out.cited = cited, out.supported = supported

    Set out.slices = ##class(RLM.Eval.Scorecard).Slices(runId)
    Set out.depth = ##class(RLM.Trace).MaxDepth(runId)
    Set out.calls = ##class(RLM.Trace).Calls(runId)

    Quit ..Json(out)
}

/// Turn scored arms into per-decision regret against the arm actually taken.
///
/// An arm the store could not score -- the dimension no longer offered here, too
/// few children, the peek budget exhausted -- is skipped rather than counted as
/// zero regret. Counting it as zero would reward a run for decisions nobody could
/// price.
ClassMethod Regrets(arms As %DynamicObject) As %DynamicArray [ Private ]
{
    Set out = []
    Set seen = ""
    Set it = arms.arms.%GetIterator()
    While it.%GetNext(, .arm) {
        Continue:arm.score=""
        Set key = arm.seq
        Set best(key) = $Select($Data(best(key), b) # 2: $Select(arm.score < b: arm.score, 1: b), 1: arm.score)
        Set chosen(key) = arm.chosen
        Set path(key) = arm.path
    }
    Set key = ""
    For {
        Set key = $Order(best(key))
        Quit:key=""
        Set taken = ##class(RLM.Trace).ChosenScore(key)
        Continue:taken=""
        Do out.%Push({
            "seq":       (key),
            "path":      (path(key)),
            "chosen":    (chosen(key)),
            "takenScore":(taken),
            "bestScore": (best(key)),
            "regret":    ($Select(taken > best(key): taken - best(key), 1: 0))
        })
    }
    Quit out
}

/// How much of the answer is traceable to a peek the run was served.
///
/// Numbers rather than prose: every figure in a peek is recorded, so a claim
/// quoting one is checkable exactly. Claims with no figure in them are not
/// counted either way -- this measures whether quoted numbers are real, not
/// whether the prose is true.
ClassMethod Grounding(
	runId As %String,
	Output cited As %Integer,
	Output supported As %Integer) [ Private ]
{
    Set cited = 0, supported = 0
    Set answer = ##class(RLM.Trace).AnswerOf(runId)
    Set served = ##class(RLM.Trace).FiguresServed(runId)   // set of numbers shown
    Set ptr = 0
    While $ListNext(..Numbers(answer), ptr, n) {
        Set cited = cited + 1
        If $Data(served(n)) { Set supported = supported + 1 }
    }
}

/// One decomposition step. The agent's tool calls land here.
///
/// Note what is not in any signature below: a predicate. The agent names a
/// dimension or a slice, and RLM.Slice resolves it against what the store
/// offered. Nothing the model wrote reaches a query.
ClassMethod Split(runId As %String) As %Status
{
    Set body = ..Body()
    Set run = ##class(RLM.Run).Open(runId)
    Set decision = run.Divide(body.slice, body.dimension, .sc)
    If $$$ISERR(sc) { Quit ..Refuse(sc) }
    Quit ..Json({"children": (decision.Describe())})
}

/// Read the records of a slice, or refuse and say why.
///
/// The refusal matters as much as the read. A slice above the cap, or one whose
/// count came back capped, gets its statistics instead -- and the caveat is in
/// the response, so the model is told it is looking at a summary rather than
/// quietly handed one.
ClassMethod Read(runId As %String) As %Status
{
    Set body = ..Body()
    Set run = ##class(RLM.Run).Open(runId)
    Set lens = ##class(RLM.Lens.Contents).%New(body.limit)
    Set view = run.View(body.slice, lens, .disclosed)
    Quit ..Json({"view": (view), "disclosed": (disclosed)})
}

}
