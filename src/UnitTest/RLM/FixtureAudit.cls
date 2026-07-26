/// A persistent class with %SYS.Audit's column shape and a known row distribution,
/// for the RLM.Source.Audit tests.
///
/// A fixture rather than the real audit log, because the real one cannot be written
/// to on demand: an audit row appears when the system decides to write one, and a
/// test that provoked real events would assert against whatever else the container
/// happened to log at the same moment. The columns are named exactly as %SYS.Audit
/// names them, so the same source class works over both -- which is what the
/// end-to-end test checks.
///
/// Every expectation is a class method returning a number worked out by hand. A
/// fixture that computed its own expectations would agree with any bug in the code
/// under test.
///
/// The planted distribution, 10 rows:
///
/// ```text
/// EventSource  EventType          Username  Namespace
/// -----------  -----------------  --------  ---------
/// %System      Login              alice     USER
/// %System      Login              alice     USER
/// %System      Login              bob       USER
/// %System      LoginFailure       bob       USER
/// %System      LoginFailure       carol     %SYS
/// %SQL         DynamicStatement   alice     USER
/// %SQL         DynamicStatement   alice     %SYS
/// %SQL         DynamicStatement   dave      USER
/// %Ensemble    Start              dave      %SYS
/// %Ensemble    Stop               dave      USER
/// ```
///
/// Chosen so that: users are 4/2/1/3 (uneven, and alice is unambiguously dominant);
/// namespaces are 7 and 3; `%Ensemble` carries exactly two event types one row each,
/// so an even split scores 1; and `Login` carries one type only, so a single-type
/// slice scores 0.
Class UnitTest.RLM.FixtureAudit Extends %Persistent
{

Property EventSource As %String;

Property EventType As %String;

Property Username As %String;

Property Namespace As %String;

/// Audit payload. No source may read it -- the marker is what proves that.
Property EventData As %String(MAXLEN = 500);

/// Free text. Same.
Property Description As %String(MAXLEN = 500);

/// Client and connection detail. Same.
Property UserInfo As %String(MAXLEN = 500);

ClassMethod Total() As %Integer
{
    Quit 10
}

ClassMethod Users() As %Integer
{
    Quit 4
}

ClassMethod Namespaces() As %Integer
{
    Quit 2
}

/// The user holding the most rows, and how many.
ClassMethod Dominant() As %String
{
    Quit "alice"
}

ClassMethod DominantCount() As %Integer
{
    Quit 4
}

/// The marker planted in every content column.
ClassMethod Marker() As %String
{
    Quit "SECRET-AUDIT-91be"
}

ClassMethod Rows() As %List
{
    Quit $ListBuild(
        "%System|Login|alice|USER", "%System|Login|alice|USER",
        "%System|Login|bob|USER", "%System|LoginFailure|bob|USER",
        "%System|LoginFailure|carol|%SYS",
        "%SQL|DynamicStatement|alice|USER", "%SQL|DynamicStatement|alice|%SYS",
        "%SQL|DynamicStatement|dave|USER",
        "%Ensemble|Start|dave|%SYS", "%Ensemble|Stop|dave|USER")
}

ClassMethod Build() As %Status
{
    Do ..Wipe()
    Set ptr = 0
    While $ListNext(..Rows(), ptr, row) {
        Set r = ..%New()
        Set r.EventSource = $Piece(row, "|", 1)
        Set r.EventType = $Piece(row, "|", 2)
        Set r.Username = $Piece(row, "|", 3)
        Set r.Namespace = $Piece(row, "|", 4)
        Set r.EventData = ..Marker()_" payload"
        Set r.Description = ..Marker()_" description"
        Set r.UserInfo = ..Marker()_" userinfo"
        Set sc = r.%Save()
        If $$$ISERR(sc) { Quit }
    }
    Quit $Get(sc, $$$OK)
}

ClassMethod Wipe()
{
    Do ..%KillExtent()
}

}
