part of 'diagram_view.dart';

const _kWhileCornerTL = [
  '.....#',
  '..####',
  '.#####',
  '.#####',
  '.#####',
  '######',
];

const _kWhileCornerTR = [
  '....##',
  '...###',
  '.#####',
  '.#####',
  '.#####',
  '######',
];

const _kWhileCornerBL = [
  '.....#',
  '..####',
  '..####',
  '.#####',
  '######',
  '######',
];

const _kWhileArrow = [
  '.........',
  '.........',
  '.########',
  '..#######',
  '#########',
  '#########',
  '#########',
  '#########',
  '#########',
  '#####...#',
];

const _kWhileBand = 6;

const _kCaseInsensitiveGlyph = [
  '.####.............',
  '##..##............',
  '##..##.......###..',
  '######.####....##.',
  '##..##.......####.',
  '##..##.####.##.##.',
  '##..##.......#####',
];

const _kForLoopFold = 8.0;

const _loopBlue = Color(0xFF0033CC);

/// Border terminal bitmaps (`termBmp`) that structures draw on their frames.
enum BdStructureTerminal {
  iteration(1),
  count(2),
  leftShiftRegister(3),
  rightShiftRegister(4),
  caseSelector(5),
  conditional(192);

  const BdStructureTerminal(this.bmp);

  final int bmp;

  static BdStructureTerminal? fromBmp(int bmp) {
    for (final terminal in values) {
      if (terminal.bmp == bmp) return terminal;
    }
    return null;
  }
}

const _forLoopNGlyph = (
  origin: (4, 3),
  rows: [
    '#.....#',
    '##....#',
    '###...#',
    '####..#',
    '#.###.#',
    '#..####',
    '#...###',
    '#....##',
    '#.....#',
  ],
);

const _forLoopIGlyph = (
  origin: (7, 4),
  rows: ['##', '..', '##', '##', '##', '##', '##', '##', '##'],
);

const _stopTerminal = [
  'GGGGGGGGGGGGGGGG',
  'GccccccccccccccG',
  'GccccXXXXXXccccG',
  'GcccXccccccXcccG',
  'GccXccRRRRccXccG',
  'GcXccRRRRRRccXcG',
  'GcXcRRRRRRRRcXcG',
  'GcXcRRRRRRRRcXcG',
  'GcXcRRRRRRRRcXcG',
  'GcXcRRRRRRRRcXcG',
  'GcXccRRRRRRccXcG',
  'GccXccRRRRccXccG',
  'GcccXccccccXcccG',
  'GccccXXXXXXccccG',
  'GccccccccccccccG',
  'GGGGGGGGGGGGGGGG',
];

const _selectorLeftPager = [
  '.....#',
  '...###',
  '.#####',
  '######',
  '.#####',
  '...###',
  '.....#',
];

const _selectorRightPager = [
  '#.....',
  '###...',
  '#####.',
  '######',
  '#####.',
  '###...',
  '#.....',
];

const _selectorDropdown = ['#######', '.#####.', '..###..', '...#...'];

extension _StructurePass on BdDiagramPainter {
  void _paintStructures(
    Canvas canvas,
    List<ViHeapObject> structures, {
    required Set<int> arrayShellOids,
    required Set<Rect> chromeOwnedRects,
  }) {
    for (final object in structures) {
      if (object.objectClass == HeapObjectClass.loop) {
        final rect = _rectOf(object);
        if (rect.width <= 40 && rect.height <= 24) {
          _drawSmallClusterBox(canvas, object, rect);
          continue;
        }
      }
      final rect = _rectOf(object);
      final structDisabled = disabledOids.contains(object.oid);
      final structColor = switch (object.structRgb == kDefaultStructureRgb
          ? null
          : bdDecodedColor(object.structRgb)) {
        null => null,
        final c => _dimFor(object.oid, c),
      };
      final terminals =
          structureTerminals[object.oid] ?? const <({HeapRect box, int bmp})>[];
      if (object.objectClass == HeapObjectClass.caseOrSequence &&
          arrayShellOids.contains(object.oid)) {
        _drawArrayConstantShell(canvas, object);
        continue;
      }
      switch (object.objectClass) {
        case HeapObjectClass.bdForLoop:
          _drawForLoopBorder(canvas, rect, disabled: structDisabled);
        case HeapObjectClass.bdWhileLoop:
          _drawWhileLoopBand(
            canvas,
            rect,
            structColor,
            disabled: structDisabled,
          );
        case HeapObjectClass.bdStructureFrame:
          _drawStructureHatchBorder(
            canvas,
            rect,
            object.absBounds!.left,
            object.absBounds!.top,
            disabled: structDisabled,
            error: errorCaseOids.contains(object.oid),
          );
          if (((object.objFlags ?? 0) & 0x1000000) != 0) {
            _drawCaseInsensitiveBadge(
              canvas,
              rect,
              disabled: structDisabled,
              oid: object.oid,
            );
          }
        case HeapObjectClass.bdFlatSequence:
          _drawFlatSequenceBorder(canvas, rect, object);
        case HeapObjectClass.bdSequenceFrame:
          break;
        case HeapObjectClass.bdDisableStructure:
          final showsDisabled = scene.diagram
              .children(object.oid)
              .any(
                (k) =>
                    k.objectClass == HeapObjectClass.bdSelectorLabel &&
                    k.label?.trim().toLowerCase() == 'disabled',
              );
          if (showsDisabled) {
            final grey = _solidNoAa(
              _dimFor(object.oid, const Color(0xFF999999)),
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.left, rect.top, rect.width, 1),
              grey,
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.left, rect.bottom - 1, rect.width, 1),
              grey,
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.left, rect.top, 1, rect.height),
              grey,
            );
            canvas.drawRect(
              Rect.fromLTWH(rect.right - 1, rect.top, 1, rect.height),
              grey,
            );
          } else {
            final black = _solidNoAa(_dimFor(object.oid, Colors.black));
            final hatchPts = <double>[];
            void hatchCell(double x, double y) {
              final rx = (x - rect.left).round() & 3;
              final ry = ((y - rect.top).round() + 1) & 3;
              if (kBdStructureHatch[ry][rx] == '#') {
                hatchPts
                  ..add(x + 0.5)
                  ..add(y + 0.5);
              }
            }

            for (var y = rect.top; y < rect.bottom; y++) {
              for (var k = 0; k < 3; k++) {
                hatchCell(rect.left + k, y);
                hatchCell(rect.right - 3 + k, y);
              }
            }
            for (var y = rect.bottom - 3; y < rect.bottom; y++) {
              for (var x = rect.left + 3; x < rect.right - 3; x++) {
                hatchCell(x, y);
              }
            }
            _drawCellPoints(
              canvas,
              hatchPts,
              _dimFor(object.oid, const Color(0xFF777777)),
            );
            canvas.drawRect(
              Rect.fromLTRB(
                rect.left + 3,
                rect.top,
                rect.right - 3,
                rect.top + 1,
              ),
              black,
            );
          }
        default:
          final frame =
              structColor ??
              _dimFor(object.oid, _kindColor(ViObjectKind.structure));
          if (structColor != null) {
            canvas.drawRect(
              rect,
              Paint()..color = structColor.withValues(alpha: 0.12),
            );
          }
          canvas.drawRect(
            rect,
            Paint()
              ..color = frame
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0,
          );
          canvas.drawRect(
            rect.deflate(3),
            Paint()
              ..color = frame.withValues(alpha: 0.55)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.0,
          );
          continue;
      }
      _drawStructureTerminals(
        canvas,
        rect,
        terminals,
        chromeOwnedRects: chromeOwnedRects,
        disabled: structDisabled,
      );
    }
  }

  void _paintCaseSelectorStrips(Canvas canvas, List<ViHeapObject> solids) {
    for (final object in solids) {
      if (object.objectClass == HeapObjectClass.bdSelectorLabel)
        _drawCaseSelector(canvas, _rectOf(object));
    }
  }

  void _paintBorderChrome(
    Canvas canvas,
    List<
      (Rect, ({int kind, bool hollow, bool centreDot, bool disabled}), Color)
    >
    tunnelSquares,
  ) {
    tunnelSquares.sort(
      (a, b) => _chromeZOrder(a.$2.kind).compareTo(_chromeZOrder(b.$2.kind)),
    );
    for (final (rect, info, color) in tunnelSquares) {
      _drawBorderTerminalChrome(canvas, rect, info, color);
    }
  }

  void _drawFlatSequenceBorder(Canvas canvas, Rect rect, ViHeapObject seq) {
    final black = _dimFor(seq.oid, Colors.black);
    final grey = _dimFor(seq.oid, const Color(0xFFDDDDDD));
    final blackFill = _solidNoAa(black);
    final greyFill = _solidNoAa(grey);
    final whiteFill = _solidNoAa(Colors.white);
    void px(Paint paint, double x, double y, [double w = 1, double h = 1]) {
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    }

    final l = rect.left, t = rect.top, r = rect.right, b = rect.bottom;
    final w = rect.width;
    for (final top in [true, false]) {
      final y0 = top ? t : b - 10;
      final rows = top
          ? [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
          : [9, 8, 7, 6, 5, 4, 3, 2, 1, 0];
      px(blackFill, l, y0 + rows[0], w);
      px(greyFill, l, y0 + rows[1], w);
      px(greyFill, l, y0 + rows[8], w);
      px(blackFill, l, y0 + rows[9], w);
      for (final holeRow in [rows[2], rows[7]]) {
        px(greyFill, l, y0 + holeRow, w);
      }
      for (final sideRow in [rows[3], rows[4], rows[5], rows[6]]) {
        px(greyFill, l, y0 + sideRow, w);
      }
      for (var hx = 9.0; hx + 6 <= w; hx += 12) {
        for (final holeRow in [rows[2], rows[7]]) {
          px(blackFill, l + hx, y0 + holeRow, 6);
        }
        for (final sideRow in [rows[3], rows[4], rows[5], rows[6]]) {
          px(blackFill, l + hx, y0 + sideRow);
          px(whiteFill, l + hx + 1, y0 + sideRow, 4);
          px(blackFill, l + hx + 5, y0 + sideRow);
        }
      }
    }
    final innerTop = t + 10, innerBottom = b - 10;
    final sideH = innerBottom - innerTop;
    if (sideH > 0) {
      px(greyFill, l + 2, t + 1, 3, b - t - 2);
      px(blackFill, l + 5, innerTop, 1, sideH);
      px(blackFill, r - 6, innerTop, 1, sideH);
      px(greyFill, r - 5, t + 1, 3, b - t - 2);
      for (var y = t + 1; y < b - 1; y++) {
        final greyFirst = (((y + origin.dy).round() + 1) ~/ 2).isOdd;
        px(greyFirst ? greyFill : blackFill, l, y.toDouble());
        px(greyFirst ? blackFill : greyFill, l + 1, y.toDouble());
        px(greyFirst ? blackFill : greyFill, r - 2, y.toDouble());
        px(greyFirst ? greyFill : blackFill, r - 1, y.toDouble());
      }
      for (final top in [true, false]) {
        final holeTop = top ? t + 3 : b - 7;
        final capTop = top ? t + 2 : b - 8;
        px(whiteFill, l + 1, holeTop, 1, 4);
        px(blackFill, l + 2, capTop, 1, 6);
        px(blackFill, l + 1, capTop, 2);
        px(blackFill, l + 1, capTop + 5, 2);
        px(whiteFill, r - 4, holeTop, 3, 4);
        px(blackFill, r - 5, capTop, 1, 6);
        px(blackFill, r - 5, capTop, 4);
        px(blackFill, r - 5, capTop + 5, 4);
      }
      var cum = 0.0;
      final frames = scene.diagram
          .children(seq.oid)
          .where(
            (c) =>
                c.objectClass == HeapObjectClass.bdSequenceFrame &&
                c.absBounds != null,
          )
          .toList();
      for (var i = 0; i + 1 < frames.length; i++) {
        cum += frames[i].absBounds!.right - frames[i].absBounds!.left;
        px(blackFill, l + cum - 6, innerTop, 1, sideH);
        px(greyFill, l + cum - 5, innerTop - 1, 5, sideH + 2);
        px(blackFill, l + cum, innerTop, 1, sideH);
      }
    }
  }

  void _drawBorderTerminalChrome(
    Canvas canvas,
    Rect t,
    ({int kind, bool hollow, bool centreDot, bool disabled}) info,
    Color wireColor,
  ) {
    final kind = info.kind;
    final ringColor = info.disabled ? kBdDisabledChromeGrey : kBdTunnelBorder;
    final creamColor = info.disabled
        ? bdDimDisabled(kBdTerminalFill)
        : kBdTerminalFill;
    final noAa = _solidNoAa(wireColor);
    switch (kind) {
      case 0x22 || 0x2d || 0x2a || 0xcb || 0xce:
        if (info.hollow) {
          canvas.drawRect(t, _solidNoAa(creamColor));
          if (t.width == 9 && t.height == 9) {
            const ring = ['xx.xx', 'x...x', 'x...x', 'x...x', 'xx.xx'];
            _stampBitmap(canvas, noAa, ring, t.left + 2, t.top + 2, on: 'x');
          }
        } else {
          canvas.drawRect(t, noAa);
          if (info.centreDot && t.width >= 7 && t.height >= 7) {
            final cx = t.left + (t.width - 3) / 2;
            final cy = t.top + (t.height - 3) / 2;
            canvas.drawRect(
              Rect.fromLTWH(cx, cy, 3, 3),
              _solidNoAa(Colors.white),
            );
            canvas.drawRect(Rect.fromLTWH(cx + 1, cy + 1, 1, 1), noAa);
          }
        }
        canvas.drawRect(
          Rect.fromLTRB(
            t.left + 0.5,
            t.top + 0.5,
            t.right - 0.5,
            t.bottom - 0.5,
          ),
          Paint()
            ..color = ringColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..isAntiAlias = false,
        );
      case 0x27 || 0x28:
        canvas.drawRect(t, noAa);
        canvas.drawRect(t.deflate(2), _solidNoAa(creamColor));
        if (t.width == 16 && t.height == 12) {
          final down = kind == 0x27;
          for (var i = 0; i < 5; i++) {
            final width = down ? 10 - 2 * i : 2 + 2 * i;
            final row = (down ? 2 + i : 1 + i).toDouble();
            canvas.drawRect(
              Rect.fromLTWH(
                t.left + 2 + (12 - width) / 2,
                t.top + 2 + row,
                width.toDouble(),
                1,
              ),
              noAa,
            );
          }
        }
      case 0x2e:
        canvas.drawRect(t, noAa);
        canvas.drawRect(t.deflate(1), _solidNoAa(creamColor));
        if (t.width == 8 && t.height == 12) {
          const glyph = [
            '......',
            '..xx..',
            '.x..x.',
            '....x.',
            '...x..',
            '..x...',
            '..x...',
            '......',
            '..x...',
            '......',
          ];
          _stampBitmap(canvas, noAa, glyph, t.left + 1, t.top + 1, on: 'x');
        }
    }
  }

  void _drawWhileLoopBand(
    Canvas canvas,
    Rect rect,
    Color? tint, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    final grey = tint ?? dim(style.whileBandGrey);
    final l = rect.left.round(), t = rect.top.round();
    final r = rect.right.round(), b = rect.bottom.round();
    const band = _kWhileBand;
    final aw = _kWhileArrow.first.length, ah = _kWhileArrow.length;
    final ax0 = r - aw, ay0 = b - ah;

    final pts = <double>[];
    void add(int x, int y) => pts
      ..add(x + 0.5)
      ..add(y + 0.5);

    void cell(int x, int y) {
      final dt = y - t, db = b - 1 - y;
      final dl = x - l, dr = r - 1 - x;
      if (x >= ax0 && y >= ay0) return;
      bool grey1;
      if (dt < band && dl < band) {
        grey1 = _kWhileCornerTL[dt][dl] == '#';
      } else if (dt < band && dr < band) {
        grey1 = _kWhileCornerTR[dt][dr] == '#';
      } else if (db < band && dl < band) {
        grey1 = _kWhileCornerBL[db][dl] == '#';
      } else {
        grey1 = true;
      }
      if (grey1) add(x, y);
    }

    final bandBottom = math.max(b - band, t + band);
    for (var y = t; y < math.min(t + band, b); y++) {
      for (var x = l; x < r; x++) {
        cell(x, y);
      }
    }
    for (var y = bandBottom; y < b; y++) {
      for (var x = l; x < r; x++) {
        cell(x, y);
      }
    }
    for (var y = t + band; y < bandBottom; y++) {
      for (var x = l; x < math.min(l + band, r); x++) {
        cell(x, y);
      }
      for (var x = math.max(r - band, l + band); x < r; x++) {
        cell(x, y);
      }
    }
    for (var ry = 0; ry < ah; ry++) {
      for (var rx = 0; rx < aw; rx++) {
        if (_kWhileArrow[ry][rx] == '#') add(ax0 + rx, ay0 + ry);
      }
    }
    _drawCellPoints(canvas, pts, grey);
  }

  void _drawForLoopBorder(Canvas canvas, Rect rect, {bool disabled = false}) {
    final ink = disabled
        ? bdDimDisabled(const Color(0xFF000000))
        : const Color(0xFF000000);
    final paint = _solidNoAa(ink);
    final l = rect.left.roundToDouble();
    final t = rect.top.roundToDouble();
    final r = rect.right.roundToDouble();
    final b = rect.bottom.roundToDouble();
    void px(double x, double y) =>
        canvas.drawRect(Rect.fromLTRB(x, y, x + 1, y + 1), paint);
    void hline(double x0, double x1, double y) =>
        canvas.drawRect(Rect.fromLTRB(x0, y, x1 + 1, y + 1), paint);
    void vline(double x, double y0, double y1) =>
        canvas.drawRect(Rect.fromLTRB(x, y0, x + 1, y1 + 1), paint);

    const fold = _kForLoopFold;
    final backRight = r - 5, backBottom = b - 5;
    hline(l, backRight, t);
    vline(l, t, backBottom);
    vline(backRight, t, backBottom - fold);
    hline(l, backRight - fold, backBottom);
    hline(backRight - fold, backRight, backBottom - fold);
    vline(backRight - fold, backBottom - fold, backBottom);
    for (var i = 1; i < fold; i++) {
      px(backRight - i, backBottom - fold + i);
    }
    for (final o in const [2.0, 4.0]) {
      hline(l + o, backRight + o, backBottom + o);
      vline(backRight + o, t + o, backBottom + o);
      hline(backRight + o - 2, backRight + o, t + o);
      px(l + o, backBottom + o - 1);
    }
  }

  void _drawStructureHatchBorder(
    Canvas canvas,
    Rect rect,
    int absLeft,
    int absTop, {
    bool disabled = false,
    bool error = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    final paint = _solidNoAa(dim(const Color(0xFF000000)));
    final l = rect.left.round(), t = rect.top.round();
    final w = rect.width.round(), h = rect.height.round();
    if (w < 2 || h < 2) return;
    canvas.drawRect(
      Rect.fromLTWH(l.toDouble(), t.toDouble(), w.toDouble(), 1),
      paint,
    );
    canvas.drawRect(
      Rect.fromLTWH(l.toDouble(), (t + h - 1).toDouble(), w.toDouble(), 1),
      paint,
    );
    canvas.drawRect(
      Rect.fromLTWH(l.toDouble(), t.toDouble(), 1, h.toDouble()),
      paint,
    );
    canvas.drawRect(
      Rect.fromLTWH((l + w - 1).toDouble(), t.toDouble(), 1, h.toDouble()),
      paint,
    );
    final tile = error ? kBdErrorHatch : kBdStructureHatch;
    final offset = error ? style.errorHatchOffset : style.hatchOffset;
    final band = <double>[];
    final field = error ? <double>[] : null;
    void cell(int i, int j) {
      final d = math.min(math.min(i, j), math.min(w - 1 - i, h - 1 - j));
      if (d < 1 || d > kBdHatchBand) return;
      if (tile[(absTop + j + offset.y) & 3][(absLeft + i + offset.x) & 3] ==
          '#') {
        band
          ..add(l + i + 0.5)
          ..add(t + j + 0.5);
      } else {
        field
          ?..add(l + i + 0.5)
          ..add(t + j + 0.5);
      }
    }

    final sideTop = math.min(kBdHatchBand + 1, h);
    final sideBottom = math.max(h - 1 - kBdHatchBand, sideTop);
    for (var j = 0; j < sideTop; j++) {
      for (var i = 0; i < w; i++) {
        cell(i, j);
      }
    }
    for (var j = sideBottom; j < h; j++) {
      for (var i = 0; i < w; i++) {
        cell(i, j);
      }
    }
    for (var j = sideTop; j < sideBottom; j++) {
      for (var i = 0; i < math.min(kBdHatchBand + 1, w); i++) {
        cell(i, j);
      }
      for (
        var i = math.max(w - 1 - kBdHatchBand, kBdHatchBand + 1);
        i < w;
        i++
      ) {
        cell(i, j);
      }
    }
    if (field != null) {
      _drawCellPoints(canvas, field, dim(style.errorCaseGreen));
    }
    _drawCellPoints(
      canvas,
      band,
      error ? dim(style.whileBandGrey) : dim(const Color(0xFF000000)),
    );
  }

  void _drawCaseInsensitiveBadge(
    Canvas canvas,
    Rect rect, {
    required bool disabled,
    required int oid,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : _dimFor(oid, c);
    canvas.drawRect(
      Rect.fromLTWH(rect.left + 1, rect.bottom - 10, 21, 9),
      _solidNoAa(dim(Colors.white)),
    );
    _stampBitmap(
      canvas,
      _solidNoAa(dim(const Color(0xFFFF00FF))),
      _kCaseInsensitiveGlyph,
      rect.left + 2,
      rect.bottom - 9,
    );
  }

  void _drawConditionalTerminal(
    Canvas canvas,
    Rect box, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    final inks = {
      'G': _solidNoAa(dim(style.booleanGreen)),
      'c': _solidNoAa(dim(kBdTerminalFill)),
      'X': _solidNoAa(dim(const Color(0xFF000000))),
      'R': _solidNoAa(dim(const Color(0xFFFF0000))),
    };
    for (final e in inks.entries) {
      _stampBitmap(
        canvas,
        e.value,
        _stopTerminal,
        box.left,
        box.top,
        on: e.key,
      );
    }
  }

  void _drawTerminalArt(
    Canvas canvas,
    Rect box,
    BdTerminalArt art, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    canvas.drawRect(box, _solidNoAa(dim(Colors.white)));
    final inks = {
      'B': _solidNoAa(dim(art.base)),
      'M': _solidNoAa(dim(art.mid)),
      'L': _solidNoAa(dim(art.light)),
      'X': _solidNoAa(dim(const Color(0xFF000000))),
    };
    for (final e in inks.entries) {
      _stampBitmap(canvas, e.value, art.rows, box.left, box.top, on: e.key);
    }
  }

  void _drawLoopGlyphTerminal(
    Canvas canvas,
    Rect box,
    ({(int, int) origin, List<String> rows}) glyph, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    final ink = _solidNoAa(dim(const Color(0xFF0000FF)));
    final l = box.left.roundToDouble(), t = box.top.roundToDouble();
    canvas.drawRect(box, _solidNoAa(dim(kBdTerminalFill)));
    canvas.drawRect(Rect.fromLTWH(l, t, 16, 2), ink);
    canvas.drawRect(Rect.fromLTWH(l, t + 14, 16, 2), ink);
    canvas.drawRect(Rect.fromLTWH(l, t, 2, 16), ink);
    canvas.drawRect(Rect.fromLTWH(l + 14, t, 2, 16), ink);
    final (ox, oy) = glyph.origin;
    _stampBitmap(canvas, ink, glyph.rows, l + ox, t + oy);
  }

  void _drawStructureTerminals(
    Canvas canvas,
    Rect frame,
    List<({HeapRect box, int bmp})> terminals, {
    Set<Rect> chromeOwnedRects = const {},
    bool disabled = false,
  }) {
    Color dim(Color color) => disabled ? bdDimDisabled(color) : color;
    for (final terminal in terminals) {
      final box = Rect.fromLTWH(
        frame.left + terminal.box.left,
        frame.top + terminal.box.top,
        terminal.box.width.toDouble(),
        terminal.box.height.toDouble(),
      );
      if (chromeOwnedRects.contains(box)) continue;
      final kind = BdStructureTerminal.fromBmp(terminal.bmp);
      final glyphSized = box.width == 16 && box.height == 16;
      if (glyphSized &&
          (kind == BdStructureTerminal.count ||
              kind == BdStructureTerminal.iteration)) {
        _drawLoopGlyphTerminal(
          canvas,
          box,
          kind == BdStructureTerminal.count ? _forLoopNGlyph : _forLoopIGlyph,
          disabled: disabled,
        );
        continue;
      }
      if (glyphSized && kind == BdStructureTerminal.conditional) {
        _drawConditionalTerminal(canvas, box, disabled: disabled);
        continue;
      }
      final border = kind == BdStructureTerminal.conditional
          ? dim(const Color(0xFF007F00))
          : dim(_loopBlue);
      canvas.drawRect(box, Paint()..color = Colors.white);
      canvas.drawRect(
        box,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
      final centre = box.center;
      switch (kind) {
        case BdStructureTerminal.iteration:
          _drawGlyphText(canvas, box, 'i', dim(_loopBlue));
        case BdStructureTerminal.count:
          _drawGlyphText(canvas, box, 'N', dim(_loopBlue));
        case BdStructureTerminal.caseSelector:
          _drawGlyphText(canvas, box, '?', border);
        case BdStructureTerminal.leftShiftRegister ||
            BdStructureTerminal.rightShiftRegister:
          final pointsDown = kind == BdStructureTerminal.leftShiftRegister;
          final baseY = pointsDown ? centre.dy - 3 : centre.dy + 3;
          final tipY = pointsDown ? centre.dy + 4 : centre.dy - 4;
          final triangle = Path()
            ..moveTo(centre.dx - 4, baseY)
            ..lineTo(centre.dx + 4, baseY)
            ..lineTo(centre.dx, tipY)
            ..close();
          canvas.drawPath(
            triangle,
            Paint()..color = dim(Colors.black).withValues(alpha: 0.87),
          );
        case BdStructureTerminal.conditional:
          const radius = 5.0;
          final octagon = Path();
          for (var vertex = 0; vertex < 8; vertex++) {
            final angle = (vertex * 45 + 22.5) * math.pi / 180;
            final point = Offset(
              centre.dx + radius * math.cos(angle),
              centre.dy + radius * math.sin(angle),
            );
            if (vertex == 0) {
              octagon.moveTo(point.dx, point.dy);
            } else {
              octagon.lineTo(point.dx, point.dy);
            }
          }
          octagon.close();
          canvas.drawPath(
            octagon,
            Paint()..color = dim(const Color(0xFFCC0000)),
          );
        case null:
          break;
      }
    }
  }

  void _drawCaseSelector(Canvas canvas, Rect rect) {
    final ink = _solidNoAa(Colors.black);
    final l = rect.left.roundToDouble(), t = rect.top.roundToDouble();
    final r = rect.right.roundToDouble();
    final bottom = t + 16;
    final left = l - 8, right = r + 18;
    void hline(double x0, double x1, double y) =>
        canvas.drawRect(Rect.fromLTRB(x0, y, x1 + 1, y + 1), ink);
    void vline(double x, double y0, double y1) =>
        canvas.drawRect(Rect.fromLTRB(x, y0, x + 1, y1 + 1), ink);
    canvas.drawRect(
      Rect.fromLTRB(left, t, right + 1, bottom + 1),
      _solidNoAa(Colors.white),
    );
    hline(left, right, t);
    hline(left, right, bottom);
    vline(left, t, bottom);
    vline(l, t, bottom);
    vline(r + 10, t, bottom);
    vline(right, t, bottom);
    _stampBitmap(canvas, ink, _selectorLeftPager, l - 7, t + 5);
    _stampBitmap(canvas, ink, _selectorDropdown, r + 1, t + 6);
    _stampBitmap(canvas, ink, _selectorRightPager, r + 11, t + 5);
  }
}
