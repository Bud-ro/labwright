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
        final color => _dimFor(object.oid, color),
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
          _drawDisableStructureFrame(canvas, rect, object);
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

  void _drawDisableStructureFrame(
    Canvas canvas,
    Rect rect,
    ViHeapObject structure,
  ) {
    final showsDisabled = scene.diagram
        .children(structure.oid)
        .any(
          (child) =>
              child.objectClass == HeapObjectClass.bdSelectorLabel &&
              child.label?.trim().toLowerCase() == 'disabled',
        );
    if (showsDisabled) {
      final grey = _solidNoAa(_dimFor(structure.oid, const Color(0xFF999999)));
      _strokePixelFrame(canvas, rect, grey);
    } else {
      final black = _solidNoAa(_dimFor(structure.oid, Colors.black));
      final hatchCells = <double>[];
      void hatchCell(double column, double row) {
        final tileColumn = (column - rect.left).round() & 3;
        final tileRow = ((row - rect.top).round() + 1) & 3;
        if (kBdStructureHatch[tileRow][tileColumn] == '#') {
          hatchCells
            ..add(column + 0.5)
            ..add(row + 0.5);
        }
      }

      for (var row = rect.top; row < rect.bottom; row++) {
        for (var edgeColumn = 0; edgeColumn < 3; edgeColumn++) {
          hatchCell(rect.left + edgeColumn, row);
          hatchCell(rect.right - 3 + edgeColumn, row);
        }
      }
      for (var row = rect.bottom - 3; row < rect.bottom; row++) {
        for (var column = rect.left + 3; column < rect.right - 3; column++) {
          hatchCell(column, row);
        }
      }
      _drawCellPoints(
        canvas,
        hatchCells,
        _dimFor(structure.oid, const Color(0xFF777777)),
      );
      canvas.drawRect(
        Rect.fromLTRB(rect.left + 3, rect.top, rect.right - 3, rect.top + 1),
        black,
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
    final left = rect.left,
        top = rect.top,
        right = rect.right,
        bottom = rect.bottom;
    final width = rect.width;
    for (final atTop in [true, false]) {
      final y0 = atTop ? top : bottom - 10;
      final rows = atTop
          ? [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
          : [9, 8, 7, 6, 5, 4, 3, 2, 1, 0];
      _fillPixels(canvas, blackFill, left, y0 + rows[0], width);
      _fillPixels(canvas, greyFill, left, y0 + rows[1], width);
      _fillPixels(canvas, greyFill, left, y0 + rows[8], width);
      _fillPixels(canvas, blackFill, left, y0 + rows[9], width);
      for (final holeRow in [rows[2], rows[7]]) {
        _fillPixels(canvas, greyFill, left, y0 + holeRow, width);
      }
      for (final sideRow in [rows[3], rows[4], rows[5], rows[6]]) {
        _fillPixels(canvas, greyFill, left, y0 + sideRow, width);
      }
      for (var holeX = 9.0; holeX + 6 <= width; holeX += 12) {
        for (final holeRow in [rows[2], rows[7]]) {
          _fillPixels(canvas, blackFill, left + holeX, y0 + holeRow, 6);
        }
        for (final sideRow in [rows[3], rows[4], rows[5], rows[6]]) {
          _fillPixels(canvas, blackFill, left + holeX, y0 + sideRow);
          _fillPixels(canvas, whiteFill, left + holeX + 1, y0 + sideRow, 4);
          _fillPixels(canvas, blackFill, left + holeX + 5, y0 + sideRow);
        }
      }
    }
    final innerTop = top + 10, innerBottom = bottom - 10;
    final sideH = innerBottom - innerTop;
    if (sideH > 0) {
      _fillPixels(canvas, greyFill, left + 2, top + 1, 3, bottom - top - 2);
      _fillPixels(canvas, blackFill, left + 5, innerTop, 1, sideH);
      _fillPixels(canvas, blackFill, right - 6, innerTop, 1, sideH);
      _fillPixels(canvas, greyFill, right - 5, top + 1, 3, bottom - top - 2);
      for (var row = top + 1; row < bottom - 1; row++) {
        final greyFirst = (((row + origin.dy).round() + 1) ~/ 2).isOdd;
        _fillPixels(
          canvas,
          greyFirst ? greyFill : blackFill,
          left,
          row.toDouble(),
        );
        _fillPixels(
          canvas,
          greyFirst ? blackFill : greyFill,
          left + 1,
          row.toDouble(),
        );
        _fillPixels(
          canvas,
          greyFirst ? blackFill : greyFill,
          right - 2,
          row.toDouble(),
        );
        _fillPixels(
          canvas,
          greyFirst ? greyFill : blackFill,
          right - 1,
          row.toDouble(),
        );
      }
      for (final atTop in [true, false]) {
        final holeTop = atTop ? top + 3 : bottom - 7;
        final capTop = atTop ? top + 2 : bottom - 8;
        _fillPixels(canvas, whiteFill, left + 1, holeTop, 1, 4);
        _fillPixels(canvas, blackFill, left + 2, capTop, 1, 6);
        _fillPixels(canvas, blackFill, left + 1, capTop, 2);
        _fillPixels(canvas, blackFill, left + 1, capTop + 5, 2);
        _fillPixels(canvas, whiteFill, right - 4, holeTop, 3, 4);
        _fillPixels(canvas, blackFill, right - 5, capTop, 1, 6);
        _fillPixels(canvas, blackFill, right - 5, capTop, 4);
        _fillPixels(canvas, blackFill, right - 5, capTop + 5, 4);
      }
      var framesWidth = 0.0;
      final frames = scene.diagram
          .children(seq.oid)
          .where(
            (child) =>
                child.objectClass == HeapObjectClass.bdSequenceFrame &&
                child.absBounds != null,
          )
          .toList();
      for (var frameIndex = 0; frameIndex + 1 < frames.length; frameIndex++) {
        framesWidth +=
            frames[frameIndex].absBounds!.right -
            frames[frameIndex].absBounds!.left;
        _fillPixels(
          canvas,
          blackFill,
          left + framesWidth - 6,
          innerTop,
          1,
          sideH,
        );
        _fillPixels(
          canvas,
          greyFill,
          left + framesWidth - 5,
          innerTop - 1,
          5,
          sideH + 2,
        );
        _fillPixels(canvas, blackFill, left + framesWidth, innerTop, 1, sideH);
      }
    }
  }

  void _drawBorderTerminalChrome(
    Canvas canvas,
    Rect box,
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
          canvas.drawRect(box, _solidNoAa(creamColor));
          if (box.width == 9 && box.height == 9) {
            const ring = ['xx.xx', 'x...x', 'x...x', 'x...x', 'xx.xx'];
            _stampBitmap(
              canvas,
              noAa,
              ring,
              box.left + 2,
              box.top + 2,
              on: 'x',
            );
          }
        } else {
          canvas.drawRect(box, noAa);
          if (info.centreDot && box.width >= 7 && box.height >= 7) {
            final dotLeft = box.left + (box.width - 3) / 2;
            final dotTop = box.top + (box.height - 3) / 2;
            canvas.drawRect(
              Rect.fromLTWH(dotLeft, dotTop, 3, 3),
              _solidNoAa(Colors.white),
            );
            canvas.drawRect(Rect.fromLTWH(dotLeft + 1, dotTop + 1, 1, 1), noAa);
          }
        }
        canvas.drawRect(
          Rect.fromLTRB(
            box.left + 0.5,
            box.top + 0.5,
            box.right - 0.5,
            box.bottom - 0.5,
          ),
          Paint()
            ..color = ringColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..isAntiAlias = false,
        );
      case 0x27 || 0x28:
        canvas.drawRect(box, noAa);
        canvas.drawRect(box.deflate(2), _solidNoAa(creamColor));
        if (box.width == 16 && box.height == 12) {
          final down = kind == 0x27;
          for (var line = 0; line < 5; line++) {
            final width = down ? 10 - 2 * line : 2 + 2 * line;
            final row = (down ? 2 + line : 1 + line).toDouble();
            canvas.drawRect(
              Rect.fromLTWH(
                box.left + 2 + (12 - width) / 2,
                box.top + 2 + row,
                width.toDouble(),
                1,
              ),
              noAa,
            );
          }
        }
      case 0x2e:
        canvas.drawRect(box, noAa);
        canvas.drawRect(box.deflate(1), _solidNoAa(creamColor));
        if (box.width == 8 && box.height == 12) {
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
          _stampBitmap(canvas, noAa, glyph, box.left + 1, box.top + 1, on: 'x');
        }
    }
  }

  void _drawWhileLoopBand(
    Canvas canvas,
    Rect rect,
    Color? tint, {
    bool disabled = false,
  }) {
    Color dim(Color color) => disabled ? bdDimDisabled(color) : color;
    final grey = tint ?? dim(style.whileBandGrey);
    final left = rect.left.round(), top = rect.top.round();
    final right = rect.right.round(), bottom = rect.bottom.round();
    const band = _kWhileBand;
    final arrowWidth = _kWhileArrow.first.length,
        arrowHeight = _kWhileArrow.length;
    final arrowLeft = right - arrowWidth, arrowTop = bottom - arrowHeight;

    final greyCells = <double>[];
    void addCell(int column, int row) => greyCells
      ..add(column + 0.5)
      ..add(row + 0.5);

    void cell(int column, int row) {
      final fromTop = row - top, fromBottom = bottom - 1 - row;
      final fromLeft = column - left, fromRight = right - 1 - column;
      if (column >= arrowLeft && row >= arrowTop) return;
      final bool isGrey;
      if (fromTop < band && fromLeft < band) {
        isGrey = _kWhileCornerTL[fromTop][fromLeft] == '#';
      } else if (fromTop < band && fromRight < band) {
        isGrey = _kWhileCornerTR[fromTop][fromRight] == '#';
      } else if (fromBottom < band && fromLeft < band) {
        isGrey = _kWhileCornerBL[fromBottom][fromLeft] == '#';
      } else {
        isGrey = true;
      }
      if (isGrey) addCell(column, row);
    }

    final bandBottom = math.max(bottom - band, top + band);
    for (var row = top; row < math.min(top + band, bottom); row++) {
      for (var column = left; column < right; column++) {
        cell(column, row);
      }
    }
    for (var row = bandBottom; row < bottom; row++) {
      for (var column = left; column < right; column++) {
        cell(column, row);
      }
    }
    for (var row = top + band; row < bandBottom; row++) {
      for (var column = left; column < math.min(left + band, right); column++) {
        cell(column, row);
      }
      for (
        var column = math.max(right - band, left + band);
        column < right;
        column++
      ) {
        cell(column, row);
      }
    }
    for (var arrowRow = 0; arrowRow < arrowHeight; arrowRow++) {
      for (var arrowColumn = 0; arrowColumn < arrowWidth; arrowColumn++) {
        if (_kWhileArrow[arrowRow][arrowColumn] == '#')
          addCell(arrowLeft + arrowColumn, arrowTop + arrowRow);
      }
    }
    _drawCellPoints(canvas, greyCells, grey);
  }

  void _drawForLoopBorder(Canvas canvas, Rect rect, {bool disabled = false}) {
    final ink = disabled
        ? bdDimDisabled(const Color(0xFF000000))
        : const Color(0xFF000000);
    final paint = _solidNoAa(ink);
    final left = rect.left.roundToDouble();
    final top = rect.top.roundToDouble();
    final right = rect.right.roundToDouble();
    final bottom = rect.bottom.roundToDouble();
    void px(double x, double y) => _fillPixels(canvas, paint, x, y);
    void hline(double startX, double endX, double atY) =>
        _hline(canvas, paint, startX, endX, atY);
    void vline(double atX, double startY, double endY) =>
        _vline(canvas, paint, atX, startY, endY);

    const fold = _kForLoopFold;
    final backRight = right - 5, backBottom = bottom - 5;
    hline(left, backRight, top);
    vline(left, top, backBottom);
    vline(backRight, top, backBottom - fold);
    hline(left, backRight - fold, backBottom);
    hline(backRight - fold, backRight, backBottom - fold);
    vline(backRight - fold, backBottom - fold, backBottom);
    for (var step = 1; step < fold; step++) {
      px(backRight - step, backBottom - fold + step);
    }
    for (final shadow in const [2.0, 4.0]) {
      hline(left + shadow, backRight + shadow, backBottom + shadow);
      vline(backRight + shadow, top + shadow, backBottom + shadow);
      hline(backRight + shadow - 2, backRight + shadow, top + shadow);
      px(left + shadow, backBottom + shadow - 1);
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
    Color dim(Color color) => disabled ? bdDimDisabled(color) : color;
    final paint = _solidNoAa(dim(const Color(0xFF000000)));
    final left = rect.left.round(), top = rect.top.round();
    final width = rect.width.round(), height = rect.height.round();
    if (width < 2 || height < 2) return;
    _strokePixelFrame(
      canvas,
      Rect.fromLTWH(
        left.toDouble(),
        top.toDouble(),
        width.toDouble(),
        height.toDouble(),
      ),
      paint,
    );
    final tile = error ? kBdErrorHatch : kBdStructureHatch;
    final offset = error ? style.errorHatchOffset : style.hatchOffset;
    final band = <double>[];
    final field = error ? <double>[] : null;
    void cell(int column, int row) {
      final inset = math.min(
        math.min(column, row),
        math.min(width - 1 - column, height - 1 - row),
      );
      if (inset < 1 || inset > kBdHatchBand) return;
      if (tile[(absTop + row + offset.y) & 3][(absLeft + column + offset.x) &
              3] ==
          '#') {
        band
          ..add(left + column + 0.5)
          ..add(top + row + 0.5);
      } else {
        field
          ?..add(left + column + 0.5)
          ..add(top + row + 0.5);
      }
    }

    final sideTop = math.min(kBdHatchBand + 1, height);
    final sideBottom = math.max(height - 1 - kBdHatchBand, sideTop);
    for (var row = 0; row < sideTop; row++) {
      for (var column = 0; column < width; column++) {
        cell(column, row);
      }
    }
    for (var row = sideBottom; row < height; row++) {
      for (var column = 0; column < width; column++) {
        cell(column, row);
      }
    }
    for (var row = sideTop; row < sideBottom; row++) {
      for (
        var column = 0;
        column < math.min(kBdHatchBand + 1, width);
        column++
      ) {
        cell(column, row);
      }
      for (
        var column = math.max(width - 1 - kBdHatchBand, kBdHatchBand + 1);
        column < width;
        column++
      ) {
        cell(column, row);
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
    Color dim(Color color) =>
        disabled ? bdDimDisabled(color) : _dimFor(oid, color);
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
    Color dim(Color color) => disabled ? bdDimDisabled(color) : color;
    final inks = {
      'G': _solidNoAa(dim(style.booleanGreen)),
      'c': _solidNoAa(dim(kBdTerminalFill)),
      'X': _solidNoAa(dim(const Color(0xFF000000))),
      'R': _solidNoAa(dim(const Color(0xFFFF0000))),
    };
    for (final MapEntry(key: symbol, value: ink) in inks.entries) {
      _stampBitmap(canvas, ink, _stopTerminal, box.left, box.top, on: symbol);
    }
  }

  void _drawTerminalArt(
    Canvas canvas,
    Rect box,
    BdTerminalArt art, {
    bool disabled = false,
  }) {
    Color dim(Color color) => disabled ? bdDimDisabled(color) : color;
    canvas.drawRect(box, _solidNoAa(dim(Colors.white)));
    final inks = {
      'B': _solidNoAa(dim(art.base)),
      'M': _solidNoAa(dim(art.mid)),
      'L': _solidNoAa(dim(art.light)),
      'X': _solidNoAa(dim(const Color(0xFF000000))),
    };
    for (final MapEntry(key: symbol, value: ink) in inks.entries) {
      _stampBitmap(canvas, ink, art.rows, box.left, box.top, on: symbol);
    }
  }

  void _drawLoopGlyphTerminal(
    Canvas canvas,
    Rect box,
    ({(int, int) origin, List<String> rows}) glyph, {
    bool disabled = false,
  }) {
    Color dim(Color color) => disabled ? bdDimDisabled(color) : color;
    final ink = _solidNoAa(dim(const Color(0xFF0000FF)));
    final left = box.left.roundToDouble(), top = box.top.roundToDouble();
    canvas.drawRect(box, _solidNoAa(dim(kBdTerminalFill)));
    canvas.drawRect(Rect.fromLTWH(left, top, 16, 2), ink);
    canvas.drawRect(Rect.fromLTWH(left, top + 14, 16, 2), ink);
    canvas.drawRect(Rect.fromLTWH(left, top, 2, 16), ink);
    canvas.drawRect(Rect.fromLTWH(left + 14, top, 2, 16), ink);
    final (glyphLeft, glyphTop) = glyph.origin;
    _stampBitmap(canvas, ink, glyph.rows, left + glyphLeft, top + glyphTop);
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
    final labelLeft = rect.left.roundToDouble(), top = rect.top.roundToDouble();
    final labelRight = rect.right.roundToDouble();
    final bottom = top + 16;
    final boxLeft = labelLeft - 8, boxRight = labelRight + 18;
    canvas.drawRect(
      Rect.fromLTRB(boxLeft, top, boxRight + 1, bottom + 1),
      _solidNoAa(Colors.white),
    );
    _hline(canvas, ink, boxLeft, boxRight, top);
    _hline(canvas, ink, boxLeft, boxRight, bottom);
    for (final atX in [boxLeft, labelLeft, labelRight + 10, boxRight]) {
      _vline(canvas, ink, atX, top, bottom);
    }
    _stampBitmap(canvas, ink, _selectorLeftPager, labelLeft - 7, top + 5);
    _stampBitmap(canvas, ink, _selectorDropdown, labelRight + 1, top + 6);
    _stampBitmap(canvas, ink, _selectorRightPager, labelRight + 11, top + 5);
  }
}
