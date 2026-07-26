/// An `RLM.LLM` over AI Hub's configured providers.
///
/// On an AI Hub instance the provider is already named, configured and credentialed
/// at the instance level, so a run says "use the configured provider" and no copy
/// of a key ends up in a `%New()` argument the way `RLM.LLM.REST` requires.
///
/// Built on `%AI.Provider.ChatComplete` and deliberately not on `%AI.Agent.Chat`.
/// `%AI.Agent` maintains a session and runs a tool loop -- `MaxIterations` defaults
/// to 10 -- and this design is one bounded round-trip per decision with all evidence
/// pre-computed. A loop the engine does not control breaks budget accounting (the
/// engine charges one slot and the provider spends ten) and breaks replay (the
/// trajectory depends on tool results, not only on the store). `ChatComplete` is
/// stateless and single-shot, which is the `RLM.LLM` contract exactly.
///
/// Two things this class exists to reconcile:
///
/// `%AI.*` signals failure by throwing. `RLM.LLM`'s contract is that an
/// implementation returns "" and sets a status, so that a provider outage costs a
/// run one slot rather than the whole report. Every call is therefore wrapped.
///
/// `%AI.LLM.Response` carries `Content`, `ToolCalls` and `Usage` and no finish
/// reason -- `FromJSON` reads exactly those three keys. `RLM.LLM.REST` refuses a
/// completion whose `finish_reason` is `length`, because a self-truncated answer read
/// as complete is the documented RLM failure mode and Constitution III forbids it.
/// With no finish reason to read, truncation is inferred from the reported completion
/// token count against the requested limit. See `Truncated()`.
Class RLMAIHub.Provider Extends RLM.LLM
{

/// The configured provider's name, for the trace and for a refusal's reason.
Property ProviderName As %String;

/// The resolved provider. Settable so a test can substitute a scripted subclass
/// and so a caller can hand in a provider it resolved itself.
Property Provider As %AI.Provider;

Property Temperature As %Numeric [ InitialExpression = 0 ];

/// Completion token ceiling. Empty means unset: no ceiling is sent, and the
/// truncation check below does not run.
Property MaxTokens As %Integer;

/// Optional. Consulted before the call; a refusal is returned as a status.
Property AuthPolicy As %AI.Policy.Authorization;

/// Optional. Told the outcome after the call, with its duration.
Property AuditPolicy As %AI.Policy.Audit;

/// Provider-reported usage from the last call. Empty when the provider reported
/// none, because zero is a measurement and absence is not.
///
/// Not written into the trace's tokensIn/tokensOut: `RLM.Engine` fills those with
/// `$Length(prompt)` and `$Length(out)`, which are characters. Redefining them for
/// one provider would make an AI Hub run and a REST run incomparable in the
/// scorecard that exists to compare them.
Property LastPromptTokens As %Integer;

Property LastCompletionTokens As %Integer;

/// `settings` resolves a provider through `%AI.Provider.Create`; omit it to use the
/// instance's configured provider of that name.
///
/// `settings` holds a `%DynamicObject` but is declared `%String`, because an override
/// of `%OnNew` may only widen `%RegisteredObject`'s `initvalue As %String` and any
/// other declared type is `ERROR #5478` at compile time. Method arguments are not
/// runtime-typechecked, so the oref passes through intact.
Method %OnNew(
	providerName As %String,
	model As %String,
	settings As %String = "") As %Status
{
    Set ..ProviderName = providerName
    Set ..Model = model
    // A construction failure is a status, not a throw, for the same reason a call
    // failure is: the caller gets to decide whether an unreachable provider ends
    // the run, and Ready() is where they ask.
    Try {
        If $IsObject(settings) {
            Set ..Provider = ##class(%AI.Provider).Create(providerName, settings)
        } Else {
            Set ..Provider = ##class(%AI.Provider).Create(providerName, {})
        }
    } Catch {
        Set ..Provider = ""
    }
    Quit $$$OK
}

/// One completion. Never throws (FR3): every failure is a status.
Method Complete(
	instructions As %String,
	prompt As %String,
	Output sc As %Status) As %String
{
    Set sc = $$$OK
    Set ..LastPromptTokens = "", ..LastCompletionTokens = ""
    Set started = $ZHorolog
    Set out = ""

    Set messages = ..BuildMessages(instructions, prompt)

    If $IsObject(..AuthPolicy) {
        Set sc = ..Authorize(messages)
        If $$$ISERR(sc) {
            Do ..Log(started, sc)
            Quit ""
        }
    }

    If '$IsObject(..Provider) {
        Set sc = $$$ERROR($$$GeneralError, "the AI Hub provider """_..ProviderName_""" did not resolve, so no completion was attempted")
        Do ..Log(started, sc)
        Quit ""
    }

    // Quit is not permitted inside a Catch, so the failure is signalled by resp
    // being unset rather than by returning from the handler.
    Try {
        Set resp = ..Provider.ChatComplete(..Model, messages, ..Temperature, ..MaxTokens)
    } Catch e {
        Set sc = $$$ERROR($$$GeneralError, "the AI Hub provider """_..ProviderName_""" failed: "_e.DisplayString())
    }

    If $$$ISOK(sc) {
        If '$IsObject($Get(resp)) {
            Set sc = $$$ERROR($$$GeneralError, "the AI Hub provider returned no response object")
        } Else {
            Do ..ReadUsage(resp)
            Set out = resp.Content
            If out = "" {
                Set sc = $$$ERROR($$$GeneralError, "the AI Hub provider returned an empty completion; an empty answer is not a decision")
            } ElseIf ..Truncated() {
                Set sc = $$$ERROR($$$GeneralError, "the AI Hub completion reached the "_..MaxTokens_"-token limit, so it was cut off rather than finished; a truncated answer is not a complete one")
                Set out = ""
            }
        }
    }

    Do ..Log(started, sc)
    If $$$ISERR(sc) { Quit "" }
    Quit out
}

/// System turn then user turn, and nothing else.
///
/// The same two messages `RLM.LLM.REST.BuildBody` sends. Kept separate from
/// `Complete` so a test can assert the request shape: if the two providers built
/// different prompts, every scorecard comparison between them would be measuring
/// the prompt rather than the model.
Method BuildMessages(
	instructions As %String,
	prompt As %String) As %DynamicArray
{
    Set messages = []
    Do messages.%Push({"role": "system", "content": (instructions)})
    Do messages.%Push({"role": "user", "content": (prompt)})
    Quit messages
}

/// Whether the last completion was cut off at the token ceiling.
///
/// A proxy, because the platform exposes no finish reason. It over-refuses: a
/// completion that legally ends on the limit is rejected. That is the correct
/// direction of error under Constitution III -- a false refusal is disclosed in the
/// report and costs one slot, while a false acceptance puts half a sentence into a
/// report as a finding and says nothing.
///
/// Both figures must be known. No ceiling means no check, and a provider that
/// reports no usage is not thereby evidence of truncation.
Method Truncated() As %Boolean
{
    If ..MaxTokens = "" { Quit 0 }
    If ..LastCompletionTokens = "" { Quit 0 }
    Quit (..LastCompletionTokens >= ..MaxTokens)
}

/// Whether a call can be attempted, and why not.
///
/// Separate from construction because construction proves nothing: measured on
/// 2026.3.0AI Build 126U, `%AI.Provider.Create("openai", {"api_key": "sk-not-a-real-key"})`
/// returns a provider object and lists capabilities. A caller that read construction
/// as readiness would find out one exhausted budget later.
Method Ready(Output reason As %String) As %Boolean
{
    Set reason = ""
    If '$IsObject(..Provider) {
        Set reason = "the AI Hub provider """_..ProviderName_""" did not resolve on this instance"
        Quit 0
    }
    // The capability list, not HasCapability(). Measured on 2026.3.0AI Build 126U:
    // `HasCapability("ChatCompletion")` returns 0 -- not an error -- on a provider
    // whose configuration cannot be resolved, so a plain false conflates "this
    // provider cannot chat" with "nobody could tell me". `GetCapabilities()` throws
    // in the second case, which is the distinction Ready() needs to make.
    //
    // A provider that cannot be asked is treated as able. Refusing a working
    // provider because a capability query is unavailable would be a refusal with no
    // real reason behind it, and a reason nobody can act on is worse than no check.
    Set able = 1
    Try {
        Set caps = ..Provider.GetCapabilities()
        If $IsObject(caps), caps.%Size() > 0 {
            Set able = 0
            For i = 0:1:caps.%Size() - 1 {
                If caps.%Get(i) = "ChatCompletion" { Set able = 1 }
            }
        }
    } Catch {
    }
    If 'able {
        Set reason = "the AI Hub provider """_..ProviderName_""" does not advertise chat completion"
        Quit 0
    }
    Quit 1
}

/// Copy the provider's usage figures onto the object, tolerating any shape.
///
/// `%AI.LLM.Response.FromJSON` passes the `usage` object through verbatim, so its
/// keys are whatever the provider sent rather than anything the platform normalizes.
/// OpenAI's names are read; anything else leaves the counts empty, which is honest.
Method ReadUsage(resp As %AI.LLM.Response) [ Private ]
{
    If '$IsObject(resp.Usage) { Quit }
    Set p = resp.Usage.%Get("prompt_tokens")
    Set c = resp.Usage.%Get("completion_tokens")
    If p '= "" { Set ..LastPromptTokens = +p }
    If c '= "" { Set ..LastCompletionTokens = +c }
}

/// Ask the instance's authorization policy. A refusal is a status; so is a policy
/// that throws, for the same reason a provider that throws is.
Method Authorize(messages As %DynamicArray) As %Status [ Private ]
{
    // Quit is not permitted inside a Catch, so the handler records the failure and
    // the single exit below reports it.
    Set threw = ""
    Try {
        Set psc = ..AuthPolicy.%CanExecute(..CallName(), ..CallDescriptor(), ..Metadata())
    } Catch e {
        Set psc = $$$OK
        Set threw = e.DisplayString()
    }
    If threw '= "" {
        Quit $$$ERROR($$$GeneralError, "the AI Hub authorization policy failed: "_threw)
    }
    If $$$ISERR(psc) {
        Quit $$$ERROR($$$GeneralError, "the AI Hub authorization policy refused the completion: "_$System.Status.GetErrorText(psc))
    }
    Quit $$$OK
}

/// Tell the instance's audit policy what happened. Never allowed to affect the
/// result: an audit sink that throws must not turn a successful completion into a
/// failed one, so its own failure is swallowed here rather than propagated.
Method Log(
	started As %Numeric,
	sc As %Status) [ Private ]
{
    If '$IsObject(..AuditPolicy) { Quit }
    Set ms = $Normalize(($ZHorolog - started) * 1000, 0)
    Try {
        Do ..AuditPolicy.%LogExecution(..CallDescriptor(), ..Metadata(), ..Result(sc), ms, sc)
    } Catch {
    }
}

/// What the policy seam is told this call is.
Method CallName() As %String [ Private ]
{
    Quit "rlm.completion"
}

/// The call as the policy sees it.
///
/// Deliberately holds no prompt and no completion text. Constitution I is about what
/// reaches a model, but the same reasoning applies leaving the other way: the prompt
/// carries slice statistics about a store the caller may not export, and an audit
/// sink is not a place to put them. The policy gets the shape of the call -- who,
/// what model, how many characters -- and the report remains the only place the
/// content appears.
Method CallDescriptor() As %DynamicObject [ Private ]
{
    Quit {"tool": "rlm.completion", "provider": (..ProviderName), "model": (..Model)}
}

Method Metadata() As %DynamicObject [ Private ]
{
    Quit {"source": "rlm-aihub", "user": ($Username), "namespace": ($Namespace)}
}

Method Result(sc As %Status) As %DynamicObject [ Private ]
{
    Set ok = $$$ISOK(sc)
    Set out = {"ok": (ok)}
    If 'ok { Set out.error = $System.Status.GetErrorText(sc) }
    If ..LastPromptTokens '= "" { Set out."prompt_tokens" = ..LastPromptTokens }
    If ..LastCompletionTokens '= "" { Set out."completion_tokens" = ..LastCompletionTokens }
    Quit out
}

}
