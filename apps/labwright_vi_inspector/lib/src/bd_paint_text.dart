part of 'diagram_view.dart';

extension _TextPass on BdDiagramPainter {
  BdGlyph _glyph(
    String glyph,
    Color color,
    double fontSize,
    FontWeight fontWeight,
    FontStyle? fontStyle,
  ) {
    final key = (
      glyph,
      color.toARGB32(),
      fontSize,
      fontWeight,
      fontStyle,
      bdTextFontFamily,
    );
    final cached = scene.textGlyphCache[key];
    if (cached != null) return cached;
    TextPainter build(Color inkColor) => TextPainter(
      text: TextSpan(
        text: glyph,
        style: TextStyle(
          color: inkColor,
          fontSize: fontSize,
          height: kBdTextLineHeight,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          fontFamily: bdTextFontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final main = build(color);
    final hinted = fontSize == kBdTextSize && glyph.length == 1
        ? bdHintedAdvance(
            glyph.codeUnitAt(0),
            bold: fontWeight.value >= FontWeight.w700.value,
          )
        : null;
    final overdraw = fontWeight.value >= FontWeight.w700.value
        ? kBdTextOverdrawAlphaBold
        : kBdTextOverdrawAlpha;
    final slot = BdGlyph(
      main: main,
      dim: build(color.withValues(alpha: color.a * overdraw)),
      advance: hinted ?? main.width.round(),
      baseline: main.computeDistanceToActualBaseline(TextBaseline.alphabetic),
    );
    scene.textGlyphCache[key] = slot;
    return slot;
  }

  BdTextRun _layoutText(
    String text, {
    required Color color,
    double fontSize = kBdTextSize,
    FontWeight fontWeight = FontWeight.w400,
    FontStyle? fontStyle,
    int? maxLines,
  }) {
    var lineCount = 1;
    for (var charIndex = 0; charIndex < text.length; charIndex++) {
      if (text.codeUnitAt(charIndex) == 0x0a) lineCount++;
    }
    if (maxLines != null && maxLines < lineCount) lineCount = maxLines;
    final key = (
      text,
      color.toARGB32(),
      fontSize,
      fontWeight,
      fontStyle,
      lineCount,
      bdTextFontFamily,
    );
    final cached = scene.textLayoutCache[key];
    if (cached != null) return cached;

    final lineHeight = bdLineBox(fontSize);
    final lines = text.split('\n');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    var width = 0.0;
    for (final dimPass in [true, false]) {
      var lineTop = 0.0;
      for (var line = 0; line < lineCount; line++) {
        var penX = 0.0;
        for (final rune in lines[line].runes) {
          final slot = _glyph(
            String.fromCharCode(rune),
            color,
            fontSize,
            fontWeight,
            fontStyle,
          );
          final pen = Offset(
            penX,
            lineTop + slot.baseline.roundToDouble() - slot.baseline,
          );
          (dimPass ? slot.dim : slot.main).paint(canvas, pen);
          penX += slot.advance;
        }
        width = math.max(width, penX);
        lineTop += lineHeight;
      }
    }
    final run = BdTextRun(
      text: text,
      width: width,
      height: lineHeight * lineCount,
      fontSize: fontSize,
      picture: recorder.endRecording(),
    );
    scene.textLayoutCache[key] = run;
    return run;
  }

  void _paintText(Canvas canvas, BdTextRun run, Offset at, {Rect? clip}) {
    at = Offset(at.dx.roundToDouble(), at.dy.roundToDouble());
    if (clip != null) {
      canvas
        ..save()
        ..clipRect(clip);
    }
    run.paint(canvas, at);
    if (clip != null) canvas.restore();
    if (!scene.recordPaintedText) return;
    scene.paintedText.add((
      text: run.text,
      rect: clip == null ? at & run.size : (at & run.size).intersect(clip),
      fontSize: run.fontSize,
    ));
  }

  void _paintLabelBackings(
    Canvas canvas,
    List<(int, Rect, Color)> labelBackings,
  ) {
    for (final (oid, rect, backing) in labelBackings) {
      canvas.drawRect(rect, Paint()..color = _dimFor(oid, Colors.black));
      canvas.drawRect(rect.deflate(1), Paint()..color = _dimFor(oid, backing));
    }
  }

  void _paintCaptions(Canvas canvas) {
    final byOid = {for (final object in objects) object.oid: object};
    for (final object in objects) {
      if (kBdTextLabelClasses.contains(object.objectClass)) {
        if (object.isLabelHidden) continue;
        var text = object.objectClass == HeapObjectClass.bdSelectorLabel
            ? (object.label?.trim().isEmpty ?? true ? null : object.label)
            : object.label?.trim();
        if (text == null || text.isEmpty) {
          final diagramById = scene.diagram.byId;
          String? constValue;
          var ancestorOid = object.parentOid;
          for (var hop = 0; hop < 4 && ancestorOid != null; hop++) {
            final ancestor = diagramById[ancestorOid];
            if (ancestor == null) break;
            final decoded = bdDrawnConstText(ancestor);
            if (decoded != null) {
              constValue = decoded;
              break;
            }
            ancestorOid = ancestor.parentOid;
          }
          text = constValue ?? byOid[object.parentOid]?.typeName;
        }
        if (text == null || text.isEmpty) continue;
        final rect = _rectOf(object);
        if (rect.width < 8 || rect.height < 8) continue;
        final selector = object.objectClass == HeapObjectClass.bdSelectorLabel;
        final labelFont = object.labelFont;
        final fontSize = labelFont == null
            ? kBdTextSize
            : bdEmForCellHeight(labelFont.resolvedSize);
        final run = _layoutText(
          text,
          color: _dimFor(
            object.oid,
            bdDecodedColor(object.fgRgb) ?? Colors.black,
          ),
          fontSize: fontSize,
          fontWeight: object.labelIsBold ? FontWeight.w700 : FontWeight.w400,
          maxLines: math.max(1, (rect.height / bdLineBox(fontSize)).round()),
        );
        final centered = !selector && object.labelJustifyCenter;
        _paintText(
          canvas,
          run,
          selector
              ? Offset(rect.left + 1, bdCentredTextTop(rect, run.height))
              : centered
              ? Offset(bdCentredLabelLeft(rect, run.width), rect.top + 1)
              : rect.topLeft + Offset(object.labelTextInset.toDouble(), 1),
          clip: selector
              ? Rect.fromLTRB(rect.left, rect.top, rect.right - 4, rect.bottom)
              : null,
        );
        continue;
      }
      final String? text;
      if (object.category == ViObjectKind.structure ||
          object.category == ViObjectKind.node) {
        text = null;
      } else {
        final literal = bdDrawnConstText(object);
        final label = object.label?.trim();
        text = literal ?? (label != null && label.isNotEmpty ? label : null);
      }
      if (text == null) continue;
      final rect = _rectOf(object);
      if (rect.width < 26 || rect.height < 11) continue;
      final textColor = _dimFor(
        object.oid,
        bdDecodedColor(object.fgRgb) ?? Colors.black,
      );
      final run = _layoutText(text, color: textColor, maxLines: 1);
      _paintText(
        canvas,
        run,
        rect.topLeft + Offset(object.labelTextInset.toDouble(), 1),
        clip: rect.deflate(1),
      );
    }
  }

  void _drawGlyphText(Canvas canvas, Rect box, String glyph, Color color) {
    final run = _layoutText(
      glyph,
      color: color,
      fontSize: 11,
      fontWeight: FontWeight.w700,
      fontStyle: FontStyle.italic,
    );
    _paintText(canvas, run, bdCentredTextAnchor(box, run.size));
  }
}
