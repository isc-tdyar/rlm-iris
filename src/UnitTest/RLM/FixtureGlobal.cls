/// A global with a hand-counted structure, for the RLM.Source.Global tests.
///
/// Every figure the source reports is declared here as a class method, so a test
/// asserts against a number a person worked out rather than against a second
/// walk. A fixture that computed its own expectations would agree with any bug
/// the walk has.
///
/// The globals are process-private (`^||`), so two tests cannot collide and no
/// run leaves state in the namespace.
///
/// Structure of `^||RLMTest`, in `$ORDER` order -- numerics first in canonical
/// order, then strings collated:
///
/// ```text
/// ^||RLMTest(7,"z2",1)                = 2 chars
/// ^||RLMTest(42,"z1",1)               = 8 chars
/// ^||RLMTest("2019-11-04")            = 2 chars      <- value AND children
/// ^||RLMTest("2019-11-04","BOS-GEN",1)= 2 chars
/// ^||RLMTest("2019-11-04","BOS-GEN",2)= 5 chars
/// ^||RLMTest("2019-11-04","NYC-MEM",1)= 5 chars
/// ^||RLMTest("2019-11-04","x)y",1)    = 5 chars
/// ^||RLMTest("2020-03-11","BOS-GEN",1)= 8 chars
/// ^||RLMTest("a,b","q""z",1)          = 8 chars
/// ```
///
/// Chosen so that:
///
/// - level 1 mixes numeric and string subscripts, and level 2 and 3 include a
///   comma, a close paren and a double quote -- the subscripts that break any
///   reference built by string concatenation;
/// - one level-1 node holds a value *and* children, which is the case that
///   separates "has a value" from "has descendants";
/// - the nine values have lengths 2, 2, 2, 5, 5, 5, 8, 8, 8, so the mean is
///   exactly 5 and the population variance exactly 6;
/// - the child subtree sizes are 3, 3, 8, 3, 3, which normalized fanout entropy
///   scores at 0.935 -- above the even threshold without being uniform, so a
///   metric that returns a constant 1 fails.
///
/// `n` throughout is the *closed* subtree: the slice's own node plus every
/// descendant. That is what makes `parent.n = 1 + sum(child.n)` hold, and an
/// identity that holds at every level is what a test can assert without
/// restating the fixture.
Class UnitTest.RLM.FixtureGlobal Extends %RegisteredObject
{

/// The fixture global's name.
Parameter REF = "^||RLMTest";

/// The same structure with a hundred times the leaves under each level-1
/// subscript, for the assertion that peek size does not grow with store size.
Parameter BIGREF = "^||RLMBig";

/// One level-1 subscript with one child, for the metric that must be 0 when
/// there is nothing to divide.
Parameter ONEREF = "^||RLMOne";

/// One level-1 subscript holding 95% of the nodes, for the skewed-fanout score.
Parameter SKEWREF = "^||RLMSkew";

// ---- declared expectations, worked out by hand from the table above ----

/// Nodes in the closed subtree at the root: the 20 descendants plus the root
/// node itself. Counting the node itself is what makes the identity
/// `parent.n = 1 + sum(child.n)` hold at every level.
ClassMethod RootNodes() As %Integer
{
    Quit 21
}

ClassMethod RootChildren() As %Integer
{
    Quit 5
}

/// Nodes holding a value: eight leaves plus `^||RLMTest("2019-11-04")`.
ClassMethod RootDataNodes() As %Integer
{
    Quit 9
}

/// Nodes with descendants and no value: the root, four of the five level-1 nodes
/// -- `"2019-11-04"` is excluded because it holds a value as well -- and all
/// seven level-2 nodes. 1 + 4 + 7.
ClassMethod RootPointerNodes() As %Integer
{
    Quit 12
}

/// Subscript levels below the root that the walk reaches.
ClassMethod RootDepth() As %Integer
{
    Quit 3
}

/// 7 and 42.
ClassMethod RootSubNumeric() As %Integer
{
    Quit 2
}

/// "2019-11-04", "2020-03-11", "a,b".
ClassMethod RootSubString() As %Integer
{
    Quit 3
}

ClassMethod RootSubList() As %Integer
{
    Quit 0
}

/// (2+2+2+5+5+5+8+8+8) / 9.
ClassMethod ValueLenMean() As %Numeric
{
    Quit 5
}

/// Population standard deviation of the same nine lengths: variance is
/// (3*9 + 3*0 + 3*9) / 9 = 6.
ClassMethod ValueLenSd() As %Numeric
{
    Quit 6 ** 0.5
}

/// Level-1 subscripts in walk order, as `subscript|closed subtree node count`.
ClassMethod Children() As %List
{
    Quit $ListBuild("7|3", "42|3", "2019-11-04|8", "2020-03-11|3", "a,b|3")
}

/// Every subscript used anywhere in the fixture, for the round-trip test. The
/// last three are the ones that break naive quoting.
ClassMethod EverySubscript() As %List
{
    Quit $ListBuild(
        7, 42, "2019-11-04", "2020-03-11", "a,b",
        "z1", "z2", "BOS-GEN", "NYC-MEM", 1, 2,
        "x)y", "q""z")
}

/// Build every fixture global. Idempotent: each is killed first, so a test that
/// mutates one cannot leak into the next.
ClassMethod Build() As %Status
{
    Kill ^||RLMTest
    Set ^||RLMTest(7, "z2", 1) = ..Pad(2)
    Set ^||RLMTest(42, "z1", 1) = ..Pad(8)
    Set ^||RLMTest("2019-11-04") = ..Pad(2)
    Set ^||RLMTest("2019-11-04", "BOS-GEN", 1) = ..Pad(2)
    Set ^||RLMTest("2019-11-04", "BOS-GEN", 2) = ..Pad(5)
    Set ^||RLMTest("2019-11-04", "NYC-MEM", 1) = ..Pad(5)
    Set ^||RLMTest("2019-11-04", "x)y", 1) = ..Pad(5)
    Set ^||RLMTest("2020-03-11", "BOS-GEN", 1) = ..Pad(8)
    Set ^||RLMTest("a,b", "q""z", 1) = ..Pad(8)

    // Same five level-1 subscripts, a hundred leaves each. `children` is
    // therefore identical and only the counts differ, which is exactly the
    // comparison the peek-size assertion needs.
    Kill ^||RLMBig
    Set subs = $ListBuild(7, 42, "2019-11-04", "2020-03-11", "a,b")
    For i = 1:1:$ListLength(subs) {
        Set s = $ListGet(subs, i)
        For j = 1:1:100 {
            Set ^||RLMBig(s, "f"_(j # 7), j) = ..Pad(5)
        }
    }

    Kill ^||RLMOne
    Set ^||RLMOne("only", 1) = ..Pad(3)

    // 95 nodes under one child, 5 spread over five others.
    Kill ^||RLMSkew
    For j = 1:1:95 {
        Set ^||RLMSkew("hot", j) = ..Pad(3)
    }
    For j = 1:1:5 {
        Set ^||RLMSkew("cold"_j, 1) = ..Pad(3)
    }
    Quit $$$OK
}

/// A value of exactly `n` characters. `$Justify` rather than a literal, so the
/// declared value-length moments cannot drift from the data by a typo.
ClassMethod Pad(n As %Integer) As %String
{
    Quit $Translate($Justify("", n), " ", "v")
}

/// A value that appears at exactly one node, for the assertion that no stored
/// value reaches a peek or a prompt. Written by the caller, not by Build, so its
/// presence in the fixture is visible in the test that cares.
ClassMethod PlantSecret() As %String
{
    Set secret = "QUUXSENTINEL9137"
    Set ^||RLMTest("2019-11-04", "BOS-GEN", 3) = secret
    Quit secret
}

}
