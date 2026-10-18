import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

import 'heap_view_chrome.dart';

/// The front panel of a VI: every placed object of the largest panel drawn in its own box,
/// with a legend of object roles and a card for the selected object.
class FrontPanelView extends StatefulWidget {
  const FrontPanelView({super.key, required this.panels});

  final List<FpPanel>? panels;

  @override
  State<FrontPanelView> createState() => _FrontPanelViewState();
}

class _FrontPanelViewState extends State<FrontPanelView> {
  final _transform = TransformationController();

  FpPlaced? _selected;
  Set<FpPlaced> _members = const {};
  Size? _lastViewport;
  bool _fitted = false;
  bool _shelfOpen = true;

  late final FpPanel? _panel = switch (widget.panels) {
    null => null,
    final panels => largestHeap(panels),
  };

  late final List<FpPlaced> _drawable = fpDrawableObjects(_panel);

  late final Rect _content = heapContentRect(_drawable, margin: 16);

  late final Map<FpObjectKind, int> _counts = countBy(
    _drawable,
    (o) => o.category,
  );

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_panel == null) {
      return heapPlaceholder('No front-panel objects recovered in this file.');
    }
    if (_drawable.isEmpty) {
      return heapPlaceholder('Panel has no positioned objects.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heapViewToolbar(
          objectCount: _drawable.length,
          onFit: _fit,
          shelfOpen: _shelfOpen,
          onToggleShelf: () => setState(() => _shelfOpen = !_shelfOpen),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _panelStack()),
              if (_shelfOpen) _shelf(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _shelf() => SizedBox(
    width: 250,
    child: ListView(
      padding: const EdgeInsets.only(left: 8),
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final entry in _counts.entries)
              LegendChip(
                color: fpKindColor(entry.key),
                label: '${entry.key.name} ${entry.value}',
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (final dco in _panel!.dataObjects)
          ListTile(
            dense: true,
            leading: Icon(
              dco.isIndicator ? Icons.output : Icons.input,
              size: 16,
            ),
            title: Text(dco.typeName ?? dco.label ?? 'control ${dco.oid}'),
            subtitle: Text(
              [
                if (dco.dataType case final type?) type.name,
                if (dco.conNum case final conNum? when conNum != kViNotOnPane)
                  'pane $conNum',
              ].join(' · '),
            ),
            onTap: () => _select(_bodyOf(dco)),
          ),
      ],
    ),
  );

  Widget _panelStack() => Stack(
    children: [
      Positioned.fill(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = Size(constraints.maxWidth, constraints.maxHeight);
            if (viewport != _lastViewport) {
              _lastViewport = viewport;
              _fitted = false;
            }
            if (!_fitted) {
              WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
            }
            return heapCanvas(
              controller: _transform,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => _selectAt(details.localPosition),
                child: CustomPaint(
                  size: _content.size,
                  painter: FrontPanelPainter(
                    drawable: _drawable,
                    origin: _content.topLeft,
                    selected: _selected,
                    members: _members,
                  ),
                ),
              ),
            );
          },
        ),
      ),
      if (_selected case final selected?)
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: _FpDetailsCard(
            panel: _panel!,
            object: selected,
            members: _members,
            onClose: () => _select(null),
          ),
        ),
    ],
  );

  /// The placed body of a data object: its first placed child, or the object itself when it
  /// has none in the drawable list.
  FpPlaced? _bodyOf(FpDataObject dco) =>
      _panel!.childrenOf(dco).whereType<FpPlaced>().firstOrNull ??
      _drawable.where((o) => o.parentOid == dco.oid).firstOrNull;

  void _select(FpPlaced? object) => setState(() {
    _selected = object;
    _members = object != null && object.category == FpObjectKind.container
        ? fpMembersOf(_panel!, object, _drawable)
        : const {};
  });

  void _selectAt(Offset local) {
    final x = local.dx + _content.left;
    final y = local.dy + _content.top;
    FpPlaced? hit;
    var bestArea = double.infinity;
    for (final object in _drawable) {
      final bounds = object.absBounds;
      if (x < bounds.left ||
          x > bounds.right ||
          y < bounds.top ||
          y > bounds.bottom)
        continue;
      final area = (bounds.width * bounds.height).toDouble();
      if (area <= bestArea) {
        bestArea = area;
        hit = object;
      }
    }
    _select(hit);
  }

  void _fit() {
    final viewport = _lastViewport;
    if (viewport == null) return;
    final fit = fitTransform(viewport, _content);
    if (fit == null) return;
    _transform.value = fit.transform;
    _fitted = true;
  }
}

/// The objects of [panel] drawn as boxes, in paint order (shallower first): everything with a
/// positive, plausible area except the per-panel records, chrome, and the display parts of a
/// control, which the control's own box stands for.
List<FpPlaced> fpDrawableObjects(FpPanel? panel) {
  if (panel == null) return const [];
  bool underControl(FpObject object) {
    for (var p = panel.parentOf(object); p != null; p = panel.parentOf(p)) {
      if (p is HeapControlBody && (p as HeapControlBody).isValueControl)
        return true;
    }
    return false;
  }

  bool scaffolding(FpObject object) => switch (object.objectClass) {
    FpObjectClass.chrome => true,
    FpObjectClass.numericDisplay ||
    FpObjectClass.controlPart ||
    FpObjectClass.terminalCluster ||
    FpObjectClass.itemList => underControl(object),
    _ => false,
  };
  final drawable = [
    for (final object in panel.placed)
      if (object.absBounds case final bounds
          when bounds.isValid &&
              bounds.width > 0 &&
              bounds.height > 0 &&
              bounds.width < 8000 &&
              bounds.height < 8000)
        if (object.category != FpObjectKind.root &&
            !(object is FpText && bounds.left == 0 && bounds.bottom == 0) &&
            !scaffolding(object))
          object,
  ];
  return drawable..sort((a, b) {
    final byDepth = panel.depthOf(a).compareTo(panel.depthOf(b));
    return byDepth != 0 ? byDepth : a.index.compareTo(b.index);
  });
}

/// The drawable objects inside [container].
Set<FpPlaced> fpMembersOf(
  FpPanel panel,
  FpPlaced container,
  List<FpPlaced> drawable,
) => {
  for (final object in drawable)
    if (!identical(object, container))
      for (var p = panel.parentOf(object); p != null; p = panel.parentOf(p))
        if (identical(p, container)) object,
};

Color fpKindColor(FpObjectKind kind) => switch (kind) {
  FpObjectKind.root => const Color(0xFF9E9E9E),
  FpObjectKind.pane => const Color(0xFFB0BEC5),
  FpObjectKind.container => const Color(0xFF9A6B2E),
  FpObjectKind.control => const Color(0xFF5C9BD6),
  FpObjectKind.part => const Color(0xFFBDBDBD),
  FpObjectKind.terminalCluster => const Color(0xFF2BB8A8),
  FpObjectKind.unknown => const Color(0xFF9E9E9E),
};

Color? _rgb(int? rgb) => rgb == null ? null : Color(0xFF000000 | rgb);

/// Paints a panel's objects as boxes: panes and containers as outlines, controls filled with
/// their background colour and outlined in their role colour, labels as text.
class FrontPanelPainter extends CustomPainter {
  FrontPanelPainter({
    required this.drawable,
    required this.origin,
    this.selected,
    this.members = const {},
  });

  final List<FpPlaced> drawable;
  final Offset origin;
  final FpPlaced? selected;
  final Set<FpPlaced> members;

  Rect _rectOf(FpPlaced object) {
    final b = object.absBounds;
    return Rect.fromLTRB(
      b.left - origin.dx,
      b.top - origin.dy,
      b.right - origin.dx,
      b.bottom - origin.dy,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final object in drawable) {
      final rect = _rectOf(object);
      if (object is FpText) {
        _paintLabel(canvas, object, rect);
        continue;
      }
      final kindColor = fpKindColor(object.category);
      final (Color? fillColor, Color strokeColor) = switch (object.category) {
        FpObjectKind.pane => (
          _rgb(object.bgRgb) ?? const Color(0xFFF5F5F5),
          kindColor,
        ),
        FpObjectKind.control => (
          _rgb(object.bgRgb) ?? Colors.white,
          _rgb(object.borderRgb) ?? kindColor,
        ),
        FpObjectKind.container ||
        FpObjectKind.part => (_rgb(object.bgRgb), kindColor),
        _ => (null, kindColor),
      };
      if (fillColor != null) canvas.drawRect(rect, fill..color = fillColor);
      canvas.drawRect(rect, stroke..color = strokeColor);
    }
    final memberPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = const Color(0xFFEF6C00);
    for (final member in members) {
      canvas.drawRect(_rectOf(member).inflate(1.5), memberPaint);
    }
    if (selected case final object?) {
      canvas.drawRect(
        _rectOf(object).inflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFE53935),
      );
    }
  }

  void _paintLabel(Canvas canvas, FpText object, Rect rect) {
    final text = object.label?.trim();
    if (text == null || text.isEmpty || object.isHidden) return;
    if (_rgb(object.bgRgb) case final color?) {
      canvas.drawRect(rect, Paint()..color = color);
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: _rgb(object.fgRgb) ?? Colors.black,
          fontSize: 12,
          fontWeight: object.isBold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(rect.width - 2, 1));
    final dx = object.justifyCenter
        ? rect.left + (rect.width - painter.width) / 2
        : rect.left + 1;
    painter.paint(
      canvas,
      Offset(dx, rect.top + math.max(0, (rect.height - painter.height) / 2)),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(FrontPanelPainter old) =>
      old.drawable != drawable ||
      old.origin != origin ||
      old.selected != selected ||
      old.members.length != members.length ||
      !old.members.containsAll(members);
}

class _FpDetailsCard extends StatelessWidget {
  const _FpDetailsCard({
    required this.panel,
    required this.object,
    required this.members,
    required this.onClose,
  });

  final FpPanel panel;

  final FpPlaced object;
  final Set<FpPlaced> members;
  final VoidCallback onClose;

  static String _contentLabel(FpObject o) {
    final label = o.label?.trim();
    return (label != null && label.isNotEmpty) ? label : o.objectClass.label;
  }

  @override
  Widget build(BuildContext context) {
    final bounds = object.absBounds;
    final cls = object.objectClass;
    final conf = cls.confidence == ClassConfidence.confirmed
        ? ''
        : ' (${cls.confidence.name})';
    final dco = switch (object) {
      FpControl() =>
        panel.parentOf(object) is FpDataObject
            ? panel.parentOf(object) as FpDataObject
            : null,
      _ => null,
    };
    final range = switch (object) {
      final FpNumericControl control => control,
      _ => null,
    };
    final graph = switch (object) {
      final FpGraph graph => graph,
      _ => null,
    };
    final items = switch (object) {
      HeapItems(:final items) => items,
      _ => const <String>[],
    };
    final displayFormat = switch (object) {
      FpPart(:final displayFormat) => displayFormat,
      _ => null,
    };
    return HeapDetailsCard(
      swatch: fpKindColor(object.category),
      title: object.label ?? cls.label,
      subtitle:
          '${cls.label}$conf · ${object.category.name} · class 0x${object.kind.toRadixString(16)} · oid ${object.oid}'
          '${switch (object) {
            FpText(isHidden: true) => ' · hidden',
            _ => '',
          }}'
          '${object.typeName != null ? ' · ${object.typeName}' : ''}'
          '${object.dataType != null
              ? ' · ${object.dataType!.name}'
              : object.typeKind != ViTypeKind.unknown
              ? ' · type ${object.typeKind.name}'
              : ''}'
          ' · ${bounds.width}×${bounds.height} @(${bounds.left},${bounds.top})'
          '${object.parentOid != null ? ' · parent ${object.parentOid}' : ''}',
      details: [
        if (dco != null)
          detailLine(
            'data object',
            '${dco.isIndicator ? 'indicator' : 'control'}'
                '${switch (dco.conNum) {
                  null => ' · pane terminal 0 (unnumbered)',
                  kViNotOnPane => ' · not on the pane',
                  final conNum => ' · pane terminal $conNum',
                }}',
          ),
        if (items.isNotEmpty)
          detailLine(
            'values',
            items.take(8).join(', ') + (items.length > 8 ? ', …' : ''),
          ),
        if (range != null)
          if (formatControlRange(range.min, range.max) case final text?)
            detailLine('range', text),
        if (displayFormat case final format?) detailLine('format', format),
        if (graph != null && graph.plotNames.isNotEmpty)
          detailLine('plots', graph.plotNames.join(', ')),
        if (object.helpText case final help?
            when stripHelpMarkup(help).isNotEmpty)
          detailLine('help', stripHelpMarkup(help)),
        if (members.isNotEmpty)
          detailLine(
            'contains',
            members.map(_contentLabel).take(10).join(', ') +
                (members.length > 10 ? ', …' : ''),
          ),
      ],
      onClose: onClose,
    );
  }
}
