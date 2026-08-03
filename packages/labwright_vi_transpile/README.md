# labwright_vi_transpile

The **VI-to-Dart type model**: what a LabVIEW VI's data types become in Dart.
Input is a VI's consolidated type pool (`VCTP`) as decoded by
`labwright_rsrc_parse`; output is, per pool entry, a Dart representation, a
"not a dataflow value" verdict, or a documented review item. No code generator
lives here yet.

Every number below is a census over the pinned 7,524-VI corpus
(`packages/labwright_rsrc_parse/corpus/vi`, 7,490 of which carry a type pool),
totalling **551,681 type descriptors**. `test/corpus_type_sweep_test.dart`
re-derives them on every run and fails if any code falls outside the tables.

| bucket | descriptors | share |
| --- | --- | --- |
| mapped to a Dart type | 390,758 | 70.8% |
| not a dataflow value (`kInternalTypeCodes`) | 151,333 | 27.4% |
| review list (`kUnmappedTypeCodes`) | 9,563 | 1.7% |
| descriptor did not frame | 27 | <0.01% |

## Numerics

Width is load-bearing: a U32 `a + b` truncates at 32 bits, so a digest that
carries into bit 32 is simply wrong. `LvNumericKind.wrap` is the renormalizing
expression a generator wraps every arithmetic result in.

| LabVIEW | corpus | Dart carrier | `wrap('a + b')` | array storage | hazards |
| --- | --- | --- | --- | --- | --- |
| U8 | 5,845 | `int` | `(a + b) & 0xFF` | `Uint8List` | — |
| U16 | 7,127 | `int` | `(a + b) & 0xFFFF` | `Uint16List` | — |
| U32 | 19,261 | `int` | `(a + b) & 0xFFFFFFFF` | `Uint32List` | — |
| U64 | 2,676 | `int` (raw bits) | *identity* | `Uint64List` | compare, `~/`/`%`, `>>`, formatting |
| I8 | 2,902 | `int` | `(a + b) << 56 >> 56` | `Int8List` | — |
| I16 | 8,342 | `int` | `(a + b) << 48 >> 48` | `Int16List` | — |
| I32 | 32,827 | `int` | `(a + b) << 32 >> 32` | `Int32List` | — |
| I64 | 791 | `int` | *identity* | `Int64List` | — |
| SGL | 753 | `double` | `(Float32List(1)..[0] = a + b)[0]` | `Float32List` | binary32 narrowing |
| DBL | 8,372 | `double` | *identity* | `Float64List` | — |

Masked unsigned values are non-negative, so `<`, `~/` and `>>` are already
exact on U8/U16/U32; Dart's `int` *is* an I64, so I64 needs nothing. **U64 is
the exception**: it needs all 64 bits of the carrier, so `+ - * & | ^ << ~`
still wrap correctly (two's complement is sign-agnostic) but comparison,
division, `>>` and `toString` read the pattern as signed. Each wrong operator
and its correct form is enumerated in `LvArithmeticHazard`.

The model targets the Dart **native** runtime. On the web compilers `int` is a
binary64 double with no wraparound, so none of these expressions hold there.

## Arrays

A 1-D array is the element's exact-width storage — a `dart:typed_data` list
for a numeric element, `List<T>` otherwise (Dart has no typed list for `bool`,
`String`, records, or the runtime handle types). The corpus holds 818 boolean
arrays and 9,468 string arrays, so `List<T>` is not a corner case.

Multi-dimensional arrays are `LvArrayNd<Storage>`: a **flat, row-major** typed
list plus a `Uint32List` of dimension lengths. LabVIEW arrays are rectangular,
so a nested `List<Uint8List>` would admit ragged shapes LabVIEW forbids and add
an indirection per row. Corpus dimensionality: 30,329 × 1-D, 1,173 × 2-D,
132 × 3-D, nothing deeper; no array whose element is itself an array.
(MD5's pool, for example, holds two 2-D I32 index tables and 1-D arrays of U8
and U32.)

**Growth rule — grow in a builder, convert at the boundary.** LabVIEW arrays
resize as a diagram appends to them; a typed list is fixed-length. So:

- every array-typed wire, terminal and signature position holds the final
  storage — nothing else ever appears in a type;
- a node that appends (Build Array, Insert Into Array, an auto-indexing output
  tunnel) grows a `List<E>` local that never escapes the node or loop owning it;
- that builder is converted **exactly once**, where the value leaves it, by
  `lvArrayFreeze` (`Uint8List.fromList(acc)`), so appending stays amortized
  O(1) and the conversion is a single bulk copy.

In-place element writes (Replace Array Subset) need no builder.

Array dimension words are the variable-length sentinel `0xFFFFFFFF` in 32,956
of 33,071 cases. The other 115 carry bit 31 set over a small value
(`0x80000001`, `0x80000400`, `0x80002850`, …); that encoding is **not decoded**,
so those arrays are still modelled as dynamically sized. See the review list.

## Clusters, typedefs, enums

**Identity is structural, not nominal.** A cluster's name is only the preferred
spelling: the corpus reuses 1,460 distinct names across 36,977 named clusters
(`error out` 6,388 times, `Cluster` 328), so two clusters share a generated
class only when their member types and member names agree. Collision-suffixing
is the generator's job.

- **Named cluster** → a nominal Dart class named by `lvClassName`.
- **Anonymous cluster** (62,368 of 99,345 have no name) → a Dart **record**:
  named fields when every member has a distinct sanitizable name
  (`({double volts, String serialNumber})`), positional otherwise
  (`(double, int)`). A record's identity is structural, exactly like an unnamed
  cluster's, and costs no generated declaration.
- **Typedef** (`0xf1`) → nominal only when its base is a cluster or an enum,
  which need a declaration anyway; a typedef of a scalar, string or array is
  transparent. Corpus typedef bases: cluster 19,890, enumU16 5,548, U64 1,347,
  enumU32 1,053, refnum 934, and 15 further kinds; 20 of 31,060 typedef
  descriptors expose no base and are unmapped.
- **Enum** → a generated Dart `enum` over the decoded item labels, sized U8 /
  U16 / U32; an enum whose labels did not decode still maps, with a note.

## Error clusters

Detection requires **both** the member types and the member names: three
members typed `{boolean, I32 or U32, string}` and named `status` / `code` /
`source`. Corpus, over 99,345 clusters:

- 23,754 match — 23,381 with an I32 `code` and **373 with a U32 `code`**, both
  genuine error clusters;
- types alone would additionally take 242 `{boolean, I32, string}` clusters
  whose members carry no recovered names;
- names alone would additionally take 6 clusters of **three booleans** named
  status/code/source, which are not error clusters;
- 2-of-3 near misses are ordinary user clusters (`control`/`shift`/`key`,
  `active`/`accessScope`/`code`) and stay ordinary.

Both carrying modes are modelled from the start because they change function
signatures (`LvErrorMode`, `lvSignature`):

- `exceptions` (**default**) — error terminals are elided from the signature and
  a set `status` becomes a thrown `LvError`. What a Dart caller expects, and it
  collapses a diagram's error-case structures into ordinary control flow.
- `threaded` (**opt-in**) — error terminals stay first-class `LvError` values,
  preserving LabVIEW's behaviour that a node with an incoming error does
  nothing and passes it through.

Connector-pane terminal **direction** is not recovered by the reader, so
`lvSignature` models which terminals survive and how the error travels, not the
input/output split.

## Other value types

| LabVIEW | corpus | Dart |
| --- | --- | --- |
| void (`0x00`) | 12,571 | `void` |
| boolean (`0x21`) | 45,799 | `bool` |
| string (`0x30`), C string (`0x34`) | 55,325 / 113 | `String`, Latin-1 code units |
| path (`0x32`) | 10,668 | `LvPath` |
| refnum (`0x70`) | 51,615 | `LvRefnum` (opaque) |
| variant (`0x53`) | 4,579 | `LvVariant` (opaque) |

A LabVIEW string is a length-counted **byte** sequence with no encoding
attached, so the carrier is a Dart `String` whose code units are those bytes.
Latin-1 round-trips every byte 0..255 exactly; reading the bytes back is
`latin1.encode(s)`, never `utf8.encode(s)`. Interpreting them as UTF-8 text is
the caller's decision, not the translation's.

Refnum descriptors carry a discriminator in their first interior `u16`, taking
17 distinct values across the corpus's 51,615 refnums (`0x1e` 18,828 and `0x08`
17,661 dominate). Which reference class each selects is **not decoded**, so all
refnums share one opaque handle rather than a per-class Dart type.

## Not a dataflow value

Connector-pane (`0xf0`, 42,022) and polymorphic-VI (`0xf2`, 787) signatures;
the data-space storage-block family (`0x60`–`0x64`, 49,782) and alignment
markers (`0x65`, 239); the pointer types that flatten to nothing (`0x80` 8,992,
`0x83` 3,038, `0x41` 130). A container built from them — the corpus's
`{cluster, ptr}`, `{refnum, ptr}` and `{ptr, U32}` shapes — is data-space
layout too, and inherits the verdict.

## Review list

Value types with no decided Dart representation. The corpus sweep asserts that
nothing outside this list goes unmapped, so it cannot grow silently.

| code | kind | descriptors | VIs | what is missing | example VI |
| --- | --- | --- | --- | --- | --- |
| `0x3f` | subString | 3,099 | 1,221 | whether it carries an offset/length into another string | `JKISoftware_JKI-State-Machine-Objects/…/Declare Dependency.vi` |
| `0x4f` | subArray | 1,762 | 873 | interior is a dim count and element index with no bounds | `DAQIO_LVMQTT/…/Sub_Read_Fixed_Header.vi` |
| `0x54` | measureData | 1,105 | 661 | subkind word decodes (3, 6, 7, 8, 9) but its layout does not | `JKISoftware_JKI-State-Machine-Objects/…/Clear Registered Process.vi` |
| `0x33` | picture | 703 | 292 | the draw-op stream | `NEVSTOP-LAB_Communicable-State-Machine/…/FixJKIHelper.vi` |
| `0x37` | tag | 87 | 87 | the fixed record after its sentinel | `CrossTheRoadElec_FRC-Examples-STEAMWORKS/…/Vision Processing.vi` |
| `0x0b` | ext | 34 | 14 | Dart has no wider-than-binary64 float; any mapping loses precision | `picotech_picosdk-ni-labview-examples/…/PicoScope2000FrequencyToDeltaPhase.vi` |
| `0x73` | uncatalogued | 9 | 9 | descriptor interior (`40 73 00 xx 03 's' 'e' 't'`), adjacent to refnum | `opengds_OpenGDS/…/GetInterfaceParents.vi` |
| `0x0d` | complexDbl | 6 | 6 | no Dart complex type; `(re, im)` representation undecided | `picotech_picosdk-ni-labview-examples/…/PicoScope2000ExampleBlock.vi` |
| `0x0c` | complexSgl | 3 | 3 | as above | `vipm-io_caraya/…/xml.numeric.vi` |
| `0x1a` | unitDbl | 2 | 1 | the physical-unit exponent vector | `vipm-io_caraya/…/Test Assert Equal (Float Units).vi` |
| `0x74` | uncatalogued | 2 | 2 | descriptor interior, adjacent to refnum | `opengds_OpenGDS/…/GDSLvIcon_AnalyseViIcon.vi` |
| `0x5f` | fixedPoint | 1 | 1 | word length / integer word length | `Rompil_LabVIEW/…/Display Frequencies.vi` |
| `0x0e` | complexExt | 1 | 1 | as `0x0b` and `0x0c` | `vipm-io_caraya/…/Equal Value Comparison.vi` |
| `0x5e`, `0x19`, `0x1b`, `0x1c`–`0x1e`, `0x20`, `0x35` | complexFixedPoint, unit floats, booleanU16, pascalString | 0 | 0 | listed for completeness; absent from this corpus | — |

Two further items for review that are not type codes:

- **Fixed-size array dimensions.** 115 dimension words (112 arrays, plus 3
  arrays mixing fixed and variable dims) carry bit 31 set over a small value
  instead of the `0xFFFFFFFF` variable sentinel. The encoding is not decoded,
  so those arrays are modelled as dynamically sized like every other.
- **Refnum reference class.** 17 distinct discriminator values, meanings not
  decoded (see above).
