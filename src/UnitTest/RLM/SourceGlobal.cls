/// Tests for the global source's walk, dimensions and arithmetic.
///
/// The store here has no schema, which is the whole point: every figure comes
/// from walking subscripts, and every expectation comes from
/// UnitTest.RLM.FixtureGlobal, where a person wrote the number down. Comparing a
/// walk against a second walk would agree with any bug the first one has.
Class UnitTest.RLM.SourceGlobal Extends %UnitTest.TestCase
{

Property Source As RLM.Source.Global;

Method OnBeforeOneTest(testname As %String) As %Status
{
    Do ##class(UnitTest.RLM.FixtureGlobal).Build()
    Set ..Source = ##class(RLM.Source.Global).%New(
        ##class(UnitTest.RLM.FixtureGlobal).#REF, "^||RLM*", .sc)
    Quit sc
}

/// Children are the subscripts that are there, in walk order, each with a hex
/// token and the raw subscript as its label. The token is what the model names
/// and the label is what it reads.
Method TestDimensionsEnumerateTheFirstLevel()
{
    Set dims = ..Source.Dimensions()
    Do $$$AssertTrue(dims.%IsDefined("s1"), "level 1 is a dimension")
    Set kids = dims.%Get("s1").children
    Do $$$AssertEquals(kids.%Size(), 5, "five level-1 subscripts")

    Set labels = "", it = kids.%GetIterator()
    While it.%GetNext(, .child) {
        Set labels = labels_$Select(labels="":"", 1:"|")_child.label
    }
    Do $$$AssertEquals(labels, "7|42|2019-11-04|2020-03-11|a,b", "raw subscripts, walk order")
}

/// Hex, not the raw subscript, because a subscript may contain `:` or `/` -- the
/// slice grammar's own separators. An unencoded token carrying either would be
/// parsed as extra structure and resolve to a different slice.
Method TestTokensAreHexAndCarryNoSeparator()
{
    Set kids = ..Source.Dimensions().%Get("s1").children
    Set it = kids.%GetIterator()
    While it.%GetNext(, .child) {
        Set kept = $ZStrip(child.token, "*E", "", "0123456789ABCDEF")
        Do $$$AssertEquals(kept, child.token, "token "_child.token_" is hex")
        Do $$$AssertEquals($Length(child.token) # 2, 0, "and an even number of digits")
        Do $$$AssertEquals(child.token [ ":", 0, "no token separator in "_child.token)
        Do $$$AssertEquals(child.token [ "/", 0, "no path separator in "_child.token)
    }
}

/// Every subscript in the fixture, including the comma, the close paren and the
/// double quote. These are the cases that break a reference built by
/// concatenation, and the failure is a read of the wrong node rather than an
/// error.
Method TestEverySubscriptRoundTrips()
{
    Set subs = ##class(UnitTest.RLM.FixtureGlobal).EverySubscript()
    Set ptr = 0
    While $ListNext(subs, ptr, sub) {
        Set hex = ##class(RLM.Source.Global).Encode(sub)
        Set back = ##class(RLM.Source.Global).Decode(hex)
        Do $$$AssertEquals(back, sub, "round-trips: ["_sub_"]")
        Do $$$AssertEquals(hex [ ":", 0, "no colon in hex of ["_sub_"]")
        Do $$$AssertEquals(hex [ "/", 0, "no slash in hex of ["_sub_"]")
    }
}

/// A subscript that would collide with the grammar if it were carried raw. Not
/// in the fixture because it cannot be: the point is the encoding, and the
/// encoding is what makes it storable in a slice name at all.
Method TestAHostileSubscriptRoundTrips()
{
    Set hostile = "hostile:tok/en"
    Set hex = ##class(RLM.Source.Global).Encode(hostile)
    Do $$$AssertEquals(##class(RLM.Source.Global).Decode(hex), hostile, "round-trips")
    Do $$$AssertEquals(hex [ ":", 0, "and carries no separator")
}

Method TestRootPeekMatchesTheHandCount()
{
    Set f = "UnitTest.RLM.FixtureGlobal"
    Set peek = ..Source.Peek("")
    Do $$$AssertEquals(peek.%Get("error"), "", "no error")
    Do $$$AssertEquals(peek.n, $classmethod(f, "RootNodes"), "node count")
    Do $$$AssertEquals(peek.children, $classmethod(f, "RootChildren"), "children")
    Do $$$AssertEquals(peek.dataNodes, $classmethod(f, "RootDataNodes"), "data nodes")
    Do $$$AssertEquals(peek.pointerNodes, $classmethod(f, "RootPointerNodes"), "pointer nodes")
    Do $$$AssertEquals(peek.depth, $classmethod(f, "RootDepth"), "depth")
    Do $$$AssertEquals(peek.capped, 0, "the fixture fits under the cap")
}

/// Every node is either a data node or a pointer node, never both and never
/// neither. A walk that classified one node twice would report a total that
/// looks right and a node kind mix that does not.
Method TestNodeKindsPartitionTheWalk()
{
    Set peek = ..Source.Peek("")
    Do $$$AssertEquals(peek.dataNodes + peek.pointerNodes, peek.n, "kinds partition n")
}

/// The identity that lets a report's arithmetic close: a parent's count is its
/// own node plus its children's closed subtrees. If this fails, every figure in
/// a decomposition is individually plausible and collectively wrong.
Method TestChildrenSumToTheParent()
{
    Set root = ..Source.Peek("")
    Set kids = ..Source.Dimensions().%Get("s1").children
    Set sum = 0, it = kids.%GetIterator()
    While it.%GetNext(, .child) {
        Set sc = ##class(RLM.Slice).Resolve(..Source, "s1:"_child.token, .pred, .label)
        Do $$$AssertStatusOK(sc, "s1:"_child.label_" resolves")
        Set sum = sum + ..Source.Peek(pred).n
    }
    Do $$$AssertEquals(sum + 1, root.n, "children plus the root's own node")
    Do $$$AssertEquals(..Source.NullCount("", "s1"), 0, "a walked dimension misses nothing")
}

/// Each child's count against the number written down for it, so a walk that is
/// merely self-consistent still fails.
Method TestEachChildMatchesItsDeclaredCount()
{
    Set decl = ##class(UnitTest.RLM.FixtureGlobal).Children()
    Set ptr = 0
    While $ListNext(decl, ptr, row) {
        Set sub = $Piece(row, "|", 1), want = $Piece(row, "|", 2)
        Set pred = ..Source.Predicate($ListBuild("s1:"_##class(RLM.Source.Global).Encode(sub)))
        Do $$$AssertEquals(..Source.Peek(pred).n, +want, "["_sub_"] holds "_want)
    }
}

/// The regression from research.md R2. A scoped walk compared against the parent
/// reference including its trailing `)` finds nothing, reports 0 for every
/// subtree, and the run still looks successful.
Method TestScopedWalkDoesNotReturnZero()
{
    Set pred = ..Source.Predicate($ListBuild("s1:"_##class(RLM.Source.Global).Encode("2019-11-04")))
    Set peek = ..Source.Peek(pred)
    Do $$$AssertTrue(peek.n > 1, "the subtree is not empty")
    Do $$$AssertEquals(peek.n, 8, "and it is exactly the declared size")
}

/// A global's level-2 subscripts depend on which level-1 slice you are in. This
/// is the property the Dimensions(path) seam exists for.
Method TestDimensionsAreComputedAtThePath()
{
    Set e = ##class(RLM.Source.Global).Encode("2019-11-04")
    Set f = ##class(RLM.Source.Global).Encode("a,b")
    Set inNov = ..Labels(..Source.Dimensions("s1:"_e).%Get("s2").children)
    Set inAb = ..Labels(..Source.Dimensions("s1:"_f).%Get("s2").children)
    Do $$$AssertEquals(inNov, "BOS-GEN|NYC-MEM|x)y", "November's facilities")
    Do $$$AssertEquals(inAb, "q""z", "and a,b's, which are not the same")
}

/// A level-2 token belonging to a different parent must be refused, not resolved
/// against the wrong subtree. The wrong-subtree outcome is the dangerous one: it
/// returns real figures about a population nobody asked about.
Method TestATokenFromAnotherParentIsRefused()
{
    Set nov = ##class(RLM.Source.Global).Encode("2019-11-04")
    Set ab = ##class(RLM.Source.Global).Encode("a,b")
    Set bos = ##class(RLM.Source.Global).Encode("BOS-GEN")
    Set legal = ##class(RLM.Slice).Resolve(..Source, "s1:"_nov_"/s2:"_bos, .p1)
    Set wrong = ##class(RLM.Slice).Resolve(..Source, "s1:"_ab_"/s2:"_bos, .p2)
    Do $$$AssertStatusOK(legal, "BOS-GEN is under 2019-11-04")
    Do $$$AssertStatusNotOK(wrong, "BOS-GEN is not under a,b")
}

/// The Constitution II case. A token the store never enumerated cannot become a
/// predicate, so there is no place for a model to write one.
Method TestAFabricatedTokenIsRefused()
{
    Set made = ##class(RLM.Source.Global).Encode("NO-SUCH-SUBSCRIPT")
    Set sc = ##class(RLM.Slice).Resolve(..Source, "s1:"_made, .pred, .label)
    Do $$$AssertStatusNotOK(sc, "a subscript that does not exist is refused")
    Set why = $System.Status.GetErrorText(sc)
    Do $$$AssertNotEquals($Find(why, "dimension"), 0, "and the refusal carries the grammar")
}

/// Not hex at all, and hex of the wrong length. Both are refusals rather than
/// decode failures, because the token never matches an enumerated child.
Method TestAMalformedTokenIsRefused()
{
    Do $$$AssertStatusNotOK(##class(RLM.Slice).Resolve(..Source, "s1:zzz", .p1), "not hex")
    Do $$$AssertStatusNotOK(##class(RLM.Slice).Resolve(..Source, "s1:4", .p2), "odd length")
}

/// A deeper slice narrows further, and the count is that subtree's.
Method TestNestedSliceNarrowsFurther()
{
    Set nov = ##class(RLM.Source.Global).Encode("2019-11-04")
    Set bos = ##class(RLM.Source.Global).Encode("BOS-GEN")
    Do ##class(RLM.Slice).Resolve(..Source, "s1:"_nov_"/s2:"_bos, .pred, .label)
    Set peek = ..Source.Peek(pred)
    Do $$$AssertEquals(peek.n, 3, "BOS-GEN in November: its node and two leaves")
    Do $$$AssertEquals(label, "2019-11-04 / BOS-GEN", "labelled with raw subscripts")
}

/// A slice of a global that is not there is empty, not an error. A namespace
/// where the data has not arrived yet must produce a report saying so.
Method TestAnAbsentGlobalPeeksToZero()
{
    Set src = ##class(RLM.Source.Global).%New("^||RLMNoSuch", "^||RLM*", .sc)
    Do $$$AssertStatusOK(sc, "allowed and absent")
    Set peek = src.Peek("")
    Do $$$AssertEquals(peek.n, 0, "no nodes")
    Do $$$AssertEquals(peek.children, 0, "no children")
    Do $$$AssertEquals(peek.capped, 0, "and nothing was truncated")
}

/// Describe names every figure it emits. A model asked to quote a number it was
/// given positionally quotes the wrong one.
Method TestDescribeIsSelfLabelling()
{
    Set peek = ..Source.Peek("")
    Set text = ..Source.Describe("^||RLMTest", peek)
    Do $$$AssertNotEquals($Find(text, "nodes"), 0, "labels the count")
    Do $$$AssertNotEquals($Find(text, "children"), 0, "labels the children")
    Do $$$AssertNotEquals($Find(text, "21"), 0, "and carries the figure")
}

/// A refused source does not exist. `%New` discards the instance when `%OnNew`
/// returns an error, so there is no object to walk -- which is a stronger
/// guarantee than an object that politely declines, and the reason the gate lives
/// in the constructor.
Method TestARefusedSourceCannotBeWalked()
{
    Set src = ##class(RLM.Source.Global).%New("^ROUTINE", "^*", .sc)
    Do $$$AssertStatusNotOK(sc, "refused at construction")
    Do $$$AssertNotTrue($IsObject(src), "and no source was handed back")

    // A source that was never constructed cannot be walked at all; one built
    // without a ref -- the shape %New would return if it ever stopped
    // discarding -- errors on every peek rather than reading.
    Set bare = ##class(RLM.Source.Global).%New("^RLMNoSuchXYZ", "^RLM*", .sc2)
    Do $$$AssertStatusOK(sc2, "a legitimate source for contrast")
    Set bare.GlobalRef = ""
    Do $$$AssertNotEquals(bare.Peek("").%Get("error"), "", "and a ref-less peek errors")
}

/// Pipe-joined child labels, so an assertion reads as the list a person expects.
ClassMethod Labels(children As %DynamicArray) As %String
{
    Set out = "", it = children.%GetIterator()
    While it.%GetNext(, .child) {
        Set out = out_$Select(out="":"", 1:"|")_child.label
    }
    Quit out
}

}
