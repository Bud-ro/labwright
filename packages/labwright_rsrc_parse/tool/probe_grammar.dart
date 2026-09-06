import 'dart:io';
import 'dart:typed_data';

import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

String _corpusBase() {
  const pkgRel = 'packages/labwright_rsrc_parse/corpus';
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/$pkgRel/sources.json').existsSync()) return '${dir.path}/$pkgRel';
    if (File('${dir.path}/corpus/sources.json').existsSync()) return '${dir.path}/corpus';
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return 'corpus';
}

bool _printable(Uint8List bytes, int start, int end) {
  for (var i = start; i < end; i++) {
    final byte = bytes[i];
    if (byte < 0x20 || byte >= 0x7f) return false;
  }
  return true;
}

void main() {
  final dir = Directory('${_corpusBase()}/vi');
  final vis =
      dir.listSync(recursive: true).whereType<File>().where((f) => f.path.toLowerCase().endsWith('.vi')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  var vitsTotal = 0, vitsFullWalk = 0, vitsNamesOk = 0;
  var cpmpTotal = 0, cpmpExact = 0, cpmpLe = 0, cpmpBe = 0;
  var ipsrTotal = 0, ipsrAscending = 0;
  var gcdiTotal = 0, gcdiVer1 = 0;
  var bkmkTotal = 0, bkmkEmptyOk = 0, bkmkNonEmpty = 0;
  var dsimTotal = 0, dsimZero = 0, dsimPng = 0;

  for (final file in vis) {
    try {
      for (final decoded in decodeSections(file.readAsBytesSync())) {
        final bytes = decoded.bytes;
        final view = bytes.length >= 4 ? ByteData.sublistView(bytes) : null;
        switch (decoded.tag) {
          case 'VITS':
            vitsTotal++;
            if (view == null) break;
            final count = view.getUint32(0);
            if (count > 4096) break;
            var pos = 4;
            var entries = 0;
            var namesPrintable = true;
            while (entries < count && pos + 4 <= bytes.length) {
              final nameLen = view.getUint32(pos);
              pos += 4;
              if (nameLen > 4096 || pos + nameLen > bytes.length) break;
              if (!_printable(bytes, pos, pos + nameLen)) namesPrintable = false;
              pos += nameLen;
              if (pos + 4 > bytes.length) break;
              final payloadLen = view.getUint32(pos);
              pos += 4;
              if (payloadLen > bytes.length) break;
              pos += payloadLen;
              entries++;
            }
            if (entries == count && pos == bytes.length) vitsFullWalk++;
            if (entries == count && namesPrintable) vitsNamesOk++;
          case 'CPMp':
            cpmpTotal++;
            if (bytes.length < 2) break;
            final le = bytes[0] | (bytes[1] << 8);
            final be = (bytes[0] << 8) | bytes[1];
            if (2 + 2 * le == bytes.length) {
              cpmpLe++;
              cpmpExact++;
            } else if (2 + 2 * be == bytes.length) {
              cpmpBe++;
              cpmpExact++;
            }
          case 'IPSR':
            ipsrTotal++;
            if (view == null || bytes.length % 4 != 0) break;
            var ok = true;
            var prev = -1;
            for (var pos = 0; pos < bytes.length; pos += 4) {
              final value = view.getUint32(pos);
              if (value < prev) {
                ok = false;
                break;
              }
              prev = value;
            }
            if (ok) ipsrAscending++;
          case 'GCDI':
            gcdiTotal++;
            if (bytes.length >= 5 && bytes[4] == 0x01) gcdiVer1++;
          case 'BKMK':
            bkmkTotal++;
            if (view == null) break;
            final count = view.getUint32(0);
            if (count == 0 && bytes.length == 8) bkmkEmptyOk++;
            if (count > 0) bkmkNonEmpty++;
          case 'DSIM':
            dsimTotal++;
            if (view != null && view.getUint32(0) == 0) dsimZero++;
            for (var pos = 0; pos + 4 <= bytes.length && pos < 4096; pos++) {
              if (bytes[pos] == 0x89 && bytes[pos + 1] == 0x50 && bytes[pos + 2] == 0x4e && bytes[pos + 3] == 0x47) {
                dsimPng++;
                break;
              }
            }
        }
      }
    } catch (_) {}
  }

  stdout
    ..writeln('VITS  total=$vitsTotal fullWalk(name+payload pairs)=$vitsFullWalk namesPrintable=$vitsNamesOk')
    ..writeln('CPMp  total=$cpmpTotal exactLen=$cpmpExact (le=$cpmpLe be=$cpmpBe)')
    ..writeln('IPSR  total=$ipsrTotal ascendingU32=$ipsrAscending')
    ..writeln('GCDI  total=$gcdiTotal byte4==01: $gcdiVer1')
    ..writeln('BKMK  total=$bkmkTotal empty8B=$bkmkEmptyOk nonEmpty=$bkmkNonEmpty')
    ..writeln('DSIM  total=$dsimTotal u32@0==0: $dsimZero withPngMagic=$dsimPng');
}
