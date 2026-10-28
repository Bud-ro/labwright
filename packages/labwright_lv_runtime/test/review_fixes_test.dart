import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';
import 'package:test/test.dart';

final class _RecordingEnvironment extends LvUnavailableEnvironment {
  List<({String event, LvRefnum source})>? registered;

  @override
  ({LvRefnum registration, LvError errorOut}) registerForEvents(
    List<({String event, LvRefnum source})> sources,
    LvRefnum existing,
    LvError errorIn,
  ) {
    registered = sources;
    return (registration: const LvRefnum(77), errorOut: LvError.none);
  }
}

void main() {
  setUp(LvReferenceTable.instance.clear);

  test('To Time Stamp keeps a fraction of half a second or more', () {
    expect(lvToTimeStamp(10.75), const LvTimestamp(seconds: 10, fraction: -0x4000000000000000));
    expect(lvToTimeStamp(10.5).fraction, 0x8000000000000000);
    expect(lvTimestampToDouble(lvToTimeStamp(10.75)), 10.75);
  });

  test('timestamps order by an unsigned fraction', () {
    const early = LvTimestamp(seconds: 1, fraction: 0x4000000000000000);
    const late = LvTimestamp(seconds: 1, fraction: -0x4000000000000000);
    expect(lvCompareValues(early, late), lessThan(0));
    expect(lvSort1dArray([late, early]), [early, late]);
  });

  test('a file function given an error passes its refnum through for Close File', () {
    final scratch = Directory.systemTemp.createTempSync('lv_review_');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final path = lvPathOfString('${scratch.path}${Platform.pathSeparator}a.txt');
    final refnum = lvOpenCreateReplaceFile(path, operation: LvFileOperation.create.code).refnum;
    final failing = LvErrorCode.invalidArgument.error('upstream');
    expect(lvReadFromTextFile(refnum, errorIn: failing).refnumOut, refnum);
    expect(lvWriteToTextFile(refnum, 'x', errorIn: failing).refnumOut, refnum);
    expect(lvReadBytesFromBinaryFile(refnum, errorIn: failing).refnumOut, refnum);
    expect(lvWriteBytesToBinaryFile(refnum, Uint8List(1), errorIn: failing).refnumOut, refnum);
    expect(lvGetFileSize(refnum, errorIn: failing).refnumOut, refnum);
    expect(lvCloseFile(refnum).errorOut.status, isFalse);
  });

  test('Get Variant Attribute of variant type returns the attribute variant itself', () {
    final variant = lvSetVariantAttribute(LvVariant.empty, 'a', 5).variant;
    final read = lvGetVariantAttribute<LvVariant>(variant, 'a', defaultValue: LvVariant.empty);
    expect(read.found, isTrue);
    expect(read.value.value, 5);
  });

  test('File/Directory Info reads its modification time as To Time Stamp of the instant would', () {
    final scratch = Directory.systemTemp.createTempSync('lv_review_');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final file = File('${scratch.path}${Platform.pathSeparator}old.txt')..writeAsStringSync('x');
    file.setLastModifiedSync(DateTime.utc(2001, 2, 3, 4, 5, 6, 500));
    final info = lvFileDirectoryInfo(lvPathOfString(file.path));
    expect(info.lastMod, lvTimestampOfDateTime(file.lastModifiedSync()));
    final before1970 = lvTimestampOfDateTime(DateTime.utc(1969, 12, 31, 23, 59, 59, 500));
    expect(before1970.seconds, kLvEpochOffsetSeconds - 1);
    expect(before1970.fraction.toUnsigned(64), 0x8000000000000000.toUnsigned(64));
  });

  test('a variant flattens a number at the width its numeric type names', () {
    expect(lvFlattenVariantData(lvToVariant(1, numeric: LvNumericType.i32)), '\x00\x00\x00\x01');
    expect(lvFlattenVariantData(lvToVariant(1, numeric: LvNumericType.u8)), '\x01');
    expect(lvFlattenVariantData(lvToVariant(1.0, numeric: LvNumericType.sgl)).length, 4);
    expect(() => lvFlattenVariantData(lvToVariant(1)), throwsUnsupportedError);
  });

  test('Logarithm Base 10 of a power of ten is exact', () {
    expect(lvLogarithmBase10(1000), 3.0);
    expect(lvLogarithmBase10(1e-3), -3.0);
    expect(lvLogarithmBase10(2), closeTo(0.30103, 1e-5));
  });

  test('Register For Events hands the environment each source with its event name', () {
    final environment = _RecordingEnvironment();
    final previous = lvEnvironment;
    lvEnvironment = environment;
    addTearDown(() => lvEnvironment = previous);
    final registered = lvRegisterForEvents([const LvRefnum(9)], events: ['Value Change']);
    expect(registered.registration, const LvRefnum(77));
    expect(environment.registered, [(event: 'Value Change', source: const LvRefnum(9))]);
  });

  test('a forced Release Queue or Release Notifier invalidates every reference to the object', () {
    final first = LvQueue.obtain<int>(name: 'q').queue;
    final second = LvQueue.obtain<int>(name: 'q').queue;
    LvQueue.release<int>(first, forceDestroy: true);
    expect(LvQueue.enqueue(second, 1).errorOut.code, LvErrorCode.invalidReference.code);
    expect(LvQueue.obtain<int>(name: 'q').createdNew, isTrue);
    final one = LvNotifier.obtain<int>(name: 'n').notifier;
    final two = LvNotifier.obtain<int>(name: 'n').notifier;
    LvNotifier.release<int>(one, forceDestroy: true);
    expect(LvNotifier.send(two, 1).code, LvErrorCode.invalidReference.code);
  });

  test('a registration over an invalid source attaches to none of them', () {
    final event = LvUserEvent.create<int>('e').userEvent;
    final first = LvEventRegistration.register([event, const LvRefnum(999)]);
    expect(first.errorOut.status, isTrue);
    final second = LvEventRegistration.register([event]).registration;
    LvUserEvent.generate(event, 1);
    expect(LvEventRegistration.next(second)?.data, 1);
    expect(LvEventRegistration.next(second), isNull);
  });

  test('Decimate 1D Array needs an output and Reshape Array clamps negative sizes', () {
    expect(() => lvDecimate1dArray([1, 2], 0), throwsArgumentError);
    expect(lvReshapeDims([-2, 3]), [0, 3]);
    expect(lvReshapeArray([1, 2, 3], [-1, 2], 0), isEmpty);
  });
}
