/// Tests for the `path` argument on RLM.Source.Dimensions.
///
/// A table's columns are the same in every slice, so Table ignores the argument
/// and these tests pin that: adding a parameter must not change what an existing
/// source advertises. A hierarchical store is the opposite case -- the level-2
/// subscripts under one level-1 slice are not those under another -- so the
/// second half of this class proves the engine actually delivers the path rather
/// than dropping it on the way.
Class UnitTest.RLM.SourceDimPath Extends %UnitTest.TestCase
{

Method OnBeforeAllTests() As %Status
{
    Quit ##class(UnitTest.RLM.Widget).Populate()
}

/// The behaviour-preserving half. If these two disagree, every existing caller
/// that omits the argument is now getting a different answer than it did.
Method TestTableIgnoresThePath()
{
    Set src = ##class(RLM.Source.Table).%New("UnitTest.RLM.Widget", "Price")
    Do src.AddDimension("colour", "Colour")
    Do src.AddDimension("size", "Size")

    Set bare = src.Dimensions().%ToJSON()
    Set rooted = src.Dimensions("").%ToJSON()
    Set deep = src.Dimensions("colour:red").%ToJSON()

    Do $$$AssertEquals(bare, rooted, "no argument and an empty path agree")
    Do $$$AssertEquals(bare, deep, "a table's columns do not vary by slice")
}

/// The fixture source predates the argument and does not declare it. An
/// existing subclass must keep working without being edited, which is the
/// property that makes the change safe to land.
Method TestASourceThatIgnoresTheArgumentStillWorks()
{
    Set src = ##class(UnitTest.RLM.Fixture).%New()
    Do $$$AssertTrue($IsObject(src.Dimensions()), "still answers with no argument")
    Do $$$AssertTrue($IsObject(src.Dimensions("color:red")), "and with one")
}

/// The delivering half. UnitTest.RLM.FixturePathed records the path it was asked
/// with, so this asserts the value the engine passed rather than that the
/// signature merely compiles.
Method TestSliceResolvePassesTheParentPath()
{
    Set src = ##class(UnitTest.RLM.FixturePathed).%New()
    Do src.Forget()
    Set sc = ##class(RLM.Slice).Resolve(src, "s1:a/s2:x", .pred, .label)
    Do $$$AssertStatusOK(sc, "a two-level path resolves")
    Do $$$AssertEquals(pred, "s1:a/s2:x", "and yields the nested predicate")

    // Level 1 is looked up at the root; level 2 is looked up under level 1.
    Do $$$AssertEquals(src.AskedWith(1), "", "s1 asked at the root")
    Do $$$AssertEquals(src.AskedWith(2), "s1:a", "s2 asked under s1:a")
}

/// The failure this guards is not a refusal, it is a wrong answer: resolving
/// `s1:a/s2:x` against the root's dimensions would accept a token that only
/// exists under `s1:b` and then peek the wrong subtree.
Method TestATokenFromAnotherParentIsRefused()
{
    Set src = ##class(UnitTest.RLM.FixturePathed).%New()
    Set legal = ##class(RLM.Slice).Resolve(src, "s1:b/s2:y", .p1)
    Set wrong = ##class(RLM.Slice).Resolve(src, "s1:a/s2:y", .p2)
    Do $$$AssertStatusOK(legal, "y exists under b")
    Do $$$AssertStatusNotOK(wrong, "y does not exist under a")
}

Method TestEngineCandidatesAreComputedAtThePath()
{
    Set src = ##class(UnitTest.RLM.FixturePathed).%New()
    Set e = ##class(RLM.Engine).%New(src, ##class(RLM.LLM.Null).%New())
    Do src.Forget()
    Do e.Candidates("s1:a")
    Do $$$AssertEquals(src.AskedWith(1), "s1:a", "candidates asked under the slice")
}

Method TestPolicyChildrenAreComputedAtThePath()
{
    Set src = ##class(UnitTest.RLM.FixturePathed).%New()
    Do src.Forget()
    Set kids = ##class(RLM.Policy).Children(src, "s2", .sc, "s1:b")
    Do $$$AssertStatusOK(sc, "s2 has children under s1:b")
    Do $$$AssertEquals($ListToString(kids), "y,z", "and they are b's, not a's")
    Do $$$AssertEquals(src.AskedWith(1), "s1:b", "asked under the given path")
}

/// Whatever the menu advertises must resolve -- the existing Slice invariant,
/// restated for a store whose menu depends on where you are standing.
Method TestMenuAtAPathAdvertisesOnlyThatPathsChildren()
{
    Set src = ##class(UnitTest.RLM.FixturePathed).%New()
    Set menu = ##class(RLM.Slice).Menu(src, "s1:a")
    Do $$$AssertNotEquals($Find(menu, "s2:x"), 0, "x is under a")
    Do $$$AssertEquals($Find(menu, "s2:y"), 0, "y is not")
}

}
