# Phase 0 Research: RLM.Source.Global

Everything below was measured in the `rlm-iris` container on IRIS 2026.1, not
inferred from documentation. Each finding names the decision it settles.

## R1 — Walking a subtree with a runtime-computed reference

**Decision**: build references with `$NAME(@g@(sub))` and walk with `$QUERY`
under indirection.

**Measured**:

```text
sub=[42]           ref=^||T(42)             back=[42]           match=1
sub=[2019-11-04]   ref=^||T("2019-11-04")   back=[2019-11-04]   match=1
sub=[a,b]          ref=^||T("a,b")          back=[a,b]          match=1
sub=[p)r]          ref=^||T("p)r")          back=[p)r]          match=1
sub=[q"z]          ref=^||T("q""z")         back=[q"z]          match=1
```

`$NAME` quotes and escapes the subscript itself, and `$QSUBSCRIPT(ref, 1)`
returns the original value for every case including the comma, the quote and the
close paren from the spec's edge cases. String concatenation to build a reference
would have had to reimplement that escaping, and getting it wrong means reading
a different node than the one named — which is worse than an error, because it
returns plausible figures for the wrong subtree.

**Rationale**: the round-trip is the FR-012 requirement, and it holds by
construction rather than by validation.

**Alternatives rejected**: manual quoting (`"^||T("""_sub_""")"`) fails on
embedded quotes; `%Library.GlobalEdit` was not needed for the walk.

## R2 — Scoping a `$QUERY` walk to one subtree

**Decision**: compare each visited reference against the parent reference with
its trailing `)` removed.

**Measured**: walking from `^||T("2019-11-04")` and testing
`$EXTRACT(q, 1, $LENGTH(root)) '= root` returned 0 descendants, because a child
reference is `^||T("2019-11-04","BOS-GEN",1)` and the parent is
`^||T("2019-11-04")` — the `)` is in the way. Comparing against the stem
`^||T("2019-11-04"` returned the correct 3 descendants at max depth 3.

**Rationale**: this is a one-character bug that silently reports every subtree as
empty, and every count in the report would then be 0 while the run still looked
successful. It gets its own test.

## R3 — Encoding a subscript as a slice token

**Decision**: hex-encode the subscript, two uppercase hex digits per character.

**Measured**:

```text
raw=[hostile:tok/en]  hex=[686F7374696C653A746F6B2F656E]  round-trips=1
hex contains : or / = 0
raw=[fac<233>lit]     hex=[666163E96C6974]                round-trips=1
```

A subscript is arbitrary text and may contain `:` or `/`, which are
`RLM.Slice`'s token and path separators. An unencoded token containing either
would be parsed as extra structure, and `RLM.Slice` would refuse a legitimate
child — or worse, resolve to a different one.

**Alternatives rejected**: Base64 round-trips correctly but its alphabet includes
`/`, so it collides with `PATHSEP` — verified, not assumed. `$ZCVT(s,"O","URL")`
percent-encodes but leaves `/` untouched by default. Hex has a 2x length cost and
is unreadable in a slice name, which is why the child's `label` carries the
readable subscript while the `token` carries hex.

## R4 — Classifying a subscript and a node

**Decision**: `$ISVALIDNUM(sub)` for canonical-numeric detection, `$DATA(ref)`
for data-versus-pointer, `$QLENGTH(ref)` for depth.

**Measured**: `$ISVALIDNUM("2019-11-04")` is 0 and `$ISVALIDNUM("42")` is 1, so
a date-shaped subscript classifies as a string, which is the useful answer.
`$DATA` returned 11 for a node with both a value and descendants and 1 for a leaf,
so `$DATA#10` distinguishes has-value and `$DATA\10` distinguishes has-children.

## R5 — Enumerating candidate globals for the allowlist

**Decision**: `^$GLOBAL` for existence and enumeration.

**Measured**: `$ORDER(^$GLOBAL(name))` returned `^%cspSession`,
`^%qHTMLElementD`, `^%qJavaMetaDictionary` — the system globals the spec's deny
list names, confirming the deny patterns match real names in a stock namespace.

**Note**: `%SYS.GlobalQuery_NameSpaceList()` also works (returned
`DeepSee.Cubes`, `DeepSee.FolderD`, ...) but returns names without the leading
`^`, so mixing the two produces an allowlist that matches nothing. Only `^$GLOBAL`
is used.

## R6 — Multi-line ObjectScript through a piped session

**Not a feature decision, a testing one.** Multi-line blocks with braces fail
with `<SYNTAX>` when piped into `iris session` line by line. Every probe here ran
as a compiled `.mac` routine copied in with `docker cp`. The same applies to any
future diagnostic, which is worth recording because the failure looks like a
language limitation rather than a transport one.

## Open question carried forward

SPEC §8 asks whether `%SYS.GlobalQuery` block estimates beat a capped walk for
the node count. Not resolved here and not needed: a capped walk is correct, and
FR-006 requires the cap be disclosed either way. If a block estimate is adopted
later it changes `Peek` internals only, and the tests written against reported
figures stay valid.
