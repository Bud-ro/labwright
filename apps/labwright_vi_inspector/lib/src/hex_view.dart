import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'span_annotations.dart';

/// A read-only **hex + parser** view of one decoded resource-block section —
/// HxD/Wireshark style. The section's bytes are shown as a hex dump on the left,
/// record-colored; the right panel lists the parsed records (driven by the
/// clean-room `HeapOpcode` / `HeapObjectClass` / `HeapAttribute` catalogs and the
/// heap walker). Selecting a record highlights its bytes and shows its decoded
/// meaning, including typed displays (colour swatches, rectangles, strings,
/// numbers). Honest by construction: bytes the walker can't frame are shown as
/// an uncovered gap, never hidden.
class BlockHexView extends StatefulWidget {
  const BlockHexView({
    super.key,
    required this.section,
    this.siblings = const [],
  });

  final DecodedSection section;

  /// The other decoded sections of the same VI — lets a block resolve a
  /// cross-reference (e.g. CONP's u16 index into the VCTP type pool). Optional;
  /// empty when the block is viewed in isolation.
  final List<DecodedSection> siblings;

  @override
  State<BlockHexView> createState() => _BlockHexViewState();
}

class _BlockHexViewState extends State<BlockHexView> {
  final _hexScroll = ScrollController();
  final _recScroll = ScrollController();
  late final List<SpanInfo> _records;
  late final List<int> _byteToRecord;
  Widget? _preview;
  HeapWalk? _walk;
  int _selected = -1;

  @override
  void initState() {
    super.initState();
    _buildModel();
  }

  @override
  void didUpdateWidget(BlockHexView old) {
    super.didUpdateWidget(old);
    if (!identical(old.section, widget.section)) {
      _selected = -1;
      _buildModel();
    }
  }

  void _buildModel() {
    final bytes = widget.section.bytes;
    _preview = iconPreview(bytes);
    final isHeap = isRecordHeapTag(widget.section.tag);
    if (isHeap) {
      try {
        final walk = walkHeapBody(bytes);
        _walk = walk;
        _records = [
          if (bytes.length >= 4)
            SpanInfo(
              offset: 0,
              length: 4,
              lead: bytes[0],
              color: spanColorHeader,
              title: 'Heap content length (u32)',
              detail:
                  'Big-endian u32 = ${readU32be(bytes, 0)} bytes: the size of the record stream that '
                  'follows (= decompressed heap size − 4). The bracket-tree walk begins at offset 4.',
              inlinePreview: '${readU32be(bytes, 0)} B',
            ),
          for (final span in walk.spans)
            classifySpan(bytes, span, widget.section.tag),
          if (walk.stoppedAtOffset != null &&
              walk.stoppedAtOffset! < bytes.length)
            SpanInfo(
              offset: walk.stoppedAtOffset!,
              length: bytes.length - walk.stoppedAtOffset!,
              lead: walk.stoppedLead ?? bytes[walk.stoppedAtOffset!],
              color: spanColorUnframed,
              title:
                  'Unframed tail (lead 0x${(walk.stoppedLead ?? 0).toRadixString(16)})',
              detail:
                  'The record walk stopped here: this lead byte\'s record family is not yet '
                  'decoded, so the remaining ${bytes.length - walk.stoppedAtOffset!} bytes are not '
                  'individually framed. They are preserved — decoding this family is the open frontier.',
              inlinePreview: '${bytes.length - walk.stoppedAtOffset!} B',
            ),
        ];
      } catch (_) {
        _records = const [];
      }
    } else {
      _records = _fieldSpans(widget.section.tag, bytes);
    }
    _byteToRecord = List<int>.filled(bytes.length, -1);
    for (var i = 0; i < _records.length; i++) {
      final record = _records[i];
      for (
        var byteOffset = record.offset;
        byteOffset < record.offset + record.length && byteOffset < bytes.length;
        byteOffset++
      ) {
        _byteToRecord[byteOffset] = i;
      }
    }
  }

  @override
  void dispose() {
    _hexScroll.dispose();
    _recScroll.dispose();
    super.dispose();
  }

  /// Selects record [i]. Always scrolls the hex dump to the record's bytes; when
  /// the selection originated from a hex-byte tap ([fromHex]) it also scrolls the
  /// records list to bring that record into view (and vice-versa is implicit:
  /// tapping a record row scrolls the hex to its bytes).
  void _select(int recordIndex, {bool fromHex = false}) {
    setState(() => _selected = recordIndex);
    if (recordIndex < 0 || recordIndex >= _records.length) return;
    if (_hexScroll.hasClients) {
      final row = _records[recordIndex].offset ~/ 16;
      _hexScroll.animateTo(
        (row * _kRowHeight).clamp(0.0, _hexScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
    if (fromHex && _recScroll.hasClients) {
      _recScroll.animateTo(
        (recordIndex * _kRecHeight - 80).clamp(
          0.0,
          _recScroll.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.section.bytes;
    final rows = (bytes.length + 15) ~/ 16;
    final fieldCov = _fieldCoverage();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Text(
                '${widget.section.tag}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${_fmt(bytes.length)} ${widget.section.wasCompressed ? '(inflated)' : ''} · '
                  '${_records.isEmpty ? 'raw bytes (no record framing)' : '${_records.length} records'}'
                  '${_walk != null && !_walk!.complete ? ' · walk stopped at 0x${_walk!.stoppedAtOffset!.toRadixString(16)} (lead 0x${_walk!.stoppedLead!.toRadixString(16)}), ${(_walk!.coverage * 100).toStringAsFixed(0)}% framed' : ''}'
                  '${fieldCov != null ? ' · ${(fieldCov * 100).toStringAsFixed(0)}% framed' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        (_walk != null && !_walk!.complete) ||
                            (fieldCov != null && fieldCov < 1.0)
                        ? Colors.orange
                        : Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ),
              _copyMenu(context, bytes),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: Container(
                  color: const Color(0xFF1E1E1E),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: _rowWidth,
                      child: Scrollbar(
                        controller: _hexScroll,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _hexScroll,
                          itemCount: rows,
                          itemExtent: _kRowHeight,
                          itemBuilder: (context, row) => _hexRow(bytes, row),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 2,
                child: _records.isEmpty
                    ? _nonHeapPanel()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: Scrollbar(
                              controller: _recScroll,
                              thumbVisibility: true,
                              child: ListView.builder(
                                controller: _recScroll,
                                itemCount: _records.length,
                                itemExtent: _kRecHeight,
                                itemBuilder: (context, i) => _recordRow(i),
                              ),
                            ),
                          ),
                          if (_selected >= 0) _detail(_records[_selected]),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _offW = 66.0;
  static const _cellW = 21.0;
  static const _asciiW = 9.0;
  static const _gap = 14.0;
  static const _rowWidth = _offW + 16 * _cellW + _gap + 16 * _asciiW;

  Widget _hexRow(List<int> b, int row) {
    final base = row * 16;
    const hexStart = _offW;
    const asciiStart = _offW + 16 * _cellW + _gap;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) {
        final dx = d.localPosition.dx;
        int? off;
        if (dx >= hexStart && dx < hexStart + 16 * _cellW) {
          off = base + ((dx - hexStart) ~/ _cellW);
        } else if (dx >= asciiStart && dx < asciiStart + 16 * _asciiW) {
          off = base + ((dx - asciiStart) ~/ _asciiW);
        }
        if (off != null && off >= 0 && off < b.length) {
          final ri = _byteToRecord[off];
          if (ri >= 0) _select(ri, fromHex: true);
        }
      },
      child: Row(
        children: [
          SizedBox(
            width: _offW,
            child: Text(
              '  ${base.toRadixString(16).padLeft(6, '0')}',
              style: const TextStyle(
                color: Color(0xFF888888),
                fontFamily: 'monospace',
                fontSize: 12.5,
              ),
            ),
          ),
          for (var i = 0; i < 16; i++) _cell(b, base + i, hex: true),
          const SizedBox(width: _gap),
          for (var i = 0; i < 16; i++) _cell(b, base + i, hex: false),
        ],
      ),
    );
  }

  Widget _cell(List<int> b, int o, {required bool hex}) {
    if (o >= b.length) return SizedBox(width: hex ? _cellW : _asciiW);
    final ri = _byteToRecord[o];
    final color = ri < 0 ? const Color(0xFF6E6E6E) : _records[ri].color;
    final sel = ri >= 0 && ri == _selected;
    final byte = b[o];
    final text = hex
        ? b[o].toRadixString(16).padLeft(2, '0')
        : (byte >= 0x20 && byte < 0x7f ? String.fromCharCode(byte) : '·');
    return Container(
      width: hex ? _cellW : _asciiW,
      alignment: Alignment.center,
      color: sel ? color.withValues(alpha: 0.30) : null,
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          color: sel ? Colors.white : color,
          fontFamily: 'monospace',
          fontSize: 12.5,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _recordRow(int recordIndex) {
    final record = _records[recordIndex];
    final selected = recordIndex == _selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(recordIndex),
      child: Container(
        color: selected ? record.color.withValues(alpha: 0.18) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: record.color,
                shape: BoxShape.circle,
              ),
            ),
            SizedBox(
              width: 54,
              child: Text(
                '@${record.offset.toRadixString(16)}',
                style: const TextStyle(
                  color: Colors.grey,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
            Expanded(
              child: Text(
                record.title,
                style: const TextStyle(fontSize: 12.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (record.inlinePreview != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  record.inlinePreview!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Colors.grey,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            if (record.swatch != null)
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: record.swatch,
                  borderRadius: BorderRadius.circular(2),
                  border: Border.all(color: Colors.black26),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _detail(SpanInfo r) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x33FFFFFF))),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            'offset 0x${r.offset.toRadixString(16)} · ${r.length} bytes · lead 0x${r.lead.toRadixString(16)}',
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text(r.detail, style: const TextStyle(fontSize: 12.5)),
          if (r.display != null) ...[const SizedBox(height: 10), r.display!],
        ],
      ),
    );
  }

  /// Byte-coverage of a NON-heap block: the fraction of bytes covered by named
  /// field spans (excluding the explicit "Undecoded" gap spans). Null for heaps
  /// (they report the record-walk coverage) and for raw/unannotated blocks.
  /// Drives the honest "% framed" progress readout toward the every-byte goal.
  double? _fieldCoverage() {
    if (_walk != null || _records.isEmpty) return null;
    final total = widget.section.bytes.length;
    if (total == 0) return null;
    var framed = 0;
    for (final record in _records) {
      if (record.color == spanColorUnframed) continue;
      framed += record.length;
    }
    return framed / total;
  }

  /// Decoded fields for a non-heap block whose format we parse — label/value
  /// pairs straight from the viparse decoders (never fabricated; only what a
  /// decoder actually returns). Empty when the block has no decoder.
  List<MapEntry<String, String>> _parsedBlockSummary() {
    final bytes = widget.section.bytes;
    switch (widget.section.tag) {
      case 'vers':
        final versionWord = decodeVersionWord(bytes);
        return versionWord == null
            ? const []
            : [
                MapEntry('Version', versionWord.version),
                MapEntry(
                  'Stage',
                  '0x${versionWord.stage.toRadixString(16)}${versionWord.stage == 0x80 ? ' (release)' : ''}',
                ),
                MapEntry('Build', '${versionWord.build}'),
              ];
      case 'LVSR':
        final saveRecord = decodeSaveRecord(bytes);
        return saveRecord == null
            ? const []
            : [
                MapEntry('LabVIEW version', saveRecord.version),
                MapEntry(
                  'BD password-protected',
                  saveRecord.isBlockDiagramPasswordProtected ? 'yes' : 'no',
                ),
              ];
      case 'CONP':
      case 'CPC2':
        final pane = decodeConnectorPane(bytes);
        if (pane == null) return const [];
        if (pane.isInline)
          return [const MapEntry('Form', 'inline (not yet decoded)')];
        final out = [MapEntry('VCTP type index', '${pane.typeIndex}')];
        final pool = widget.siblings.isEmpty
            ? const <ViType>[]
            : typePoolFromDecoded(widget.siblings);
        final idx = pane.typeIndex;
        if (idx != null && idx >= 1 && idx <= pool.length) {
          final type = pool[idx - 1];
          final name = type.name != null && type.name!.isNotEmpty
              ? " '${type.name}'"
              : '';
          out.add(MapEntry('Conpane type', '${typeLabel(type, pool)}$name'));
        }
        return out;
      case 'HLPP':
        final helpPath = decodeHelpPath(bytes);
        return (helpPath == null || !helpPath.isPth0 || helpPath.path.isEmpty)
            ? const []
            : [MapEntry('Help path', helpPath.path)];
      case 'STRG':
      case 'HLPT':
        final text = decodeStringBlock(bytes);
        if (text == null || text.isEmpty) return const [];
        return [
          MapEntry(
            'Text',
            text.length > 240 ? '${text.substring(0, 240)}…' : text,
          ),
        ];
      case 'HIST':
        final history = decodeHistory(bytes);
        return history == null
            ? const []
            : [
                MapEntry('Format version', '${history.formatVersion}'),
                MapEntry('Revision entries', '${history.entryCount}'),
              ];
      case 'FTAB':
        final ft = decodeFontTable(bytes);
        if (ft == null) return const [];
        return [
          MapEntry('Fonts', '${ft.fontCount}'),
          if (ft.names.isNotEmpty) MapEntry('Names', ft.names.join(', ')),
        ];
      case 'NUID':
      case 'SUID':
      case 'BNID':
        final it = decodeIdTable(bytes);
        return it == null ? const [] : [MapEntry('Id count', '${it.count}')];
      default:
        return const [];
    }
  }

  Widget _nonHeapPanel() {
    final info = blockInfo(widget.section.tag);
    if (widget.section.tag == 'VCTP') {
      final types = decodeTypePool(widget.section.bytes);
      if (types.isNotEmpty) {
        const cap = 200;
        final shown = types.length > cap ? types.take(cap).toList() : types;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text(
              'Parsed · ${info.name}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              '${types.length} types',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const Divider(height: 14),
            for (final type in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '#${type.index} ',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                      TextSpan(
                        text: typeLabel(type, types),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      if (type.name != null && type.name!.isNotEmpty)
                        TextSpan(
                          text: "  '${type.name}'",
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: Color(0xFF4C8C4C),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (types.length > cap)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '+${types.length - cap} more (not shown)',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
          ],
        );
      }
    }
    final bpp = legacyIconBpp(widget.section.tag);
    if (bpp != null) {
      final icon = decodeLegacyIcon(widget.section.bytes, bpp);
      if (icon != null) {
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text(
              'Parsed · ${info.name}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 2),
            Text(
              '${widget.section.tag} · 32×32 @ ${bpp}bpp',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const Divider(height: 14),
            Center(
              child: CustomPaint(
                size: const Size(128, 128),
                painter: LegacyIconPainter(icon),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Index mask: pixel index 0 is background, any nonzero index is '
              'foreground — the true LabVIEW colour palette is not resolved, so '
              'indices are shown as foreground/background, not colours.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        );
      }
    }
    final fields = _parsedBlockSummary();
    if (_preview != null)
      return Center(
        child: Padding(padding: const EdgeInsets.all(16), child: _preview),
      );
    if (fields.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '${info.name} (${widget.section.tag})\n${info.note}\n\n'
            "Not a record heap — raw hex shown. Decoding this block's format is the open frontier.",
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          'Parsed · ${info.name}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 2),
        Text(
          '${widget.section.tag} — ${info.confidence.name}',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const Divider(height: 14),
        for (final field in fields) ...[
          Text(
            field.key,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          SelectableText(field.value, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
        ],
        Text(
          info.note,
          style: const TextStyle(
            fontSize: 11,
            color: Colors.grey,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  /// Per-byte field spans for a non-heap block whose layout we know, so the hex
  /// dump is clickable byte-by-byte (mirroring the heap record-walk). Returns []
  /// for blocks without a field layout (the raw-hex panel is shown instead).
  /// Whatever spans are produced, [_fillGaps] adds explicit "undecoded" spans so
  /// EVERY byte is accounted for — coverage is total and the gaps stay visible.
  List<SpanInfo> _fieldSpans(String tag, List<int> b) {
    final out = <SpanInfo>[];
    void span(
      int off,
      int len,
      Color c,
      String title,
      String detail, {
      String? preview,
    }) {
      if (len <= 0 || off < 0 || off + len > b.length) return;
      out.add(
        SpanInfo(
          offset: off,
          length: len,
          lead: b[off],
          color: c,
          title: title,
          detail: detail,
          inlinePreview: preview,
        ),
      );
    }

    switch (tag) {
      case 'vers':
        final vw = b is Uint8List
            ? decodeVersionWord(b)
            : decodeVersionWord(Uint8List.fromList(b));
        span(
          0,
          4,
          spanColorObject,
          'Version word (u32)',
          'BCD major · minor<<4|patch · stage · build. The same word heads LVSR. See decodeVersionWord.',
          preview: vw == null
              ? '0x${readU32be(b, 0).toRadixString(16)}'
              : 'v${vw.version}',
        );
      case 'STRG':
      case 'HLPT':
        span(
          0,
          4,
          spanColorHeader,
          'Text length (u32)',
          'Byte length of the UTF-8 text that follows (== sectionLen-4).',
          preview: '${readU32be(b, 0)} B',
        );
        span(
          4,
          b.length - 4,
          spanColorRect,
          'Text (UTF-8)',
          'The VI description / context-help text.',
        );
      case 'NUID':
      case 'SUID':
      case 'BNID':
        if (b.length >= 4) {
          final count = readU32be(b, 0);
          span(
            0,
            4,
            spanColorHeader,
            'Entry count (u32)',
            '$count u32 id entries follow ([u32 count][count u32]).',
            preview: '$count',
          );
          for (var i = 0; i < count && 4 + 4 * i + 4 <= b.length; i++) {
            span(
              4 + 4 * i,
              4,
              spanColorObject,
              'id[$i] (u32)',
              'An opaque UID/handle value (role not yet decoded).',
              preview: '0x${readU32be(b, 4 + 4 * i).toRadixString(16)}',
            );
          }
        }
      case 'HIST':
        const names = [
          'format version',
          'flags',
          'entry count',
          'reserved',
          'word4',
          'stamp A',
          'stamp B',
          'reserved',
          'reserved',
          'word9',
        ];
        for (
          var wordIndex = 0;
          wordIndex < 10 && wordIndex * 4 + 4 <= b.length;
          wordIndex++
        ) {
          span(
            wordIndex * 4,
            4,
            spanColorObject,
            'HIST @${wordIndex * 4}: ${names[wordIndex]} (u32)',
            'Revision-history record word. See decodeHistory.',
            preview: '${readU32be(b, wordIndex * 4)}',
          );
        }
      case 'LVSR':
        span(
          0,
          4,
          spanColorObject,
          'Version word (u32)',
          'BCD major · minor<<4|patch · stage · build (== vers word). See decodeSaveRecord.',
          preview: '0x${readU32be(b, 0).toRadixString(16)}',
        );
        for (final range in const [
          [4, 52],
          [68, 80],
          [112, 120],
          [136, 144],
        ]) {
          for (
            var wordOffset = range[0];
            wordOffset + 4 <= range[1] && wordOffset + 4 <= b.length;
            wordOffset += 4
          ) {
            span(
              wordOffset,
              4,
              spanColorGroup,
              'Config/flags word (u32) @$wordOffset',
              'A low-cardinality LVSR config/flags word; exact bit meaning not yet decoded.',
              preview: '0x${readU32be(b, wordOffset).toRadixString(16)}',
            );
          }
        }
        span(
          52,
          16,
          spanColorObject,
          'Per-VI value A (16B)',
          'A 16-byte value that varies per VI (≈6920 distinct across the corpus); role not yet decoded.',
        );
        span(
          80,
          16,
          spanColorObject,
          'Per-VI value B (16B)',
          'A second 16-byte per-VI value (≈6920 distinct across the corpus); role not yet decoded.',
        );
        span(
          96,
          16,
          spanColorRect,
          'BD password hash (16B)',
          'Block-diagram password hash; mirrors the BDPW block. Empty-password default = d41d8cd9…',
        );
        span(
          120,
          16,
          spanColorObject,
          'Per-VI value C (16B)',
          'A third 16-byte per-VI value (≈6854 distinct across the corpus); role not yet decoded.',
        );
        span(
          144,
          16,
          spanColorRect,
          'Secondary hash (16B)',
          'A second hash/checksum slot (role not fully decoded).',
        );
      case 'CONP':
      case 'CPC2':
        if (b.length == 2) {
          final idx = readU16be(b, 0);
          var resolved = '';
          if (widget.siblings.isNotEmpty) {
            final pool = typePoolFromDecoded(widget.siblings);
            if (idx >= 1 && idx <= pool.length) {
              final type = pool[idx - 1];
              resolved =
                  ' → ${typeLabel(type, pool)}${type.name != null && type.name!.isNotEmpty ? " '${type.name}'" : ''}';
            }
          }
          span(
            0,
            2,
            spanColorObject,
            'VCTP type index (u16)',
            '${tag == 'CONP' ? 'Index of the connector-pane type in the VCTP pool (CONP: 100% in-range).' : 'A second conpane reference (CPC2: resolves as a VCTP index only ~84%).'}$resolved',
            preview: '$idx$resolved',
          );
        }
      case 'FTAB':
        span(
          0,
          2,
          spanColorObject,
          'Version (u16)',
          'Font-table version (1 in the corpus).',
          preview: '${readU16be(b, 0)}',
        );
        if (b.length >= 6) {
          span(
            2,
            4,
            spanColorGroup,
            'Header constant (00 02 00 03)',
            'Fixed format sub-version words (u16 2, u16 3); 00 02 00 03 in all 322 corpus FTABs.',
          );
        }
        if (b.length >= 8)
          span(
            6,
            2,
            spanColorHeader,
            'Font count (u16)',
            'Number of packed name entries.',
            preview: '${readU16be(b, 6)}',
          );
        if (b.length >= 12) {
          final nameOff = readU32be(b, 8);
          span(
            8,
            4,
            spanColorHeader,
            'Name-table offset (u32)',
            'Byte offset of the packed Pascal font-name strings.',
            preview: '$nameOff',
          );
          final count = readU16be(b, 6);
          if (nameOff >= 12 && nameOff <= b.length && count > 0) {
            var pos = 12;
            for (var i = 0; i < count && pos + 12 <= nameOff; i++) {
              span(
                pos,
                12,
                spanColorObject,
                'Font[$i] metric record (12B)',
                'Per-font size/style metrics; inner fields not yet decoded.',
              );
              pos += 12;
              if (i < count - 1 && pos + 4 <= nameOff) {
                span(
                  pos,
                  4,
                  spanColorGroup,
                  'Font[$i] u32 field',
                  'A 4-byte value between font records (role not yet decoded).',
                  preview: '${readU32be(b, pos)}',
                );
                pos += 4;
              }
            }
          }
          if (nameOff < b.length)
            span(
              nameOff,
              b.length - nameOff,
              spanColorRect,
              'Font names (Pascal strings)',
              'Packed [u8 len][name] font face names. See decodeFontTable.',
            );
        }
      case 'BDPW':
        span(
          0,
          16,
          spanColorRect,
          'Password hash (16B)',
          'Block-diagram password hash; sample is MD5("") d41d8cd9…',
        );
      case 'GCPR':
        span(
          0,
          b.length,
          spanColorGroup,
          'Generated-code property (${b.length}B)',
          'Fixed-size record, byte-constant (all-zero) across the corpus.',
        );
      case 'VPDP':
        span(
          0,
          b.length,
          spanColorGroup,
          'VI property data (${b.length}B)',
          'Fixed 4-byte record, byte-constant (all-zero) across the corpus.',
        );
      case 'DLDR':
        span(
          0,
          b.length,
          spanColorGroup,
          'Default-data loader (${b.length}B)',
          'Fixed 28-byte record, byte-constant across the corpus.',
        );
      case 'RTSG':
      case 'OBSG':
      case 'CCSG':
        span(
          0,
          16,
          spanColorObject,
          '16-byte signature',
          tag == 'CCSG'
              ? 'Near-constant shared toolchain signature (opaque value).'
              : 'Per-VI signature (identity; opaque value).',
          preview: 'sig',
        );
      case 'SCSR':
        span(
          0,
          4,
          spanColorHeader,
          'Header (u32)',
          'Leading word 0x01000000 BE (version-ish).',
          preview: '0x${readU32be(b, 0).toRadixString(16)}',
        );
        span(
          4,
          16,
          spanColorObject,
          '16-byte signature',
          'Source signature (near-constant; opaque value).',
          preview: 'sig',
        );
      case 'FPSE':
      case 'BDSE':
        for (var pos = 0; pos + 4 <= b.length; pos += 4) {
          span(
            pos,
            4,
            spanColorObject,
            '$tag marker (u32)',
            '${tag == 'FPSE' ? 'Front-panel' : 'Block-diagram'} section marker word (value role not yet decoded).',
            preview: '${readU32be(b, pos)}',
          );
        }
      case 'MUID':
        span(
          0,
          4,
          spanColorObject,
          'MUID (u32)',
          'Module/object unique id (opaque value).',
          preview: '${readU32be(b, 0)}',
        );
      case 'CPST':
      case 'CPSP':
        if (b.length >= 4) {
          final count = readU32be(b, 0);
          span(
            0,
            4,
            spanColorHeader,
            'String count (u32)',
            '$count Pascal-string label entries follow ([u8 len][ASCII]).',
            preview: '$count',
          );
          var pos = 4;
          for (var i = 0; i < count && pos < b.length; i++) {
            final nameLen = b[pos];
            span(
              pos,
              1,
              spanColorObject,
              'entry[$i] length (u8)',
              'Length of the label string that follows.',
              preview: '$nameLen',
            );
            if (nameLen > 0 && pos + 1 + nameLen <= b.length) {
              span(
                pos + 1,
                nameLen,
                spanColorRect,
                'entry[$i] (ASCII)',
                'A boolean/comparison/report label.',
                preview: String.fromCharCodes(
                  b.sublist(pos + 1, pos + 1 + nameLen),
                ),
              );
            }
            pos += 1 + nameLen;
          }
        }
      case 'FPTD':
        if (b.length == 2) {
          span(
            0,
            2,
            spanColorObject,
            'Type index (u16)',
            'Front-panel terminal type descriptor; likely indexes the VCTP pool (not corpus-verified for FPTD).',
            preview: '${readU16be(b, 0)}',
          );
        }
      case 'TITL':
        if (b.isNotEmpty) {
          final nameLen = b[0];
          span(
            0,
            1,
            spanColorHeader,
            'Title length (u8)',
            'Pascal-string length of the VI title that follows.',
            preview: '$nameLen',
          );
          if (1 + nameLen <= b.length) {
            final text = String.fromCharCodes(b.sublist(1, 1 + nameLen));
            span(
              1,
              nameLen,
              spanColorRect,
              'Title (ASCII)',
              'The VI window title (Pascal string).',
              preview: text,
            );
          }
        }
      default:
        return const [];
    }
    return _fillGaps(out, b.length);
  }

  /// Inserts explicit "undecoded" spans for any byte ranges [fields] leaves
  /// uncovered (and a trailing tail), so the hex view accounts for every byte.
  List<SpanInfo> _fillGaps(List<SpanInfo> fields, int len) {
    if (fields.isEmpty) return fields;
    fields.sort((a, b) => a.offset.compareTo(b.offset));
    final out = <SpanInfo>[];
    var cursor = 0;
    void gap(int from, int to) {
      if (to > from) {
        out.add(
          SpanInfo(
            offset: from,
            length: to - from,
            lead: 0,
            color: spanColorUnframed,
            title: 'Undecoded ($from..${to - 1})',
            detail:
                'These ${to - from} bytes are not yet field-decoded for this block — preserved, not hidden.',
            inlinePreview: '${to - from} B',
          ),
        );
      }
    }

    for (final field in fields) {
      gap(cursor, field.offset);
      out.add(field);
      if (field.offset + field.length > cursor)
        cursor = field.offset + field.length;
    }
    gap(cursor, len);
    return out;
  }

  static String _fmt(int byteCount) => byteCount >= 1024
      ? '${(byteCount / 1024).toStringAsFixed(1)} KB'
      : '$byteCount B';

  /// Lower-case hex of [bytes]; [spaced] inserts a space between bytes for reading
  /// (continuous form pastes straight into a hasher — e.g. to check a BDPW hash).
  static String _hex(List<int> bytes, {bool spaced = false}) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (spaced && i > 0) sb.write(' ');
      sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  void _copy(BuildContext context, String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Copied $what'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// A copy control for the block's bytes: continuous hex (default), spaced hex,
  /// and — when a record is selected — just that record's bytes.
  Widget _copyMenu(BuildContext context, Uint8List b) {
    final sel = (_selected >= 0 && _selected < _records.length)
        ? _records[_selected]
        : null;
    final tag = widget.section.tag;
    return PopupMenuButton<int>(
      tooltip: 'Copy bytes',
      icon: const Icon(Icons.copy, size: 16),
      onSelected: (v) {
        if (v == 0) {
          _copy(context, _hex(b), '$tag · ${b.length} B (hex)');
        } else if (v == 1) {
          _copy(
            context,
            _hex(b, spaced: true),
            '$tag · ${b.length} B (spaced hex)',
          );
        } else if (v == 2 && sel != null) {
          final end = (sel.offset + sel.length).clamp(0, b.length);
          _copy(
            context,
            _hex(b.sublist(sel.offset, end)),
            'record · ${end - sel.offset} B (hex)',
          );
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 0, child: Text('Copy $tag as hex')),
        const PopupMenuItem(value: 1, child: Text('Copy as hex (spaced)')),
        if (sel != null)
          PopupMenuItem(
            value: 2,
            child: Text('Copy selected record (${sel.length} B)'),
          ),
      ],
    );
  }
}

const double _kRowHeight = 20;
const double _kRecHeight = 30;
