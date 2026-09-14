import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'span_annotations.dart';

class BlockHexView extends StatefulWidget {
  const BlockHexView({
    super.key,
    required this.section,
    this.siblings = const [],
  });

  final DecodedSection section;

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
    _preview = iconPreview(widget.section.tag, bytes);
    final isHeap = BlockTag.of(widget.section.tag)?.isRecordHeap ?? false;
    if (isHeap) {
      try {
        _walk = walkHeapBody(bytes);
        _records = [
          for (final info in describeHeapBody(bytes, widget.section.tag))
            spanInfoOf(info),
        ];
      } catch (_) {
        _records = const [];
      }
    } else {
      final layout = BlockTag.of(widget.section.tag)?.layout;
      _records = layout == null ? const [] : _layoutSpans(layout, bytes);
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_records.isEmpty || _showSummary)
                      Expanded(child: _nonHeapPanel()),
                    if (_records.isNotEmpty)
                      Expanded(
                        flex: 2,
                        child: Column(
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

  Widget _hexRow(List<int> bytes, int row) {
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
        if (off != null && off >= 0 && off < bytes.length) {
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
          for (var i = 0; i < 16; i++) _cell(bytes, base + i, hex: true),
          const SizedBox(width: _gap),
          for (var i = 0; i < 16; i++) _cell(bytes, base + i, hex: false),
        ],
      ),
    );
  }

  Widget _cell(List<int> bytes, int offset, {required bool hex}) {
    if (offset >= bytes.length) return SizedBox(width: hex ? _cellW : _asciiW);
    final ri = _byteToRecord[offset];
    final color = ri < 0 ? const Color(0xFF6E6E6E) : _records[ri].color;
    final sel = ri >= 0 && ri == _selected;
    final byte = bytes[offset];
    final text = hex
        ? bytes[offset].toRadixString(16).padLeft(2, '0')
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

  Widget _detail(SpanInfo record) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x33FFFFFF))),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            record.title,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'offset 0x${record.offset.toRadixString(16)} · ${record.length} bytes · lead 0x${record.lead.toRadixString(16)}',
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Text(record.detail, style: const TextStyle(fontSize: 12.5)),
          if (record.display != null) ...[
            const SizedBox(height: 10),
            record.display!,
          ],
        ],
      ),
    );
  }

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

  List<MapEntry<String, String>> _parsedBlockSummary() {
    final bytes = widget.section.bytes;
    switch (widget.section.tag) {
      case 'vers':
        if (bytes.length < 4) return const [];
        final versionWord = decodeVersionWord(bytes);
        return [
          MapEntry('Version', versionWord.version),
          MapEntry(
            'Stage',
            '0x${versionWord.stage.toRadixString(16)}${versionWord.stage == 0x80 ? ' (release)' : ''}',
          ),
          MapEntry('Build', '${versionWord.build}'),
        ];
      case 'LVSR':
        if (bytes.length < 8) return const [];
        final saveRecord = decodeSaveRecord(bytes);
        return [
          MapEntry('LabVIEW version', saveRecord.versionWord.version),
          MapEntry(
            'BD password-protected',
            saveRecord.isBlockDiagramPasswordProtected ? 'yes' : 'no',
          ),
        ];
      case 'CONP':
      case 'CPC2':
        if (bytes.isEmpty) return const [];
        final pane = decodeConnectorPane(bytes);
        if (pane is! ViConnectorPaneTypeIndex)
          return [const MapEntry('Form', 'inline (not yet decoded)')];
        final out = [MapEntry('VCTP type index', '${pane.typeIndex}')];
        final pool = widget.siblings.isEmpty
            ? const <ViType>[]
            : typePoolFromDecoded(widget.siblings);
        final idx = pane.typeIndex;
        if (idx >= 1 && idx <= pool.length) {
          final type = pool[idx - 1];
          final name = type.name != null && type.name!.isNotEmpty
              ? " '${type.name}'"
              : '';
          out.add(MapEntry('Conpane type', '${typeLabel(type, pool)}$name'));
        }
        return out;
      case 'HLPP':
        if (!isPth0(bytes)) return const [];
        final helpPath = decodeHelpPath(bytes);
        return helpPath.path.isEmpty
            ? const []
            : [MapEntry('Help path', helpPath.path)];
      case 'STRG':
      case 'HLPT':
        if (bytes.length < 4 || 4 + readU32be(bytes, 0) != bytes.length) {
          return const [];
        }
        final text = decodeStringBlock(bytes).text;
        if (text.isEmpty) return const [];
        return [
          MapEntry(
            'Text',
            text.length > 240 ? '${text.substring(0, 240)}…' : text,
          ),
        ];
      case 'HIST':
        if (bytes.length != 40) return const [];
        final history = decodeHistory(bytes);
        return [
          MapEntry('Format version', '${history.formatVersion}'),
          MapEntry('Revision entries', '${history.entryCount}'),
        ];
      case 'FTAB':
        if (bytes.length < 8) return const [];
        final ft = decodeFontTable(bytes);
        return [
          MapEntry('Fonts', '${ft.fontCount}'),
          if (ft.entries.isNotEmpty)
            MapEntry('Names', ft.entries.map((e) => e.name).join(', ')),
        ];
      case 'NUID':
      case 'SUID':
      case 'BNID':
        if (bytes.length < 4) return const [];
        return [MapEntry('Id count', '${readU32be(bytes, 0)}')];
      default:
        return const [];
    }
  }

  List<Widget> _parsedHeader(String name, String subtitle) => [
    Text('Parsed · $name', style: const TextStyle(fontWeight: FontWeight.bold)),
    const SizedBox(height: 2),
    Text(subtitle, style: const TextStyle(fontSize: 11, color: Colors.grey)),
    const Divider(height: 14),
  ];

  bool get _showSummary =>
      _walk == null &&
      (_preview != null ||
          widget.section.tag == 'VCTP' ||
          LegacyIconDepth.forTag(widget.section.tag) != null ||
          _parsedBlockSummary().isNotEmpty);

  Widget _nonHeapPanel() {
    final info = BlockTag.of(widget.section.tag);
    final name = info?.displayName ?? 'Unknown (${widget.section.tag})';
    if (widget.section.tag == 'VCTP') {
      final types = decodeTypePool(widget.section.bytes);
      if (types.isNotEmpty) {
        const cap = 200;
        final shown = types.length > cap ? types.take(cap).toList() : types;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ..._parsedHeader(name, '${types.length} types'),
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
    final depth = LegacyIconDepth.forTag(widget.section.tag);
    if (depth != null) {
      if (widget.section.bytes.length == depth.byteLength) {
        final icon = decodeLegacyIcon(widget.section.bytes, depth);
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ..._parsedHeader(
              name,
              '${widget.section.tag} · 32×32 @ ${depth.bits}bpp',
            ),
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
            '$name (${widget.section.tag})\n\n'
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
        ..._parsedHeader(
          name,
          '${widget.section.tag} — ${(info?.confidence ?? BlockConfidence.tentative).name}',
        ),
        for (final field in fields) ...[
          Text(
            field.key,
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          SelectableText(field.value, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  List<SpanInfo> _layoutSpans(BlockLayout layout, Uint8List bytes) {
    final out = <SpanInfo>[];
    for (final field in layout) {
      final start = field.offset;
      if (start >= bytes.length) continue;
      final end = field.size == null ? bytes.length : start + field.size!;
      if (end > bytes.length) continue;
      out.add(
        SpanInfo(
          offset: start,
          length: end - start,
          lead: bytes[start],
          color: field.isUndecoded ? spanColorUnframed : _layoutColor(field),
          title: field.isUndecoded
              ? 'Undecoded ($start..${end - 1})'
              : '${field.name} (${field.type})',
          detail: field.isUndecoded
              ? 'These ${end - start} bytes are not yet decoded for this block.'
              : field.meaning,
          inlinePreview: _fieldPreview(field, bytes, start, end),
        ),
      );
      if (field.size == null) break;
    }
    return _fillGaps(out, bytes.length);
  }

  static Color _layoutColor(BlockField field) {
    if (field.entry.isNotEmpty) return spanColorContainer;
    return switch (field.type) {
      'pstr' || 'u8[]' => spanColorString,
      '4cc' => spanColorHeader,
      _ when field.type.startsWith('u8[') => spanColorRef,
      _ when field.type.endsWith('[]') || field.type.contains('[') =>
        spanColorContainer,
      _ => spanColorObject,
    };
  }

  static String? _fieldPreview(
    BlockField field,
    Uint8List bytes,
    int start,
    int end,
  ) {
    final view = ByteData.sublistView(bytes);
    final len = end - start;
    switch (field.type) {
      case 'u8' when len == 1:
        return '${bytes[start]}';
      case 'u16' when len == 2:
        return '${view.getUint16(start)}';
      case 'i16' when len == 2:
        return '${view.getInt16(start)}';
      case 'u16le' when len == 2:
        return '${view.getUint16(start, Endian.little)}';
      case 'u32' when len == 4:
        return '${view.getUint32(start)}';
      case 'i32' when len == 4:
        return '${view.getInt32(start)}';
      case 'u32le' when len == 4:
        return '${view.getUint32(start, Endian.little)}';
      case '4cc' when len == 4:
        return String.fromCharCodes(bytes, start, end);
      case 'pstr' when len >= 1 && start + 1 + bytes[start] <= end:
        return String.fromCharCodes(bytes, start + 1, start + 1 + bytes[start]);
      default:
        return len <= 8
            ? [
                for (var i = start; i < end; i++)
                  bytes[i].toRadixString(16).padLeft(2, '0'),
              ].join(' ')
            : '$len B';
    }
  }

  List<SpanInfo> _fillGaps(List<SpanInfo> fields, int len) {
    if (fields.isEmpty) return fields;
    fields.sort((a, bytes) => a.offset.compareTo(bytes.offset));
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

  static String _hex(List<int> bytes, {bool spaced = false}) => bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join(spaced ? ' ' : '');

  void _copy(BuildContext context, String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('Copied $what'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _copyMenu(BuildContext context, Uint8List bytes) {
    final sel = (_selected >= 0 && _selected < _records.length)
        ? _records[_selected]
        : null;
    final tag = widget.section.tag;
    return PopupMenuButton<int>(
      tooltip: 'Copy bytes',
      icon: const Icon(Icons.copy, size: 16),
      onSelected: (v) {
        if (v == 0) {
          _copy(context, _hex(bytes), '$tag · ${bytes.length} B (hex)');
        } else if (v == 1) {
          _copy(
            context,
            _hex(bytes, spaced: true),
            '$tag · ${bytes.length} B (spaced hex)',
          );
        } else if (v == 2 && sel != null) {
          final end = (sel.offset + sel.length).clamp(0, bytes.length);
          _copy(
            context,
            _hex(bytes.sublist(sel.offset, end)),
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
