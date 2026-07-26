/// Portability, proven rather than reviewed.
///
/// `rlm-core` claims to install on an IRIS with no AI Hub. That claim is one
/// careless `##class(%AI.Provider)` away from false, and the failure mode is the
/// worst one available: `zpm load` aborting at compile time on a missing class,
/// on a stranger's instance, on first contact with the package.
///
/// So the guarantee is asserted against the shipped artifacts -- the `.cls` files
/// on disk and the IPM manifests that select them -- and not against the compiled
/// dictionary. A class absent from this instance because it failed to compile
/// would pass a dictionary check by being missing, which is exactly backwards.
///
/// This class must compile and run on an IRIS with no `%AI.*` at all, so it names
/// no `%AI.` class anywhere. It reads text.
///
/// Every assertion sits on one line: a macro's arguments cannot span source lines.
Class UnitTest.RLMAIHub.Manifests Extends %UnitTest.TestCase
{

/// The mounted source, not a copy: the point is to check what ships.
Parameter ROOT = "/home/irisowner/dev";

/// The two manifests exist and say what they are.
Method TestTheTwoManifestsDeclareTwoModulesOneDependentOnTheOther()
{
    Set core = ..Manifest(..#ROOT_"/module.xml")
    Set aihub = ..Manifest(..#ROOT_"/module-aihub.xml")
    Do $$$AssertTrue($Length(core) > 200, "module.xml was read")
    Do $$$AssertTrue($Length(aihub) > 200, "module-aihub.xml was read")
    Do $$$AssertTrue(core [ "<Name>rlm-core</Name>", "the core manifest names rlm-core")
    Do $$$AssertTrue(aihub [ "<Name>rlm-aihub</Name>", "the aihub manifest names rlm-aihub")
    Do $$$AssertTrue(aihub [ "rlm-core", "rlm-aihub references rlm-core")
    Do $$$AssertTrue(..Between(aihub, "<Dependencies>", "</Dependencies>") [ "rlm-core", "and references it as a dependency, not merely in prose")
    Do $$$AssertEquals(core [ "rlm-aihub", 0, "the dependency runs one way: rlm-core does not mention rlm-aihub")
}

/// Disjoint resources. Two manifests that both ship a class are one manifest with
/// a bug, and the bug surfaces as `rlm-core` dragging %AI.* onto a base IRIS.
Method TestTheTwoManifestsShipDisjointSetsOfClasses()
{
    Set coreRes = ..Resources(..Manifest(..#ROOT_"/module.xml"))
    Set aihubRes = ..Resources(..Manifest(..#ROOT_"/module-aihub.xml"))
    Do $$$AssertTrue($ListLength(coreRes) > 0, "the core manifest declares at least one resource")
    Do $$$AssertTrue($ListLength(aihubRes) > 0, "the aihub manifest declares at least one resource")
    Set ptr = 0
    While $ListNext(coreRes, ptr, r) {
        Set ptr2 = 0
        While $ListNext(aihubRes, ptr2, r2) {
            Do $$$AssertEquals(..Overlaps(r, r2), 0, "resources "_r_" and "_r2_" select disjoint sets")
        }
    }
}

/// The guarantee itself: nothing rlm-core ships mentions %AI.
///
/// Over file text rather than over `%Dictionary`, because a class that failed to
/// compile is absent from the dictionary and would pass by not being there.
Method TestNoClassShippedByRlmCoreReferencesAIHub()
{
    Set files = ..ClassFiles(..#ROOT_"/src/RLM")
    Do $$$AssertTrue($ListLength(files) >= 20, "the core source tree was walked: "_$ListLength(files)_" classes")
    Set ptr = 0
    While $ListNext(files, ptr, f) {
        Set text = ..ReadFile(f)
        Do $$$AssertTrue($Length(text) > 100, f_" was read")
        Set code = ..CodeOnly(text)
        Do $$$AssertEquals(code [ "%AI.", 0, f_": no %AI. reference")
        Do $$$AssertEquals(code [ "RLMAIHub", 0, f_": no reference to the AI Hub package")
    }
}

/// The engine and the evaluation classes specifically. Named one by one because
/// these are the four the milestone promised not to touch, and a rename that moved
/// one out of the RLM package would otherwise quietly drop it from the walk above.
Method TestTheEngineAndTheEvaluationClassesAreFreeOfAIHub()
{
    Set classes = $ListBuild("RLM/Engine", "RLM/Policy/LLM", "RLM/Replay", "RLM/Eval/Scorecard", "RLM/Eval/Arms", "RLM/LLM")
    Set ptr = 0
    While $ListNext(classes, ptr, c) {
        Set text = ..ReadFile(..#ROOT_"/src/"_c_".cls")
        Do $$$AssertTrue($Length(text) > 100, c_".cls was read")
        Set code = ..CodeOnly(text)
        Do $$$AssertEquals(code [ "%AI.", 0, c_": no %AI. reference")
        Do $$$AssertEquals(code [ "RLMAIHub", 0, c_": no reference to the AI Hub package")
    }
}

/// Every class the AI Hub module ships lives under its own top-level package.
///
/// `RLMAIHub` and not `RLM.AIHub`: IPM's `<Resource Name="RLM.PKG"/>` is recursive
/// and has no exclude, so a nested name would ship inside rlm-core and there would
/// be no layout in which the two manifests are disjoint.
Method TestTheAIHubClassesLiveOutsideTheRlmPackage()
{
    Set files = ..ClassFiles(..#ROOT_"/src/RLMAIHub")
    Do $$$AssertTrue($ListLength(files) >= 1, "the aihub source tree holds at least one class")
    Set ptr = 0
    While $ListNext(files, ptr, f) {
        Set text = ..ReadFile(f)
        Do $$$AssertTrue(text [ "Class RLMAIHub.", f_": declares a class in the RLMAIHub package")
        Do $$$AssertEquals(text [ "Class RLM.", 0, f_": does not declare a class in the RLM package")
    }
}

/// Two resource patterns overlap when either selects the other. Package resources
/// are recursive, so `RLM.PKG` selects `RLM.AIHub.Provider.CLS` -- which is the
/// whole reason the AI Hub classes are not named that.
ClassMethod Overlaps(
	a As %String,
	b As %String) As %Boolean
{
    Set aStem = ..Stem(a), bStem = ..Stem(b)
    If aStem = bStem { Quit 1 }
    If $Extract(bStem, 1, $Length(aStem) + 1) = (aStem_".") { Quit 1 }
    If $Extract(aStem, 1, $Length(bStem) + 1) = (bStem_".") { Quit 1 }
    Quit 0
}

/// A resource name without its .PKG / .CLS / .MAC suffix.
ClassMethod Stem(res As %String) As %String
{
    // A single trailing dotted piece that is one of the known kinds. Checking the
    // last piece rather than trimming a matched suffix, because `Quit <value>` is
    // illegal inside a `For` and the two-pass version of this read wrong.
    Set last = $ZConvert($Piece(res, ".", $Length(res, ".")), "U")
    If ",PKG,CLS,MAC,INC," [ (","_last_",") {
        Quit $Piece(res, ".", 1, $Length(res, ".") - 1)
    }
    Quit res
}

/// A manifest with its XML comments removed.
///
/// The same distinction `CodeOnly` draws for class source. `module.xml` carries a
/// comment explaining why its `<UnitTest>` entry names `/src/UnitTest/RLM` rather
/// than `/src/UnitTest`, and that explanation has to say the word "rlm-aihub" to be
/// worth reading. IPM does not install a comment, so a comment cannot drag the AI Hub
/// module onto a base IRIS -- only a `<Dependency>` or a `<Resource>` can.
ClassMethod Manifest(path As %String) As %String
{
    Set xml = ..ReadFile(path)
    Set out = "", pos = 1
    For {
        Set at = $Find(xml, "<!--", pos)
        If at = 0 { Quit }
        Set out = out_$Extract(xml, pos, at - 5)
        Set end = $Find(xml, "-->", at)
        // An unterminated comment swallows the rest: preferring to lose text over
        // reading a comment as markup keeps the false-positive direction consistent.
        If end = 0 { Set pos = $Length(xml) + 1  Quit }
        Set pos = end
    }
    Quit out_$Extract(xml, pos, *)
}

/// The `Name` attribute of every `<Resource>` in a manifest.
ClassMethod Resources(xml As %String) As %List
{
    Set out = "", pos = 1
    For {
        Set at = $Find(xml, "<Resource ", pos)
        If at = 0 { Quit }
        Set tag = $Extract(xml, at, $Find(xml, ">", at) - 1)
        Set name = ..Between(tag, "Name=""", """")
        If name '= "" { Set out = out_$ListBuild(name) }
        Set pos = at
    }
    Quit out
}

/// The text between the first `open` and the next `close` after it.
ClassMethod Between(
	text As %String,
	open As %String,
	close As %String) As %String
{
    Set at = $Find(text, open)
    If at = 0 { Quit "" }
    Set end = $Find(text, close, at)
    If end = 0 { Quit "" }
    Quit $Extract(text, at, end - $Length(close) - 1)
}

/// Every .cls file under a directory, recursively. Returns "" for a directory that
/// does not exist, so a test can distinguish "no classes" from "wrong path" by
/// asserting a count rather than by trusting the walk.
ClassMethod ClassFiles(dir As %String) As %List
{
    Set out = ""
    If '##class(%File).DirectoryExists(dir) { Quit out }
    Set rs = ##class(%ResultSet).%New("%File:FileSet")
    Set sc = rs.Execute(dir, "*", , 1)
    If $$$ISERR(sc) { Quit out }
    Set files = "", dirs = ""
    While rs.Next() {
        Set name = rs.Get("Name")
        If rs.Get("Type") = "D" {
            Set dirs = dirs_$ListBuild(name)
        } ElseIf $ZConvert($Extract(name, *-3, *), "U") = ".CLS" {
            Set files = files_$ListBuild(name)
        }
    }
    Do rs.Close()
    Set out = files
    Set ptr = 0
    While $ListNext(dirs, ptr, d) { Set out = out_..ClassFiles(d) }
    Quit out
}

/// Class source with its comments removed.
///
/// The distinction matters more than it looks. `RLM.LLM` and `RLM.Engine` both
/// carry a class comment *stating* that they hold no `%AI.*` reference, and a
/// naive text search reads that sentence as the very dependency it denies. A
/// comment cannot make a class fail to compile on a base IRIS; only code can. So
/// the check reads code, and the prose that documents the guarantee is allowed to
/// name the thing it is guaranteeing the absence of.
///
/// Strips `///` documentation, `//` line comments, `;` line comments and `/* */`
/// blocks. Deliberately crude: it may strip a `//` inside a string literal, which
/// can only lose coverage on a line no `%AI.` reference could survive on anyway,
/// and never the other way around.
ClassMethod CodeOnly(text As %String) As %String
{
    Set out = "", n = $Length(text, $Char(10))
    Set inBlock = 0
    For i = 1:1:n {
        Set line = $ZStrip($Piece(text, $Char(10), i), "<W")
        If inBlock {
            Set at = $Find(line, "*/")
            If at = 0 { Continue }
            Set line = $Extract(line, at, *)
            Set inBlock = 0
        }
        Set at = $Find(line, "/*")
        If at > 0 {
            Set rest = $Extract(line, at, *)
            Set line = $Extract(line, 1, at - 3)
            If $Find(rest, "*/") = 0 { Set inBlock = 1 }
        }
        If $Extract(line, 1, 3) = "///" { Continue }
        If $Extract(line, 1, 2) = "//" { Continue }
        If $Extract(line) = ";" { Continue }
        Set at = $Find(line, "//")
        If at > 0 { Set line = $Extract(line, 1, at - 3) }
        Set out = out_line_$Char(10)
    }
    Quit out
}

/// A whole file as a string. "" when it is absent, so a missing manifest fails an
/// assertion about its content rather than throwing.
ClassMethod ReadFile(path As %String) As %String
{
    If '##class(%File).Exists(path) { Quit "" }
    Set s = ##class(%Stream.FileCharacter).%New()
    If $$$ISERR(s.LinkToFile(path)) { Quit "" }
    Set out = ""
    While 's.AtEnd { Set out = out_s.Read(32000) }
    Quit out
}

}
