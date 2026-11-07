import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

SeqProperty _p(String name, {String? cls, String? type, String? value, List<SeqProperty> sub = const []}) =>
    SeqProperty(name: name, className: cls, typeName: type, scalar: value, subProps: sub);

SeqFile _fileWith(List<SeqProperty> sequenceProps, {List<SeqProperty> types = const []}) => SeqFile(
  header: const SeqFileHeader(format: SeqFormat.xml),
  types: types,
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
      expect(source, contains("if (voltageOkResult.Status == 'Failed') { // post action\n      break body;"));
      expect(source, contains('while (loop.index < 10) { // loop while'));
      expect(source, contains('voltageOkResult.Status = voltageOkResult.Status; // status expression'));
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
      expect(source, contains('run.record(await callee()); // Run it'));
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
        contains(
          "run.record(await callee(label: 'abc', enabled: true, count: count, gain: (1 + 2).toDouble())); // Run it",
        ),
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
      expect(source, contains("run.record(await callee(count: ts.eval('GetNumSockets()'))); // Run it"));
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
      expect(source, contains('run.record(await callee(real: 2)); // Run it'));
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
      expect(source, contains("run.record(await callee(label: ts.eval('Locals.N + 1'))); // Run it"));
      expect(source, contains('call parameters of sequence Callee: Label binding is not visibly String-typed'));
    });

    SeqProperty bumpingCallee({required bool byReference}) => _seqWith(
      'Callee',
      params: [
        SeqProperty(
          name: 'X',
          className: 'Num',
          scalar: '0',
          attributes: {if (byReference) 'valueflags': '${SeqPropertyFlag.passByReference.bit}'},
        ),
      ],
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
    test('a written by-ref scalar passes a box the caller reads back; a literal passes a fresh box', () {
      final callee = bumpingCallee(byReference: true);
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
      expect(
        varSource,
        contains(
          '  final xRef = ts.Ref<int>(y);\n  run.record(await callee(x: xRef)); // Run it\n  y = xRef.value;',
        ),
      );
      expect(
        varSource,
        contains('Future<String> callee({ts.Ref<int>? x}) async {\n  final xRef = x ?? ts.Ref<int>(0);'),
      );
      expect(varSource, contains("lw.test('Caller'"));

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
      expect(literalSource, contains('run.record(await callee(x: ts.Ref<int>(5))); // Run it'));
      expect(literalSource, contains("lw.test('Caller'"), reason: 'a literal has nothing to write back to — armed');
    });
    test('a by-value container parameter is copied on entry; a by-reference one is shared', () {
      final source = exportSeqFileToDart(
        _fileWith([
          _seqWith(
            'Callee',
            params: [
              SeqProperty(name: 'Copied', className: 'Obj', subProps: [_num('A', '1')]),
              SeqProperty(
                name: 'Shared',
                className: 'Obj',
                subProps: [_num('A', '1')],
                attributes: {'valueflags': '${SeqPropertyFlag.passByReference.bit}'},
              ),
            ],
          ),
        ]),
      );
      expect(source, contains('  copied = ts.copy(copied);\n'));
      expect(source, isNot(contains('shared = ts.copy(shared)')));
    });
    test('a by-value parameter the callee writes leaves a variable-path binding armed', () {
      final file = _fileWith([
        _seqWith(
          'Caller',
          locals: [_num('Y', '0')],
          steps: [
            _callStep('Run it', 'Callee', args: [_argRow('X', expr: 'Locals.Y')]),
          ],
        ),
        bumpingCallee(byReference: false),
      ]);
      final source = exportSeqFileToLabwright(file, sourceName: 'own.seq');
      expect(source, contains('run.record(await callee(x: y)); // Run it'));
      expect(source, contains("lw.test('Caller'"));
      expect(source, isNot(contains('writeback')));
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
      expect(source, contains('Future<String> callee({double x = 0}) async {'));
      expect(source, contains('run.record(await callee(x: 2.5)); // Run it'));
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
      expect(source, contains("await loadConfig(channelName: 'ps1'); // Configure: external sequence call"));
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
      expect(project.files['b_seq.dart'], contains('Future<String> helper({int x = 0}) async {'));
      expect(aSource, contains('run.record(await b_seq.helper(x: 3)); // Use helper: external sequence'));
      expect(
        aSource,
        contains("run.record(await b_seq.helper(x: ts.eval('3.5'))); // Break helper: external sequence"),
      );
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
    expect(source, contains('Future<String> mainSequence({List<dynamic>? thresholds, List<dynamic>? names}) async {'));
    expect(source, contains('thresholds ??= <dynamic>[1.5, 2];'));
    expect(source, contains('names ??= <dynamic>[];'));
    expect(source, isNot(contains('const []')), reason: 'a shared const default would alias across calls');
  });
  group('expression translation', () {
    String statement(String expression) {
      final file = _fileWith([
        _seqWith(
          'Main',
          locals: [
            _num('Count', '3'),
            _num('Ratio', '0.5'),
            _str('Text'),
            _bool('Flag'),
            _p('Bag', cls: 'Obj', sub: [_num('X')]),
          ],
          steps: [
            _stepWith(
              'Do',
              typeName: 'Statement',
              ts: [_p('PostExpr', value: expression)],
            ),
          ],
        ),
      ]);
      final source = exportSeqFileToDart(file);
      return [
        for (final line in source.split('\n'))
          if (line.endsWith('// Do') || line.endsWith('// Do (cont.)')) line.trim(),
      ].join('\n');
    }

    test('conditionals keep their branches and precedence', () {
      expect(
        statement('Locals.Flag ? (Locals.Text = "a") : (Locals.Text = @"b\\c")'),
        r"flag ? (text = 'a') : (text = 'b\\c'); // Do",
      );
      expect(statement('Locals.Ratio = (Locals.Count + 1) * 2'), 'ratio = (count + 1) * 2; // Do');
      expect(statement('Locals.Flag = Locals.Count & 4 ? True : False'), 'flag = count & 4 != 0 ? true : false; // Do');
    });
    test('AllOf, AnyOf and Evaluate of a literal lower to plain Dart', () {
      expect(
        statement('Locals.Flag = AllOf(Locals.Count > 1, AnyOf(Locals.Flag, Locals.Ratio))'),
        'flag = count > 1 && (flag || ratio != 0); // Do',
      );
      expect(statement('Locals.Ratio = Evaluate("Locals.Ratio * 2")'), 'ratio = ratio * 2; // Do');
      expect(statement('Locals.Flag = AllOf(Locals.Count++ > 1)'), startsWith('ts.eval('));
    });
    test('remainder keeps the sign of the dividend', () {
      expect(statement('Locals.Count = Locals.Count % 2'), 'count = count.remainder(2); // Do');
    });
    test('roots resolve case-insensitively; dynamic objects take any member', () {
      expect(statement('locals.bag.X += 1'), 'bag.X += 1; // Do');
    });
    test('a comma list emits one statement per item', () {
      expect(statement('Locals.Count = 1, Locals.Text = "x"'), "count = 1; // Do\ntext = 'x'; // Do (cont.)");
    });
    test('constructs without a Dart counterpart stay verbatim', () {
      expect(statement('Locals.Text = Locals.Count'), startsWith('ts.eval('));
      expect(statement('Locals.Flag = Locals.Text < "b"'), startsWith('ts.eval('));
      expect(statement('Locals.Text = PropValType_Enum'), startsWith('ts.eval('));
      expect(parseSeqExpression('&Locals.Count'), isNull);
      expect(parseSeqExpression('Locals.A <<= 1'), isNull);
    });
  });
  group('step results', () {
    final limitType = _p(
      'NumericLimitTest',
      sub: [
        SeqProperty(
          name: 'Substeps',
          array: [SeqProperty(name: 'Edit', typeName: 'EditSubstep')],
        ),
      ],
    );
    SeqProperty limitTest(String name, {String dataSource = '10', List<SeqProperty> ts = const []}) => _stepWith(
      name,
      typeName: 'NumericLimitTest',
      ts: [
        _p(
          'StatusExpr',
          value:
              'CheckLimits(Step.DataSource == "Step.Result.Numeric" ? Step.Result.Numeric : '
              '(Step.Result.Numeric = Evaluate(Step.DataSource)), Step.Limits.High, Step.Limits.Low, Step.Comp)',
        ),
        ...ts,
      ],
      props: [
        _p('Comp', cls: 'Str', value: 'GELE'),
        _p('DataSource', cls: 'Str', value: dataSource),
        _p('Limits', sub: [_num('Low', '9'), _num('High', '11')]),
        _p('Result', sub: [_str('Status', ''), _num('Numeric', '0')]),
      ],
    );
    test('a limit test without a module is judged by its status expression and fails the sequence', () {
      final source = exportSeqFileToLabwright(
        _fileWith(
          [
            _seqWith(
              'Main',
              locals: [_num('Volts', '10.5')],
              steps: [limitTest('Volts', dataSource: 'Locals.Volts')],
            ),
          ],
          types: [limitType],
        ),
      );
      expect(source, contains("dynamic voltsResult = ts.PropObj({'Status': '', 'Numeric': 0});"));
      expect(
        source,
        contains(
          "voltsResult.Status = ts.checkLimits(voltsResult.Numeric = volts, 11, 9, 'GELE'); // status expression",
        ),
      );
      expect(source, contains('run.record(voltsResult.Status);'));
      expect(source, contains('return run.status;'));
      expect(source, contains("lw.expect(await main\$(), 'Passed');"));
      expect(source, contains("lw.test('Main'"));
    });
    test('a skipped precondition sets Skipped; a step that cannot fail the sequence is not recorded', () {
      final source = exportSeqFileToDart(
        _fileWith([
          _seqWith(
            'Main',
            steps: [
              limitTest(
                'A',
                ts: [
                  _p('PreCond', value: 'False'),
                  _bool('StepFCSeqF', 'false'),
                ],
              ),
            ],
          ),
        ]),
      );
      expect(source, contains("  } else {\n    aResult.Status = 'Skipped';\n  }"));
      expect(source, isNot(contains('run.record(aResult.Status)')));
    });
    test('other steps read a result by name or id, and the sequence failure flag', () {
      final source = exportSeqFileToDart(
        _fileWith([
          _seqWith(
            'Main',
            locals: [_bool('Seen')],
            steps: [
              limitTest('A', ts: [_p('Id', value: 'ID#:abc')]),
              _stepWith(
                'B',
                typeName: 'Statement',
                ts: [
                  _p(
                    'PostExpr',
                    value:
                        'Locals.Seen = RunState.Sequence.Main["ID#:abc"].Result.Status == "Passed" || RunState.SequenceFailed',
                  ),
                ],
              ),
              _callStep('Call', 'Main'),
            ],
          ),
        ]),
      );
      expect(source, contains("seen = aResult.Status == 'Passed' || run.failed; // B"));
      expect(source, contains('run.record(await main\$()); // Call'));
    });
    test('a step that stores no status expression takes its type default', () {
      final source = exportSeqFileToDart(
        _fileWith(
          [
            _seqWith('Main', steps: [_stepWith('Check', typeName: 'PassFailTest')]),
          ],
          types: [
            _p(
              'PassFailTest',
              sub: [
                _p('TS', sub: [_p('StatusExpr', value: 'Step.Result.PassFail ? "Passed" : "Failed"')]),
              ],
            ),
          ],
        ),
      );
      expect(source, contains("checkResult.Status = ts.truthy(checkResult.PassFail) ? 'Passed' : 'Failed';"));
    });
  });
  group('post actions', () {
    SeqProperty gotoStep(String name, String target, {String expression = 'True', String action = 'Goto'}) => _stepWith(
      name,
      typeName: 'Goto',
      ts: [
        _p('CustExpr', value: expression),
        _p('CustTrueAct', value: action),
        _p('CustTrueActTarget', value: '"$target"'),
      ],
    );
    SeqProperty statement(String name, String expression) => _stepWith(
      name,
      typeName: 'Statement',
      ts: [_p('PostExpr', value: expression)],
    );
    SeqProperty flow(String name, String type, [String? condition]) => _stepWith(
      name,
      typeName: type,
      props: [if (condition != null) _p('ConditionExpr', value: condition)],
    );
    String export(List<SeqProperty> main, {List<SeqProperty> cleanup = const []}) {
      final sequence = _seqWith('Main', locals: [_num('N', '0'), _bool('Flag')], steps: main);
      return exportSeqFileToLabwright(
        _fileWith(
          [
            if (cleanup.isEmpty)
              sequence
            else
              _p(
                'Main',
                sub: [
                  ...sequence.subProps,
                  SeqProperty(name: 'Cleanup', className: 'Objs', array: cleanup),
                ],
              ),
          ],
          types: [
            _p(
              'Goto',
              sub: [SeqProperty(name: 'Substeps', array: const [])],
            ),
          ],
        ),
      );
    }

    test('a forward goto out of a block breaks a label that closes before its target', () {
      final source = export([
        flow('If', 'NI_Flow_If', 'Locals.Flag'),
        gotoStep('Skip', 'Done'),
        flow('End', 'NI_Flow_End'),
        statement('Work', 'Locals.N = 1'),
        _stepWith('Done', typeName: 'Label'),
      ]);
      expect(
        source,
        contains(
          '  skipToDone: {\n    if (flag) {\n      // goto -> Done\n      // Skip [Goto]: no code module\n'
          '      break skipToDone; // post action\n    }\n    n = 1; // Work\n  }\n  // label: Done',
        ),
      );
      expect(source, contains("lw.test('Main'"));
    });
    test('a backward goto loops; <End> leaves the group', () {
      final source = export([
        _stepWith('Top', typeName: 'Label'),
        statement('Count', 'Locals.N += 1'),
        gotoStep('Again', 'Top', expression: 'Locals.N < 3'),
        gotoStep('Out', '<End>'),
        statement('Never', 'Locals.N = 0'),
      ]);
      expect(source, contains('backToTop: while (true) {'));
      expect(source, contains('if (n < 3) { // post action\n        continue backToTop;\n      }'));
      expect(source, contains('break backToTop;\n    }'));
      expect(source, contains('break endMain; // post action'));
    });
    test('a goto into the cleanup group skips the cleanup steps before its target', () {
      final source = export(
        [gotoStep('Bail', 'Late')],
        cleanup: [
          statement('Early', 'Locals.N = 1'),
          _stepWith('Late', typeName: 'Label'),
        ],
      );
      expect(source, contains('var cleanupFrom = 0;\n  body: try {'));
      expect(source, contains('cleanupFrom = 1; break body; // post action'));
      expect(source, contains('    if (cleanupFrom < 1) {\n      n = 1; // Early\n    }\n    // label: Late\n  }'));
    });
    test('Terminate raises; Call Sequence calls the named sequence', () {
      final source = export([
        gotoStep('Stop', '', expression: 'Locals.Flag', action: 'Terminate'),
        gotoStep('Again', 'Main', action: 'Cback'),
      ]);
      expect(source, contains('if (flag) { // post action\n    ts.terminate();\n  }'));
      expect(source, contains('await main\$(); // post action'));
    });
  });
  group('loops', () {
    test('a looping step repeats under its own loop state and takes the loop status', () {
      final source = exportSeqFileToDart(
        _fileWith([
          _seqWith(
            'Main',
            locals: [_num('Total', '0')],
            steps: [
              _stepWith(
                'Retry',
                typeName: 'Statement',
                ts: [
                  _p('PostExpr', value: 'Locals.Total += RunState.LoopIndex'),
                  _p('LoopType', value: 'PassFailCount'),
                  _p('LoopInitialize', value: 'RunState.LoopIndex = 0'),
                  _p('LoopWhile', value: 'RunState.LoopIndex < 3 && RunState.LoopNumPassed < 1'),
                  _p('LoopIncrement', value: 'RunState.LoopIndex += 1'),
                  _p('LoopStatus', value: 'RunState.LoopNumPassed >= 1 ? "Passed" : "Failed"'),
                ],
              ),
            ],
          ),
        ]),
      );
      expect(
        source,
        contains(
          '  final loop = ts.StepLoop();\n'
          '  loop.index = 0; // loop initialize\n'
          '  while (loop.index < 3 && loop.numPassed < 1) { // loop while\n'
          "    retryResult = ts.PropObj({'Status': ''});\n"
          '    total += loop.index; // Retry\n'
          "    retryResult.Status = 'Done';\n"
          '    loop.count(retryResult.Status);\n'
          '    loop.index += 1; // loop increment\n'
          '  }\n'
          "  retryResult.Status = loop.numPassed >= 1 ? 'Passed' : 'Failed'; // loop status\n"
          '  run.record(retryResult.Status);',
        ),
      );
    });
    SeqProperty sweepParameter(String strategy, String target, {int? level, List<SeqProperty> extra = const []}) => _p(
      '[0]',
      sub: [
        _str('ParameterStrategy', strategy),
        _str('ParameterStepOperation', 'Linear'),
        _p('ExpressionSettings', sub: [_str('ValueExpr', target)]),
        if (level != null) _num('Level', '$level'),
        ...extra,
      ],
    );
    String sweep(List<SeqProperty> parameters) => exportSeqFileToDart(
      _fileWith([
        _seqWith(
          'Main',
          locals: [_num('Freq', '0'), _num('Amp', '0')],
          steps: [
            _stepWith(
              'Sweep Loop',
              typeName: 'NI_Flow_SweepLoop',
              props: [SeqProperty(name: 'Parameters', className: 'Objs', array: parameters)],
            ),
            _stepWith(
              'Body',
              typeName: 'Statement',
              ts: [_p('PostExpr', value: 'Locals.Amp += Locals.Freq')],
            ),
            _stepWith('End', typeName: 'NI_Flow_End'),
          ],
        ),
      ]),
    );
    test('sweep levels nest outermost first; a level sweeps its points', () {
      final source = sweep([
        sweepParameter(
          'StartStopNumPoints',
          'Locals.Freq',
          level: 0,
          extra: [_str('StartExpr', '1000'), _str('StopExpr', '6000'), _str('SweepPointsExpr', '3')],
        ),
        sweepParameter('Array', 'Locals.Amp', level: 1, extra: [_str('ArrayExpr', '{-6, -20}')]),
      ]);
      expect(
        source,
        contains(
          '  sweep: for (final value in ts.sweepPoints(1000, 6000, 3)) {\n'
          '    freq = (value as num).toDouble();\n'
          '    for (final value2 in <dynamic>[-6, -20]) {\n'
          '      amp = (value2 as num).toDouble();\n'
          '      amp += freq; // Body\n'
          '    }\n'
          '  }',
        ),
      );
    });
    test('parameters from before sweep levels existed stay unexported when there are several', () {
      final source = sweep([
        sweepParameter('Array', 'Locals.Freq', extra: [_str('ArrayExpr', '{1}')]),
        sweepParameter('Array', 'Locals.Amp', extra: [_str('ArrayExpr', '{2}')]),
      ]);
      expect(source, contains('not exported; the body runs once'));
    });
  });
  group('step types acting through the host', () {
    SeqProperty typeWith(String name, List<String> substepKinds) => _p(
      name,
      sub: [
        SeqProperty(
          name: 'Substeps',
          array: [for (final kind in substepKinds) SeqProperty(name: kind, typeName: '${kind}Substep')],
        ),
      ],
    );
    test('a message popup asks the host and stores the button and response in its result', () {
      final source = exportSeqFileToLabwright(
        _fileWith(
          [
            _seqWith(
              'Main',
              locals: [_bool('Go')],
              steps: [
                _stepWith(
                  'Ask',
                  typeName: 'MessagePopup',
                  ts: [_p('PostExpr', value: 'Locals.Go = Step.Result.ButtonHit == 1')],
                  props: [
                    _p('TitleExpr', value: 'NameOf(Step)'),
                    _p('MessageExpr', value: '"Line one\nLine two"'),
                    _p('Button1Label', value: '"Yes"'),
                    _p('Button2Label', value: '"No"'),
                    _p('Result', sub: [_str('Status', ''), _num('ButtonHit', '0'), _str('Response', '')]),
                  ],
                ),
              ],
            ),
          ],
          types: [
            typeWith('MessagePopup', ['Edit', 'Post']),
          ],
        ),
      );
      expect(
        source,
        contains(
          "final popup = await ts.stepHost.messagePopup(title: 'Ask', message: 'Line one\\nLine two', "
          "buttons: ['Yes', 'No', '', '', '', '']);\n"
          '  askResult.ButtonHit = popup.buttonHit;\n'
          '  askResult.Response = popup.response;\n'
          '  go = askResult.ButtonHit == 1; // post-expression',
        ),
      );
      expect(source, contains('step type MessagePopup acts through ts.stepHost'));
      expect(source, isNot(contains('UnimplementedError')));
    });
    test('Pre substeps run before the code module and Post substeps after it', () {
      final source = exportSeqFileToDart(
        _fileWith(
          [
            _seqWith(
              'Main',
              steps: [
                _stepWith(
                  'Measure',
                  typeName: 'Vendor',
                  sdata: [_p('ModulePath', value: 'measure.py')],
                  props: [_num('Gain', '2')],
                ),
              ],
            ),
          ],
          types: [
            typeWith('Vendor', ['Pre', 'Post']),
          ],
        ),
      );
      final pre = source.indexOf(
        "ts.stepHost.runStepType('Vendor', ts.StepPhase.pre, ts.PropObj({'Gain': 2}), measureResult);",
      );
      final post = source.indexOf(
        "ts.stepHost.runStepType('Vendor', ts.StepPhase.post, ts.PropObj({'Gain': 2}), measureResult);",
      );
      expect((pre >= 0, post > pre), (true, true));
    });
  });
}
