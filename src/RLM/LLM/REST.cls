/// An OpenAI-compatible chat-completions endpoint over %Net.HttpRequest.
///
/// This is the portable provider: it needs nothing beyond a base IRIS, so the
/// rlm-core module installs and runs on versions with no AI Hub at all. It is
/// also the seam a locally-served policy plugs into -- vLLM, Ollama and llama.cpp
/// all speak this shape, so a trained policy can be swapped in by changing a URL.
///
/// Two response shapes get rejected rather than returned. A provider error
/// object arrives as HTTP 200 often enough that treating it as an answer puts
/// "rate limited" into a report as a finding. And a completion truncated by the
/// token limit is not an answer: returning it silently is the self-truncation
/// failure the whole package is built to avoid.
Class RLM.LLM.REST Extends RLM.LLM
{

/// Base URL up to but excluding /chat/completions.
Property BaseURL As %String;

/// Bearer token. Leave empty for a local server that wants none.
Property APIKey As %String;

Property Timeout As %Integer [ InitialExpression = 60 ];

Property Temperature As %Numeric [ InitialExpression = 0 ];

/// Verify the server certificate using this SSL configuration. Required for
/// https endpoints.
Property SSLConfiguration As %String;

Method %OnNew(
	baseURL As %String,
	model As %String,
	apiKey As %String = "",
	sslConfig As %String = "") As %Status
{
    Set ..BaseURL = $ZStrip(baseURL, ">", "/")
    Set ..Model = model
    Set ..APIKey = apiKey
    Set ..SSLConfiguration = sslConfig
    Quit $$$OK
}

Method Complete(
	instructions As %String,
	prompt As %String,
	Output sc As %Status) As %String
{
    Set sc = $$$OK
    Try {
        Set req = ##class(%Net.HttpRequest).%New()
        Set req.Timeout = ..Timeout
        Set req.ContentType = "application/json"
        Set req.ContentCharset = "UTF-8"
        If ..APIKey '= "" { Do req.SetHeader("Authorization", "Bearer "_..APIKey) }
        If ..SSLConfiguration '= "" { Set req.SSLConfiguration = ..SSLConfiguration }
        Do req.EntityBody.Write(..BuildBody(instructions, prompt))

        Set sc = req.Post(..BaseURL_"/chat/completions")
        If $$$ISERR(sc) { Quit }

        Set body = ""
        While 'req.HttpResponse.Data.AtEnd {
            Set body = body_req.HttpResponse.Data.Read(32000)
        }
        If +req.HttpResponse.StatusCode '= 200 {
            Set msg = "provider returned HTTP "_req.HttpResponse.StatusCode_": "
                _$Extract(body, 1, 500)
            Set sc = $$$ERROR($$$GeneralError, msg)
            Quit
        }
        Set out = ..ParseResponse(body, .sc)
    } Catch e {
        Set sc = e.AsStatus()
    }
    If $$$ISERR(sc) { Quit "" }
    Quit $Get(out)
}

/// The request body. Separate from Complete so it can be asserted on without a
/// server: the body is the part that silently changes shape between providers.
Method BuildBody(
	instructions As %String,
	prompt As %String) As %String
{
    Set body = {"model": (..Model), "temperature": (..Temperature), "messages": []}
    Do body.messages.%Push({"role": "system", "content": (instructions)})
    Do body.messages.%Push({"role": "user", "content": (prompt)})
    Quit body.%ToJSON()
}

/// Extract the assistant message, or fail loudly.
Method ParseResponse(
	body As %String,
	Output sc As %Status) As %String
{
    Set sc = $$$OK
    // Quit is not permitted inside a Catch block, so the failure is signalled by
    // obj being unset rather than by returning from the handler.
    Try {
        Set obj = {}.%FromJSON(body)
    } Catch {
    }
    If '$IsObject($Get(obj)) {
        Set msg = "provider response is not JSON: "_$Extract(body, 1, 300)
        Set sc = $$$ERROR($$$GeneralError, msg)
        Quit ""
    }
    If $IsObject(obj.error) {
        Set msg = "provider error: "_obj.error.message
        Set sc = $$$ERROR($$$GeneralError, msg)
        Quit ""
    }
    If '$IsObject(obj.choices) || (obj.choices.%Size() = 0) {
        Set sc = $$$ERROR($$$GeneralError, "provider response has no choices")
        Quit ""
    }
    Set choice = obj.choices.%Get(0)
    If choice.%Get("finish_reason") = "length" {
        Set msg = "provider response was truncated at the token limit; "
            _"it is not a complete answer"
        Set sc = $$$ERROR($$$GeneralError, msg)
        Quit ""
    }
    If '$IsObject(choice.message) {
        Set sc = $$$ERROR($$$GeneralError, "provider choice has no message")
        Quit ""
    }
    Quit choice.message.content
}

}
