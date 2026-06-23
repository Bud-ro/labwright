# labwright_runner

Runs a Labwright `Test` from a CLI entrypoint and persists the result as three
artifacts side by side: `record.json` (the complete record), a self-describing
`record.tdms` (group per phase, channel per measurement, with requirement refs
embedded so the `.tdms` alone is enough downstream), and `record.junit.xml` (so
runs surface natively in GitHub Actions / CI test UIs). It also provides the
distributed-CI dispatcher — `shardTests` spreads work across hardware-labeled
workers with redundancy, and `mergeRuns`/`mergeAll` merge redundant runs by
majority vote (ties → worst outcome) and flag flaky disagreements — plus
`tdmsToRecordJson` and the JUnit exporters for reconstructing/aggregating records.

Part of the Labwright monorepo · BSD-3-Clause.
