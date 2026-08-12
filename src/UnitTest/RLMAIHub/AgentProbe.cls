/// What `%AI.*` this instance actually offers, read from the dictionary.
///
/// Every statement in docs/ER-AIHUB-RECURSIVE-SUBAGENTS.md about the agent surface
/// rests on measurements taken on 2026.3.0AI Build 126U while building M5. Some of
/// them are about signatures that may since have changed, and one -- `ai-hub-eap#26`
/// -- is about a defect that may since have been fixed. Neither can be re-checked
/// from a machine that cannot obtain an AI Hub image, and the AI Hub builds are
/// WRC-gated rather than on Docker Hub, so the check has to happen wherever the
/// image already is.
///
/// This class is what runs there. It reads `%Dictionary.CompiledClass` and
/// `%Dictionary.CompiledMethod` rather than calling anything, so it costs no license
/// slot, needs no provider configured, and cannot hang -- which matters because the
/// defect it exists to help re-check is a hang.
///
/// Reflection rather than a written-down expectation, because the point is to learn
/// what is there. A probe asserting a signature this repository guessed would fail
/// on a surface that had merely been improved, and the failure would look like the
/// platform's rather than the guess's.
Class UnitTest.RLMAIHub.AgentProbe Extends %UnitTest.TestCase
{

/// Classes whose shape the enhancement request depends on.
///
/// `%AI.Agent` and `%AI.Tool` are the two named in `ai-hub-eap#26`. `%AI.Op.Map` is
/// the operator SPEC §6 expects parallel fan-out to arrive on. The rest are listed
/// because the ER's open questions ask whether they carry a depth dimension.
ClassMethod Interesting() As %List
{
	Quit $ListBuild("%AI.Agent", "%AI.Tool", "%AI.Op.Map", "%AI.Env",
		"%AI.Context.Store", "%AI.LLM.Response", "%AI.Provider")
}

/// Print the surface. Not an assertion -- the output is the deliverable.
///
/// Run it standalone on an AI Hub instance:
///
///   Do ##class(UnitTest.RLMAIHub.AgentProbe).Report()
///
/// and send the output back with the build number from $ZVersion.
ClassMethod Report() As %Status
{
	Write !, "IRIS: ", $ZVersion, !
	Write "Namespace: ", $Namespace, !!

	Write "=== %AI.* classes present ===", !
	Set n = 0
	Set rs = ..Query("SELECT Name FROM %Dictionary.CompiledClass "
		_"WHERE Name %STARTSWITH '%AI.' ORDER BY Name", .sc)
	If $$$ISERR(sc) {
		Write "  (could not read the dictionary: "
			_$System.Status.GetErrorText(sc), ")", !
		Quit sc
	}
	While rs.%Next() {
		Set n = n + 1
		Write "  ", rs.%Get("Name"), !
	}
	If n = 0 {
		Write "  (none -- this instance has no AI Hub)", !
		Quit $$$OK
	}
	Write !, n, " class(es).", !!

	Set ptr = 0
	While $ListNext(..Interesting(), ptr, cls) {
		Do ..Detail(cls)
	}
	Quit $$$OK
}

/// One class's methods, properties and parameters, with signatures.
///
/// FormalSpec is the dictionary's own encoding (`name:type=default,...`), printed
/// raw rather than prettified: a transcription that dropped an `Output` or a default
/// would be the one detail a reader needed.
ClassMethod Detail(cls As %String)
{
	Write "=== ", cls, " ===", !
	If '##class(%Dictionary.CompiledClass).%ExistsId(cls) {
		Write "  (absent on this instance)", !!
		Quit
	}

	Set c = ##class(%Dictionary.CompiledClass).%OpenId(cls, , .osc)
	If $IsObject($Get(c)) {
		Write "  super: ", c.Super, !
		Write "  abstract: ", +c.Abstract, !
	}

	Write "  -- parameters --", !
	Set rs = ..Query("SELECT Name, Default FROM %Dictionary.CompiledParameter "
		_"WHERE parent = ? ORDER BY Name", .sc, cls)
	If $$$ISOK(sc) {
		While rs.%Next() {
			Write "    ", rs.%Get("Name"), " = ", rs.%Get("Default"), !
		}
	}

	Write "  -- properties --", !
	Set rs = ..Query("SELECT Name, Type FROM %Dictionary.CompiledProperty "
		_"WHERE parent = ? ORDER BY Name", .sc, cls)
	If $$$ISOK(sc) {
		While rs.%Next() {
			Write "    ", rs.%Get("Name"), " As ", rs.%Get("Type"), !
		}
	}

	Write "  -- methods --", !
	Set rs = ..Query("SELECT Name, FormalSpec, ReturnType, ClassMethod "
		_"FROM %Dictionary.CompiledMethod WHERE parent = ? "
		_"AND Private = 0 ORDER BY Name", .sc, cls)
	If $$$ISOK(sc) {
		While rs.%Next() {
			Write "    ", $Select(rs.%Get("ClassMethod"):"ClassMethod ", 1:"Method ")
			Write rs.%Get("Name"), "(", rs.%Get("FormalSpec"), ")"
			If rs.%Get("ReturnType") '= "" { Write " As ", rs.%Get("ReturnType") }
			Write !
		}
	}
	Write !
}

/// Run a query, returning a result set rather than throwing.
///
/// The same shape RLM.Source.Table.Query uses, for the same reason: a probe that
/// threw on a dictionary it could not read would report nothing about the classes it
/// could.
ClassMethod Query(
	sql As %String,
	Output sc As %Status,
	arg As %String = "") As %SQL.StatementResult
{
	Set sc = $$$OK
	Try {
		Set stmt = ##class(%SQL.Statement).%New()
		Set sc = stmt.%Prepare(sql)
		If $$$ISERR(sc) { Quit }
		If arg = "" {
			Set rs = stmt.%Execute()
		} Else {
			Set rs = stmt.%Execute(arg)
		}
		If rs.%SQLCODE < 0 {
			Set sc = $$$ERROR($$$GeneralError, "SQLCODE "_rs.%SQLCODE_": "_rs.%Message)
		}
	} Catch e {
		Set sc = e.AsStatus()
	}
	Quit $Get(rs)
}

/// The one thing worth asserting: this instance has an agent class at all.
///
/// Skipped rather than failed when absent, because the suite runs on base IRIS too
/// and a missing %AI.Agent there is the expected state, not a regression.
Method TestAgentClassIsPresentOrAbsentDeliberately()
{
	Set present = ##class(%Dictionary.CompiledClass).%ExistsId("%AI.Agent")
	If 'present {
		Do $$$LogMessage("no %AI.Agent on this instance; AI Hub probe skipped")
		Quit
	}
	Do $$$AssertTrue(present, "%AI.Agent is available to probe")
}

/// Whether the trajectory surface carries a depth or parent dimension.
///
/// ER open question 3, asked as a test so the answer arrives as output rather than
/// as someone's recollection. Logs rather than asserts: absence is the thing being
/// measured, not a failure.
Method TestReportWhetherAgentCarriesDepth()
{
	If '##class(%Dictionary.CompiledClass).%ExistsId("%AI.Agent") {
		Do $$$LogMessage("no %AI.Agent on this instance; depth probe skipped")
		Quit
	}
	Set found = ""
	Set rs = ..Query("SELECT Name FROM %Dictionary.CompiledProperty "
		_"WHERE parent = '%AI.Agent'", .sc)
	If $$$ISOK(sc) {
		While rs.%Next() {
			Set nm = rs.%Get("Name")
			If $ZConvert(nm, "L") [ "depth" { Set found = found_" "_nm }
			If $ZConvert(nm, "L") [ "parent" { Set found = found_" "_nm }
		}
	}
	Do $$$LogMessage("%AI.Agent depth/parent properties:"
		_$Select(found="":" (none)", 1:found))
}

}
