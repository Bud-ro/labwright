import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';
import 'package:test/test.dart';

LvPath _path(String text, {bool absolute = true}) => LvPath(components: text.split('/'), absolute: absolute);

void main() {
  group('numeric', () {
    test('Quotient & Remainder with a zero divisor: integers give (0, x), floats (inf, NaN)', () {
      expect(lvQuotientRemainderInt(7, 0), (0, 7));
      expect(lvQuotientRemainderInt(-7, 2), (-4, 1));
      final (quotient, remainder) = lvQuotientRemainderFloat(7.5, 0);
      expect(quotient, double.infinity);
      expect(remainder.isNaN, isTrue);
      expect(lvQuotientRemainderFloat(7.5, 2), (3.0, 1.5));
    });

    test('Max & Min: the larger first, one NaN yields the other operand twice', () {
      expect(lvMaxAndMin(3, 9), (9, 3));
      expect(lvMaxAndMin(2.5, double.nan), (2.5, 2.5));
      expect(lvMaxAndMinComparable('b', 'a'), ('b', 'a'));
    });

    test('In Range and Coerce includes the lower limit, excludes the upper, and clamps', () {
      expect(lvInRangeAndCoerce(10, 5, 0), (coerced: 5, inRange: true));
      expect(lvInRangeAndCoerce(10, 0, 0), (coerced: 0, inRange: true));
      expect(lvInRangeAndCoerce(10, 10, 0), (coerced: 10, inRange: false));
      expect(lvInRangeAndCoerce(10, 12, 0), (coerced: 10, inRange: false));
      expect(lvInRangeAndCoerce(10, -3, 0), (coerced: 0, inRange: false));
      final nan = lvInRangeAndCoerce(10.0, double.nan, 0.0);
      expect(nan.coerced.isNaN, isTrue);
      expect(nan.inRange, isFalse);
    });

    test('Boolean Array To Number reads element 0 as the least significant bit and pads', () {
      expect(lvBooleanArrayToNumber([false, true], 8, signed: true), -2);
      expect(lvBooleanArrayToNumber([false, true], 8, signed: false), 2);
      expect(lvBooleanArrayToNumber([false, true, false, true], 8, signed: true), -6);
      expect(lvBooleanArrayToNumber([false, true, false, true], 8, signed: true, signExtend: false), 10);
      expect(
        lvBooleanArrayToNumber([true, false, false, false, false, false, false, false, true], 8, signed: false),
        1,
      );
      expect(lvBooleanArrayToNumber([], 32, signed: true), 0);
    });

    test('Number To Boolean Array puts the least significant bit first', () {
      expect(lvNumberToBooleanArray(5, 8), [true, false, true, false, false, false, false, false]);
      expect(lvNumberToBooleanArray(-1, 8), everyElement(isTrue));
      expect(lvBooleanArrayToNumber(lvNumberToBooleanArray(-12345, 16), 16, signed: true), -12345);
    });

    test('Boolean To (0,1), Square Root of a negative, powers and logarithms', () {
      expect(lvBooleanToZeroOne(true), 1);
      expect(lvBooleanToZeroOne(false), 0);
      expect(lvSquareRoot(-1).isNaN, isTrue);
      expect(lvSquareRoot(16), 4.0);
      expect(lvPowerOfX(2, 10), 1024.0);
      expect(lvPowerOf10(3), 1000.0);
      expect(lvLogarithmBase10(1000), closeTo(3, 1e-12));
      expect(lvMantissaAndExponent(12.0), (1.5, 3));
      expect(lvMantissaAndExponent(0.0), (0.0, 0));
    });

    test('a float rounds to the nearest integer, ties to even, and saturates', () {
      expect(lvRoundToInteger(2.5, 32, signed: true), 2);
      expect(lvRoundToInteger(3.5, 32, signed: true), 4);
      expect(lvRoundToInteger(-2.5, 32, signed: true), -2);
      expect(lvRoundToInteger(300.0, 8, signed: true), 127);
      expect(lvRoundToInteger(-300.0, 8, signed: true), -128);
      expect(lvRoundToInteger(300.0, 8, signed: false), 255);
      expect(lvRoundToInteger(-1.0, 8, signed: false), 0);
      expect(lvRoundToInteger(double.nan, 32, signed: true), 0);
    });
  });

  group('strings', () {
    test('Number To Decimal String pads to the width with spaces, never truncates', () {
      expect(lvNumberToDecimalString(5, 2), ' 5');
      expect(lvNumberToDecimalString(3, 4), '   3');
      expect(lvNumberToDecimalString(-311, 3), '-311');
      expect(lvNumberToDecimalString(42), '42');
      expect(lvNumberToDecimalStringU64(-1), '18446744073709551615');
    });

    test('Decimal String To Number follows the published table and saturates', () {
      expect(lvDecimalStringToNumber('13ax', 0), (offsetPastNumber: 2, number: 13));
      expect(lvDecimalStringToNumber('-4.8bcde', 0), (offsetPastNumber: 2, number: -4));
      expect(lvDecimalStringToNumber('a49b', 0, defaultValue: -9), (offsetPastNumber: 0, number: -9));
      expect(lvDecimalStringToNumber('300', 0, bits: 8).number, 127);
      expect(lvDecimalStringToNumber('  7', -5).number, 7);
      expect(lvHexadecimalStringToNumber('ffg', 0), (offsetPastNumber: 2, number: 255));
      expect(lvFractExpStringToNumber('1.5e3x', 0), (offsetPastNumber: 5, number: 1500.0));
      expect(lvFractExpStringToNumber('x', 0, defaultValue: 2.5).number, 2.5);
    });

    test('Pick Line appends the indexed line and nothing for an index outside the lines', () {
      expect(lvPickLine('a=', 'one\ntwo\nthree', 1), 'a=two');
      expect(lvPickLine('a=', 'one\r\ntwo', 1), 'a=two');
      expect(lvPickLine('a=', 'one\ntwo', 2), 'a=');
      expect(lvPickLine('a=', 'one\ntwo', -1), 'a=');
    });

    test('Search/Split String splits at the match, at the offset for an empty search, or not at all', () {
      expect(lvSearchSplitString('key=value', '='), (before: 'key', matchAndRest: '=value', offsetOfMatch: 3));
      expect(lvSearchSplitString('abcdef', '', 2), (before: 'ab', matchAndRest: 'cdef', offsetOfMatch: 2));
      expect(lvSearchSplitString('abc', 'x'), (before: 'abc', matchAndRest: '', offsetOfMatch: -1));
      expect(lvSearchSplitString('a-b-c', '-', 2).offsetOfMatch, 3);
    });

    test('Search and Replace String: first or all, offset, case, regular expressions, empty search', () {
      expect(
        lvSearchAndReplaceString('a.b.c', '.', '-'),
        (result: 'a-b.c', replacements: 1, offsetPastReplacement: 2),
      );
      expect(
        lvSearchAndReplaceString('a.b.c', '.', '-', replaceAll: true),
        (result: 'a-b-c', replacements: 2, offsetPastReplacement: 4),
      );
      expect(lvSearchAndReplaceString('a.b.c', '.', '-', offset: 2).result, 'a.b-c');
      expect(lvSearchAndReplaceString('abc', 'x', '-').offsetPastReplacement, -1);
      expect(lvSearchAndReplaceString('ABC', 'b', '-', ignoreCase: true).result, 'A-C');
      expect(lvSearchAndReplaceString('ABC', 'b', '-').replacements, 0);
      expect(lvSearchAndReplaceString('ab', '', '-').result, '-ab');
      expect(lvSearchAndReplaceString('ab', '', '-', replaceAll: true).result, '-a-b-');
      expect(
        lvSearchAndReplaceString(
          'x=12, y=3',
          r'(\w)=(\d+)',
          r'\2=\1',
          replaceAll: true,
          regularExpression: true,
        ).result,
        '12=x, 3=y',
      );
      expect(
        lvSearchAndReplaceString('one\ntwo', r'^t', 'T', regularExpression: true, multiline: true).result,
        'one\nTwo',
      );
      expect(lvSearchAndReplaceString('one\ntwo', r'^t', 'T', regularExpression: true).replacements, 0);
    });

    test('a spreadsheet string splits into rows and fields by the format and delimiters', () {
      final text = lvSpreadsheetStringToRows('a\tb\r\nc\n', LvSpreadsheetFormat.text);
      expect(text.rows, [
        ['a', 'b'],
        ['c'],
      ]);
      expect(text.columns, 2);
      final numbers = lvSpreadsheetStringToRows('1.5,2\n3,4e1', LvSpreadsheetFormat.float, delimiters: [',']);
      expect(numbers.rows, [
        [1.5, 2.0],
        [3.0, 40.0],
      ]);
      expect(lvSpreadsheetStringToRows('7 8', LvSpreadsheetFormat.integer, delimiters: [' ']).rows, [
        [7, 8],
      ]);
      expect(LvSpreadsheetFormat.of('%.3f'), LvSpreadsheetFormat.float);
      expect(LvSpreadsheetFormat.of('%s'), LvSpreadsheetFormat.text);
      expect(LvSpreadsheetFormat.of('%d'), LvSpreadsheetFormat.integer);
      expect(LvSpreadsheetFormat.of('%x'), isNull);
    });

    test('Array To Spreadsheet String joins fields with the delimiter and ends each row', () {
      expect(
        lvArrayToSpreadsheetString([
          [1, 2],
          [3, 4],
        ], (value) => '$value'),
        '1\t2\n3\t4\n',
      );
      expect(
        lvArrayToSpreadsheetString(
          [
            ['a'],
          ],
          (value) => '$value',
          delimiter: ',',
          lineEnd: '\r\n',
        ),
        'a\r\n',
      );
    });

    test('case mapping and reversal', () {
      expect(lvToUpperCase('aZ9'), 'AZ9');
      expect(lvReverseString('abc'), 'cba');
      expect(() => lvToUpperCase('\u00e9'), throwsUnsupportedError);
    });
  });

  group('paths', () {
    test('Strip Path returns the last component and the path leading to it', () {
      expect(lvStripPath(_path('C:/labview/foo.vi')), (strippedPath: _path('C:/labview'), name: 'foo.vi'));
      expect(lvStripPath(const LvPath(components: ['a'], absolute: false)).strippedPath.isEmpty, isTrue);
      expect(lvStripPath(LvPath.notAPath), (strippedPath: LvPath.notAPath, name: ''));
      expect(lvStripPath(const LvPath(components: [], absolute: false)), (strippedPath: LvPath.notAPath, name: ''));
      expect(lvStripPath(const LvPath(components: [], absolute: true)), (strippedPath: LvPath.notAPath, name: ''));
    });

    test('a path round-trips through its platform string, Not A Path spelled as such', () {
      final separator = Platform.pathSeparator;
      expect(lvPathToString(const LvPath(components: ['a', 'b'], absolute: false)), 'a${separator}b');
      expect(lvPathToString(LvPath.notAPath), '<Not A Path>');
      final text = lvPathToString(const LvPath(components: ['tmp', 'x'], absolute: true));
      expect(lvPathOfString(text), const LvPath(components: ['tmp', 'x'], absolute: true));
      expect(lvPathType(LvPath.notAPath), 2);
      expect(lvPathType(const LvPath(components: [], absolute: false)), 3);
      expect(lvPathType(const LvPath(components: ['a'], absolute: false)), 1);
      final split = lvPathToArrayOfStrings(_path('a/b'));
      expect(split.relative, isFalse);
      expect(split.components, ['a', 'b']);
      expect(lvArrayOfStringsToPath(['a', 'b'], relative: true), const LvPath(components: ['a', 'b'], absolute: false));
    });
  });

  group('arrays', () {
    test('Sort 1D Array ascends by LabVIEW comparison rules', () {
      expect(lvSort1dArray([3, 1, 2]), [1, 2, 3]);
      expect(lvSort1dArray(['b', 'B', 'a']), ['B', 'a', 'b']);
      expect(lvSort1dArray([true, false]), [false, true]);
      expect(lvSort1dArray([1.0, double.nan, 0.5]).sublist(0, 2), [0.5, 1.0]);
    });

    test('Array Max & Min returns the first extreme of each, -1 on an empty array', () {
      expect(lvArrayMaxAndMin([3, 9, 9, 1, 1], 0), (maxValue: 9, maxIndex: 1, minValue: 1, minIndex: 3));
      expect(lvArrayMaxAndMin(<int>[], 0), (maxValue: 0, maxIndex: -1, minValue: 0, minIndex: -1));
    });

    test('Or/And Array Elements over empty arrays are false and true', () {
      expect(lvOrArrayElements([]), isFalse);
      expect(lvAndArrayElements([]), isTrue);
      expect(lvOrArrayElements([false, true]), isTrue);
      expect(lvAndArrayElements([false, true]), isFalse);
    });

    test('Transpose 2D Array swaps the indices', () {
      final array = LvArrayNd(Int32List.fromList([1, 2, 3, 4, 5, 6]), Uint32List.fromList([2, 3]));
      final transposed = lvTranspose2dArray(array, Int32List.new);
      expect(transposed.dims, [3, 2]);
      expect(transposed.data, [1, 4, 2, 5, 3, 6]);
    });

    test('Delete From Array, Array Subset, Insert Into Array and Split 1D Array cut at the ends', () {
      final middle = lvDeleteFromArray([1, 2, 3, 4], index: 1, length: 2);
      expect(
        [middle.remaining, middle.deleted],
        [
          [1, 4],
          [2, 3],
        ],
      );
      final last = lvDeleteFromArray([1, 2, 3]);
      expect(
        [last.remaining, last.deleted],
        [
          [1, 2],
          [3],
        ],
      );
      final past = lvDeleteFromArray([1, 2, 3], index: 2, length: 5);
      expect(
        [past.remaining, past.deleted],
        [
          [1, 2],
          [3],
        ],
      );
      expect(lvArraySubset([1, 2, 3, 4], 1, 2), [2, 3]);
      expect(lvArraySubset([1, 2, 3, 4], 3), [4]);
      expect(lvArraySubset([1, 2, 3, 4], 9, 2), <int>[]);
      expect(lvInsertIntoArray([1, 4], [2, 3], 1), [1, 2, 3, 4]);
      expect(lvInsertIntoArray([1, 2], [3]), [1, 2, 3]);
      final (first, second) = lvSplit1dArray([1, 2, 3], 1);
      expect(
        [first, second],
        [
          [1],
          [2, 3],
        ],
      );
      expect(lvSplit1dArray([1, 2, 3], 7).$2, isEmpty);
      expect(lvRotate1dArray([1, 2, 3, 4], 1), [4, 1, 2, 3]);
      expect(lvRotate1dArray([1, 2, 3, 4], -1), [2, 3, 4, 1]);
    });

    test('Threshold 1D Array interpolates the crossing index', () {
      expect(lvThreshold1dArray([0, 10, 20], 15), 1.5);
      expect(lvThreshold1dArray([0, 10, 20], -1), 0.0);
      expect(lvThreshold1dArray([0, 10, 20], 99), 2.0);
      expect(lvThreshold1dArray([0, 10, 20], 5, 1), 1.0);
    });
  });

  group('timing', () {
    test('the LabVIEW epoch is 1904 and converts both ways to microsecond precision', () {
      final unixEpoch = DateTime.utc(1970);
      expect(lvTimestampOfDateTime(unixEpoch), const LvTimestamp(seconds: kLvEpochOffsetSeconds, fraction: 0));
      final time = DateTime.utc(2024, 2, 29, 13, 45, 30, 250);
      expect(lvDateTimeOfTimestamp(lvTimestampOfDateTime(time)), time);
      expect(lvTimestampToDouble(lvToTimeStamp(1.5)), 1.5);
      expect(lvGetDateTimeInSeconds().seconds, greaterThan(kLvEpochOffsetSeconds));
    });

    test('Format Date/Time String spells the documented codes', () {
      final stamp = lvTimestampOfDateTime(DateTime.utc(2024, 2, 29, 13, 5, 9, 250));
      expect(lvFormatDateTimeString('%Y-%m-%d %H:%M:%S', stamp, utc: true), '2024-02-29 13:05:09');
      expect(lvFormatDateTimeString('%a %A %b %B', stamp, utc: true), 'Thu Thursday Feb February');
      expect(lvFormatDateTimeString('%I %p %j %y %w', stamp, utc: true), '01 PM 060 24 4');
      expect(lvFormatDateTimeString('%2u|%%|%q', stamp, utc: true), '.25|%|%q');
      expect(lvFormatDateTimeString('', stamp, utc: true), '2024-02-29 13:05:09');
      expect(lvFormatDateTimeString('%U %W', lvTimestampOfDateTime(DateTime.utc(2024)), utc: true), '00 01');
      expect(lvFormatDateTimeString('%U %W', lvTimestampOfDateTime(DateTime.utc(2024, 1, 7)), utc: true), '01 01');
      expect(lvFormatDateTimeString('%z', stamp, utc: true), '+00:00:00');
    });

    test('Wait Until Next ms Multiple returns no earlier than the next multiple', () {
      for (var run = 0; run < 5; run++) {
        final before = lvMillisecondTimer();
        final target = before % 5 == 0 ? before : before - before % 5 + 5;
        final after = lvWaitUntilNextMsMultiple(5);
        expect(after, greaterThanOrEqualTo(target));
        expect(lvMillisecondTimer(), greaterThanOrEqualTo(after));
      }
      final before = lvMillisecondTimer();
      expect(lvWaitUntilNextMsMultiple(0), greaterThanOrEqualTo(before));
    });
  });

  group('references', () {
    setUp(LvReferenceTable.instance.clear);

    test('a queue is obtained by name, bounded, and released by the last reference', () {
      final first = LvQueue.obtain<int>(name: 'q', maxSize: 2);
      final second = LvQueue.obtain<int>(name: 'q');
      expect(first.createdNew, isTrue);
      expect(second.createdNew, isFalse);
      expect(LvQueue.enqueue(first.queue, 1).errorOut.status, isFalse);
      expect(LvQueue.enqueue(first.queue, 2, end: LvQueueEnd.front).errorOut.status, isFalse);
      final full = LvQueue.enqueue(first.queue, 3, timeoutMs: 0);
      expect(full.timedOut, isTrue);
      expect(LvQueue.status<int>(second.queue, returnElements: true).elements, [2, 1]);
      expect(LvQueue.dequeue(second.queue, defaultValue: 0).element, 2);
      expect(LvQueue.dequeue(second.queue, defaultValue: 0, remove: false).element, 1);
      expect(LvQueue.dequeue(second.queue, defaultValue: 0).element, 1);
      expect(LvQueue.dequeue(second.queue, defaultValue: 0, timeoutMs: 0), (
        element: 0,
        timedOut: true,
        errorOut: LvError.none,
      ));
      expect(LvQueue.dequeue(second.queue, defaultValue: 0).errorOut.code, LvErrorCode.synchronousWait.code);
      expect(LvQueue.release<int>(first.queue).remaining, isEmpty);
      LvQueue.enqueue(second.queue, 7);
      expect(LvQueue.release<int>(second.queue).remaining, [7]);
      expect(LvQueue.enqueue(second.queue, 8).errorOut.code, LvErrorCode.invalidReference.code);
      expect(LvQueue.obtain<int>(name: 'q', createIfNotFound: false).errorOut.status, isTrue);
      expect(LvQueue.obtain<String>(name: 'q2').queue, isNot(LvRefnum.none));
      expect(LvQueue.obtain<int>(name: 'q2').errorOut.code, LvErrorCode.invalidArgument.code);
      final lossy = LvQueue.obtain<int>(maxSize: 1).queue;
      LvQueue.enqueue(lossy, 1);
      expect(LvQueue.lossyEnqueue(lossy, 2).overflow, 1);
      expect(LvQueue.flush<int>(lossy).remaining, [2]);
    });

    test('a notifier keeps its latest message, and waiting without one times out', () {
      final notifier = LvNotifier.obtain<String>(name: 'n').notifier;
      expect(LvNotifier.wait(notifier, defaultValue: '', timeoutMs: 0).timedOut, isTrue);
      expect(LvNotifier.send(notifier, 'hello').status, isFalse);
      expect(LvNotifier.wait(notifier, defaultValue: '').notification, 'hello');
      expect(LvNotifier.wait(notifier, defaultValue: '', ignorePrevious: true, timeoutMs: 0).timedOut, isTrue);
      expect(LvNotifier.status<String>(notifier).message, 'hello');
      expect(LvNotifier.release<String>(notifier).status, isFalse);
      expect(LvNotifier.send(notifier, 'x').code, LvErrorCode.invalidReference.code);
    });

    test('a data value reference reads, writes and is deleted back to its value', () {
      final reference = LvDataValueReference.create<int>(41).reference;
      expect(LvDataValueReference.read(reference, defaultValue: 0).value, 41);
      expect(LvDataValueReference.write(reference, 42).status, isFalse);
      expect(LvDataValueReference.delete(reference, defaultValue: 0).value, 42);
      expect(LvDataValueReference.read(reference, defaultValue: 0).errorOut.code, LvErrorCode.invalidReference.code);
      final failing = LvErrorCode.invalidArgument.error('upstream');
      expect(LvDataValueReference.delete(reference, defaultValue: 0, errorIn: failing).errorOut, failing);
    });

    test('a user event reaches every registration, high priority first', () {
      final event = LvUserEvent.create<String>('Stop').userEvent;
      final registration = LvEventRegistration.register([event]).registration;
      expect(LvUserEvent.generate(event, 'a').status, isFalse);
      expect(LvUserEvent.generate(event, 'b', priority: LvEventPriority.high).status, isFalse);
      expect(LvEventRegistration.next(registration)?.data, 'b');
      expect(LvEventRegistration.next(registration)?.data, 'a');
      expect(LvEventRegistration.next(registration), isNull);
      expect(LvEventRegistration.unregister(registration).status, isFalse);
      expect(LvUserEvent.destroy(event).status, isFalse);
      expect(LvUserEvent.generate(event, 'c').code, LvErrorCode.invalidReference.code);
    });

    test('Close Reference releases a live reference and the environment is asked for others', () {
      final reference = lvRegisterReference(Object());
      expect(lvCloseAnyReference(reference).status, isFalse);
      expect(lvCloseReference(reference).code, LvErrorCode.invalidReference.code);
      expect(() => lvCloseAnyReference(const LvRefnum(99)), throwsA(isA<LvEnvironmentUnavailable>()));
      expect(() => lvEnvironment.callChain(), throwsA(isA<LvEnvironmentUnavailable>()));
    });
  });

  group('variants', () {
    test('To Variant and Variant To Data round-trip a value and refuse another type', () {
      final variant = lvToVariant(3);
      expect(lvVariantToData(variant, defaultValue: 0), (data: 3, errorOut: LvError.none));
      final mismatch = lvVariantToData(variant, defaultValue: '');
      expect(mismatch.data, '');
      expect(mismatch.errorOut.code, LvErrorCode.variantTypeMismatch.code);
      expect(lvToVariant(variant), same(variant));
    });

    test('attributes are set, replaced, listed in sorted order and deleted', () {
      var variant = LvVariant.empty;
      expect(lvSetVariantAttribute(variant, 'b', 1).replaced, isFalse);
      variant = lvSetVariantAttribute(variant, 'b', 1).variant;
      variant = lvSetVariantAttribute(variant, 'a', 'x').variant;
      expect(lvSetVariantAttribute(variant, 'b', 2).replaced, isTrue);
      expect(lvSetVariantAttribute(variant, '', 2).errorOut.code, LvErrorCode.invalidArgument.code);
      expect(lvGetVariantAttribute(variant, 'b', defaultValue: 0), (
        variant: variant,
        found: true,
        value: 1,
        errorOut: LvError.none,
      ));
      expect(lvGetVariantAttribute(variant, 'zz', defaultValue: 9).value, 9);
      expect(lvGetVariantAttributes(variant).names, ['a', 'b']);
      expect(lvDeleteVariantAttribute(variant, name: 'a').variant.attributes.keys, ['b']);
      expect(lvDeleteVariantAttribute(variant).variant.attributes, isEmpty);
    });
  });

  group('files', () {
    late Directory scratch;
    setUp(() => scratch = Directory.systemTemp.createTempSync('lv_runtime_'));
    tearDown(() => scratch.deleteSync(recursive: true));

    LvPath at(String name) => lvPathOfString('${scratch.path}${Platform.pathSeparator}$name');

    test('text is written to a path, read back whole, by count and by lines', () {
      final file = at('a.txt');
      expect(lvWriteToTextFile(file, 'one\ntwo\nthree\n').errorOut.status, isFalse);
      expect(lvReadFromTextFile(file).text, 'one\ntwo\nthree\n');
      expect(lvReadFromTextFile(file, count: 3).text, 'one');
      expect(lvReadFromTextFile(file, count: 2, lines: true).text, 'one\ntwo');
      final short = lvReadFromTextFile(file, count: 99);
      expect(short.errorOut.code, LvErrorCode.endOfFile.code);
      expect(short.text, 'one\ntwo\nthree\n');
      expect(lvReadFromTextFile(at('missing.txt')).errorOut.code, LvErrorCode.fileNotFound.code);
    });

    test('an open file keeps its position across reads, writes and seeks', () {
      final file = at('b.bin');
      final opened = lvOpenCreateReplaceFile(file, operation: LvFileOperation.create.code);
      expect(opened.errorOut.status, isFalse);
      final refnum = opened.refnum;
      expect(lvWriteBytesToBinaryFile(refnum, Uint8List.fromList([1, 2, 3, 4])).refnumOut, refnum);
      expect(lvGetFileSize(refnum).size, 4);
      expect(lvGetFilePosition(refnum).offset, 4);
      expect(lvSetFilePosition(refnum, offset: 1).errorOut.status, isFalse);
      expect(lvReadBytesFromBinaryFile(refnum, count: 2).data, '\x02\x03');
      expect(lvSetFilePosition(refnum, offset: -1, from: LvFilePositionFrom.end.code).errorOut.status, isFalse);
      expect(lvReadBytesFromBinaryFile(refnum).data, '\x04');
      expect(lvSetFileSize(refnum, 2).errorOut.status, isFalse);
      expect(lvGetFileSize(refnum).size, 2);
      expect(lvCloseFile(refnum).path, file);
      expect(lvCloseFile(refnum).errorOut.code, LvErrorCode.invalidReference.code);
      expect(
        lvOpenCreateReplaceFile(file, operation: LvFileOperation.create.code).errorOut.code,
        LvErrorCode.duplicatePath.code,
      );
      expect(
        lvOpenCreateReplaceFile(at('none'), operation: LvFileOperation.open.code).errorOut.code,
        LvErrorCode.fileNotFound.code,
      );
      expect(lvGetFileSize(file).size, 2);
    });

    test('folders are created, listed, copied into, moved and deleted', () {
      final folder = at('dir');
      expect(lvCreateFolder(folder).createdPath, folder);
      expect(lvCreateFolder(folder).errorOut.code, LvErrorCode.duplicatePath.code);
      lvWriteToTextFile(lvBuildPath(folder, 'b.txt'), 'b');
      lvWriteToTextFile(lvBuildPath(folder, 'a.csv'), 'a');
      lvCreateFolder(lvBuildPath(folder, 'sub'));
      final listed = lvListFolder(folder);
      expect(listed.fileNames, ['a.csv', 'b.txt']);
      expect(listed.folderNames, ['sub']);
      expect(lvListFolder(folder, pattern: '*.txt').fileNames, ['b.txt']);
      final info = lvFileDirectoryInfo(lvBuildPath(folder, 'b.txt'));
      expect(info.directory, isFalse);
      expect(info.size, 1);
      expect(lvFileDirectoryInfo(folder).directory, isTrue);
      expect(lvFileDirectoryInfo(at('none')).errorOut.code, LvErrorCode.fileNotFound.code);
      expect(lvCopy(lvBuildPath(folder, 'b.txt'), lvBuildPath(folder, 'c.txt')).errorOut.status, isFalse);
      expect(
        lvCopy(lvBuildPath(folder, 'b.txt'), lvBuildPath(folder, 'c.txt')).errorOut.code,
        LvErrorCode.duplicatePath.code,
      );
      expect(lvMove(lvBuildPath(folder, 'c.txt'), lvBuildPath(folder, 'd.txt')).newPath, lvBuildPath(folder, 'd.txt'));
      expect(lvDelete(folder).errorOut.status, isTrue);
      expect(lvDelete(lvBuildPath(folder, 'd.txt')).errorOut.status, isFalse);
      expect(lvDelete(folder, entireHierarchy: true).deletedPath, folder);
      expect(lvDelete(folder).errorOut.code, LvErrorCode.fileNotFound.code);
    });
  });
}
