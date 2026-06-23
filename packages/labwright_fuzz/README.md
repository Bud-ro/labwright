# labwright_fuzz

An end-to-end DUT fuzzing harness: a `FuzzCampaign` drives seeded stimulus into
the device through a `FuzzProbe` oracle, under a **mandatory `SafetyEnvelope`**
(stimulus the envelope rejects is never applied — fuzzing must not damage
hardware) and a liveness watchdog (a hang counts as a failure). The first failure
is greedily **shrunk** to a minimal, deterministically replayable case, and can
be converted into a regular regression `Test`. Generators compose: scalars
(`doubleInRange`/`intInRange`), sequences (`listOf`), and grammar combinators
(`just`/`oneOf`) cover stateful command/protocol fuzzing such as
`listOf(oneOf([just(cmdA), just(cmdB)]))`.

Part of the Labwright monorepo · BSD-3-Clause.
