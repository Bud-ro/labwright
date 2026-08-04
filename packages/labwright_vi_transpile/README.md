# labwright_vi_transpile

**LabVIEW VI to Dart.** Two layers, one package:

1. the **type model** — what a VI's data types become in Dart, per entry of its
   consolidated type pool (`VCTP`) and per block-diagram wire, including the
   class and `enum` declarations a named cluster and a named enum need;
2. the **lowering** — a VI's block diagram recast as a dataflow graph and
   emitted as a Dart function (`emitLvFunction`, `dart run tool/generate.dart`).

Nothing partial is ever emitted. A construct whose meaning is not decoded
aborts the whole function with an `LvRefusal` naming what is missing, so
generated code is either complete or absent — see *Lowering* below.

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
class only when their member types and member names agree.

- **Named cluster** → a Dart class of `final` fields with a `const`
  constructor taking every one by name.
- **Anonymous cluster** (62,368 of 99,345 have no name) → a Dart **record**:
  named fields when every member has a distinct sanitizable name
  (`({double volts, String serialNumber})`), positional otherwise
  (`(double, int)`). A record's identity is structural, exactly like an unnamed
  cluster's, and costs no generated declaration.
- **Typedef** (`0xf1`) → nominal only when its base is a cluster or an enum,
  which need a declaration anyway, and the declaration then takes the
  *typedef's* name; a typedef of a scalar, string or array is transparent.
  Corpus typedef bases: cluster 19,890, enumU16 5,548, U64 1,347, enumU32
  1,053, refnum 934, and 15 further kinds; 20 of 31,060 typedef descriptors
  expose no base and are unmapped.
- **Enum** → a Dart `enum`. The descriptor's interior is `[u16 count]` then
  `count × [u8 len][chars]` — item labels in order and **no value word
  anywhere** — so an item's value is its ordinal, which is exactly a Dart
  enum's `index`.

### Declarations

`LvDeclarations` is the per-library registry a lowering names its nominal types
through, and `lvDeclarationSource` writes them. Structure is the key: two types
with the same members under the same name are one class, and a structurally
different type wanting a name already spoken for gets a numeric suffix — as
does one wanting a name the file already spells (`String`, `Uint8List`,
`LvError`; `kLvReservedTypeNames`).

Corpus, over the cluster wires that resolve a member shape, one registry per VI:
3,129 of 7,508 VIs need a declaration at all, and they need **10,437** — 8,583
cluster classes and 1,854 enums. **724** take a suffix because a structurally
different type in the same VI already holds the name, which is why the name
alone cannot be the identity. Member names come from the one naming policy:
1,213 declarations hold a member the descriptor does not name, and 1,594
members are displaced by an earlier member or by a name every Dart class
inherits.

One shape has no declaration and is **refused**
(`LvRefusalKind.typeDeclaration`, 16 VIs): an enum whose item labels did not
decode, since a Dart `enum` must have a member. Anonymous enums are declared
from an `LvEnum` stem rather than refused — their labels *are* decoded and Dart
has no structural carrier for them the way a record carries an unnamed cluster;
the corpus reaches 3.

An **error cluster never becomes a declaration**, in either error mode: the
`{status, code, source}` shape maps to the runtime's `LvError` before the
nominal branch is reached, and no typedef reaching a wire type in the corpus
wraps one (0 of 7,508 VIs).

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

Both carrying modes are implemented, because they change function signatures
(`LvErrorMode`, `lvSignature`, and the emitter):

- `exceptions` (**default**) — the error cluster leaves the *signature* and
  becomes control flow, while the diagram's error computation stays. An
  `error in` terminal is not a parameter and its wire starts at `LvError.none`;
  an `error out` terminal is not a result and the function ends with
  `if (it.status) throw it;`; a subVI call passes nothing for the callee's
  `error in` and reads `LvError.none` from its `error out`. All three follow
  from one premise: a caller that failed threw rather than returning.
- `threaded` (**opt-in**) — error terminals stay first-class `LvError` values
  and nothing throws. LabVIEW's per-node **short-circuit** is deliberately not
  emitted: which nodes skip their work on an incoming error is a property of
  LabVIEW's library, not a fact the file states.

A **Case structure selecting on an error cluster** lowers in both modes,
branching on `status`. Corpus: every one of the 10 Case structures whose
selector wire resolves an error cluster has two frames, and every displayed
selector label reads `No Error`.

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

## Wire types

A block-diagram signal word is not a pool descriptor: it holds an element type
code, an array depth and a flag nibble. `mapLvWireType` resolves it to the same
`LvTypeMapping` terms, which is enough to type a dataflow edge and is *per
wire*, so a tunnel whose two sides carry different dimensionalities reads as
two different types.

Cluster wires (`0x50`, and `0x51` for the typedef/class form) carry no member
types on the wire, so their Dart shape comes from the data-space type an
**endpoint** of the wire resolves — the type a renderer draws the wire's tint
from. Corpus, over 133,106 cluster-coded signals: 91,829 resolve exactly one
Dart type, 157 resolve two that disagree (refused), and 41,120 resolve none.
Two ends are compared by the **Dart type** they map to, not by the descriptor's
spelling — the spelling counts 90,614 / 1,372 / 41,120, because a wire whose
ends are an `error in` and an `error out` control spells two types and maps to
one.

18,105 of the resolved wires are reached only by looking **through a typedef**:
a typedef over a cluster is a cluster descriptor, exactly as `mapLvType`
already reads one, and it is the shape `0x51` names. It contradicts the
bare-cluster reading on 6 wires, which are refused like any other
disagreement. Reading the *other* half of an endpoint's resolved type instead
(an array's element for a scalar wire, or the converse) would resolve a further
586, but nothing decoded says an endpoint describing an array of clusters
describes a scalar cluster wire's element, so that route is not taken.

### Cluster member types

The 41,120 wires no endpoint resolves are the corpus's largest lowering
blocker, and two further decoded routes were scored as a source for them. Both
are censused on the **Dart type** each maps to, since that is the identity a
generated library has and the one the lowering compares by; the descriptor's
spelling scores the same routes very differently and scores them wrong.

| reading | vs. the endpoint route | would newly type | verdict |
| --- | --- | --- | --- |
| endpoint's node-terminal **parts** | 68,112 agree, 1,939 contradict (2.8%) | 38,236 | not read |
| callee's **connector-pane** terminal | 5,777 agree, 523 contradict (8.3%) | 5,918 | not read |

The part route's 1,939 contradictions are 1,874 wires whose two readings agree
on every member's own type code and differ in a **label**, and 65 that differ
in a member code outright. Since a nominal class is named from those labels,
both kinds are a different generated type.

The pane is the only decoded route that reads a cluster wire from *another
file*, and it is the route that corroborates refnum dimensionality above — but
it does not carry over. It contradicts the reading already trusted on 8.3% of
the wires where both speak (518 of the 523 by a label alone), which is what a
connector pane is: a cluster crosses it on its member **types**, so the two
files need not label the same members alike, and the callee terminal's name is
not the caller wire's. Where it does agree it is not independent either — the
part route read *at* the call node's own terminal contradicts it on 39 of
12,252 wires (0.32%) against 372 of 4,677 (7.95%) read anywhere else on the
same wires, which is what a cached copy of the callee's descriptor looks like.
It also reaches only 5,645 of the 38,236 wires the part route would newly type.

### Refnum dimensionality

A refnum wire's array-depth base rides the **reference class**, not the type
code, so the signal word decides only its depth-1 wires (28,582 of 66,473
refnum-coded signals). `lvRefnumWireDims` supplies the base for the rest from
the data-space descriptors on the node-terminal **part** objects the wire's
endpoints parent, which state the dimension count outright. It decides 30,938
of the 37,891 wires the word leaves open.

Three readings of that dimensionality are censused, and only one is read:

| reading | vs. the word's ground-truth row | verdict |
| --- | --- | --- |
| endpoint's node-terminal **parts** | 26,796 agree, 0 contradict | read |
| endpoint DCO itself | 14,046 agree, 1,335 contradict (8.7%) | not read |
| callee's **connector-pane** terminal | 1,869 agree, 0 contradict | corroborates |

The word's row is one-sided — every wire it decides is scalar, so it catches an
invented array and not a missed one. The pane reading supplies the other side:
it is the endpoint route read in a *different file*, it answers on both rows of
the undecided wires (4,661 scalar, 177 one-dimensional), and it reproduces the
part route on 4,827 of the 4,838 wires where both speak. Ten of the eleven
disagreements sit in one signal-word cell — plain refnum at depth 4, where the
pane dissents on 10 of 101 while every other cell agrees 4,736 of 4,737 — so
that cell (`kLvRefnumContradictedCells`, 1,494 wires) keeps the word's refusal
rather than being decided by either reading.

**LabVIEW's own wire stroke is not a third reading.** The stroke width is a
function of dimensionality, and the render catalogue is pixel-measured against
LabVIEW's reference rasters — but it is keyed on the signal word's low 12 bits,
the same bits `arrayDims` reads, so it can only restate them. It is catalogued
for 5,028 of the 37,891 undecided refnum wires (13.3%), all in the depth-2
plain-refnum cell, and its single stroke there is shared by the 3,969 wires the
part route calls one-dimensional and the 651 it calls scalar alike. For cluster
wires it is weaker still: the whole 133,106-wire population falls in six cells,
against the thousands of distinct member shapes the question needs.

**What the unresolved majority costs.** Cluster wires with no member shape are
the single largest lowering blocker in the corpus: of the 5,748 VIs whose own
dataflow build refuses on a wire type, 4,363 stop first on a cluster wire and
1,901 have no other unmapped wire family at all. Next is the refnum family
(`0x70`/`0x71`) — 1,154 VIs stop there first and 666 have nothing else — then
the element codes with no Dart representation (measureData `0x54` 81, uncatalogued
`0xff` 70, packed string `0x33` 46, tag `0x37` 22).

## Lowering

`emitLvFunction(diagram)` turns a decoded block diagram into a Dart function,
or returns an `LvRefusal` naming the decoded fact that is missing.

### The IR

A `ViDiagram` becomes an `LvDataflow`: **units** (primitive nodes, diagram
constants, connector-pane terminals, structures) joined by typed **edges**, and
grouped into one `LvRegion` per structure frame.

- **Direction.** An endpoint holder's own flag bit `0x8000` marks it a wire's
  sink, except on a connector-pane terminal (`0x16`), which answers from its
  panel data item's control/indicator bit. Corpus, over 428,043 signals in
  7,524 files: 424,466 (99.2%) resolve to exactly one source endpoint. The
  panel bit never contradicts the flag — it agrees on all 38,744 connector-pane
  endpoints of already-resolved signals — and it settles 481 signals the flag
  alone leaves with two sources.

  The remaining 3,577 are refused. Every one has **several** sources, none has
  zero, and 2,629 are two plain endpoint holders that both read as producers.
  The terminal record's own `0x1` output bit would single out a producer for
  2,182 of them, but it disagrees with the sink flag on 39 of the 213,394
  already-resolved signals where it speaks, so it is not a law and is not
  applied.
- **Nesting.** Every node, structure and signal is parented to a frame
  (`0x1b`), so each edge lives in exactly one region and a structure terminal
  splits into an outer port and one inner port per frame.
- **Acyclicity.** A loop's feedback runs through a shift register, whose inner
  read is a region entry and inner write a region exit — never an edge. A back
  edge that survives that is refused as a cycle.

Each edge becomes one single-assignment local, named from the decoded label
nearest to it: the connector-pane control's name, the constant's caption, or
the primitive's own name.

### Structures

| structure | lowers to |
| --- | --- |
| For loop (`0x20`) | `for` over the count terminal and every auto-indexed array's length (`_lvIterationCount` when both) |
| shift register (`0x27`/`0x28`) | a loop-carried local, initialised from the left register's outer input and reassigned from the right register's inner write |
| auto-indexing input tunnel | `array[i]`, bound at the top of the body |
| auto-indexing output tunnel | a `List<E>` builder, frozen once after the loop by `lvArrayFreeze` |
| plain tunnel | the outer value, bound to the frame's inner reads |
| Case structure (`0x2c`) | `if`/`else` over a boolean selector, each output tunnel a `final` assigned in both branches |
| Diagram Disable (`0xcd`) | the Enabled frame's region, inline |
| While loop (`0x21`) | **refused** — the conditional terminal's stop-if-true / continue-if-true polarity is not decoded |
| In Place Element (`0x14d`) | **refused** — see below |

An auto-indexing tunnel is identified by flag `0x1000000`. Corpus, over 21,486
loop tunnels whose two sides both resolve a dimensionality: all 6,584 flagged
tunnels drop exactly one dimension and all 10,370 unflagged ones drop none.
595 unflagged tunnels do drop a dimension; the emitter refuses those rather
than pick a side.

A Case structure lowers only over a **boolean** selector with two frames. The
file records the case value of the *displayed* frame alone (its `0x95` label),
so any other frame's value is decoded only when it is the complement of a
boolean. Frame order does not supply it: over 3,587 two-frame boolean cases the
displayed frame is index 1 labelled `True` 1,840 times, but index 0 labelled
`True` 328 times.

A For loop's **non-indexing output tunnel** is refused: it carries the last
iteration's value, or the element type's default when the loop runs zero times,
and that default is not decoded.

The **In Place Element Structure** (`0x14d`) is common but is not the lever its
frequency suggests, and `kCorpusInPlaceElement` is the measurement. 705 corpus
VIs carry one, 904 in total — but a lowering refuses at the first thing it
cannot read, and the structure is that first thing in only **27** of them.
The other 678 are held up earlier, 482 by a single cause: a cluster wire whose
member types no endpoint resolves. Modelling the structure's control flow would
therefore move at most 0.36% of the corpus.

Those 27 then split against it. 22 carry a border node from `0x150` / `0x14f` /
`0x152`, whose element access is not recovered — the parser labels that family
by tree position alone — so control flow is not what they are missing. The
remaining 5 carry only `0x153`, the read/write pair that accesses a **data
value reference**, which is the one border node whose role is decoded and which
would need a reference model this package does not have.

### Primitives

A node is mapped only when its **identity** and its **operand roles** are both
decoded. `kLvMappedPrimOps` is deliberately narrow: commutative pairs, unary
operations and the width conversions — everything whose roles follow from the
terminals themselves. `Subtract`, `Divide` and the ordered comparisons are
absent because nothing decoded says which terminal is the left operand.

Having one operand is necessary but not sufficient — the *result* must follow
from the operand too. These unary corpus operations are refused for want of a
rule rather than a role: `Sort 1D Array` (181 nodes; sort direction and tie
order unstated), `Boolean To (0,1)` (550; which boolean maps to which member),
`Number To Boolean Array` / `Boolean Array To Number` (21 / 26; bit order), and
`Transpose 2D Array` and a rank-2 `Array Size` (the array's own dimension order
— the same missing tie that refuses a higher-rank Index Array).

Where an operation's *domain* is decoded but its behaviour outside that domain
is not, the rule lowers and the **runtime** throws at the boundary rather than
inventing a value, each with a `TODO` naming the gap: `String Subset` outside
the string, `To Lower Case` above code unit `0x7F`, `Initialize Array` at a
negative size, `Type Cast` on a size mismatch, a rotation by anything but a
count inside one width, and a hexadecimal conversion of a value wider than the
field it is given.

Two node classes carry their identity in the class code, with corpus node
labels as the evidence: `0x44` Index Array (×27 labels, no competing caption)
and `0xB9` Replace Array Subset (×10). Their operand roles come from role bits
on each terminal's own record — array `0x20000`, output `0x1`, new element
`0x40000`, single index `0x600000` — the shape 1,623 Index Array and 310
Replace Array Subset nodes carry. Higher-rank variants split the index across
`0x200000`/`0x400000` and growable ones repeat the output/index pair; both are
refused.

Integer conversions emit a width helper carrying a `TODO(lv-convert-range)`:
they are exact for every value the target width holds, and LabVIEW's rule for
one outside it (truncate or saturate) is not established from the file format.

The **review list** is everything else, pinned by count in
`test/corpus_lowering_sweep_test.dart`: 88 distinct unmapped identities over
471 nodes across the tracked snippets, headed by Match Pattern (134) and node
classes `0x93` (18), `0x105` (16) and `0xa9` (15).

### subVI calls

A call node's terminals are its callee's connector pane, in pane order, and
`subvi.dart` states the three decoded facts that join the two files: the pane
order itself, `CPMp` naming each pane terminal's panel data item counted from
the last data-space slot backwards, and that item's block-diagram terminal
reached through the terminal's `dcoRef`. A call lowers to a Dart call with
**named** arguments, so the binding is by terminal rather than by position, and
each callee is emitted once into the same file however many sites reach it.

Corpus, over the 1,290 call nodes in diagrams whose dataflow builds: 545 have a
callee with a connector pane of the right width, and of the 337 wired terminals
at those calls, 304 resolve a callee terminal. Two independent checks confirm
the binding — the caller's own wire direction agrees with the named control's
on **304 of 304**, and the two VIs' wire types agree on **189 of 189** where
both are decided. The rest are refused by name: 567 calls whose callee carries
no `CPMp`, 159 whose callee is absent, 13 that name no file, 6 whose pane width
disagrees.

### Outcomes

Over the 46 tracked VI snippets: 8 lower (`MD5`, `PNG CRC32`,
`crc32_lookup_table`, `crc8`, `ReverseBitsVim`, `basic`, and `VI Tree` /
`decorations_only`, which have no dataflow) and 38 refuse. Refusals are pinned
per VI and concentrate in cluster / path / variant wire types (24), undecoded
primitives (5), unresolved wire direction (3), constants whose value the heap
decode did not recover (2), structures (2) and subVI calls whose callee is not
supplied (2).

Over the whole 7,508-VI corpus, with every VI available as a subVI: 229 lower
and the rest refuse, 5,809 of them on a wire type — overwhelmingly a cluster
wire no endpoint resolves a member shape for. The rest are pinned per kind in
`kCorpusLoweringSweep`: 524 on a primitive, 322 on a subVI call, 234 on an
unwired terminal, 111 on a structure, 107 on a wire's direction, 135 on a
constant's value, 18 on a declaration that cannot be written.

Those 229 lowerings are **79 distinct Dart sources** (a VI copied across
repositories lowers to the same text). The corpus sweep writes all 79 into a
throwaway package resolved against this repo's own package graph, runs one
`dart analyze` over the batch at `package:lints/recommended.yaml`, and asserts
**zero diagnostics** — errors, warnings and infos alike; a `dart compile
kernel` of one entry point importing all 79 is the independent check that they
link against `labwright_lv_runtime`. So "the emitted code is clean" is measured
corpus-wide rather than inferred from the one checked-in file.

Lowering is not the same as being *checked*, though, and the gap is what the
behavioural tests close. Eight VIs are verified against a published vector
rather than against this reader's own reading of them: `crc8.vi`,
`crc32_lookup_table.vi`, `PNG CRC32.vi`, `Calculate CRC.vi`, `Calc CRC-16.vi`,
`Calc LRC-8.vi`, `ReverseBitsVim.vi` and `MD5.vi`.

### crc8.vi, byte-exact

`test/generated/crc8.g.dart` is the Dart lowered from `crc8.vi`'s block
diagram: six connector-pane parameters, a 256-iteration For loop building the
CRC lookup table through an 8-iteration bit loop, a main byte loop over an
auto-indexed array, and three Case structures for the reflect-in / reflect-out
options. `test/crc8_behaviour_test.dart` checks it against a bit-at-a-time
reference CRC-8 written from the public parameter model, over the ten
catalogued CRC-8 algorithms × 261 messages: **2,610 comparisons, all exact**.
The reference itself is anchored to the published check values, so neither side
can drift alone.

### CRC-32 and CRC-16, both halves of each

Two algorithms are checked from both ends, so the table and the code that
drives it are proven separately rather than as one round trip.

- **CRC-32/ISO-HDLC.** `crc32_lookup_table.vi` *builds* the 256-entry table and
  `PNG CRC32.vi` *consumes* one, and both land on the published check value
  0xCBF43926 — the CRC of the nine ASCII bytes `123456789`. The consumer side
  is the wider test: it has to get the 0xFFFFFFFF preset, the per-byte
  `table[(register ^ byte) & 0xFF] ^ (register >>> 8)` fold and the final
  complement all right at once, which exercises a U32 right shift, an Index
  Array read against a constant table, a string auto-indexed into a byte loop,
  and a `Select` whose two values are arrays.
- **CRC-16/MODBUS.** `Calculate CRC.vi` folds the polynomial a bit at a time
  and `Calc CRC-16.vi` — the largest lowering the fetched corpus produces —
  reads two 256-byte tables through two shift registers that cross over each
  iteration. Both reproduce the published check value 0x4B37, and they are
  compared with each other as well as with a reference, so the table pair, the
  crossover and the emitted byte order are each pinned.

`PNG CRC32.vi` also shows what a faithful lowering looks like when the VI and
the standard disagree. Its diagram routes an empty byte array to a one-element
zero constant, so it digests a single zero byte where CRC-32 defines the empty
message's value to be zero. The lowering reproduces the diagram, and the test
states that deviation as the value it produces instead of excluding the input.

### MD5.vi, and hypotheses a published vector decides

`MD5.vi` is the largest tracked snippet, and it lowers: `kMd5Blockers` is empty
and `test/md5_behaviour_test.dart` checks the result against **RFC 1321's own
test suite**. The RFC fixes 128 bits of output per message, so each vector
rejects a lowering that misreads any node and all seven together accept only
one reading of every node — a two-sided oracle, and the reason several
operations here rest on behaviour rather than on a decoded field.

What that method decided, and what it did not:

- **`primResID` 1082 and 1181** carry no name any corpus VI states. Their
  terminal grammar and their position in the diagram give a hypothesis — 1082
  has `Logical Shift`'s grammar exactly and sits under a rotation table; 1181
  takes an I16 width and an integer and yields a string, in a run whose
  neighbours 1180 and 1184 are corpus-labelled — and the digests confirm it.
  `kLvProvenPrimResIds` records **what each computes in the shapes the vectors
  exercise**, which is a weaker claim than naming the primitive, and a node
  outside those shapes is refused exactly as an unnamed one is: both lower only
  a 32-bit result, and the readings the vectors leave open — a rotation count
  past one width, a field narrower than the value — are refused by the runtime
  rather than guessed.
- **Compound Arithmetic**'s mode field (bits 16..18 of the node record) selects
  five reductions. Two of them — the four-term U32 sum and the three-term
  combination MD5 draws — are decided by the digests; the other three are named
  from the palette order the two bracket and are **not lowered**
  (`LvCompoundMode`). The per-terminal inversion bit is not decoded either way,
  and a node carrying it is refused, as is a float wire: the vectors are over
  integers, where both lowered reductions are associative and the drawn order
  cannot change the value.
- **`String Subset`'s unwired length** defaults to the rest of the string. Every
  message whose length is not a multiple of 64 depends on it, so the vectors
  decide it; an unwired *offset* has no such witness and stays refused.
- **`To Lower Case`** and 1181's digit case are proven only as a **pair**: the
  digests are wrong if either the conversion writes lower case and the mapping
  is a no-op, or the reverse, but they cannot separate the two. The VI's own
  diagram is what breaks the tie — an author draws `To Lower Case` after a
  conversion only when that conversion writes upper case.

### Auto-indexing tunnels

A loop tunnel's `0x23` **indexer** record states whether the boundary iterates
its array element-wise. It is read by whether the record's flag word is set at
all: over the 18,244 corpus tunnels whose two sides both resolve a
dimensionality, all 6,770 with a non-zero indexer drop exactly one dimension
and 11,341 of the 11,474 without one drop none. The 133 exceptions are rank-2
and rank-3 arrays and are refused. The tunnel record's own `0x1000000` bit reads
the same way and is subsumed: it marks 6,336 of the same tunnels and misses 567
where this misses 133.

### crc8.vi, continued

One ordering difference is recorded there: the VI applies its Xor Out *before*
the output reflection, where the published model reflects first. The two
coincide when the output is not reflected or the Xor Out is zero, which every
catalogued CRC-8 satisfies — asserted in the test so the untested corner cannot
be forgotten.
