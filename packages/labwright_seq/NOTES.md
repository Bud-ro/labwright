# labwright_seq — decode notes

Findings that don't have a natural home in code. The XML and INI readers reach the typed
`SeqFile` model; the **binary TOF1** record grammar is the open frontier (see below).
Counts are corpus-probed (288 binary, 26 XML, 58 INI at last fetch); re-probe before
relying on an exact figure.

## Binary TOF1 record grammar — current recon (still undecoded)
The body inflates and the string pools / name table / object names / module paths / ID#
refs / expressions / literals all extract, but the **record grammar that links them into
the hierarchical PropertyObject model is not yet decoded**. What is known:

- `leadingWords[2]` (3rd u32) is a **constant 1** across all 288 binary files. The record
  stream opens by referencing the name pool by index: `word[2]==1` selects `name[1] == 'Data'`.
- `leadingWords[1]` is **not** a two-valued `{16,118}` layout selector (that earlier
  hypothesis was overfit to the small NI-example set and is refuted). It takes many values
  (16, 18, 20, 118, 256, 272, 276, …). The record-prefix structure past the header is
  undecoded; `leadingWords[0]`'s meaning is likewise open.
- Name pool: the name table is **never reliably the largest** segment, and the largest
  segment is **not reliably the expression table** (both refuted). Expression-like strings
  live in a segment other than the name table.
- The name scaffold `[SequenceFileData, Data, Objs, Seq, [0]]` is dominant (>95%) but **not
  universal** — other roots occur, e.g. `[…, Data, Attributes, Obj, TestStand]`.
- Candidate record shape: an object-record triplet `[u32 name-index][u32 field][u32 count]`
  preceded by a `0x00000000`/`0xffffffff` boundary. It is a real but **noisy** signal —
  real-name indices match ~86% vs a ~40% control — so it corroborates the record shape but
  is not yet clean enough to extract objects byte-exactly.

## INI reader
- `_IniBuilder.build` produces members in a deterministic order: instance `DEF` declarations
  first (authoritative + typed), then value-only members, then members implied by deeper
  sections, then members inherited from the type but never mentioned.
- The `if (eq < 0) continue;` in `parseIniSeq` is purely defensive: no section line lacks a
  ` = ` separator in any corpus INI file (verified and guarded by a corpus test).
