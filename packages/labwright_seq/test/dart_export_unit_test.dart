import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// Corpus-free unit pins for exporter behaviors small enough to state
/// exactly (the whole-corpus batched analyze gate covers everything else):
///  * stub NAMING strips a known trailing file extension (review fix: the
///    `\$`-in-raw-string regex never matched, so stub names carried
///    `.vi`/`.seq` tails);
///  * the typed SequenceCall argument/prototype lenses on [StepModule];
///  * CALL-PARAMETER EXPORT, one pin per translation shape: UseDef
///    omission (exact, armed), literal/varpath/bool/int-widening
///    translation, eval-fallback values (emitted + hazard-disarmed),
///    stale argument names, the lhs-type guard, scalar by-ref writeback,
///    stub signatures from prototype snapshots (typed / dynamic-union),
///    expression-form targets, and cross-module binding against the
///    predicted callee scope;
///  * array parameters export as NULLABLE with a `??=` preamble carrying
///    the sequence's DECLARED default (a const `[]` default would alias
///    across calls and throw on element writes).
void main() {
  SeqFile fileWith(List<SeqProperty> sequenceProps) => SeqFile(
    header: const SeqFileHeader(format: SeqFormat.xml),
    types: const [],
    data: SeqProperty(
      name: 'Data',
      subProps: [
        SeqProperty(name: 'Seq', className: 'Objs', array: sequenceProps),
      ],
    ),
  );

  SeqProperty stepWith(String name, {String? typeName, List<SeqProperty> sdata = const []}) => SeqProperty(
    name: name,
    typeName: typeName,
    subProps: [
      SeqProperty(
        name: 'TS',
        subProps: [
          if (sdata.isNotEmpty) SeqProperty(name: 'SData', subProps: sdata),
        ],
      ),
    ],
  );

  group('stub naming (extension strip)', () {
    test('a VI stub name drops the .vi extension, case-insensitively', () {
      final file = fileWith([
        SeqProperty(
          name: 'MainSequence',
          subProps: [
            SeqProperty(
              name: 'Main',
              className: 'Objs',
              array: [
                stepWith(
                  'Call VI',
                  sdata: [
                    SeqProperty(
                      name: 'ViCall',
                      subProps: [SeqProperty(name: 'VIPath', scalar: r'lib\Measure Thing.VI')],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToDart(file);
      expect(source, contains('await callMeasureThing();'));
      expect(source, isNot(contains('callMeasureThingVi')), reason: 'the .VI tail must be stripped from the stub name');
    });

    test('an external sequence stub drops .seq; a dotted TARGET NAME keeps its segments', () {
      final file = fileWith([
        SeqProperty(
          name: 'MainSequence',
          subProps: [
            SeqProperty(
              name: 'Main',
              className: 'Objs',
              array: [
                stepWith(
                  'Call helper',
                  sdata: [
                    SeqProperty(name: 'SeqName', scalar: 'Load Ini File'),
                    SeqProperty(name: 'SFPath', scalar: r'..\Load Ini File.seq'),
                  ],
                ),
                stepWith(
                  'Set caption',
                  sdata: [
                    SeqProperty(name: 'SeqName', scalar: 'UI.TestSocket.SetCaption'),
                    SeqProperty(name: 'SFPath', scalar: 'ui.seq'),
                  ],
                ),
              ],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToDart(file, sourceName: 'caller.seq');
      expect(source, contains('await loadIniFile();'));
      expect(source, isNot(contains('loadIniFileSeq')));
      // Only a TRAILING known extension strips — a dotted sequence name is
      // not a path and keeps every segment in the generated name.
      expect(source, contains('uiTestSocketSetCaption'));
    });
  });

  group('StepModule typed SequenceCall lenses', () {
    final module = StepModule.fromSData(
      SeqProperty(
        name: 'SData',
        subProps: [
          SeqProperty(name: 'SeqName', scalar: 'Callee'),
          SeqProperty(name: 'SFPath', scalar: r'other\Callee.seq'),
          SeqProperty(
            name: 'ActualArgs',
            className: 'Obj',
            subProps: [
              SeqProperty(
                name: 'ChannelName',
                subProps: [
                  SeqProperty(name: 'UseDef', className: 'Bool', scalar: 'False'),
                  SeqProperty(name: 'Expr', scalar: '"PowerSupply_" + Locals.TestSocketName'),
                  SeqProperty(name: 'ParamType', className: 'Num', scalar: '2'),
                  SeqProperty(name: 'ParamRepresentation', className: 'Num', scalar: '1'),
                  SeqProperty(name: 'Flags', className: 'Num', scalar: '0'),
                ],
              ),
              SeqProperty(
                name: 'VoltageLimit',
                subProps: [
                  SeqProperty(name: 'UseDef', className: 'Bool', scalar: 'True'),
                  SeqProperty(name: 'ParamType', className: 'Num', scalar: '4'),
                ],
              ),
            ],
          ),
          SeqProperty(
            name: 'Prototype',
            className: 'Obj',
            subProps: [
              SeqProperty(name: 'ChannelName', className: 'Str', scalar: 'dev1'),
              SeqProperty(name: 'VoltageLimit', className: 'Num', scalar: '5'),
            ],
          ),
        ],
      ),
    );

    test('sequenceArguments reads the ActualArgs rows in order', () {
      final args = module.sequenceArguments;
      expect(args, hasLength(2));
      expect(args[0].name, 'ChannelName');
      expect(args[0].usesDefault, isFalse);
      expect(args[0].expression, '"PowerSupply_" + Locals.TestSocketName');
      expect(args[0].parameterTypeCode, 2);
      expect(args[0].parameterRepresentationCode, 1);
      expect(args[0].flagsCode, 0);
      expect(args[1].name, 'VoltageLimit');
      expect(args[1].usesDefault, isTrue);
      expect(args[1].expression, isNull, reason: 'a UseDef row binds no expression');
      expect(args[1].parameterTypeCode, 4);
    });

    test('prototypeParameters reads the call-site parameter snapshot', () {
      final params = module.prototypeParameters;
      expect([for (final p in params) p.name], ['ChannelName', 'VoltageLimit']);
      expect(params[0].type, 'Str');
      expect(params[0].value, 'dev1');
      expect(params[1].type, 'Num');
      expect(params[1].value, '5');
    });

    test('a module with no ActualArgs/Prototype reads empty', () {
      final bare = StepModule.fromSData(
        SeqProperty(
          name: 'SData',
          subProps: [SeqProperty(name: 'SeqName', scalar: 'Callee')],
        ),
      );
      expect(bare.sequenceArguments, isEmpty);
      expect(bare.prototypeParameters, isEmpty);
    });

    test('resolvesLocalCall: UseCurFile, no file named, or the file\'s own path', () {
      StepModule call({String? file, String? useCurFile}) => StepModule.fromSData(
        SeqProperty(
          name: 'SData',
          subProps: [
            SeqProperty(name: 'SeqName', scalar: 'Callee'),
            if (file != null) SeqProperty(name: 'SFPath', scalar: file),
            if (useCurFile != null) SeqProperty(name: 'UseCurFile', className: 'Bool', scalar: useCurFile),
          ],
        ),
      );
      expect(call(useCurFile: 'True').resolvesLocalCall(ownFilePath: 'a.seq'), isTrue);
      expect(call().resolvesLocalCall(ownFilePath: 'a.seq'), isTrue, reason: 'no target file named at all');
      expect(
        call(file: r'dir\A.SEQ').resolvesLocalCall(ownFilePath: 'other/a.seq'),
        isTrue,
        reason: 'own basename, case-insensitive',
      );
      expect(call(file: 'b.seq').resolvesLocalCall(ownFilePath: 'a.seq'), isFalse);
      expect(call(file: 'b.seq').resolvesLocalCall(), isFalse, reason: 'unknown own path never matches a named file');
    });
  });

  group('call-parameter export', () {
    SeqProperty num$(String name, [String? value]) => SeqProperty(name: name, className: 'Num', scalar: value);
    SeqProperty str$(String name, [String? value]) => SeqProperty(name: name, className: 'Str', scalar: value);
    SeqProperty bool$(String name, [String? value]) => SeqProperty(name: name, className: 'Bool', scalar: value);

    SeqProperty seqWith(
      String name, {
      List<SeqProperty> params = const [],
      List<SeqProperty> locals = const [],
      List<SeqProperty> steps = const [],
    }) => SeqProperty(
      name: name,
      subProps: [
        if (params.isNotEmpty) SeqProperty(name: 'Parameters', className: 'Obj', subProps: params),
        if (locals.isNotEmpty) SeqProperty(name: 'Locals', className: 'Obj', subProps: locals),
        SeqProperty(name: 'Main', className: 'Objs', array: steps),
      ],
    );

    SeqProperty argRow(String name, {bool useDefault = false, String? expr}) => SeqProperty(
      name: name,
      subProps: [
        SeqProperty(name: 'UseDef', className: 'Bool', scalar: useDefault ? 'True' : 'False'),
        if (expr != null) SeqProperty(name: 'Expr', scalar: expr),
      ],
    );

    SeqProperty callStep(
      String stepName,
      String callee, {
      String? file,
      List<SeqProperty> args = const [],
      List<SeqProperty>? prototype,
    }) => stepWith(
      stepName,
      sdata: [
        SeqProperty(name: 'SeqName', scalar: callee),
        if (file != null) SeqProperty(name: 'SFPath', scalar: file),
        if (args.isNotEmpty) SeqProperty(name: 'ActualArgs', className: 'Obj', subProps: args),
        if (prototype != null) SeqProperty(name: 'Prototype', className: 'Obj', subProps: prototype),
      ],
    );

    SeqProperty statementStep(String stepName, String postExpr) => SeqProperty(
      name: stepName,
      typeName: 'Statement',
      subProps: [
        SeqProperty(
          name: 'TS',
          subProps: [SeqProperty(name: 'PostExpr', scalar: postExpr)],
        ),
      ],
    );

    test('UseDef rows are omitted (exact) and the caller stays ARMED', () {
      final file = fileWith([
        seqWith(
          'Caller',
          steps: [
            callStep('Run it', 'Callee', args: [argRow('Threshold', useDefault: true)]),
          ],
        ),
        seqWith('Callee', params: [num$('Threshold', '5')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains('await callee(); // Run it'));
      expect(source, contains("lw.test('Caller'"), reason: 'omission is exact — no disarm');
      expect(source, isNot(contains('call parameters')));
    });

    test('literals, variable paths, and bools translate to named arguments', () {
      final file = fileWith([
        seqWith(
          'Caller',
          locals: [num$('Count', '3')],
          steps: [
            callStep(
              'Run it',
              'Callee',
              args: [
                argRow('Label', expr: '"abc"'),
                argRow('Enabled', expr: 'True'),
                argRow('Count', expr: 'Locals.Count'),
                argRow('Gain', expr: '1 + 2'),
              ],
            ),
          ],
        ),
        seqWith('Callee', params: [str$('Label'), bool$('Enabled', 'False'), num$('Count', '0'), num$('Gain', '2.5')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      // Count is int in both scopes (integral defaults, int-grammar binding);
      // Gain declares 2.5 so it stays double, and Dart will not widen the
      // int EXPRESSION `1 + 2` — the exporter widens it losslessly.
      expect(
        source,
        contains('await callee(label: "abc", enabled: true, count: count, gain: (1 + 2).toDouble()); // Run it'),
      );
      expect(source, contains("lw.test('Caller'"), reason: 'every argument translated mechanically — armed');
    });

    test('an eval-fallback VALUE still emits and the hazard scan disarms the test', () {
      final file = fileWith([
        seqWith(
          'Caller',
          steps: [
            callStep('Run it', 'Callee', args: [argRow('Count', expr: 'GetNumSockets()')]),
          ],
        ),
        seqWith('Callee', params: [num$('Count', '0')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains("await callee(count: ts.eval('GetNumSockets()')); // Run it"));
      expect(source, contains("lw.skipTest('Caller'"));
      expect(source, contains('untranslated expression in body'));
    });

    test('a stale argument name is omitted and disarms the SITE with its reason', () {
      final file = fileWith([
        seqWith(
          'Caller',
          steps: [
            callStep(
              'Run it',
              'Callee',
              args: [
                argRow('Ghost', expr: '1'),
                argRow('Real', expr: '2'),
              ],
            ),
          ],
        ),
        seqWith('Callee', params: [num$('Real', '0')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains('await callee(real: 2); // Run it'));
      expect(source, contains("lw.skipTest('Caller'"));
      expect(source, contains('call parameters of sequence Callee: no parameter named Ghost (stale binding)'));
    });

    test('a type-guard rejection keeps the raw expression in eval and states why', () {
      final file = fileWith([
        seqWith(
          'Caller',
          locals: [num$('N', '0')],
          steps: [
            callStep('Run it', 'Callee', args: [argRow('Label', expr: 'Locals.N + 1')]),
          ],
        ),
        seqWith('Callee', params: [str$('Label')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains("await callee(label: ts.eval('Locals.N + 1')); // Run it"));
      expect(source, contains('call parameters of sequence Callee: Label binding is not visibly String-typed'));
    });

    test('scalar by-ref writeback disarms a variable-path binding; a literal binding is safe', () {
      final callee = seqWith(
        'Callee',
        params: [num$('X', '0')],
        steps: [statementStep('Bump', 'Parameters.X = Parameters.X + 1')],
      );
      final varBound = fileWith([
        seqWith(
          'Caller',
          locals: [num$('Y', '0')],
          steps: [
            callStep('Run it', 'Callee', args: [argRow('X', expr: 'Locals.Y')]),
          ],
        ),
        callee,
      ]);
      final varSource = exportSeqFileToLabwright(varBound, sourceName: 'own.seq');
      expect(varSource, contains('await callee(x: y); // Run it'), reason: 'the value still passes in');
      expect(varSource, contains("lw.skipTest('Caller'"));
      expect(varSource, contains('by-ref writeback of parameter X of sequence Callee not exported'));

      final literalBound = fileWith([
        seqWith(
          'Caller',
          steps: [
            callStep('Run it', 'Callee', args: [argRow('X', expr: '5')]),
          ],
        ),
        callee,
      ]);
      final literalSource = exportSeqFileToLabwright(literalBound, sourceName: 'own.seq');
      expect(literalSource, contains('await callee(x: 5); // Run it'));
      expect(literalSource, contains("lw.test('Caller'"), reason: 'a literal has nothing to write back to — armed');
    });

    test('a call binding demotes an int-refined callee parameter (analyze-safe)', () {
      final file = fileWith([
        seqWith(
          'Caller',
          steps: [
            callStep('Run it', 'Callee', args: [argRow('X', expr: '2.5')]),
          ],
        ),
        seqWith('Callee', params: [num$('X', '0')]),
      ]);
      final source = exportSeqFileToDart(file, sourceName: 'own.seq');
      expect(source, contains('Future<void> callee({double x = 0}) async {'));
      expect(source, contains('await callee(x: 2.5); // Run it'));
    });

    test('an external stub gets a TYPED signature from the prototype snapshot', () {
      final proto = [
        str$('ChannelName', 'dev1'),
        num$('VoltageLimit', '5'),
        SeqProperty(name: 'Thresholds', className: 'Nums', array: []),
      ];
      final file = fileWith([
        seqWith(
          'Caller',
          steps: [
            callStep(
              'Configure',
              'Load Config',
              file: r'..\Load Config.seq',
              args: [
                argRow('ChannelName', expr: '"ps1"'),
                argRow('VoltageLimit', useDefault: true),
              ],
              prototype: proto,
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(
        source,
        contains(
          "Future<Object?> loadConfig({String channelName = 'dev1', double voltageLimit = 5, List<dynamic>? thresholds}) async =>",
        ),
      );
      expect(source, contains('await loadConfig(channelName: "ps1"); // Configure: external sequence call'));
      expect(source, contains("/// Signature: the call sites' prototype snapshot"));
    });

    test('disagreeing prototype snapshots yield an honest dynamic-union stub', () {
      final file = fileWith([
        seqWith(
          'Caller',
          steps: [
            callStep(
              'First',
              'Helper',
              file: 'other.seq',
              args: [argRow('A', expr: '1')],
              prototype: [num$('A', '0')],
            ),
            callStep(
              'Second',
              'Helper',
              file: 'other.seq',
              args: [argRow('B', expr: '2')],
              prototype: [num$('B', '0')],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains('Future<Object?> helper({dynamic a, dynamic b}) async =>'));
      expect(source, contains('they disagree or are partly missing'));
      expect(source, contains('await helper(a: 1); // First: external sequence call'));
      expect(source, contains('await helper(b: 2); // Second: external sequence call'));
    });

    test('expression-form targets stay untranslated (no argument list)', () {
      final file = fileWith([
        seqWith(
          'Caller',
          steps: [
            stepWith(
              'Dynamic call',
              sdata: [
                SeqProperty(name: 'SpecifyByExpr', className: 'Bool', scalar: 'True'),
                SeqProperty(name: 'SeqNameExpr', scalar: 'Locals.Target'),
                SeqProperty(name: 'SFPathExpr', scalar: '"x.seq"'),
                SeqProperty(name: 'SeqName', scalar: ''),
                SeqProperty(
                  name: 'ActualArgs',
                  className: 'Obj',
                  subProps: [argRow('X', expr: '1')],
                ),
              ],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains('await localsTarget(); // Dynamic call'));
      expect(source, contains("lw.skipTest('Caller'"));
    });

    test('project export binds cross-module arguments against the predicted scope', () {
      final caller = fileWith([
        seqWith(
          'MainSequence',
          steps: [
            callStep(
              'Use helper',
              'Helper',
              file: 'b.seq',
              args: [argRow('X', expr: '3')],
            ),
            callStep(
              'Break helper',
              'Helper',
              file: 'b.seq',
              args: [argRow('X', expr: '3.5')],
            ),
          ],
        ),
      ]);
      final calleeFile = fileWith([
        seqWith('Helper', params: [num$('X', '0')]),
      ]);
      final project = exportSeqProjectToLabwright({'a.seq': caller, 'b.seq': calleeFile});
      final aSource = project.files['a_seq.dart']!;
      // Helper.X refines int inside b.seq (integral default, no demoting
      // assigns THERE) — the integral binding passes straight through; the
      // non-integral one is honest (eval + site disarm), never truncated.
      expect(project.files['b_seq.dart'], contains('Future<void> helper({int x = 0}) async {'));
      expect(aSource, contains('await b_seq.helper(x: 3); // Use helper: external sequence'));
      expect(aSource, contains("await b_seq.helper(x: ts.eval('3.5')); // Break helper: external sequence"));
      expect(aSource, contains('call parameters of sequence Helper: X binding is not visibly int-typed'));
    });
  });

  group('array parameters (nullable + ??= preamble)', () {
    test('an array parameter is nullable and ??= materializes the declared default', () {
      final file = fileWith([
        SeqProperty(
          name: 'MainSequence',
          subProps: [
            SeqProperty(
              name: 'Parameters',
              className: 'Obj',
              subProps: [
                SeqProperty(
                  name: 'Thresholds',
                  className: 'Nums',
                  array: [
                    SeqProperty(name: '[0]', className: 'Num', scalar: '1.5'),
                    SeqProperty(name: '[1]', className: 'Num', scalar: '2'),
                  ],
                ),
                SeqProperty(name: 'Names', className: 'Strs', array: []),
              ],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToDart(file);
      expect(source, contains('Future<void> mainSequence({List<dynamic>? thresholds, List<dynamic>? names}) async {'));
      expect(source, contains('thresholds ??= <dynamic>[1.5, 2];'));
      expect(source, contains('names ??= <dynamic>[];'));
      expect(source, isNot(contains('const []')), reason: 'a shared const default would alias across calls');
    });
  });
}
