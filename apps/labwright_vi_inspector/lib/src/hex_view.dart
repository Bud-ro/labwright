import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:labwright_videcode/labwright_videcode.dart';
import 'package:labwright_viparse/labwright_viparse.dart';

/// A read-only **hex + parser** view of one decoded resource-block section —
/// HxD/Wireshark style. The section's bytes are shown as a hex dump on the left,
/// record-colored; the right panel lists the parsed records (driven by the
/// clean-room `HeapOpcode` / `HeapObjectClass` / `HeapAttribute` catalogs and the
/// heap walker). Selecting a record highlights its bytes and shows its decoded
/// meaning, including typed displays (colour swatches, rectangles, strings,
/// numbers). Honest by construction: bytes the walker can't frame are shown as
/// an uncovered gap, never hidden.
class BlockHexView extends StatefulWidget {
  const BlockHexView({super.key, required this.section, this.siblings = const []});

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
  late final List<_SpanInfo> _records;
  late final List<int> _byteToRecord; // byte offset -> record index (or -1)
  Widget? _preview; // typed whole-section display (e.g. an icon image)
  HeapWalk? _walk; // the record walk (for coverage / stop-point reporting)
  int _selected = -1;

  @override
  void initState() {
    super.initState();
    _buildModel();
  }

  @override
  void didUpdateWidget(BlockHexView old) {
    super.didUpdateWidget(old);
    // The Inspect tab swaps the selected block in-place (same State), so rebuild
    // the record/byte map when the section changes — otherwise a stale
    // _byteToRecord (sized for the old block) range-errors the hex dump.
    if (!identical(old.section, widget.section)) {
      _selected = -1;
      _buildModel();
    }
  }

  void _buildModel() {
    final b = widget.section.bytes;
    _preview = iconPreview(b);
    // Only the corpus-confirmed C4 record heaps (FPHb/BDHb/FPHc/BDHc) get the
    // bracket-walk. Gating on the block tag — not a byte heuristic — stops other
    // compressed blocks (VCTP type pool, VICD code, DFDS data, …) and short
    // look-alikes (e.g. TM80) from being mis-read as heaps with a bogus
    // content-length and a fat "unframed tail".
    final isHeap = isRecordHeapTag(widget.section.tag);
    if (isHeap) {
      try {
        final w = walkHeapBody(b);
        _walk = w;
        _records = [
          // The heap stream opens with a u32 big-endian content-length header
          // (= record-stream bytes that follow = decompressed size − 4). The walk
          // proper begins at offset 4; annotate the header so no byte is unlabeled.
          if (b.length >= 4)
            _SpanInfo(
              offset: 0,
              length: 4,
              lead: b[0],
              color: _cHeader,
              title: 'Heap content length (u32)',
              detail: 'Big-endian u32 = ${_u32(b, 0)} bytes: the size of the record stream that '
                  'follows (= decompressed heap size − 4). The bracket-tree walk begins at offset 4.',
              inlinePreview: '${_u32(b, 0)} B',
            ),
          for (final s in w.spans) _classify(b, s, widget.section.tag),
          // If the walk stopped on an un-framable record, account for the
          // remaining bytes explicitly (so NO byte is silently unlabeled): a
          // single "unframed tail" span. Honest — the bytes are preserved; their
          // record family is just not yet decoded (the coverage frontier; ~0.2%
          // of corpus heaps). Complete walks (99.8%) need no tail.
          if (w.stoppedAtOffset != null && w.stoppedAtOffset! < b.length)
            _SpanInfo(
              offset: w.stoppedAtOffset!,
              length: b.length - w.stoppedAtOffset!,
              lead: w.stoppedLead ?? b[w.stoppedAtOffset!],
              color: _cUnframed,
              title: 'Unframed tail (lead 0x${(w.stoppedLead ?? 0).toRadixString(16)})',
              detail: 'The record walk stopped here: this lead byte\'s record family is not yet '
                  'decoded, so the remaining ${b.length - w.stoppedAtOffset!} bytes are not '
                  'individually framed. They are preserved — decoding this family is the open frontier.',
              inlinePreview: '${b.length - w.stoppedAtOffset!} B',
            ),
        ];
      } catch (_) {
        _records = const [];
      }
    } else {
      // Non-heap block: annotate per-byte from the block's known field layout so
      // every byte is clickable to its purpose (with explicit "undecoded" spans
      // for any bytes we can't yet name — honest, total coverage). Empty when the
      // block has no field decoder, in which case the raw-hex panel is shown.
      _records = _fieldSpans(widget.section.tag, b);
    }
    _byteToRecord = List<int>.filled(b.length, -1);
    for (var i = 0; i < _records.length; i++) {
      final r = _records[i];
      for (var o = r.offset; o < r.offset + r.length && o < b.length; o++) {
        _byteToRecord[o] = i;
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
  void _select(int i, {bool fromHex = false}) {
    setState(() => _selected = i);
    if (i < 0 || i >= _records.length) return;
    if (_hexScroll.hasClients) {
      final row = _records[i].offset ~/ 16;
      _hexScroll.animateTo((row * _kRowHeight).clamp(0.0, _hexScroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
    if (fromHex && _recScroll.hasClients) {
      _recScroll.animateTo((i * _kRecHeight - 80).clamp(0.0, _recScroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.section.bytes;
    final rows = (b.length + 15) ~/ 16;
    final fieldCov = _fieldCoverage();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Text('${widget.section.tag}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace')),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${_fmt(b.length)} ${widget.section.wasCompressed ? '(inflated)' : ''} · '
                  '${_records.isEmpty ? 'raw bytes (no record framing)' : '${_records.length} records'}'
                  '${_walk != null && !_walk!.complete ? ' · walk stopped at 0x${_walk!.stoppedAtOffset!.toRadixString(16)} (lead 0x${_walk!.stoppedLead!.toRadixString(16)}), ${(_walk!.coverage * 100).toStringAsFixed(0)}% framed' : ''}'
                  '${fieldCov != null ? ' · ${(fieldCov * 100).toStringAsFixed(0)}% framed' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: (_walk != null && !_walk!.complete) || (fieldCov != null && fieldCov < 1.0)
                          ? Colors.orange
                          : Colors.grey,
                      fontSize: 12),
                ),
              ),
              _copyMenu(context, b),
            ],
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // hex dump
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
                          itemBuilder: (context, row) => _hexRow(b, row),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              // records panel
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

  // Fixed-width columns so the hex/ASCII grids align regardless of the platform
  // font (a "monospace" family alone does not guarantee equal glyph advance),
  // and so a tap maps to an exact byte.
  static const _offW = 66.0; // offset column
  static const _cellW = 21.0; // per-hex-byte cell
  static const _asciiW = 9.0; // per-ascii-char cell
  static const _gap = 14.0; // hex→ascii gap
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
            child: Text('  ${base.toRadixString(16).padLeft(6, '0')}',
                style: const TextStyle(color: Color(0xFF888888), fontFamily: 'monospace', fontSize: 12.5)),
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
    final c = b[o];
    final text = hex ? b[o].toRadixString(16).padLeft(2, '0') : (c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : '·');
    return Container(
      width: hex ? _cellW : _asciiW,
      alignment: Alignment.center,
      color: sel ? color.withValues(alpha: 0.30) : null,
      child: Text(text,
          maxLines: 1,
          style: TextStyle(color: sel ? Colors.white : color, fontFamily: 'monospace', fontSize: 12.5, height: 1.35)),
    );
  }

  Widget _recordRow(int i) {
    final r = _records[i];
    final selected = i == _selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _select(i),
      child: Container(
        color: selected ? r.color.withValues(alpha: 0.18) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          children: [
            Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(color: r.color, shape: BoxShape.circle)),
            SizedBox(
              width: 54,
              child: Text('@${r.offset.toRadixString(16)}',
                  style: const TextStyle(color: Colors.grey, fontFamily: 'monospace', fontSize: 11)),
            ),
            Expanded(child: Text(r.title, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis)),
            if (r.inlinePreview != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(r.inlinePreview!,
                    style: const TextStyle(fontSize: 11.5, color: Colors.grey, fontFamily: 'monospace')),
              ),
            if (r.swatch != null)
              Container(width: 14, height: 14, decoration: BoxDecoration(color: r.swatch, borderRadius: BorderRadius.circular(2), border: Border.all(color: Colors.black26))),
          ],
        ),
      ),
    );
  }

  Widget _detail(_SpanInfo r) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0x33FFFFFF)))),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('offset 0x${r.offset.toRadixString(16)} · ${r.length} bytes · lead 0x${r.lead.toRadixString(16)}',
              style: const TextStyle(color: Colors.grey, fontSize: 11)),
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
    for (final r in _records) {
      if (r.color == _cUnframed) continue; // skip the "Undecoded (a..b)" gaps
      framed += r.length;
    }
    return framed / total;
  }

  /// Decoded fields for a non-heap block whose format we parse — label/value
  /// pairs straight from the viparse decoders (never fabricated; only what a
  /// decoder actually returns). Empty when the block has no decoder.
  List<MapEntry<String, String>> _parsedBlockSummary() {
    final b = widget.section.bytes;
    switch (widget.section.tag) {
      case 'vers':
        final v = decodeVersionWord(b);
        return v == null
            ? const []
            : [
                MapEntry('Version', v.version),
                MapEntry('Stage', '0x${v.stage.toRadixString(16)}${v.stage == 0x80 ? ' (release)' : ''}'),
                MapEntry('Build', '${v.build}'),
              ];
      case 'LVSR':
        final r = decodeSaveRecord(b);
        return r == null
            ? const []
            : [
                MapEntry('LabVIEW version', r.version),
                MapEntry('BD password-protected', r.isBlockDiagramPasswordProtected ? 'yes' : 'no'),
              ];
      case 'CONP':
      case 'CPC2':
        final c = decodeConnectorPane(b);
        if (c == null) return const [];
        if (c.isInline) return [const MapEntry('Form', 'inline (not yet decoded)')];
        final out = [MapEntry('VCTP type index', '${c.typeIndex}')];
        // Resolve the index against the sibling VCTP type pool, when available.
        final pool = widget.siblings.isEmpty ? const <ViType>[] : typePoolFromDecoded(widget.siblings);
        final idx = c.typeIndex;
        if (idx != null && idx >= 1 && idx <= pool.length) {
          final t = pool[idx - 1];
          final name = t.name != null && t.name!.isNotEmpty ? " '${t.name}'" : '';
          out.add(MapEntry('Conpane type', '${typeLabel(t, pool)}$name'));
        }
        return out;
      case 'HLPP':
        final p = decodeHelpPath(b);
        return (p == null || !p.isPth0 || p.path.isEmpty) ? const [] : [MapEntry('Help path', p.path)];
      case 'STRG':
      case 'HLPT':
        final t = decodeStringBlock(b);
        if (t == null || t.isEmpty) return const [];
        return [MapEntry('Text', t.length > 240 ? '${t.substring(0, 240)}…' : t)];
      case 'HIST':
        final h = decodeHistory(b);
        return h == null
            ? const []
            : [MapEntry('Format version', '${h.formatVersion}'), MapEntry('Revision entries', '${h.entryCount}')];
      case 'FTAB':
        final ft = decodeFontTable(b);
        if (ft == null) return const [];
        return [
          MapEntry('Fonts', '${ft.fontCount}'),
          if (ft.names.isNotEmpty) MapEntry('Names', ft.names.join(', ')),
        ];
      case 'NUID':
      case 'SUID':
      case 'BNID':
        final it = decodeIdTable(b);
        return it == null ? const [] : [MapEntry('Id count', '${it.count}')];
      default:
        return const [];
    }
  }

  Widget _nonHeapPanel() {
    final info = blockInfo(widget.section.tag);
    // VCTP — the VI's type pool. Its decompressed bytes decode to the type list.
    if (widget.section.tag == 'VCTP') {
      final types = decodeTypePool(widget.section.bytes);
      if (types.isNotEmpty) {
        const cap = 200;
        final shown = types.length > cap ? types.take(cap).toList() : types;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Parsed · ${info.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('${types.length} types', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const Divider(height: 14),
            for (final t in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '#${t.index} ', style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.grey)),
                  TextSpan(text: typeLabel(t, types), style: const TextStyle(fontSize: 12.5)),
                  if (t.name != null && t.name!.isNotEmpty)
                    TextSpan(text: "  '${t.name}'", style: const TextStyle(fontSize: 12.5, color: Color(0xFF4C8C4C))),
                ])),
              ),
            if (types.length > cap)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('+${types.length - cap} more (not shown)', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
          ],
        );
      }
    }
    // Legacy icon bitmaps (icl8/icl4/ICON) render as a real 32x32 preview.
    final bpp = legacyIconBpp(widget.section.tag);
    if (bpp != null) {
      final icon = decodeLegacyIcon(widget.section.bytes, bpp);
      if (icon != null) {
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Parsed · ${info.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('${widget.section.tag} · 32×32 @ ${bpp}bpp', style: const TextStyle(fontSize: 11, color: Colors.grey)),
            const Divider(height: 14),
            Center(
              child: CustomPaint(
                size: const Size(128, 128),
                painter: _LegacyIconPainter(icon),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              bpp == 1
                  ? '1-bit mask: black = set pixel.'
                  : 'Shown as palette indices (shaded by index) — the true LabVIEW colour palette is not yet mapped.',
              style: const TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic),
            ),
          ],
        );
      }
    }
    final fields = _parsedBlockSummary();
    if (_preview != null) return Center(child: Padding(padding: const EdgeInsets.all(16), child: _preview));
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
        Text('Parsed · ${info.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text('${widget.section.tag} — ${info.confidence.name}', style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const Divider(height: 14),
        for (final f in fields) ...[
          Text(f.key, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          SelectableText(f.value, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 8),
        ],
        Text(info.note, style: const TextStyle(fontSize: 11, color: Colors.grey, fontStyle: FontStyle.italic)),
      ],
    );
  }

  /// Per-byte field spans for a non-heap block whose layout we know, so the hex
  /// dump is clickable byte-by-byte (mirroring the heap record-walk). Returns []
  /// for blocks without a field layout (the raw-hex panel is shown instead).
  /// Whatever spans are produced, [_fillGaps] adds explicit "undecoded" spans so
  /// EVERY byte is accounted for — coverage is total and the gaps stay visible.
  List<_SpanInfo> _fieldSpans(String tag, List<int> b) {
    final out = <_SpanInfo>[];
    void span(int off, int len, Color c, String title, String detail, {String? preview}) {
      if (len <= 0 || off < 0 || off + len > b.length) return;
      out.add(_SpanInfo(offset: off, length: len, lead: b[off], color: c, title: title, detail: detail, inlinePreview: preview));
    }

    switch (tag) {
      case 'vers':
        final vw = b is Uint8List ? decodeVersionWord(b) : decodeVersionWord(Uint8List.fromList(b));
        span(0, 4, _cObject, 'Version word (u32)',
            'BCD major · minor<<4|patch · stage · build. The same word heads LVSR. See decodeVersionWord.',
            preview: vw == null ? '0x${_u32(b, 0).toRadixString(16)}' : 'v${vw.version}');
        // bytes 4.. are the Pascal version string + VIDS title — left as undecoded
        // here (decodeVersion reads them as strings, not byte-framed yet).
      case 'STRG':
      case 'HLPT':
        span(0, 4, _cHeader, 'Text length (u32)', 'Byte length of the UTF-8 text that follows (== sectionLen-4).',
            preview: '${_u32(b, 0)} B');
        span(4, b.length - 4, _cRect, 'Text (UTF-8)', 'The VI description / context-help text.');
      case 'NUID':
      case 'SUID':
      case 'BNID':
        if (b.length >= 4) {
          final count = _u32(b, 0);
          span(0, 4, _cHeader, 'Entry count (u32)', '$count u32 id entries follow ([u32 count][count u32]).',
              preview: '$count');
          for (var i = 0; i < count && 4 + 4 * i + 4 <= b.length; i++) {
            span(4 + 4 * i, 4, _cObject, 'id[$i] (u32)', 'An opaque UID/handle value (role not yet decoded).',
                preview: '0x${_u32(b, 4 + 4 * i).toRadixString(16)}');
          }
        }
      case 'HIST':
        const names = ['format version', 'flags', 'entry count', 'reserved', 'word4', 'stamp A', 'stamp B', 'reserved', 'reserved', 'word9'];
        for (var w = 0; w < 10 && w * 4 + 4 <= b.length; w++) {
          span(w * 4, 4, _cObject, 'HIST @${w * 4}: ${names[w]} (u32)', 'Revision-history record word. See decodeHistory.',
              preview: '${_u32(b, w * 4)}');
        }
      case 'LVSR':
        span(0, 4, _cObject, 'Version word (u32)', 'BCD major · minor<<4|patch · stage · build (== vers word). See decodeSaveRecord.',
            preview: '0x${_u32(b, 0).toRadixString(16)}');
        span(52, 16, _cObject, 'Per-VI value A (16B)',
            'A 16-byte value that varies per VI (≈6920 distinct across the corpus); role not yet decoded.');
        span(80, 16, _cObject, 'Per-VI value B (16B)',
            'A second 16-byte per-VI value (≈6920 distinct across the corpus); role not yet decoded.');
        span(96, 16, _cRect, 'BD password hash (16B)', 'Block-diagram password hash; mirrors the BDPW block. Empty-password default = d41d8cd9…');
        span(144, 16, _cRect, 'Secondary hash (16B)', 'A second hash/checksum slot (role not fully decoded).');
        // bytes 4..52, 68..80, 112..144, 160.. are flag/enum words not yet field-decoded -> _fillGaps marks them.
      case 'CONP':
      case 'CPC2':
        if (b.length == 2) {
          final idx = _u16(b, 0);
          // Resolve the index against the sibling VCTP pool so the conpane type
          // shows here too (not lost when CONP routes to the per-byte view).
          var resolved = '';
          if (widget.siblings.isNotEmpty) {
            final pool = typePoolFromDecoded(widget.siblings);
            if (idx >= 1 && idx <= pool.length) {
              final t = pool[idx - 1];
              resolved = ' → ${typeLabel(t, pool)}${t.name != null && t.name!.isNotEmpty ? " '${t.name}'" : ''}';
            }
          }
          span(0, 2, _cObject, 'VCTP type index (u16)',
              '${tag == 'CONP' ? 'Index of the connector-pane type in the VCTP pool (CONP: 100% in-range).' : 'A second conpane reference (CPC2: resolves as a VCTP index only ~84%).'}$resolved',
              preview: '$idx$resolved');
        }
        // the rare >=28-byte inline form is left undecoded (gap-filled).
      case 'FTAB':
        span(0, 2, _cObject, 'Version (u16)', 'Font-table version (1 in the corpus).', preview: '${_u16(b, 0)}');
        if (b.length >= 6) {
          span(2, 4, _cGroup, 'Header constant (00 02 00 03)',
              'Fixed format sub-version words (u16 2, u16 3); 00 02 00 03 in all 322 corpus FTABs.');
        }
        if (b.length >= 8) span(6, 2, _cHeader, 'Font count (u16)', 'Number of packed name entries.', preview: '${_u16(b, 6)}');
        if (b.length >= 12) {
          final nameOff = _u32(b, 8);
          span(8, 4, _cHeader, 'Name-table offset (u32)', 'Byte offset of the packed Pascal font-name strings.', preview: '$nameOff');
          // Per-font metric records between the header (12) and the name table:
          // each font has a 12-byte metric record, with a u32 between adjacent
          // fonts (count-1 of them). Corpus-confirmed: the region is exactly
          // count*16 - 4 bytes across all 322 FTABs. Inner metric fields and the
          // u32 value are not yet decoded — framed as opaque, not guessed.
          final count = _u16(b, 6);
          if (nameOff >= 12 && nameOff <= b.length && count > 0) {
            var p = 12;
            for (var i = 0; i < count && p + 12 <= nameOff; i++) {
              span(p, 12, _cObject, 'Font[$i] metric record (12B)',
                  'Per-font size/style metrics; inner fields not yet decoded.');
              p += 12;
              if (i < count - 1 && p + 4 <= nameOff) {
                span(p, 4, _cGroup, 'Font[$i] u32 field',
                    'A 4-byte value between font records (role not yet decoded).', preview: '${_u32(b, p)}');
                p += 4;
              }
            }
          }
          if (nameOff < b.length) span(nameOff, b.length - nameOff, _cRect, 'Font names (Pascal strings)', 'Packed [u8 len][name] font face names. See decodeFontTable.');
        }
        // header (0..12), the per-font metric region, and names are all framed now.
      case 'BDPW':
        span(0, 16, _cRect, 'Password hash (16B)', 'Block-diagram password hash; sample is MD5("") d41d8cd9…');
        // remaining bytes (salt/secondary) not yet decoded -> gap-filled.
      case 'GCPR':
        span(0, b.length, _cGroup, 'Generated-code property (${b.length}B)', 'Fixed-size record, byte-constant (all-zero) across the corpus.');
      case 'VPDP':
        span(0, b.length, _cGroup, 'VI property data (${b.length}B)', 'Fixed 4-byte record, byte-constant (all-zero) across the corpus.');
      case 'DLDR':
        span(0, b.length, _cGroup, 'Default-data loader (${b.length}B)', 'Fixed 28-byte record, byte-constant across the corpus.');
      case 'RTSG':
      case 'OBSG':
      case 'CCSG':
        span(0, 16, _cObject, '16-byte signature', tag == 'CCSG' ? 'Near-constant shared toolchain signature (opaque value).' : 'Per-VI signature (identity; opaque value).',
            preview: 'sig');
      case 'SCSR':
        span(0, 4, _cHeader, 'Header (u32)', 'Leading word 0x01000000 BE (version-ish).', preview: '0x${_u32(b, 0).toRadixString(16)}');
        span(4, 16, _cObject, '16-byte signature', 'Source signature (near-constant; opaque value).', preview: 'sig');
      case 'FPSE':
      case 'BDSE':
        // Section marker: one u32 per 4 bytes. Corpus is overwhelmingly a single
        // u32 (4 B); a rare 8-byte form carries two. The value's exact meaning
        // (size/offset/flags) is not yet decoded — labeled honestly as a marker.
        for (var p = 0; p + 4 <= b.length; p += 4) {
          span(p, 4, _cObject, '$tag marker (u32)',
              '${tag == 'FPSE' ? 'Front-panel' : 'Block-diagram'} section marker word (value role not yet decoded).',
              preview: '${_u32(b, p)}');
        }
      case 'MUID':
        span(0, 4, _cObject, 'MUID (u32)', 'Module/object unique id (opaque value).', preview: '${_u32(b, 0)}');
      case 'CPST':
      case 'CPSP':
        // String-label table: [u32 count][count × [u8 len][ASCII]]. Corpus shows
        // boolean / comparison / report labels (e.g. "True", "Equal (Value)").
        // Empty slots are len-0 Pascal strings. Confirmed across the corpus.
        if (b.length >= 4) {
          final count = _u32(b, 0);
          span(0, 4, _cHeader, 'String count (u32)',
              '$count Pascal-string label entries follow ([u8 len][ASCII]).', preview: '$count');
          var p = 4;
          for (var i = 0; i < count && p < b.length; i++) {
            final n = b[p];
            span(p, 1, _cObject, 'entry[$i] length (u8)', 'Length of the label string that follows.', preview: '$n');
            if (n > 0 && p + 1 + n <= b.length) {
              span(p + 1, n, _cRect, 'entry[$i] (ASCII)', 'A boolean/comparison/report label.',
                  preview: String.fromCharCodes(b.sublist(p + 1, p + 1 + n)));
            }
            p += 1 + n;
          }
        }
      case 'FPTD':
        // Overwhelmingly a 2-byte u16 (3119/3123). Likely a VCTP type index, but
        // unlike CONP that mapping is NOT corpus-verified for FPTD — so it is
        // labeled a type index without resolving/claiming the pool entry. The
        // rare larger forms are left raw (no confident layout) → gap-filled.
        if (b.length == 2) {
          span(0, 2, _cObject, 'Type index (u16)',
              'Front-panel terminal type descriptor; likely indexes the VCTP pool (not corpus-verified for FPTD).',
              preview: '${_u16(b, 0)}');
        }
      case 'TITL':
        if (b.isNotEmpty) {
          final n = b[0];
          span(0, 1, _cHeader, 'Title length (u8)', 'Pascal-string length of the VI title that follows.', preview: '$n');
          if (1 + n <= b.length) {
            final text = String.fromCharCodes(b.sublist(1, 1 + n));
            span(1, n, _cRect, 'Title (ASCII)', 'The VI window title (Pascal string).', preview: text);
          }
        }
      default:
        return const [];
    }
    return _fillGaps(out, b.length);
  }

  /// Inserts explicit "undecoded" spans for any byte ranges [fields] leaves
  /// uncovered (and a trailing tail), so the hex view accounts for every byte.
  List<_SpanInfo> _fillGaps(List<_SpanInfo> fields, int len) {
    if (fields.isEmpty) return fields;
    fields.sort((a, b) => a.offset.compareTo(b.offset));
    final out = <_SpanInfo>[];
    var cursor = 0;
    void gap(int from, int to) {
      if (to > from) {
        out.add(_SpanInfo(
          offset: from,
          length: to - from,
          lead: 0,
          color: _cUnframed,
          title: 'Undecoded ($from..${to - 1})',
          detail: 'These ${to - from} bytes are not yet field-decoded for this block — preserved, not hidden.',
          inlinePreview: '${to - from} B',
        ));
      }
    }

    for (final f in fields) {
      gap(cursor, f.offset);
      out.add(f);
      if (f.offset + f.length > cursor) cursor = f.offset + f.length;
    }
    gap(cursor, len);
    return out;
  }

  static String _fmt(int n) => n >= 1024 ? '${(n / 1024).toStringAsFixed(1)} KB' : '$n B';

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
      SnackBar(content: Text('Copied $what'), duration: const Duration(seconds: 2)),
    );
  }

  /// A copy control for the block's bytes: continuous hex (default), spaced hex,
  /// and — when a record is selected — just that record's bytes.
  Widget _copyMenu(BuildContext context, Uint8List b) {
    final sel = (_selected >= 0 && _selected < _records.length) ? _records[_selected] : null;
    final tag = widget.section.tag;
    return PopupMenuButton<int>(
      tooltip: 'Copy bytes',
      icon: const Icon(Icons.copy, size: 16),
      onSelected: (v) {
        if (v == 0) {
          _copy(context, _hex(b), '$tag · ${b.length} B (hex)');
        } else if (v == 1) {
          _copy(context, _hex(b, spaced: true), '$tag · ${b.length} B (spaced hex)');
        } else if (v == 2 && sel != null) {
          final end = (sel.offset + sel.length).clamp(0, b.length);
          _copy(context, _hex(b.sublist(sel.offset, end)), 'record · ${end - sel.offset} B (hex)');
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 0, child: Text('Copy $tag as hex')),
        const PopupMenuItem(value: 1, child: Text('Copy as hex (spaced)')),
        if (sel != null) PopupMenuItem(value: 2, child: Text('Copy selected record (${sel.length} B)')),
      ],
    );
  }
}

const double _kRowHeight = 20;
const double _kRecHeight = 30; // records-list row height (fixed → smooth scroll + scroll-to-index)

/// One parsed record for display.
class _SpanInfo {
  _SpanInfo({
    required this.offset,
    required this.length,
    required this.lead,
    required this.color,
    required this.title,
    required this.detail,
    this.swatch,
    this.display,
    this.inlinePreview,
  });
  final int offset;
  final int length;
  final int lead;
  final Color color;
  final String title;
  final String detail;
  final Color? swatch;
  final Widget? display;

  /// A short value shown inline in the record row (right-aligned) — a "preview"
  /// of the decoded value (e.g. a size/count) so it is legible without selecting
  /// the row, mirroring the colour swatch for colour records.
  final String? inlinePreview;
}

int _u16(List<int> b, int p) => (b[p] << 8) | b[p + 1];
int _u32(List<int> b, int p) => (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];

const _cHeader = Color(0xFFD08BB0);
const _cUnframed = Color(0xFFE57373); // the un-framable tail (decode frontier)
const _cObject = Color(0xFF9E7BE0);
const _cGroup = Color(0xFF8A8A8A);
const _cRect = Color(0xFF5C9BD6);
const _cString = Color(0xFF6FCF6F);
const _cContainer = Color(0xFF2BB8A8);
const _cAttr = Color(0xFFE8A33A);
const _cRef = Color(0xFF49C4D8);
const _cOther = Color(0xFFB0B0B0);

_SpanInfo _classify(Uint8List b, HeapSpan s, String tag) {
  final o = s.offset, lead = s.lead, len = s.length;
  _SpanInfo make(Color c, String title, String detail, {Color? swatch, Widget? display, String? inlinePreview}) =>
      _SpanInfo(
          offset: o,
          length: len,
          lead: lead,
          color: c,
          title: title,
          detail: detail,
          swatch: swatch,
          display: display,
          inlinePreview: inlinePreview);

  // Object header: 10/11/12 02 fe <kind> fd <oid>
  if ((lead == 0x10 || lead == 0x11 || lead == 0x12) && o + 9 <= b.length && b[o + 2] == 0x02 && b[o + 3] == 0xfe && b[o + 6] == 0xfd) {
    final kind = _u16(b, o + 4), oid = _u16(b, o + 7);
    final cls = HeapObjectClass.fromCode(kind);
    final conf = cls.confidence == ClassConfidence.confirmed ? '' : ' (${cls.confidence.name})';
    return make(_cObject, 'Object · ${cls.label}',
        'Declares object #$oid of class 0x${kind.toRadixString(16)} — ${cls.label}$conf.');
  }
  // Named property token (the decoded hi-nibble 0/1 family) — show its meaning.
  final prop = decodeHeapPropertyToken(b, o);
  if (prop != null) {
    final t = prop.token;
    final conf = t.confidence == AttrConfidence.confirmed ? '' : ' (${t.confidence.name})';
    final hexpair = '${lead.toRadixString(16).padLeft(2, '0')} ${b[o + 1].toRadixString(16).padLeft(2, '0')}';
    final val = prop.value == null ? '' : ' = ${prop.value}';
    return make(_cAttr, '$hexpair · ${t.tokenName}', 'Object property$val$conf.');
  }
  // Group open / close (bracket tree). What MAKES a group: a record
  // <10|11|12|13> <subop> <count> <type-tag> where the byte at +3 is a type tag
  // (fb/fe/fd) — that type tag is the discriminator (a 0x10/0x11 WITHOUT it is a
  // property token, not a group). The matching close is the open's lead − 0x08
  // (0x08←0x10, 0x09←0x11, 0x0a←0x12) carrying the same subop tag — STRUCTURAL,
  // not coincidence: corpus-measured 99.99% on the lead and 99.8% on the tag, with
  // the tree ~99.93% balanced (the rest pop the innermost open positionally).
  String _hx(int v) => '0x${v.toRadixString(16).padLeft(2, '0')}';
  if (lead == 0x10 || lead == 0x11 || lead == 0x12 || lead == 0x13) {
    final hasTypeTag = o + 3 < b.length && (b[o + 3] == 0xfb || b[o + 3] == 0xfe || b[o + 3] == 0xfd);
    if (hasTypeTag) {
      final tag = o + 1 < b.length ? b[o + 1] : -1;
      return make(_cGroup, 'Group open · tag ${_hx(tag)}',
          'Opens a bracket-tree group: ${_hx(lead)} subop count ${_hx(b[o + 3])}(type tag). The '
          'type tag at +3 (fb/fe/fd) is what makes this a GROUP rather than a property token. Its '
          'matching close is lead ${_hx(lead - 0x08)} (open − 0x08) carrying the same tag ${_hx(tag)} '
          '— structural (corpus: 99.99% lead, 99.8% tag).');
    }
    // No type tag at +3 → this is not a group open; fall through to generic classification.
  }
  if (lead == 0x08 || lead == 0x09 || lead == 0x0a || lead == 0x0b) {
    final tag = o + 1 < b.length ? b[o + 1] : -1;
    return make(_cGroup, 'Group close · tag ${_hx(tag)}',
        'Closes the group whose open lead is ${_hx(lead + 0x08)} (open − 0x08) and which carries '
        'the same tag ${_hx(tag)}. The pairing is structural (corpus: 99.99% lead, 99.8% tag); '
        'otherwise the innermost open is popped positionally (~0.07% of closes have no tracked open).');
  }
  // Typed object reference: 14 <subop> 01 fd <oid> (the heap's object graph).
  final ref = decodeHeapRef(b, o);
  if (ref != null) {
    final conf = ref.kind.confidence == AttrConfidence.confirmed ? '' : ' (${ref.kind.confidence.name})';
    return make(_cRef, '${ref.kind.refName} → #${ref.targetOid}',
        'A typed object reference (${ref.kind.refName}$conf) — a link in the object graph, not a wire.');
  }
  // C4 length-prefixed record
  if (lead == kHeapRecordPrefix) {
    final rec = c4FrameAt(b, o, tag);
    if (rec != null) {
      final op = rec.opcode;
      final opc = rec.kind;
      final hexop = 'C4 ${op.toRadixString(16).padLeft(2, '0')}';
      final r = rec.rect; // any rectangle-shape opcode (0x2d/0x1f/0x4a/0x5f/…), not just bounds/size
      if (r != null) {
        return make(_cRect, '$hexop · ${opc.name}',
            'Rectangle (4× s16): top ${r.top}, left ${r.left}, bottom ${r.bottom}, right ${r.right}  (${r.width}×${r.height}).',
            display: _RectPreview(r));
      }
      final text = rec.text ?? rec.descriptionText ?? rec.path;
      if (text != null && text.isNotEmpty) {
        return make(_cString, '$hexop · ${opc.name}', 'String payload:', display: _StringPreview(text));
      }
      final c = opc == HeapOpcode.container24 || opc == HeapOpcode.container44 || opc == HeapOpcode.container64;
      return make(c ? _cContainer : _cOther, '$hexop · ${opc == HeapOpcode.unknown ? 'record' : opc.name}',
          opc.isDecoded ? 'A decoded ${opc.name} record.' : 'A framed ${opc.name} record (${rec.payload.length}-byte payload).');
    }
  }
  // Attribute records (nibble family / 84 colour / C5 f64 / C6 blob)
  final attr = decodeHeapAttr(b, o);
  if (attr != null) {
    final a = attr.attribute;
    final name = a == HeapAttribute.unknown ? 'attribute 0x${attr.id.toRadixString(16)}' : a.attrName;
    final hexlead = lead.toRadixString(16).padLeft(2, '0');
    switch (attr.kind) {
      case HeapAttrKind.color:
        final rgb = attr.rgb ?? 0;
        final swatch = attr.isTransparent ? null : Color(0xFF000000 | rgb);
        return make(_cAttr, '$hexlead · $name',
            attr.isTransparent ? 'Colour: transparent.' : 'Colour #${rgb.toRadixString(16).padLeft(6, '0')}.',
            swatch: swatch, display: swatch == null ? null : _ColorPreview(swatch, rgb));
      case HeapAttrKind.controlParam:
        return make(_cAttr, '$hexlead · $name', 'Numeric-control parameter (f64) = ${attr.asDouble}.');
      case HeapAttrKind.stringBlob:
        return make(_cString, '$hexlead · $name', 'String/blob:', display: _StringPreview(attr.asString ?? ''));
      case HeapAttrKind.rectangle:
        final r = attr.asRect;
        return r == null
            ? make(_cAttr, '$hexlead · $name', 'Rectangle (4× s16).')
            : make(_cRect, '$hexlead · $name',
                'Rectangle (4× s16): top ${r.top}, left ${r.left}, bottom ${r.bottom}, right ${r.right}  (${r.width}×${r.height}).',
                display: _RectPreview(r));
      case HeapAttrKind.container:
        return make(_cContainer, '$hexlead · $name',
            'An opaque length-prefixed container (count-like lead byte ${attr.asInt}; e.g. a front-panel attribute blob).');
      default:
        return make(_cAttr, '$hexlead · $name',
            '${_kindLabel(attr.kind)} = ${attr.asInt} (${attr.width.name}).');
    }
  }
  if (isTypeDescriptorToken(lead)) {
    return make(_cOther, '04 ${b[o + 1].toRadixString(16).padLeft(2, '0')} · 04-token',
        'A bare 04 <subop> token (framed; role undecoded).');
  }
  return make(_cOther, 'lead 0x${lead.toRadixString(16)}', 'Framed record ($len bytes); role not individually decoded.');
}

String _kindLabel(HeapAttrKind k) => switch (k) {
      HeapAttrKind.coordinate => 'Coordinate',
      HeapAttrKind.size => 'Size',
      HeapAttrKind.enumValue => 'Enum value',
      HeapAttrKind.flag => 'Flag',
      HeapAttrKind.ordinal => 'Index',
      HeapAttrKind.numeric => 'Numeric',
      HeapAttrKind.text => 'Text attribute',
      _ => 'Value',
    };

class _RectPreview extends StatelessWidget {
  const _RectPreview(this.r);
  final HeapRect r;
  @override
  Widget build(BuildContext context) {
    final w = r.width.abs().clamp(1, 200).toDouble();
    final h = r.height.abs().clamp(1, 80).toDouble();
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(border: Border.all(color: _cRect), color: _cRect.withValues(alpha: 0.15)),
      alignment: Alignment.center,
      child: Text('${r.width}×${r.height}', style: const TextStyle(fontSize: 10, color: Colors.white70)),
    );
  }
}

class _ColorPreview extends StatelessWidget {
  const _ColorPreview(this.color, this.rgb);
  final Color color;
  final int rgb;
  @override
  Widget build(BuildContext context) => Row(children: [
        Container(width: 40, height: 24, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3), border: Border.all(color: Colors.black26))),
        const SizedBox(width: 8),
        Text('#${rgb.toRadixString(16).padLeft(6, '0')}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      ]);
}

/// A typed whole-section display for the VI icon. The recognizable icon is a
/// plain 24-bit RGB bitmap embedded (uncompressed) in a LabVIEW "picture" stream
/// — it can appear under several tags (`PICC`/`DSIM`/`FPHb`/…), *not* the
/// `ICON`/`icl4`/`icl8` resource blocks (those hold unrelated metadata). So this
/// keys on the bitmap signature in the bytes, not the tag. Returns null when the
/// section carries no embedded RGB bitmap.
Widget? iconPreview(Uint8List bytes) {
  final icon = extractRgbIcon(bytes);
  if (icon == null) return null;
  return _IconView(
    caption: '${icon.width}×${icon.height} · embedded 24-bit RGB picture',
    child: ViIconImage(icon: icon),
  );
}

/// Renders a decoded [ViIcon] (24-bit RGB bitmap) at [size]×[size], nearest-
/// neighbour scaled so the small icon stays crisp.
class ViIconImage extends StatelessWidget {
  const ViIconImage({super.key, required this.icon, this.size = 160});
  final ViIcon icon;
  final double size;
  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: CustomPaint(painter: _RgbIconPainter(icon)));
}

class _IconView extends StatelessWidget {
  const _IconView({required this.caption, required this.child});
  final String caption;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(border: Border.all(color: const Color(0x33FFFFFF))),
            child: child,
          ),
          const SizedBox(height: 8),
          Text(caption, style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      );
}

class _RgbIconPainter extends CustomPainter {
  _RgbIconPainter(this.icon);
  final ViIcon icon;
  @override
  void paint(Canvas canvas, Size size) {
    final pw = size.width / icon.width, ph = size.height / icon.height;
    final p = Paint();
    var k = 0;
    for (var y = 0; y < icon.height; y++) {
      for (var x = 0; x < icon.width; x++) {
        p.color = Color.fromARGB(255, icon.rgb[k], icon.rgb[k + 1], icon.rgb[k + 2]);
        k += 3;
        canvas.drawRect(Rect.fromLTWH(x * pw, y * ph, pw + 0.5, ph + 0.5), p);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RgbIconPainter oldDelegate) => false;
}

class _StringPreview extends StatelessWidget {
  const _StringPreview(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(4)),
        child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5)),
      );
}

/// Paints a 32×32 [ViLegacyIcon] scaled to fill the given size. 1-bit pixels are
/// drawn black/white (mask); 4/8-bit pixels are shaded by their palette index
/// (grayscale) — an honest stand-in, since the true LabVIEW palette is not mapped.
class _LegacyIconPainter extends CustomPainter {
  _LegacyIconPainter(this.icon);
  final ViLegacyIcon icon;

  @override
  void paint(Canvas canvas, Size size) {
    const dim = 32;
    final cw = size.width / dim;
    final ch = size.height / dim;
    final maxIdx = (1 << icon.bpp) - 1; // 1, 15, or 255
    final p = Paint();
    for (var y = 0; y < dim; y++) {
      for (var x = 0; x < dim; x++) {
        final v = icon.pixels[y * dim + x];
        if (icon.bpp == 1) {
          p.color = v == 0 ? Colors.white : Colors.black;
        } else {
          final g = maxIdx == 0 ? 0 : (255 * v ~/ maxIdx).clamp(0, 255);
          p.color = Color.fromARGB(255, g, g, g);
        }
        canvas.drawRect(Rect.fromLTWH(x * cw, y * ch, cw + 0.5, ch + 0.5), p);
      }
    }
    // a faint border so a mostly-white icon is still visible
    canvas.drawRect(Offset.zero & size, Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0xFF888888));
  }

  @override
  bool shouldRepaint(_LegacyIconPainter old) => !identical(old.icon, icon);
}
