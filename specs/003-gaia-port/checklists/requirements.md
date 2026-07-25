# Specification Quality Checklist: Port the gaia-iml prototype onto rlm-iris

**Purpose**: Validate specification completeness and quality before proceeding to
planning
**Created**: 2026-07-25
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

Two checklist items are honoured in spirit rather than literally, and the
deviation is deliberate rather than overlooked.

**"No implementation details" and "written for non-technical stakeholders."** The
deliverable of this feature _is_ a set of class names and method signatures. The
user of the feature is a developer, and the thing being specified is one library's
fitness as a dependency of one application. A version of this document that said
"the analysis component should read the store through a standard interface" would
be unverifiable — there would be no way to tell a passing port from a failing one.
So `Gaia.Source`, `RLM.LLM.Complete()` and `%AI.` appear by name, because they are
the requirement and not an implementation of it.

Success criteria stay outcome-shaped even so: SC-002 counts lines removed, SC-003
counts byte-identical runs, SC-005 counts occurrences of a string. Each is checkable
by someone who has never read the code.

**Two open questions were closed by decision rather than deferred to planning.**
`Triage`'s `pct_change > 100` scope becomes a slice name in the variability
dimension (FR-010), which the port must confirm is expressible — if the declared
breakpoints do not include the boundary the prototype used, that is a real finding
about the bucketing contract and belongs in `rlm-iris`. And `Gaia.RLM2` survives
(FR-012), because the reason it exists is comparison, and a comparison with one
side deleted proves nothing.
