/// Driving the recursion, written as if AI Hub already supported it.
///
/// Companion to Delegate.cls. Same convention: NOT TODAY marks a line with no
/// platform equivalent, and names the ask in
/// docs/ER-AIHUB-RECURSIVE-SUBAGENTS.md. Does not compile; lives outside `src/`.
Class Wanted.Run Extends %RegisteredObject
{

ClassMethod Decompose(
	question As %String,
	scope As %String) As %String
{
    Set provider = ##class(%AI.Provider).Create("openai", {"api_key": "..."})
    Set agent = ##class(%AI.Agent).%New(provider)
    Set agent.SystemPrompt = "Decompose the question. Delegate parts you cannot answer directly."

    // NOT TODAY -- ask 1, a ceiling the platform enforces.
    // Without this the only control is the Best Practices line in the guide
    // telling us to keep nesting to 2-3 levels.
    Set agent.MaxDepth = 3

    // NOT TODAY -- ask 1, behaviour at the ceiling.
    // Refuse, or fall back to a plain completion. We do not mind which, so long
    // as it is not silent -- a run that quietly stopped going deeper and a run
    // that finished look identical in the output today.
    Set agent.OnMaxDepth = "refuse"

    Set t = ##class(Wanted.Delegate).%New()
    Set t.ParentAgent = agent
    Set t.Scope = scope
    Do agent.ToolManager.AddTool(t)

    Set session = agent.CreateSession()
    Set response = agent.Run(session, question)

    // NOT TODAY -- ask 2, the trace.
    // This is the one we care most about, and it may already exist: you ship
    // OTel for iris-mcp-server, and we have not seen what it emits for an agent
    // running in-process. What we need out of a finished run is
    //
    //   * one trace covering the whole tree, not one per agent
    //   * each sub-agent a child span of the parent that spawned it
    //   * tokens and model id on every model call
    //
    // With those three, span nesting *is* the depth dimension and a finished run
    // is a dataset we can score offline instead of re-running. Without them a
    // recursive run is a flat list of calls that cannot be credited by level.
    Set trace = agent.Trace()
    Do ##class(Wanted.Export).ToJSONL(trace, "/tmp/run.jsonl")

    Quit response.Content
}

/// What fan-out should look like.
///
/// NOT TODAY -- the guide says nested calls are sequential, and
/// NestedAgents.ParallelDelegation()'s own comment disclaims its name. Not
/// blocking us, but decomposition is about examining many slices per decision,
/// and one-at-a-time turns a wide shallow tree into a slow one.
ClassMethod FanOut(
	agent As %AI.Agent,
	tasks As %List) As %List
{
    Quit agent.MapChildren(tasks)
}

}
