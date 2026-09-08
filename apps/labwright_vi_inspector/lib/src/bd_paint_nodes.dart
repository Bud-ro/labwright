part of 'diagram_view.dart';

const _boolFalseBlock = [
  '################',
  '################',
  '##............##',
  '##............##',
  '##....#####...##',
  '##....##......##',
  '##....####....##',
  '##....##......##',
  '##....##......##',
  '##....##......##',
  '##............##',
  '##............##',
  '################',
  '################',
];

const _boolTrueBlock = [
  '################',
  '################',
  '##............##',
  '##.##########.##',
  '##.##......##.##',
  '##.####..####.##',
  '##.####..####.##',
  '##.####..####.##',
  '##.####..####.##',
  '##.####..####.##',
  '##.##########.##',
  '##............##',
  '################',
  '################',
];

extension _NodePass on BdDiagramPainter {
  void _paintDecorations(Canvas canvas, List<ViHeapObject> decorations) {
    final backdropCandidates = [
      for (final other in objects)
        if (other.category == ViObjectKind.node ||
            other.category == ViObjectKind.structure ||
            other.category == ViObjectKind.terminal)
          other,
    ];
    bool isBackdrop(ViHeapObject deco) {
      final bounds = deco.absBounds!;
      for (final other in backdropCandidates) {
        if (identical(other, deco)) continue;
        final b = other.absBounds!;
        if (b.left >= bounds.left &&
            b.top >= bounds.top &&
            b.right <= bounds.right &&
            b.bottom <= bounds.bottom) {
          return true;
        }
      }
      return false;
    }

    for (final object in decorations) {
      final rect = _rectOf(object);
      final decoded =
          bdDecodedColor(object.bgRgb) ?? bdDecodedColor(object.contentRgb);
      if (decoded != null) {
        canvas.drawRect(rect, Paint()..color = _dimFor(object.oid, decoded));
      } else if (!isBackdrop(object)) {
        canvas.drawRect(
          rect,
          Paint()..color = _dimFor(object.oid, const Color(0xFFF4F4F4)),
        );
        canvas.drawRect(
          rect,
          Paint()
            ..color = _dimFor(object.oid, Colors.black.withValues(alpha: 0.45))
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8,
        );
      }
    }
  }

  void _paintSolids(
    Canvas canvas,
    List<ViHeapObject> solids,
    List<(int, Rect, Color)> labelBackings,
  ) {
    final stampedPrimIcons = <({Rect dst, int id})>[];
    for (final object in solids) {
      final rect = _rectOf(object);
      if (kBdTextLabelClasses.contains(object.objectClass)) {
        if (object.objectClass == HeapObjectClass.bdSelectorLabel) continue;
        final holder = scene.diagram.byId[object.parentOid ?? -1];
        final backed =
            holder?.kind == 0x1b ||
            (holder?.objectClass == HeapObjectClass.caseOrSequence &&
                ((object.objFlags ?? 0) & 0x800) == 0);
        final backing = object.isLabelHidden || !backed || object.bgRgb == null
            ? null
            : bdDecodedColor(bdLabelBackingRgb(object.bgRgb!));
        if (backing != null) labelBackings.add((object.oid, rect, backing));
        continue;
      }
      if (object.objectClass == HeapObjectClass.loop &&
          rect.width <= 40 &&
          rect.height <= 24) {
        _drawSmallClusterBox(canvas, object, rect);
        continue;
      }
      switch (object.category) {
        case ViObjectKind.terminal:
          _paintTerminal(canvas, object, rect);
        case ViObjectKind.node:
          _paintNode(canvas, object, rect, stampedPrimIcons);
        default:
          _paintPlainSolid(canvas, object, rect);
      }
    }
  }

  void _paintTerminal(Canvas canvas, ViHeapObject object, Rect rect) {
    var box = rect;
    if (constValues[object.oid] != null) {
      final kids =
          scene.diagram.childrenByOid[object.oid] ?? const <ViHeapObject>[];
      final named = kids.any(
        (c) =>
            c.objectClass == HeapObjectClass.controlLabel &&
            !c.isLabelHidden &&
            (c.label?.trim().isNotEmpty ?? false),
      );
      if (named) {
        for (final c in kids) {
          final b = c.absBounds;
          if (c.objectClass == HeapObjectClass.controlChrome &&
              b != null &&
              b.right > b.left) {
            box = _toCanvas(b);
            break;
          }
        }
      }
    }
    final constHolder = scene.diagram.byId[object.parentOid ?? -1];
    final boolValue = constHolder?.objectClass == HeapObjectClass.bdConstDco
        ? constHolder!.constBool
        : null;
    if (boolValue != null && box.width == 16 && box.height == 14) {
      _drawBoolConstant(
        canvas,
        box,
        boolValue,
        disabled: disabledOids.contains(object.oid),
      );
      return;
    }
    final artType = object.dataType ?? _dataTypeOfTypeKind(object.typeKind);
    if (artType != null &&
        object.isIndicator != null &&
        box.width == 32 &&
        box.height == 16) {
      final elementKind = artType == ViDataType.array
          ? object.resolvedElementType?.kind
          : null;
      final art = elementKind != null
          ? bdArrayTerminalArtFor(
              elementKind,
              indicator: object.isIndicator == true,
            )
          : bdTerminalArtFor(artType, indicator: object.isIndicator == true);
      if (art != null) {
        _drawTerminalArt(
          canvas,
          box,
          art,
          disabled: disabledOids.contains(object.oid),
        );
        return;
      }
    }
    final typed = object.typeKind != ViTypeKind.unknown || object.fgRgb != null;
    final tint = _dimFor(
      object.oid,
      object.typeKind != ViTypeKind.unknown
          ? labviewTypeColor(object.typeKind)
          : (bdDecodedColor(object.fgRgb) ?? kBdUnknownTerminalFill),
    );
    final border = typed ? tint : _dimFor(object.oid, const Color(0xFF5A5A5A));
    final constValue = constValues[object.oid];
    final shellParent = scene.diagram.byId[object.parentOid ?? -1];
    if (object.objectClass == HeapObjectClass.numericControl &&
        shellParent?.objectClass == HeapObjectClass.caseOrSequence) {
      return;
    }
    if (object.isIndicator == true) {
      canvas.drawRect(
        box,
        Paint()
          ..color = border
          ..isAntiAlias = false,
      );
      canvas.drawRect(
        box.deflate(1),
        Paint()
          ..color = Colors.white
          ..isAntiAlias = false,
      );
    } else {
      canvas.drawRect(box, Paint()..color = Colors.white);
      canvas.drawRect(
        box.deflate(1),
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
      if (object.objectClass == HeapObjectClass.stringOrArrayControl &&
          box.width > 8) {
        canvas.drawRect(
          Rect.fromLTWH(box.left, box.top, 4, box.height),
          _solidNoAa(border),
        );
      }
      if (object.objectClass == HeapObjectClass.pathControl &&
          box.width > 14 &&
          box.height >= 17) {
        const glyphRows = [
          '####..',
          '#..#..',
          '#..#..',
          '####..',
          '...#..',
          '...#..',
          '..####',
          '..#..#',
          '..#..#',
          '..####',
        ];
        _stampBitmap(
          canvas,
          _solidNoAa(border),
          glyphRows,
          box.left + 3,
          box.top + 4,
        );
      }
    }
    final isConstant =
        constValue != null ||
        shellParent?.objectClass == HeapObjectClass.bdConstDco;
    if (object.isIndicator != true &&
        !isConstant &&
        box.width > 10 &&
        box.height > 10) {
      canvas.drawRect(
        box.deflate(3.5),
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }
    if (object.isIndicator != null && box.height >= 12 && box.width >= 12) {
      final indicator = object.isIndicator == true;
      final cy = box.center.dy;
      final double tipX;
      if (indicator) {
        tipX = box.left + 7;
      } else {
        tipX = box.right - 3;
      }
      final shade = Rect.fromLTRB(
        indicator ? box.left + 3 : box.right - 10,
        box.top + 4,
        indicator ? box.left + 10 : box.right - 3,
        box.bottom - 4,
      );
      canvas.drawRect(shade, Paint()..color = tint.withValues(alpha: 0.25));
      final tri = Path()
        ..moveTo(tipX - 3, cy - 3.5)
        ..lineTo(tipX, cy)
        ..lineTo(tipX - 3, cy + 3.5)
        ..close();
      canvas.drawPath(
        tri,
        Paint()
          ..color = _dimFor(object.oid, Colors.black).withValues(alpha: 0.87),
      );
    }
    var hasRadixMarker = false;
    if (constValue != null) {
      final marker =
          kBdRadixMarkerGlyphs[bdFormatConversion(
            bdDisplayFormatOf(scene.diagram, object.oid),
          )];
      final radixPart = marker == null
          ? null
          : scene.diagram
                .children(object.oid)
                .where(
                  (part) =>
                      part.objectClass == HeapObjectClass.controlSubPart &&
                      part.absBounds != null,
                )
                .firstOrNull;
      if (marker != null && radixPart != null) {
        final (dx, dy, rows) = marker;
        final corner = _toCanvas(radixPart.absBounds!).topLeft;
        hasRadixMarker = true;
        _stampBitmap(
          canvas,
          _solidNoAa(tint),
          rows,
          corner.dx + dx,
          corner.dy + dy,
        );
      }
    }
    if (constValue != null && box.width >= 12 && box.height >= 12) {
      final run = _layoutText(
        constValue,
        color: _dimFor(object.oid, Colors.black),
        maxLines: 1,
      );
      _paintText(
        canvas,
        run,
        Offset(box.right - 4 - run.width, bdCentredTextTop(box, run.height)),
        clip: box.deflate(hasRadixMarker ? 2 : 1),
      );
    }
    final glyph =
        constValue != null ||
            object.dataType == null ||
            (shellParent?.objectClass == HeapObjectClass.bdConstDco &&
                bdDrawnConstText(shellParent) != null)
        ? null
        : dataTypeGlyph(object.dataType!);
    if (glyph != null &&
        box.width >= 6.0 * glyph.length + 10 &&
        box.height >= 13) {
      final run = _layoutText(
        glyph,
        color: border,
        fontSize: 8.5,
        fontWeight: FontWeight.w700,
      );
      _paintText(canvas, run, bdCentredTextAnchor(box, run.size));
    }
  }

  void _paintNode(
    Canvas canvas,
    ViHeapObject object,
    Rect rect,
    List<({Rect dst, int id})> stampedPrimIcons,
  ) {
    final isSubVi = kSubViCallNodeCodes.contains(object.kind);
    final facade = xnodeFacades[object.oid];
    if (facade != null) {
      canvas.drawImageRect(
        facade,
        Rect.fromLTWH(0, 0, facade.width.toDouble(), facade.height.toDouble()),
        rect,
        Paint()..filterQuality = FilterQuality.none,
      );
      return;
    }
    if (object.objectClass == HeapObjectClass.bdGrowableNode) {
      _paintGrowableNode(canvas, object, rect);
      return;
    }
    final icon = subViIcons[object.oid];
    final iconKey = primIconKeyOf(object);
    final disabled = disabledOids.contains(object.oid);
    final primIcon =
        (disabled
            ? primIconArtFor(object, scene.diagram, primIconsGrey)
            : null) ??
        primIconArtFor(object, scene.diagram, primIcons);
    if (primIcon != null) {
      final filter =
          style.iconFilterQuality == FilterQuality.none ||
              style.canvasScale >= kPrimIconPrescale
          ? FilterQuality.none
          : style.iconFilterQuality;
      final art = filter == FilterQuality.none ? primIcon.base : primIcon.sharp;
      final dst = primIconStampRect(
        rect,
        primIcon.base.width,
        primIcon.base.height,
        key: iconKey,
      );
      canvas.drawImageRect(
        art,
        Rect.fromLTWH(0, 0, art.width.toDouble(), art.height.toDouble()),
        dst,
        Paint()..filterQuality = filter,
      );
      final ladderId = disabled ? null : loadedPrimIconIdOf(object);
      final corners =
          (ladderId == null ? null : _primIconPixels[ladderId]?.cornerAa) ??
          const <int>{};
      for (final artIndex in corners) {
        final artWidth = primIcon.base.width;
        final cornerX = dst.left + artIndex % artWidth;
        final cornerY = dst.top + artIndex ~/ artWidth;
        var beneathCorner = false;
        Color? restore;
        for (final prior in stampedPrimIcons.reversed) {
          final localX = (cornerX - prior.dst.left).round();
          final localY = (cornerY - prior.dst.top).round();
          final priorArt = _primIconPixels[prior.id];
          if (priorArt == null ||
              localX < 0 ||
              localY < 0 ||
              localX >= priorArt.width ||
              localY >= priorArt.height) {
            continue;
          }
          final priorIndex = localY * priorArt.width + localX;
          if (priorArt.alpha[priorIndex] == 0) continue;
          if (priorArt.cornerAa.contains(priorIndex)) {
            beneathCorner = true;
            continue;
          }
          restore = Color.fromARGB(
            0xff,
            priorArt.rgba[priorIndex * 4],
            priorArt.rgba[priorIndex * 4 + 1],
            priorArt.rgba[priorIndex * 4 + 2],
          );
          break;
        }
        final rung = restore ?? (beneathCorner ? _kCornerAaRung2 : null);
        if (rung != null) {
          canvas.drawRect(
            Rect.fromLTWH(cornerX, cornerY, 1, 1),
            _solidNoAa(rung),
          );
        }
      }
      if (ladderId != null) {
        stampedPrimIcons.add((dst: dst, id: ladderId));
      }
    } else if (icon != null) {
      paintLegacyIcon(canvas, icon, rect);
    } else {
      final fill = _dimFor(
        object.oid,
        isSubVi ? kBdSubViNodeFill : kBdPrimitiveNodeFill,
      );
      canvas.drawRect(rect, Paint()..color = fill);
    }
    if (primIcon == null) {
      final ring = _solidNoAa(_dimFor(object.oid, Colors.black));
      canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, rect.width, 1), ring);
      canvas.drawRect(
        Rect.fromLTWH(rect.left, rect.bottom - 1, rect.width, 1),
        ring,
      );
      canvas.drawRect(Rect.fromLTWH(rect.left, rect.top, 1, rect.height), ring);
      canvas.drawRect(
        Rect.fromLTWH(rect.right - 1, rect.top, 1, rect.height),
        ring,
      );
    }
    final glyph = icon == null && primIcon == null && object.primResId != null
        ? primOpGlyph(PrimOp.fromId(object.primResId!))
        : null;
    if (glyph != null && rect.width >= 14 && rect.height >= 12) {
      final run = _layoutText(
        glyph,
        color: _dimFor(object.oid, Colors.black).withValues(alpha: 0.75),
        fontSize: glyph.length > 2 ? 8.0 : 12,
        maxLines: 1,
      );
      _paintText(canvas, run, bdCentredTextAnchor(rect, run.size));
    }
  }

  void _paintGrowableNode(Canvas canvas, ViHeapObject object, Rect rect) {
    canvas.drawRect(
      rect,
      Paint()..color = _dimFor(object.oid, const Color(0xFF444444)),
    );
    canvas.drawRect(
      rect.deflate(1),
      Paint()..color = _dimFor(object.oid, Colors.white),
    );
    final rows = <HeapRect>[];
    final rowTerms = <(ViHeapObject, HeapRect)>[];
    final cells = <HeapRect>[];
    final nodeH = object.absBounds!.bottom - object.absBounds!.top;
    final nodeW = object.absBounds!.right - object.absBounds!.left;
    for (final dco in scene.diagram.children(object.oid)) {
      if (dco.kind != kNodeEndpointDcoKind) continue;
      for (final t in scene.diagram.children(dco.oid)) {
        final tb = t.termBounds;
        if (t.kind != 0x62 || tb == null) continue;
        if (tb.height >= nodeH) {
          cells.add(tb);
        } else {
          rows.add(tb);
          rowTerms.add((t, tb));
        }
      }
    }
    final black = Paint()
      ..color = _dimFor(object.oid, Colors.black)
      ..isAntiAlias = false;
    final cream = Paint()
      ..color = _dimFor(object.oid, const Color(0xFFFFFFCC))
      ..isAntiAlias = false;
    rows.sort((a, b) => a.top.compareTo(b.top));
    for (var i = 0; i + 1 < rows.length; i++) {
      if (rows[i].bottom != rows[i + 1].top) continue;
      canvas.drawRect(
        Rect.fromLTWH(
          rect.left + rows[i].left + 1,
          rect.top + rows[i].bottom,
          (rows[i].right - rows[i].left - 2).toDouble(),
          1,
        ),
        black,
      );
    }
    for (final cell in cells) {
      final leftSide = cell.left < nodeW - cell.right;
      if (leftSide) {
        canvas.drawRect(
          Rect.fromLTRB(
            rect.left + 1,
            rect.top + 1,
            rect.left + cell.right,
            rect.bottom - 1,
          ),
          cream,
        );
        canvas.drawRect(
          Rect.fromLTWH(
            rect.left + cell.right,
            rect.top + 1,
            1,
            rect.height - 2,
          ),
          black,
        );
        final cy = rect.top + (nodeH ~/ 2);
        canvas.drawRect(Rect.fromLTWH(rect.left + 1, cy - 1.0, 6, 3), black);
        for (var i = 0; i < 4; i++) {
          canvas.drawRect(
            Rect.fromLTWH(
              rect.left + 7 + i,
              cy - 3.0 + i,
              1,
              (7 - 2 * i).toDouble(),
            ),
            black,
          );
        }
      } else {
        final rowsRight = rows.isEmpty ? cell.left : rows.first.right;
        final top = rect.top + 1;
        final h = rect.height - 2;
        canvas.drawRect(
          Rect.fromLTRB(
            rect.left + rowsRight,
            top,
            rect.left + cell.right - 1,
            top + h,
          ),
          cream,
        );
        canvas.drawRect(
          Rect.fromLTWH(rect.left + rowsRight - 1, top, 1, h),
          black,
        );
        canvas.drawRect(
          Rect.fromLTWH(rect.left + cell.left - 1, top, 1, h),
          black,
        );
        const arrowRows = [
          '...........#...',
          '.#####.....##..',
          '#.############.',
          '#.#############',
          '#.############.',
          '.#####.....##..',
          '...........#...',
        ];
        final arrowTop = rect.top + (nodeH ~/ 2) - 3;
        _stampBitmap(canvas, black, arrowRows, rect.left + rowsRight, arrowTop);
      }
    }
    for (final (term, tb) in rowTerms) {
      final name = term.typeName?.trim();
      if (name == null || name.isEmpty) continue;
      final elementKind = term.typeKind == ViTypeKind.array
          ? term.resolvedElementType?.kind
          : null;
      final rowColor = elementKind != null
          ? labviewTypeColor(_typeKindOfDataType(elementKind))
          : labviewTypeColor(term.typeKind);
      final cell = Rect.fromLTRB(
        rect.left + tb.left + 1,
        rect.top + tb.top,
        rect.left + tb.right - 1,
        rect.top + tb.bottom,
      );
      final run = _layoutText(
        name,
        color: _dimFor(object.oid, rowColor),
        maxLines: 1,
      );
      _paintText(canvas, run, bdCentredTextAnchor(cell, run.size), clip: cell);
    }
  }

  void _paintPlainSolid(Canvas canvas, ViHeapObject object, Rect rect) {
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(2.5));
    final fill = _dimFor(
      object.oid,
      bdFillColor(object) ?? _objectColor(object),
    );
    canvas.drawRRect(rr, Paint()..color = fill.withValues(alpha: 0.92));
    canvas.drawRRect(
      rr,
      Paint()
        ..color = _dimFor(object.oid, Colors.black).withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }

  void _drawArrayConstantShell(Canvas canvas, ViHeapObject shell) {
    final children = scene.diagram.children(shell.oid).toList();
    ViTypeKind elementType = ViTypeKind.unknown;
    ViHeapObject? element;
    for (final c in children) {
      if (c.objectClass != HeapObjectClass.numericControl) continue;
      if (c.typeKind != ViTypeKind.unknown) elementType = c.typeKind;
      if (c.absBounds != null &&
          (element == null || c.absBounds!.right > element.absBounds!.right)) {
        element = c;
      }
    }
    final tint = _dimFor(shell.oid, labviewTypeColor(elementType));
    final fill = _solidNoAa(tint);
    void border(HeapRect b) {
      final l = (b.left - origin.dx).toDouble();
      final t = (b.top - origin.dy).toDouble();
      final w = (b.right - b.left).toDouble();
      final h = (b.bottom - b.top).toDouble();
      if (w <= 0 || h <= 0) return;
      canvas.drawRect(Rect.fromLTWH(l, t, w, 1), fill);
      canvas.drawRect(Rect.fromLTWH(l, t + h - 1, w, 1), fill);
      canvas.drawRect(Rect.fromLTWH(l, t, 1, h), fill);
      canvas.drawRect(Rect.fromLTWH(l + w - 1, t, 1, h), fill);
    }

    bool contains(HeapRect outer, HeapRect inner) =>
        outer.left <= inner.left &&
        outer.top <= inner.top &&
        outer.right >= inner.right &&
        outer.bottom >= inner.bottom;
    final white = _solidNoAa(Colors.white);
    for (final b in bdArrayShellWrapRects(scene.diagram, shell.oid)) {
      canvas.drawRect(
        Rect.fromLTWH(
          (b.left - origin.dx).toDouble(),
          (b.top - origin.dy).toDouble(),
          (b.right - b.left).toDouble(),
          (b.bottom - b.top).toDouble(),
        ),
        white,
      );
      border(b);
    }
    for (final c in children) {
      final b = c.absBounds;
      if (c.objectClass == HeapObjectClass.numericControl &&
          b != null &&
          !identical(c, element)) {
        for (final part in scene.diagram.children(c.oid)) {
          final pb = part.absBounds;
          if (pb == null) continue;
          if (part.objectClass == HeapObjectClass.controlSubPart ||
              part.objectClass == HeapObjectClass.controlChrome)
            border(pb);
          if (part.objectClass == HeapObjectClass.controlChrome &&
              pb.width >= 10 &&
              pb.height >= 12) {
            final indexText = '${shell.arrayIndex ?? 0}';
            final run = _layoutText(
              indexText,
              color: _dimFor(shell.oid, Colors.black),
              maxLines: 1,
            );
            _paintText(
              canvas,
              run,
              Offset(
                (pb.left + 2 - origin.dx).toDouble(),
                bdCentredTextTop(_toCanvas(pb), run.height),
              ),
            );
          }
          if (part.objectClass == HeapObjectClass.controlSubPart) {
            final up = pb.top == b.top;
            final cx = (pb.left + 3 - origin.dx).toDouble();
            for (var i = 0; i < 4; i++) {
              final half = [0, 1, 1, 2][i];
              final row = up ? pb.top + 2 + i : pb.bottom - 4 - i;
              canvas.drawRect(
                Rect.fromLTWH(
                  cx - half,
                  (row - origin.dy).toDouble(),
                  2.0 * half + 1,
                  1,
                ),
                fill,
              );
            }
          }
        }
      }
    }
    if (element == null) return;
    final cell = element.absBounds!;
    final cellW = cell.width, cellH = cell.height;
    if (cellW <= 0 || cellH <= 0) return;
    HeapRect grid = cell;
    var gridArea = 1 << 60;
    for (final c in children) {
      final b = c.absBounds;
      if (c.objectClass != HeapObjectClass.controlChrome ||
          b == null ||
          !contains(b, cell))
        continue;
      final area = b.width * b.height;
      if (area < gridArea) {
        grid = b;
        gridArea = area;
      }
    }
    final cols = math.max(1, grid.width ~/ cellW);
    final rows = math.max(1, grid.height ~/ cellH);
    final holder = scene.diagram.byId[shell.parentOid ?? -1];
    final values = holder?.objectClass == HeapObjectClass.bdConstDco
        ? holder!.constArray
        : null;
    final dims = holder?.objectClass == HeapObjectClass.bdConstDco
        ? holder!.constArrayDims
        : null;
    final format = bdDisplayFormatOf(scene.diagram, element.oid);
    final marker = kBdRadixMarkerGlyphs[bdFormatConversion(format)];
    var radixDx = 2, radixDy = 3;
    for (final part in scene.diagram.children(element.oid)) {
      if (part.objectClass == HeapObjectClass.controlSubPart &&
          part.absBounds != null) {
        radixDx = part.absBounds!.left - cell.left;
        radixDy = part.absBounds!.top - cell.top;
      }
    }
    final windowStart = dims != null && dims.length >= 2
        ? 0
        : (shell.arrayIndex ?? 0);
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < cols; i++) {
        final index = dims != null && dims.length >= 2
            ? j * dims.last + i
            : windowStart + i + j;
        final value =
            values != null &&
                index < values.length &&
                (dims == null || dims.length < 2 || i < dims.last)
            ? values[index]
            : null;
        _drawArrayCell(
          canvas,
          shellOid: shell.oid,
          cell: Rect.fromLTWH(
            (grid.left + i * cellW - origin.dx).toDouble(),
            (grid.top + j * cellH - origin.dy).toDouble(),
            cellW.toDouble(),
            cellH.toDouble(),
          ),
          tint: tint,
          value: value,
          empty: values != null && value == null,
          format: format,
          marker: marker,
          radixDx: radixDx,
          radixDy: radixDy,
        );
      }
    }
  }

  void _drawArrayCell(
    Canvas canvas, {
    required int shellOid,
    required Rect cell,
    required Color tint,
    required num? value,
    required bool empty,
    required String? format,
    required (int, int, List<String>)? marker,
    required int radixDx,
    required int radixDy,
  }) {
    final outer = Rect.fromLTRB(
      cell.left - 1,
      cell.top - 1,
      cell.right + 1,
      cell.bottom + 1,
    );
    canvas.drawRect(outer, Paint()..color = Colors.white);
    final ringFill = _solidNoAa(empty ? bdDimDisabled(tint) : tint);
    canvas.drawRect(
      Rect.fromLTWH(outer.left, outer.top, outer.width, 3),
      ringFill,
    );
    canvas.drawRect(
      Rect.fromLTWH(outer.left, outer.bottom - 3, outer.width, 3),
      ringFill,
    );
    canvas.drawRect(
      Rect.fromLTWH(outer.left, outer.top, 3, outer.height),
      ringFill,
    );
    canvas.drawRect(
      Rect.fromLTWH(outer.right - 3, outer.top, 3, outer.height),
      ringFill,
    );
    if (empty) {
      final pure = _solidNoAa(tint);
      canvas.drawRect(
        Rect.fromLTWH(outer.left, outer.top, outer.width, 1),
        pure,
      );
      canvas.drawRect(
        Rect.fromLTWH(outer.left, outer.bottom - 1, outer.width, 1),
        pure,
      );
      canvas.drawRect(
        Rect.fromLTWH(outer.left, outer.top, 1, outer.height),
        pure,
      );
      canvas.drawRect(
        Rect.fromLTWH(outer.right - 1, outer.top, 1, outer.height),
        pure,
      );
    }
    if (marker != null && (value != null || empty)) {
      final (gx, gy, glyphRows) = marker;
      _stampBitmap(
        canvas,
        _solidNoAa(empty ? bdDimDisabled(tint) : tint),
        glyphRows,
        cell.left + radixDx + gx,
        cell.top + radixDy + gy,
      );
    }
    final text = value != null
        ? bdFormatConstValue(value, format)
        : empty
        ? '0'
        : null;
    if (text == null || cell.width < 10 || cell.height < 12) return;
    final ink = _dimFor(
      shellOid,
      empty ? bdDimDisabled(Colors.black) : Colors.black,
    );
    final run = _layoutText(text, color: ink, maxLines: 1);
    _paintText(
      canvas,
      run,
      Offset(
        cell.left + (marker != null ? 9 : 3),
        bdCentredTextTop(cell, run.height),
      ),
      clip: cell,
    );
  }

  void _drawBoolConstant(
    Canvas canvas,
    Rect box,
    bool value, {
    bool disabled = false,
  }) {
    Color dim(Color c) => disabled ? bdDimDisabled(c) : c;
    canvas.drawRect(box, _solidNoAa(dim(Colors.white)));
    _stampBitmap(
      canvas,
      _solidNoAa(dim(style.booleanGreen)),
      value ? _boolTrueBlock : _boolFalseBlock,
      box.left,
      box.top,
    );
  }

  void _drawSmallClusterBox(Canvas canvas, ViHeapObject object, Rect rect) {
    final tint = _dimFor(
      object.oid,
      object.resolvedMembers.isNotEmpty
          ? _clusterTint(object.resolvedMembers)
          : labviewTypeColor(object.typeKind),
    );
    canvas.drawRect(rect, _solidNoAa(tint));
    canvas.drawRect(rect.deflate(1), _solidNoAa(Colors.white));
    canvas.drawRect(rect.deflate(2), _solidNoAa(tint));
    canvas.drawRect(rect.deflate(3), _solidNoAa(Colors.white));
    if (scene.diagram.byId[object.parentOid ?? -1]?.objectClass !=
        HeapObjectClass.bdConstDco) {
      return;
    }
    const glyphRows = [
      '#####.###.###',
      '#...#.#.#....',
      '#####.#.#.###',
      '......#.#.#.#',
      '.###..###.###',
    ];
    _stampBitmap(
      canvas,
      _solidNoAa(tint),
      glyphRows,
      rect.left + 5,
      rect.top + 6,
    );
  }
}
