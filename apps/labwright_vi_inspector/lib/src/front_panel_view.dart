import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';

/// The front panel of a VI: every placed object of the largest panel drawn in its own box,
/// with a legend of object roles and a card for the selected object.
class FrontPanelView extends StatefulWidget {
  const FrontPanelView({
    super.key,
    required this.panels,
    this.emptyHint = 'No front-panel objects recovered in this file.',
  });

  final List<FpPanel>? panels;

  final String emptyHint;

  @override
  State<FrontPanelView> createState() => _FrontPanelViewState();
}

class _FrontPanelViewState extends State<FrontPanelView> {
  final _transform = TransformationController();

  FpObject? _selected;
  Size? _lastViewport;
  bool _fitted = false;
  bool _shelfOpen = true;

  late final FpPanel? _panel = switch (widget.panels) {
    null => null,
    final panels => largestHeap(panels),
  };

  late final List<FpObject> _drawable = fpDrawableObjects(_panel);

  late final Rect _content = fpContentRect(_drawable);

  late final Map<FpObjectKind, int> _counts = _countByKind(_drawable);

  static Map<FpObjectKind, int> _countByKind(List<FpObject> objects) {
    final counts = <FpObjectKind, int>{};
    for (final object in objects) {
      counts[object.category] = (counts[object.category] ?? 0) + 1;
    }
    return counts;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_panel == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            widget.emptyHint,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    if (_drawable.isEmpty) {
      return const Center(
        child: Text(
          'Panel has no positioned objects.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
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

  Widget _toolbar() => Wrap(
    spacing: 12,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        '${_drawable.length} objects',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      IconButton(
        tooltip: 'Fit to view',
        onPressed: _fit,
        icon: const Icon(Icons.fit_screen),
      ),
      IconButton(
        tooltip: _shelfOpen ? 'Hide details panel' : 'Show details panel',
        onPressed: () => setState(() => _shelfOpen = !_shelfOpen),
        icon: Icon(
          _shelfOpen ? Icons.view_sidebar : Icons.view_sidebar_outlined,
        ),
      ),
    ],
  );

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
              Chip(
                avatar: CircleAvatar(backgroundColor: fpKindColor(entry.key)),
                label: Text('${entry.key.name} ${entry.value}'),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
        const SizedBox(height: 8),
        for (final control in _panel!.controls)
          ListTile(
            dense: true,
            leading: Icon(
              control.dataObject!.isIndicator ? Icons.output : Icons.input,
              size: 16,
            ),
            title: Text(
              control.typeName ?? control.label ?? 'control ${control.oid}',
            ),
            subtitle: Text(
              [
                if (control.dataType case final type?) type.name,
                if (control.dataObject!.conNum case final conNum?
                    when conNum != kViNotOnPane)
                  'pane $conNum',
              ].join(' · '),
            ),
            onTap: () => setState(() => _selected = control),
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
            return ClipRect(
              child: ColoredBox(
                color: const Color(0xFFE9E9E9),
                child: InteractiveViewer(
                  transformationController: _transform,
                  constrained: false,
                  minScale: 0.02,
                  maxScale: 16,
                  boundaryMargin: const EdgeInsets.all(2000),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) => _selectAt(details.localPosition),
                    child: CustomPaint(
                      size: _content.size,
                      painter: FrontPanelPainter(
                        panel: _panel!,
                        drawable: _drawable,
                        origin: _content.topLeft,
                        selected: _selected,
                      ),
                    ),
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
            object: selected,
            onClose: () => setState(() => _selected = null),
          ),
        ),
    ],
  );

  void _selectAt(Offset local) {
    final x = local.dx + _content.left;
    final y = local.dy + _content.top;
    FpObject? hit;
    var bestArea = double.infinity;
    for (final object in _drawable) {
      final bounds = object.absBounds!;
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
    setState(() => _selected = hit);
  }

  void _fit() {
    final viewport = _lastViewport;
    if (viewport == null || _content.width <= 0 || _content.height <= 0) return;
    final scale =
        math.min(
          viewport.width / _content.width,
          viewport.height / _content.height,
        ) *
        0.94;
    final tx = (viewport.width - _content.width * scale) / 2;
    final ty = (viewport.height - _content.height * scale) / 2;
    _transform.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
    _fitted = true;
  }
}

/// The objects of [panel] that occupy an area: everything with positive bounds except the
/// per-panel records.
List<FpObject> fpDrawableObjects(FpPanel? panel) => [
  if (panel != null)
    for (final object in panel.objects)
      if (object.absBounds case final bounds?
          when bounds.width > 0 && bounds.height > 0)
        if (object.category != FpObjectKind.root) object,
];

/// The rectangle that holds every drawable object, with a margin; empty for none.
Rect fpContentRect(List<FpObject> drawable) {
  if (drawable.isEmpty) return Rect.zero;
  var left = double.infinity,
      top = double.infinity,
      right = double.negativeInfinity,
      bottom = double.negativeInfinity;
  for (final object in drawable) {
    final b = object.absBounds!;
    left = math.min(left, b.left.toDouble());
    top = math.min(top, b.top.toDouble());
    right = math.max(right, b.right.toDouble());
    bottom = math.max(bottom, b.bottom.toDouble());
  }
  return Rect.fromLTRB(left, top, right, bottom).inflate(16);
}

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
    required this.panel,
    required this.drawable,
    required this.origin,
    this.selected,
  });

  final FpPanel panel;
  final List<FpObject> drawable;
  final Offset origin;
  final FpObject? selected;

  Rect _rectOf(FpObject object) {
    final b = object.absBounds!;
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
      switch (object.category) {
        case FpObjectKind.pane:
          canvas.drawRect(
            rect,
            fill..color = _rgb(object.bgRgb) ?? const Color(0xFFF5F5F5),
          );
          canvas.drawRect(rect, stroke..color = fpKindColor(FpObjectKind.pane));
        case FpObjectKind.container:
          if (_rgb(object.bgRgb) case final color?)
            canvas.drawRect(rect, fill..color = color);
          canvas.drawRect(
            rect,
            stroke..color = fpKindColor(FpObjectKind.container),
          );
        case FpObjectKind.control:
          canvas.drawRect(
            rect,
            fill..color = _rgb(object.bgRgb) ?? Colors.white,
          );
          canvas.drawRect(
            rect,
            stroke
              ..color =
                  _rgb(object.borderRgb) ?? fpKindColor(FpObjectKind.control),
          );
        case FpObjectKind.part:
          if (object.isTextLabel) {
            _paintLabel(canvas, object, rect);
          } else {
            if (_rgb(object.bgRgb) case final color?)
              canvas.drawRect(rect, fill..color = color);
            canvas.drawRect(
              rect,
              stroke..color = fpKindColor(FpObjectKind.part),
            );
          }
        case FpObjectKind.terminalCluster ||
            FpObjectKind.unknown ||
            FpObjectKind.root:
          canvas.drawRect(rect, stroke..color = fpKindColor(object.category));
      }
    }
    if (selected case final object? when object.absBounds != null) {
      canvas.drawRect(
        _rectOf(object).inflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFE53935),
      );
    }
  }

  void _paintLabel(Canvas canvas, FpObject object, Rect rect) {
    final text = object.label?.trim();
    if (text == null || text.isEmpty || object.isLabelHidden) return;
    if (_rgb(object.bgRgb) case final color?) {
      canvas.drawRect(rect, Paint()..color = color);
    }
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: _rgb(object.fgRgb) ?? Colors.black,
          fontSize: 12,
          fontWeight: object.labelIsBold ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(rect.width - 2, 1));
    final dx = object.labelJustifyCenter
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
      old.panel != panel ||
      old.drawable != drawable ||
      old.origin != origin ||
      old.selected != selected;
}

class _FpDetailsCard extends StatelessWidget {
  const _FpDetailsCard({required this.object, required this.onClose});

  final FpObject object;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final bounds = object.absBounds;
    final cls = object.objectClass;
    final conf = cls.confidence == ClassConfidence.confirmed
        ? ''
        : ' (${cls.confidence.name})';
    final dco = object.dataObject;
    final range = object.numericRange;
    final graph = object.graph;
    return Card(
      margin: const EdgeInsets.only(top: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 14,
              height: 14,
              margin: const EdgeInsets.only(top: 2, right: 8),
              decoration: BoxDecoration(
                color: fpKindColor(object.category),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    object.label ?? cls.label,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${cls.label}$conf · ${object.category.name} · class 0x${object.kind.toRadixString(16)} · oid ${object.oid}'
                    '${object.isLabelHidden ? ' · hidden' : ''}'
                    '${object.typeName != null ? ' · ${object.typeName}' : ''}'
                    '${object.dataType != null
                        ? ' · ${object.dataType!.name}'
                        : object.typeKind != ViTypeKind.unknown
                        ? ' · type ${object.typeKind.name}'
                        : ''}'
                    '${bounds != null ? ' · ${bounds.width}×${bounds.height} @(${bounds.left},${bounds.top})' : ''}'
                    '${object.parentOid != null ? ' · parent ${object.parentOid}' : ''}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  if (dco != null)
                    _detail(
                      'data object',
                      '${dco.isIndicator ? 'indicator' : 'control'}'
                          '${switch (dco.conNum) {
                            null => ' · pane terminal 0 (unnumbered)',
                            kViNotOnPane => ' · not on the pane',
                            final conNum => ' · pane terminal $conNum',
                          }}',
                    ),
                  if (object.items.isNotEmpty)
                    _detail(
                      'values',
                      object.items.take(8).join(', ') +
                          (object.items.length > 8 ? ', …' : ''),
                    ),
                  if (range != null)
                    if (formatControlRange(range.min, range.max)
                        case final text?)
                      _detail('range', text),
                  if (object.displayFormat case final format?)
                    _detail('format', format),
                  if (graph != null && graph.plotNames.isNotEmpty)
                    _detail('plots', graph.plotNames.join(', ')),
                  if (object.helpText case final help?
                      when stripHelpMarkup(help).isNotEmpty)
                    _detail('help', stripHelpMarkup(help)),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 3),
    child: Text.rich(
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      TextSpan(
        style: const TextStyle(fontSize: 12),
        children: [
          TextSpan(
            text: '$label: ',
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Color(0xFF5B9BD5),
            ),
          ),
          TextSpan(text: value),
        ],
      ),
    ),
  );
}
