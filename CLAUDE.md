# Agent Instructions

Labwright is an open, cross-platform, **Dart**-based ecosystem of tools aimed at
understanding and replacing the National Instruments (NI) suite of tools, namely
**LabVIEW and TestStand**.

Heavy emphasis is placed upon clean-room implementation. At no point should you
install any NI software. You should always follow NI's legal guidelines: https://www.ni.com/en/about-ni/legal.html
the most pressing being those around trademark: https://www.ni.com/en/about-ni/legal/trademarks-and-logo-guidelines.html

Using resources found on the web is fair game. Screenshots of these programs,
GitHub and other repositories with real example files paired with useful context,
wikis and blogs, etc. may all be used. We are NOT users of NI's software, so it is
fair game to liberate the whole stack.

## Current Focus

Total understanding of every single byte, and support for every version of every file format.
The RSRC reader and TestStand readers are most pressing here.

## Conventions

- **Privacy:** NEVER put the maintainer's real name in source, comments, commit
  messages, or docs. Refer to "the maintainer" / "the user" / "review feedback".
- **Performance:** Think about performance since it is incredibly important.
  The more performant the software, the more we can expand our corpus and fuzz
  the software. Also a lower memory footprint generally improves performance
  on top of improving stability.
- **No Hacks:** probe the FULL corpus before any factual claim
  about a format; mark undecoded byte ranges explicitly with TODOs to revisit; 
  never fabricate data; never overclaim ("not yet recovered/decoded", never "unrecoverable").
- **Commits:** commit ONLY your own files, by **explicit path**. Never
  `git add -A`/`-u`. Put `git commit` on its own line. 
- **PR descriptions:** write them with as little knowledge from the viewer
  required as possible — never reference the conversation that produced the
  work. Make it objective, non-contextual, pithy, and useful. The same rule
  applies to doc comments and other kinds of comments: they describe the code
  as it is, never the session, review, or brief that produced it.
- **Comments:** do not write comments unless explicitly asked. The only
  comment edits permitted on your own initiative are correcting an existing
  comment that is factually wrong, or deleting one. Names, enums, types and
  tests carry the meaning; corpus statistics, rationale and history do not
  belong in source. Lint/format directives and bare trailing `//` formatter
  hints are not comments for this purpose.
- **Cleanliness** Keep `dart analyze` clean and the relevant test suites green
  before committing. Run `./format.sh` (a thin wrapper over `dart format .`)
  so hand/agent edits match VS Code's format-on-save and diffs stay noise-free.
  Prefer small, reviewable PRs over large unfocused pushes. Keep note of test
  run times, and do not allow them to balloon.

## Code style

- We're dealing with a great deal of serialized/deserialized data. Ensure that
  when touching it we use `ByteData` or `Uint8List`. 
- Magic numbers are DANGEROUS. There are situations where it is okay, but generally
  you should catalogs constants using an enhanced `enum` with strong doc comments.

## Testing

For the pub workspace you can `dart analyze packages` and `dart test packages`.
You can also specify a specific package. The apps aren't under the workspace so
you'll need to analyze/test them separately.

Tests that read fetched data are tagged `corpus` and assume the data is there:
run the three fetch tools (`packages/labwright_rsrc_parse/tool/fetch_corpus.dart`,
`packages/labwright_seq/tool/fetch_seq_corpus.dart`,
`packages/labwright_rsrc_parse/tool/fetch_snippets.dart`) and then
`dart test -t corpus` / `flutter test --tags corpus`; without the data run
`dart test -x corpus` / `flutter test --exclude-tags corpus`, which is what
CI's regular jobs do. CI's `corpus` job runs only the tagged tests.

Make sure to run the appropriate snapshot tests when updating any parsers.
