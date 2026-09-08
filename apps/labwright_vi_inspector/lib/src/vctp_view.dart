import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'span_annotations.dart';

typedef VctpSpan = ({int offset, int length, ViType type});

List<VctpSpan> vctpTypeSpans(Uint8List body) {
  final types = decodeTypePool(body);
  if (types.isEmpty || body.length < 8) return const [];
  final data = ByteData.sublistView(body);
  final count = data.getUint32(0);
  if (count <= 0) return const [];
  final out = <VctpSpan>[];
  var off = 4;
  for (var i = 0; i < count && i < types.length; i++) {
    if (off + 4 > body.length) break;
    final descLen = data.getUint16(off);
    if (descLen < 4 || off + descLen > body.length) break;
    out.add((offset: off, length: descLen, type: types[i]));
    off += descLen;
  }
  return out;
}

class VctpCorrelationView extends StatefulWidget {
  const VctpCorrelationView({super.key, required this.body});

  final Uint8List body;

  @override
  State<VctpCorrelationView> createState() => _VctpCorrelationViewState();
}

class _VctpCorrelationViewState extends State<VctpCorrelationView> {
  final _hexScroll = ScrollController();
  final _listScroll = ScrollController();
  late List<VctpSpan> _spans;

  late List<int> _byteToSpan;

  int _selected = -1;

  int _selectedByte = -1;

  @override
  void initState() {
    super.initState();
    _build();
  }

  @override
  void didUpdateWidget(VctpCorrelationView old) {
    super.didUpdateWidget(old);
    if (!identical(old.body, widget.body)) {
      _selected = -1;
      _selectedByte = -1;
      _build();
    }
  }

  void _build() {
    _spans = vctpTypeSpans(widget.body);
    _byteToSpan = List<int>.filled(widget.body.length, -1);
    for (var i = 0; i < _spans.length; i++) {
      final span = _spans[i];
      for (
        var b = span.offset;
        b < span.offset + span.length && b < _byteToSpan.length;
        b++
      ) {
        _byteToSpan[b] = i;
      }
    }
  }

  @override
  void dispose() {
    _hexScroll.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  void _select(int i, {bool fromHex = false, int byteOffset = -1}) {
    setState(() {
      _selected = i;
      _selectedByte = byteOffset;
    });
    if (i < 0 || i >= _spans.length) return;
    if (_hexScroll.hasClients) {
      final row = _spans[i].offset ~/ 16;
      _hexScroll.animateTo(
        (row * _kRowHeight).clamp(0.0, _hexScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    }
    if (fromHex && _listScroll.hasClients) {
      _listScroll.animateTo(
        (i * _kTypeRowHeight - 80).clamp(
          0.0,
          _listScroll.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_spans.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'VCTP body did not frame into type descriptors.',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    final rows = (widget.body.length + 15) ~/ 16;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Text(
            'Raw VCTP bytes (left) ↔ decoded type descriptors (right). Select a '
            'type to highlight its bytes; tap a byte to highlight its descriptor '
            'and field.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
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
                          itemBuilder: (context, row) => _hexRow(row),
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
                    Expanded(
                      child: Scrollbar(
                        controller: _listScroll,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _listScroll,
                          itemCount: _spans.length,
                          itemExtent: _kTypeRowHeight,
                          itemBuilder: (context, i) => _typeRow(i),
                        ),
                      ),
                    ),
                    if (_selected >= 0) _detail(_spans[_selected]),
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

  Widget _hexRow(int row) {
    final body = widget.body;
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
        if (off != null && off >= 0 && off < body.length) {
          final si = _byteToSpan[off];
          if (si >= 0) {
            _select(si, fromHex: true, byteOffset: off);
          } else {
            setState(() {
              _selected = -1;
              _selectedByte = off!;
            });
          }
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
          for (var i = 0; i < 16; i++) _cell(base + i, hex: true),
          const SizedBox(width: _gap),
          for (var i = 0; i < 16; i++) _cell(base + i, hex: false),
        ],
      ),
    );
  }

  Widget _cell(int offset, {required bool hex}) {
    final body = widget.body;
    if (offset >= body.length) return SizedBox(width: hex ? _cellW : _asciiW);
    final si = _byteToSpan[offset];
    final inSelected = si >= 0 && si == _selected;
    final byte = body[offset];
    final color = si < 0
        ? const Color(0xFF6E6E6E)
        : (inSelected ? Colors.white : const Color(0xFFBFA6E8));
    final text = hex
        ? byte.toRadixString(16).padLeft(2, '0')
        : (byte >= 0x20 && byte < 0x7f ? String.fromCharCode(byte) : '·');
    return Container(
      width: hex ? _cellW : _asciiW,
      alignment: Alignment.center,
      color: inSelected
          ? spanColorObject.withValues(alpha: 0.35)
          : (offset == _selectedByte ? Colors.white24 : null),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          color: color,
          fontFamily: 'monospace',
          fontSize: 12.5,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _typeRow(int i) {
    final span = _spans[i];
    final type = span.type;
    final name = type.name ?? '';
    final selected = i == _selected;
    final extra = type.enumItems.isNotEmpty
        ? '${type.enumItems.length} items'
        : type.members.isNotEmpty
        ? '${type.members.length} members'
        : '';
    return GestureDetector(
      key: ValueKey('vctp-type-$i'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(i, byteOffset: span.offset),
      child: Container(
        color: selected ? spanColorObject.withValues(alpha: 0.18) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: Text(
                '#${type.index}',
                style: const TextStyle(
                  color: Colors.grey,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
            SizedBox(
              width: 34,
              child: Text(
                '0x${type.code.toRadixString(16).padLeft(2, '0')}',
                style: const TextStyle(
                  color: Colors.grey,
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: type.kind.name),
                    if (name.isNotEmpty)
                      TextSpan(
                        text: "  '$name'",
                        style: const TextStyle(color: Color(0xFF4C8C4C)),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            if (extra.isNotEmpty)
              Text(
                extra,
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }

  static String _fieldAt(VctpSpan span, int byteOffset) {
    final rel = byteOffset - span.offset;
    if (rel < 0) return '';
    if (rel < 2) return 'descriptor length (u16) @+0';
    if (rel == 2) return 'flags (u8) @+2';
    if (rel == 3) return 'type code (u8) @+3';
    return 'interior @+$rel';
  }

  Widget _detail(VctpSpan span) {
    final type = span.type;
    final name = type.name ?? '';
    final field = _selectedByte >= 0 ? _fieldAt(span, _selectedByte) : '';
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
            'Descriptor #${type.index} · ${type.kind.name}'
            '${name.isEmpty ? '' : " '$name'"}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'bytes 0x${span.offset.toRadixString(16)}..'
            '0x${(span.offset + span.length - 1).toRadixString(16)} · '
            '${span.length} B · code 0x${type.code.toRadixString(16).padLeft(2, '0')}',
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
          if (field.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Byte 0x${_selectedByte.toRadixString(16)}: $field',
              style: const TextStyle(fontSize: 12),
            ),
          ],
          if (type.enumItems.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'items: ${type.enumItems.take(12).join(', ')}'
              '${type.enumItems.length > 12 ? ', …' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
          if (type.members.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'member type indices: ${type.members.join(', ')}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

const double _kRowHeight = 20;
const double _kTypeRowHeight = 28;
