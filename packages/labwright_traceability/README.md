# labwright_traceability

Links Labwright tests to the org's existing numbered, content-hashed JSON
requirements. Tests tag phases and measurements with `RequirementRef`s; this
package parses the requirements file (tolerant of several JSON shapes, with a
`lintRequirements` check for duplicate ids and missing hashes), then builds a
`TraceMatrix` reporting coverage, **hash drift** (a requirement changed since a
test pinned it), and references to unknown requirements. Render it as a human
report (`traceReport`) or machine-readable JSON (`traceMatrixToJson`) and gate CI
on a coverage threshold — consuming either a `record.json` or a self-describing
`.tdms`.

Part of the Labwright monorepo · BSD-3-Clause.
