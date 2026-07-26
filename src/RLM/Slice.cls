/// The slice-name grammar: `dim:token[/dim:token...]`.
///
/// This class is the security boundary. A model names a slice; Resolve either
/// translates that name into a store predicate or refuses it. Because the
/// predicate is built here from a whitelist rather than parsed out of the
/// model's text, a hostile or confused slice name is indistinguishable from a
/// misspelled one: both are simply not in Dimensions(), and both are refused.
///
/// It fails closed on purpose, and every refusal returns the grammar with it --
/// a bare "invalid" makes a model retry at random, and random retries are what
/// exhaust a call budget.
Class RLM.Slice Extends %RegisteredObject
{

/// Longest path a slice name may have. Each component must name a distinct
/// dimension, so this also bounds how many dimensions a store can usefully
/// declare before deeper paths become unreachable.
Parameter MAXDEPTH = 3;

/// Separator between path components.
Parameter PATHSEP = "/";

/// Separator between a dimension and its token.
Parameter TOKENSEP = ":";

/// Resolve a slice name against a Source.
///
/// On success `predicate` is what the store needs to restrict the slice and
/// `label` is a human-readable name for the report. On failure both are
/// undefined and the status carries the reason plus the grammar.
ClassMethod Resolve(
	source As RLM.Source,
	path As %String = "",
	Output predicate As %String,
	Output label As %String) As %Status
{
    Set predicate = "", label = ""

    // The empty path is the whole store, not an error: it is where every
    // decomposition starts.
    If $ZStrip(path, "<>W") = "" {
        Set label = source.Name
        Quit $$$OK
    }

    Set depth = $Length(path, ..#PATHSEP)
    If depth > ..#MAXDEPTH {
        Quit ..Refuse("a slice name may nest at most "_..#MAXDEPTH_" levels", source)
    }

    Set components = "", labels = "", seen = "", sofar = ""
    For i = 1:1:depth {
        // Each component is checked against the moves legal *where it stands*,
        // not against the root's. For a hierarchical store those differ, and
        // checking level 2 against the root would accept a token belonging to a
        // sibling subtree -- a wrong answer rather than a refusal.
        Set dims = source.Dimensions(sofar)
        If '$IsObject(dims) { Quit }

        Set comp = $ZStrip($Piece(path, ..#PATHSEP, i), "<>W")

        // Exactly one separator. Zero means it is not a slice name; two or more
        // means something is trying to smuggle structure through.
        If $Length(comp, ..#TOKENSEP) '= 2 {
            Quit
        }
        Set dim = $Piece(comp, ..#TOKENSEP, 1)
        Set token = $Piece(comp, ..#TOKENSEP, 2)
        If (dim = "") || (token = "") { Quit }

        // One dimension per path. Splitting twice on the same dimension cannot
        // narrow anything, so allowing it only burns budget.
        If $ListFind(seen, dim) { Set dim = "", token = "" Quit }

        If 'dims.%IsDefined(dim) { Set dim = "" Quit }
        Set spec = dims.%Get(dim)

        Set childLabel = ..ChildLabel(spec, token)
        If childLabel = "" { Set token = "" Quit }

        Set seen = seen_$ListBuild(dim)
        Set components = components_$ListBuild(dim_..#TOKENSEP_token)
        Set labels = labels_$ListBuild(childLabel)
        Set sofar = sofar_$Select(sofar="":"", 1:..#PATHSEP)_dim_..#TOKENSEP_token
    }

    // Any of the loop's guards leaves the path partially consumed. Comparing
    // counts catches every one of them without a flag per failure mode.
    If $ListLength(components) '= depth {
        Quit ..Refuse("'"_path_"' is not a slice this store offers", source)
    }

    Set predicate = source.Predicate(components)
    Set label = $ListToString(labels, " / ")
    Quit $$$OK
}

/// The label of a dimension's child, or "" if the token is not one of its
/// children. Returning "" rather than a status keeps Resolve's loop flat.
ClassMethod ChildLabel(spec As %DynamicObject, token As %String) As %String
{
    If '$IsObject(spec) { Quit "" }
    If '$IsObject(spec.children) { Quit "" }
    Set it = spec.children.%GetIterator()
    While it.%GetNext(, .child) {
        If child.token = token {
            Quit
        }
    }
    If '$Data(child) || '$IsObject(child) { Quit "" }
    If child.token '= token { Quit "" }
    Quit $Select(child.label'="":child.label, 1:token)
}

/// A refusal carrying the grammar. The attached menu is what stops a refused
/// model from guessing.
ClassMethod Refuse(reason As %String, source As RLM.Source) As %Status
{
    Quit $$$ERROR($$$GeneralError, reason_$Char(10)_..MenuBrief(source))
}

/// One-line statement of the grammar.
ClassMethod MenuBrief(source As RLM.Source) As %String
{
    Quit "Slices are named `dimension"_..#TOKENSEP_"child` and nest with `"
        _..#PATHSEP_"` up to "_..#MAXDEPTH_" levels. "
        _"Each dimension may appear at most once in a name."
}

/// The full menu of legal slice names.
///
/// Whatever this advertises must resolve; offering a model a move it will then
/// be refused for making is worse than offering nothing. That is why `path` is
/// here: for a store whose children vary by parent, a menu built at the root
/// advertises moves that are illegal below it.
ClassMethod Menu(
	source As RLM.Source,
	path As %String = "") As %String
{
    Set out = ..MenuBrief(source)_$Char(10)
    Set dims = source.Dimensions(path)
    If '$IsObject(dims) { Quit out }
    Set it = dims.%GetIterator()
    While it.%GetNext(.dim, .spec) {
        Set out = out_$Char(10)_dim_" ("_$Select(spec.label'="":spec.label, 1:dim)_"):"_$Char(10)
        If '$IsObject(spec.children) { Continue }
        Set kids = spec.children.%GetIterator()
        While kids.%GetNext(, .child) {
            Set out = out_"  "_dim_..#TOKENSEP_child.token
                _$Select(child.label'="":" - "_child.label, 1:"")_$Char(10)
        }
    }
    Quit out
}

}
