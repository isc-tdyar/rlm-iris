/// The recursive sub-agent pattern, written as if AI Hub already supported it.
///
/// This does not compile, and it lives outside `src/` so nothing tries. Every
/// line marked NOT TODAY is somewhere the platform has no equivalent; the comment
/// says what we have to do instead and which ask in
/// docs/ER-AIHUB-RECURSIVE-SUBAGENTS.md it belongs to.
///
/// Read it top to bottom. The shape is deliberately ordinary -- a delegation tool
/// that hands part of a task to a child and recurses -- because the point is that
/// the ordinary shape is the one that does not work.
Class Wanted.Delegate Extends %AI.Tool
{

Parameter DESCRIPTION = "Delegate part of a task to a specialist sub-agent.";

Property ParentAgent As %AI.Agent;

/// The slice of the store this tool may read.
///
/// NOT TODAY -- ask 3, model-invisible tool arguments.
/// We want the caller to set this and the model never to see it in the generated
/// schema, so the model chooses *which* subtask to delegate but never supplies
/// the predicate that scopes it. Python does this with `RunContext[T]`.
/// ObjectScript leaves two options, and both are wrong for us: make it a
/// model-visible argument, where the model can rewrite the scope it was given,
/// or hold it as instance state, which your own shell-tool docs warn is fragile
/// behind a CSP job pool.
Property Scope As %String [ Internal ];

Method Execute(task As %String) As %String [ WebMethod ]
{
    // NOT TODAY -- ask 1, a child that knows its own depth.
    // There is no Depth and no MaxDepth on %AI.Agent. Today the parent has to
    // thread the number through the child's prompt, which means any entry point
    // that forgets to thread it recurses without a bound.
    If ..ParentAgent.Depth >= ..ParentAgent.MaxDepth {
        Quit "[depth limit reached; answering from what is already known]"
    }

    Set child = ..ParentAgent.CreateSubAgent("You are a specialist. Delegate further if useful.")

    // WORKS TODAY, and this is the whole problem.
    // The shipped Sample.AI.Tools.DelegateTask omits these three lines, so its
    // child holds no tools and the sample stops at one level. Adding them is the
    // documented way to give a sub-agent a tool. Nothing then stops the recursion.
    Set t = ##class(Wanted.Delegate).%New()
    Set t.ParentAgent = child
    Set t.Scope = ..NarrowScope(task)
    Do child.ToolManager.AddTool(t)

    // NOT TODAY -- ask 1, subtree budgets.
    // MaxIterations is inherited whole and max_iterations/timeout_ms live on a
    // session the child creates fresh, so every level gets a full allowance of
    // each. We want a child to inherit what is *left*, not a new copy.
    Set child.Budget = ..ParentAgent.Budget.Remaining()

    Set session = child.CreateSession()
    Quit child.Run(session, task).Content
}

/// Narrow the scope for the child. Ordinary code; nothing missing here.
Method NarrowScope(task As %String) As %String
{
    Quit ..Scope
}

}
