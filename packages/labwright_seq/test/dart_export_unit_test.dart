import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

SeqProperty _p(String name, {String? cls, String? type, String? value, List<SeqProperty> sub = const []}) =>
    SeqProperty(name: name, className: cls, typeName: type, scalar: value, subProps: sub);

SeqFile _fileWith(List<SeqProperty> sequenceProps) => SeqFile(
  header: const SeqFileHeader(format: SeqFormat.xml),
  types: const [],
  data: _p(
    'Data',
    sub: [SeqProperty(name: 'Seq', className: 'Objs', array: sequenceProps)],
  ),
);

SeqProperty _stepWith(
  String name, {
  String? typeName,
  List<SeqProperty> sdata = const [],
  List<SeqProperty> ts = const [],
  List<SeqProperty> props = const [],
}) => _p(
  name,
  type: typeName,
  sub: [
    _p(
      'TS',
      sub: [
        if (sdata.isNotEmpty) _p('SData', sub: sdata),
        ...ts,
      ],
    ),
    ...props,
  ],
);

SeqProperty _seqWith(
  String name, {
  List<SeqProperty> params = const [],
  List<SeqProperty> locals = const [],
  List<SeqProperty> steps = const [],
}) => _p(
  name,
  sub: [
    if (params.isNotEmpty) _p('Parameters', cls: 'Obj', sub: params),
    if (locals.isNotEmpty) _p('Locals', cls: 'Obj', sub: locals),
    SeqProperty(name: 'Main', className: 'Objs', array: steps),
  ],
);

SeqProperty _num(String name, [String? value]) => _p(name, cls: 'Num', value: value);
SeqProperty _str(String name, [String? value]) => _p(name, cls: 'Str', value: value);
SeqProperty _bool(String name, [String? value]) => _p(name, cls: 'Bool', value: value);

SeqProperty _argRow(String name, {bool useDefault = false, String? expr}) => _p(
  name,
  sub: [
    _p('UseDef', cls: 'Bool', value: useDefault ? 'True' : 'False'),
    if (expr != null) _p('Expr', value: expr),
  ],
);

SeqProperty _callStep(
  String stepName,
  String callee, {
  String? file,
  List<SeqProperty> args = const [],
  List<SeqProperty>? prototype,
}) => _stepWith(
  stepName,
  sdata: [
    _p('SeqName', value: callee),
    if (file != null) _p('SFPath', value: file),
    if (args.isNotEmpty) _p('ActualArgs', cls: 'Obj', sub: args),
    if (prototype != null) _p('Prototype', cls: 'Obj', sub: prototype),
  ],
);

void main() {
  group('stub naming (extension strip)', () {
    test('a VI stub name drops the .vi extension, case-insensitively', () {
      final file = _fileWith([
        _seqWith(
          'MainSequence',
          steps: [
            _stepWith(
              'Call VI',
              sdata: [
                _p('ViCall', sub: [_p('VIPath', value: r'lib\Measure Thing.VI')]),
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
      final file = _fileWith([
        _seqWith(
          'MainSequence',
          steps: [
            _stepWith(
              'Call helper',
              sdata: [
                _p('SeqName', value: 'Load Ini File'),
                _p('SFPath', value: r'..\Load Ini File.seq'),
              ],
            ),
            _stepWith(
              'Set caption',
              sdata: [
                _p('SeqName', value: 'UI.TestSocket.SetCaption'),
                _p('SFPath', value: 'ui.seq'),
              ],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToDart(file, sourceName: 'caller.seq');
      expect(source, contains('await loadIniFile();'));
      expect(source, isNot(contains('loadIniFileSeq')));
      expect(
        source,
        contains('uiTestSocketSetCaption'),
        reason: 'a dotted sequence name is not a path — keeps every segment',
      );
    });
  });

  group('StepModule typed SequenceCall lenses', () {
    final module = StepModule.fromSData(
      _p(
        'SData',
        sub: [
          _p('SeqName', value: 'Callee'),
          _p('SFPath', value: r'other\Callee.seq'),
          _p(
            'ActualArgs',
            cls: 'Obj',
            sub: [
              _p(
                'ChannelName',
                sub: [
                  _p('UseDef', cls: 'Bool', value: 'False'),
                  _p('Expr', value: '"PowerSupply_" + Locals.TestSocketName'),
                  _p('ParamType', cls: 'Num', value: '2'),
                  _p('ParamRepresentation', cls: 'Num', value: '1'),
                  _p('Flags', cls: 'Num', value: '0'),
                ],
              ),
              _p(
                'VoltageLimit',
                sub: [
                  _p('UseDef', cls: 'Bool', value: 'True'),
                  _p('ParamType', cls: 'Num', value: '4'),
                ],
              ),
            ],
          ),
          _p('Prototype', cls: 'Obj', sub: [_str('ChannelName', 'dev1'), _num('VoltageLimit', '5')]),
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
      expect(
        [for (final p in params) (p.name, p.type, p.value)],
        [
          ('ChannelName', 'Str', 'dev1'),
          ('VoltageLimit', 'Num', '5'),
        ],
      );
    });

    test('a module with no ActualArgs/Prototype reads empty', () {
      final bare = StepModule.fromSData(_p('SData', sub: [_p('SeqName', value: 'Callee')]));
      expect(bare.sequenceArguments, isEmpty);
      expect(bare.prototypeParameters, isEmpty);
    });

    test('resolvesLocalCall: UseCurFile, no file named, or the file\'s own path', () {
      StepModule call({String? file, String? useCurFile}) => StepModule.fromSData(
        _p(
          'SData',
          sub: [
            _p('SeqName', value: 'Callee'),
            if (file != null) _p('SFPath', value: file),
            if (useCurFile != null) _p('UseCurFile', cls: 'Bool', value: useCurFile),
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

  group('step payload notes', () {
    test('limit criterion, flow action, step loop, and status expression surface and disarm', () {
      final file = _fileWith([
        _seqWith(
          'MainSequence',
          steps: [
            _stepWith(
              'Voltage OK',
              typeName: 'NumericLimitTest',
              ts: [
                _p('FailAct', value: 'Goto'),
                _p('FailActTarget', value: '"<Cleanup>"'),
                _p('LoopType', value: 'PassFailCount'),
                _p('LoopWhile', value: 'RunState.LoopIndex < 10'),
                _p('StatusExpr', value: 'Step.Result.Status'),
              ],
              props: [
                _p('Comp', value: 'GELE'),
                _p('DataSource', value: 'Locals.Voltage'),
                _p('Limits', sub: [_num('Low', '9'), _num('High', '11')]),
                _p('Result', sub: [_str('Units', 'V')]),
              ],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToLabwright(file);
      expect(source, contains('// checks: Locals.Voltage GELE [low 9, high 11] V'));
      expect(source, contains('// on fail: Goto -> <Cleanup>'));
      expect(source, contains('// step loop (PassFailCount): while RunState.LoopIndex < 10'));
      expect(source, contains('// status expression: Step.Result.Status'));
      expect(source, contains('lw.skipTest('));
      expect(source, contains('flow action of step "Voltage OK"'));
      expect(source, contains('per-step looping not exported'));
      expect(source, contains('status expression of step "Voltage OK" not exported'));
    });

    test('a status expression of the literal "" is noted but does not disarm', () {
      final file = _fileWith([
        _seqWith(
          'MainSequence',
          locals: [_num('X', '0')],
          steps: [
            _stepWith(
              'Clear status',
              typeName: 'Statement',
              ts: [
                _p('StatusExpr', value: '""'),
                _p('PostExpr', value: 'Locals.X = 1'),
              ],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToLabwright(file);
      expect(source, contains('// status expression: ""'));
      expect(source, contains('lw.test('), reason: 'a cleared status cannot encode pass/fail logic');
      expect(source, isNot(contains('lw.skipTest(')));
    });

    test('a VI call states its connector wiring', () {
      final file = _fileWith([
        _seqWith(
          'MainSequence',
          steps: [
            _stepWith(
              'Read DMM',
              sdata: [
                _p(
                  'ViCall',
                  sub: [
                    _p('VIPath', value: 'Read.vi'),
                    SeqProperty(
                      name: 'Parms',
                      array: [
                        _p(
                          '0',
                          sub: [
                            _str('Label', 'VISA resource name'),
                            _p('ArgVal', value: 'Locals.Session'),
                          ],
                        ),
                        _p('1', sub: [_str('Label', 'unwired input')]),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToDart(file);
      expect(source, contains('//   VISA resource name <- Locals.Session'));
      expect(source, isNot(contains('unwired input')), reason: 'a row with no binding and no out direction is silent');
    });

    test('a .NET call chain is recognized and stated; the throw names the member', () {
      final step = _stepWith(
        'DMM Read',
        sdata: [
          SeqProperty(
            name: 'Calls',
            array: [
              _p(
                '0',
                sub: [
                  _str('ClassName', 'Knv.Instr.GenericDMM'),
                  _num('MemberType', '6'),
                  _str('MemberName', 'Use Existing Object'),
                ],
              ),
              _p(
                '1',
                sub: [
                  _str('ClassName', 'Knv.Instr.GenericDMM'),
                  _num('MemberType', '1'),
                  _str('MemberName', 'Read'),
                ],
              ),
            ],
          ),
          _p('AssemblyPath', value: r'bin\Knv.Instr.dll'),
          _p('ClassName', value: 'Knv.Instr.GenericDMM'),
        ],
      );
      final module = Step(step).module;
      expect(module.adapter, SeqAdapter.dotNet);
      expect(module.assemblyPath, r'bin\Knv.Instr.dll');
      expect([for (final call in module.dotNetCalls) call.memberName], ['Use Existing Object', 'Read']);
      final source = exportSeqFileToLabwright(
        _fileWith([
          _seqWith('MainSequence', steps: [step]),
        ]),
      );
      expect(source, contains(r'// .NET assembly: bin\Knv.Instr.dll'));
      expect(source, contains('// .NET call: Knv.Instr.GenericDMM.Use Existing Object'));
      expect(source, contains('// .NET call: Knv.Instr.GenericDMM.Read'));
      expect(source, contains('dotNet call: Knv.Instr.GenericDMM.Read'));
    });

    test('an async sequence call is stated and disarms', () {
      final file = _fileWith([
        _seqWith(
          'MainSequence',
          steps: [
            _stepWith(
              'Spawn monitor',
              sdata: [
                _p('SeqName', value: 'Monitor'),
                _num('ThreadOpt', '1'),
              ],
            ),
            _stepWith(
              'Do work',
              typeName: 'Statement',
              ts: [_p('PostExpr', value: 'Locals.X = 1')],
            ),
          ],
        ),
        _seqWith('Monitor'),
      ]);
      final source = exportSeqFileToLabwright(file);
      expect(source, contains('// sequence call spawns a new thread in the engine'));
      expect(source, contains('runs its sequence call in a new thread (not exported)'));
    });

    test('popup, database, and executable payloads surface as notes', () {
      final file = _fileWith([
        _seqWith(
          'MainSequence',
          steps: [
            _stepWith(
              'Ask operator',
              typeName: 'MessagePopup',
              props: [
                _p('TitleExpr', value: '"Result"'),
                _p('MessageExpr', value: 'Str(Locals.Reading)'),
                _p('Button1Label', value: '"OK"'),
                _p('Button2Label', value: '""'),
              ],
            ),
            _stepWith(
              'Open statement',
              typeName: 'NI_OpenSQLStatement',
              props: [
                _p('SQLStatement', value: 'Locals.FullSQLStatement'),
                _p('StatementHandle', value: 'Locals.StatementRef'),
              ],
            ),
            _stepWith(
              'Run tool',
              typeName: 'CallExecutable',
              props: [
                _p('Executable', value: 'cmd.exe'),
                _p('Arguments', value: '"cmd /c echo hi"'),
                _p('WaitCondition', value: 'WAIT_FOR_EXIT'),
              ],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToDart(file);
      expect(source, contains('// popup title: "Result"'));
      expect(source, contains('// popup message: Str(Locals.Reading)'));
      expect(source, contains('// popup buttons: "OK"'));
      expect(source, isNot(contains('""')), reason: 'unlabeled buttons are skipped');
      expect(source, contains('// SQL: Locals.FullSQLStatement'));
      expect(source, contains('// statement handle: Locals.StatementRef'));
      expect(source, contains('// runs executable: cmd.exe "cmd /c echo hi" (WAIT_FOR_EXIT)'));
    });
  });

  group('call-parameter export', () {
    test('UseDef rows are omitted (exact) and the caller stays ARMED', () {
      final file = _fileWith([
        _seqWith(
          'Caller',
          steps: [
            _callStep('Run it', 'Callee', args: [_argRow('Threshold', useDefault: true)]),
          ],
        ),
        _seqWith('Callee', params: [_num('Threshold', '5')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains('await callee(); // Run it'));
      expect(source, contains("lw.test('Caller'"), reason: 'omission is exact — no disarm');
      expect(source, isNot(contains('call parameters')));
    });

    test('literals, variable paths, and bools translate to named arguments', () {
      final file = _fileWith([
        _seqWith(
          'Caller',
          locals: [_num('Count', '3')],
          steps: [
            _callStep(
              'Run it',
              'Callee',
              args: [
                _argRow('Label', expr: '"abc"'),
                _argRow('Enabled', expr: 'True'),
                _argRow('Count', expr: 'Locals.Count'),
                _argRow('Gain', expr: '1 + 2'),
              ],
            ),
          ],
        ),
        _seqWith('Callee', params: [_str('Label'), _bool('Enabled', 'False'), _num('Count', '0'), _num('Gain', '2.5')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(
        source,
        contains('await callee(label: "abc", enabled: true, count: count, gain: (1 + 2).toDouble()); // Run it'),
      );
      expect(source, contains("lw.test('Caller'"), reason: 'every argument translated mechanically — armed');
    });

    test('an eval-fallback VALUE still emits and the hazard scan disarms the test', () {
      final file = _fileWith([
        _seqWith(
          'Caller',
          steps: [
            _callStep('Run it', 'Callee', args: [_argRow('Count', expr: 'GetNumSockets()')]),
          ],
        ),
        _seqWith('Callee', params: [_num('Count', '0')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains("await callee(count: ts.eval('GetNumSockets()')); // Run it"));
      expect(source, contains("lw.skipTest('Caller'"));
      expect(source, contains('untranslated expression in body'));
    });

    test('a stale argument name is omitted and disarms the SITE with its reason', () {
      final file = _fileWith([
        _seqWith(
          'Caller',
          steps: [
            _callStep(
              'Run it',
              'Callee',
              args: [
                _argRow('Ghost', expr: '1'),
                _argRow('Real', expr: '2'),
              ],
            ),
          ],
        ),
        _seqWith('Callee', params: [_num('Real', '0')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains('await callee(real: 2); // Run it'));
      expect(source, contains("lw.skipTest('Caller'"));
      expect(source, contains('call parameters of sequence Callee: no parameter named Ghost (stale binding)'));
    });

    test('a type-guard rejection keeps the raw expression in eval and states why', () {
      final file = _fileWith([
        _seqWith(
          'Caller',
          locals: [_num('N', '0')],
          steps: [
            _callStep('Run it', 'Callee', args: [_argRow('Label', expr: 'Locals.N + 1')]),
          ],
        ),
        _seqWith('Callee', params: [_str('Label')]),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains("await callee(label: ts.eval('Locals.N + 1')); // Run it"));
      expect(source, contains('call parameters of sequence Callee: Label binding is not visibly String-typed'));
    });

    test('scalar by-ref writeback disarms a variable-path binding; a literal binding is safe', () {
      final callee = _seqWith(
        'Callee',
        params: [_num('X', '0')],
        steps: [
          _p(
            'Bump',
            type: 'Statement',
            sub: [
              _p('TS', sub: [_p('PostExpr', value: 'Parameters.X = Parameters.X + 1')]),
            ],
          ),
        ],
      );
      final varBound = _fileWith([
        _seqWith(
          'Caller',
          locals: [_num('Y', '0')],
          steps: [
            _callStep('Run it', 'Callee', args: [_argRow('X', expr: 'Locals.Y')]),
          ],
        ),
        callee,
      ]);
      final varSource = exportSeqFileToLabwright(varBound, sourceName: 'own.seq');
      expect(varSource, contains('await callee(x: y); // Run it'), reason: 'the value still passes in');
      expect(varSource, contains("lw.skipTest('Caller'"));
      expect(varSource, contains('by-ref writeback of parameter X of sequence Callee not exported'));

      final literalBound = _fileWith([
        _seqWith(
          'Caller',
          steps: [
            _callStep('Run it', 'Callee', args: [_argRow('X', expr: '5')]),
          ],
        ),
        callee,
      ]);
      final literalSource = exportSeqFileToLabwright(literalBound, sourceName: 'own.seq');
      expect(literalSource, contains('await callee(x: 5); // Run it'));
      expect(literalSource, contains("lw.test('Caller'"), reason: 'a literal has nothing to write back to — armed');
    });

    test('a call binding demotes an int-refined callee parameter (analyze-safe)', () {
      final file = _fileWith([
        _seqWith(
          'Caller',
          steps: [
            _callStep('Run it', 'Callee', args: [_argRow('X', expr: '2.5')]),
          ],
        ),
        _seqWith('Callee', params: [_num('X', '0')]),
      ]);
      final source = exportSeqFileToDart(file, sourceName: 'own.seq');
      expect(source, contains('Future<void> callee({double x = 0}) async {'));
      expect(source, contains('await callee(x: 2.5); // Run it'));
    });

    test('an external stub gets a TYPED signature from the prototype snapshot', () {
      final proto = [
        _str('ChannelName', 'dev1'),
        _num('VoltageLimit', '5'),
        SeqProperty(name: 'Thresholds', className: 'Nums', array: []),
      ];
      final file = _fileWith([
        _seqWith(
          'Caller',
          steps: [
            _callStep(
              'Configure',
              'Load Config',
              file: r'..\Load Config.seq',
              args: [
                _argRow('ChannelName', expr: '"ps1"'),
                _argRow('VoltageLimit', useDefault: true),
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
      final file = _fileWith([
        _seqWith(
          'Caller',
          steps: [
            _callStep(
              'First',
              'Helper',
              file: 'other.seq',
              args: [_argRow('A', expr: '1')],
              prototype: [_num('A', '0')],
            ),
            _callStep(
              'Second',
              'Helper',
              file: 'other.seq',
              args: [_argRow('B', expr: '2')],
              prototype: [_num('B', '0')],
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
      final file = _fileWith([
        _seqWith(
          'Caller',
          steps: [
            _stepWith(
              'Dynamic call',
              sdata: [
                _p('SpecifyByExpr', cls: 'Bool', value: 'True'),
                _p('SeqNameExpr', value: 'Locals.Target'),
                _p('SFPathExpr', value: '"x.seq"'),
                _p('SeqName', value: ''),
                _p(
                  'ActualArgs',
                  cls: 'Obj',
                  sub: [_argRow('X', expr: '1')],
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
      final caller = _fileWith([
        _seqWith(
          'MainSequence',
          steps: [
            _callStep(
              'Use helper',
              'Helper',
              file: 'b.seq',
              args: [_argRow('X', expr: '3')],
            ),
            _callStep(
              'Break helper',
              'Helper',
              file: 'b.seq',
              args: [_argRow('X', expr: '3.5')],
            ),
          ],
        ),
      ]);
      final calleeFile = _fileWith([
        _seqWith('Helper', params: [_num('X', '0')]),
      ]);
      final project = exportSeqProjectToLabwright({'a.seq': caller, 'b.seq': calleeFile});
      final aSource = project.files['a_seq.dart']!;
      expect(project.files['b_seq.dart'], contains('Future<void> helper({int x = 0}) async {'));
      expect(aSource, contains('await b_seq.helper(x: 3); // Use helper: external sequence'));
      expect(aSource, contains("await b_seq.helper(x: ts.eval('3.5')); // Break helper: external sequence"));
      expect(aSource, contains('call parameters of sequence Helper: X binding is not visibly int-typed'));
    });
  });

  test('array parameters export NULLABLE with a ??= preamble carrying the DECLARED default', () {
    final file = _fileWith([
      _p(
        'MainSequence',
        sub: [
          _p(
            'Parameters',
            cls: 'Obj',
            sub: [
              SeqProperty(
                name: 'Thresholds',
                className: 'Nums',
                array: [
                  _p('[0]', cls: 'Num', value: '1.5'),
                  _p('[1]', cls: 'Num', value: '2'),
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
}
