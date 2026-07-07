import 'package:labwright_seq/labwright_seq.dart';
import 'package:test/test.dart';

/// Corpus-free unit pins for exporter behaviors small enough to state
/// exactly (the whole-corpus batched analyze gate covers everything else):
///  * stub NAMING strips a known trailing file extension (review fix: the
///    `\$`-in-raw-string regex never matched, so stub names carried
///    `.vi`/`.seq` tails);
///  * the typed SequenceCall argument/prototype lenses on [StepModule];
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
