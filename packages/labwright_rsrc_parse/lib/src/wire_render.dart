library;

import 'dart:math' show min;

import 'blocks/type_pool.dart';
import 'graph.dart' show ViSignalType;

enum ViWireRenderStyle {
  solid1px,

  solid2px,

  hollowDouble,

  dotted,

  dottedAlternating,

  zigzag,

  chainLink,

  chainLinkWide,

  braid,

  braidWide,

  braidDense,

  braidDenseWide,

  weave,
}

const int kWeaveWireCode = 0x74;

const Map<int, ViWireRenderStyle> _measuredCells = {
  0x103: ViWireRenderStyle.solid1px,
  0x104: ViWireRenderStyle.solid1px,
  0x105: ViWireRenderStyle.solid1px,
  0x106: ViWireRenderStyle.solid1px,
  0x107: ViWireRenderStyle.solid1px,
  0x108: ViWireRenderStyle.solid1px,
  0x10a: ViWireRenderStyle.solid1px,
  0x170: ViWireRenderStyle.solid1px,
  0x203: ViWireRenderStyle.solid2px,
  0x205: ViWireRenderStyle.solid2px,
  0x207: ViWireRenderStyle.solid2px,
  0x208: ViWireRenderStyle.solid2px,
  0x270: ViWireRenderStyle.solid2px,
  0x303: ViWireRenderStyle.hollowDouble,
  0x121: ViWireRenderStyle.dotted,
  0x221: ViWireRenderStyle.dottedAlternating,
  0x230: ViWireRenderStyle.zigzag,
  0x232: ViWireRenderStyle.zigzag,
  0x237: ViWireRenderStyle.zigzag,
  0x330: ViWireRenderStyle.chainLink,
  0x332: ViWireRenderStyle.chainLink,
  0x430: ViWireRenderStyle.chainLinkWide,
  0x350: ViWireRenderStyle.braid,
  0x450: ViWireRenderStyle.braidWide,
  0x353: ViWireRenderStyle.braidDense,
  0x451: ViWireRenderStyle.braidDenseWide,
  (3 << 8) | kWeaveWireCode: ViWireRenderStyle.weave,
};

bool _isNumericCode(int code) => code >= TypeCode.i8 && code <= TypeCode.complexExt;

extension ViSignalTypeRenderStyle on ViSignalType {
  ViWireRenderStyle? get renderStyle => _measuredCells[raw & 0xfff];

  ViWireRenderStyle? get renderStyleEstimate {
    final measured = renderStyle;
    if (measured != null) return measured;
    final code = typeCode;
    final d = depth;
    if (_isNumericCode(code)) {
      return switch (d) {
        1 => ViWireRenderStyle.solid1px,
        2 => ViWireRenderStyle.solid2px,
        3 => ViWireRenderStyle.hollowDouble,
        _ => null,
      };
    }
    if (code == TypeCode.boolean) {
      return switch (d) {
        1 => ViWireRenderStyle.dotted,
        2 => ViWireRenderStyle.dottedAlternating,
        _ => null,
      };
    }
    if (code == TypeCode.string || code == TypeCode.path || code == TypeCode.tag) {
      return switch (d) {
        2 => ViWireRenderStyle.zigzag,
        3 => ViWireRenderStyle.chainLink,
        4 => ViWireRenderStyle.chainLinkWide,
        _ => null,
      };
    }
    if (code == TypeCode.cluster) {
      return switch (d) {
        3 => ViWireRenderStyle.braid,
        4 => ViWireRenderStyle.braidWide,
        _ => null,
      };
    }
    if (code == ViSignalType.clusterVariantCode) {
      return d == 4 ? ViWireRenderStyle.braidDenseWide : null;
    }
    if (code == TypeCode.variant) {
      return d == 3 ? ViWireRenderStyle.braidDense : null;
    }
    if (code == TypeCode.refnum || code == ViSignalType.typedRefnumCode) {
      return switch (d) {
        1 => ViWireRenderStyle.solid1px,
        2 => ViWireRenderStyle.solid2px,
        _ => null,
      };
    }
    return null;
  }
}

int dimDisabledFrameRgb(int rgb) {
  int dim(int c) => min(255, 153 + (c >> 1));
  return (dim((rgb >> 16) & 0xff) << 16) | (dim((rgb >> 8) & 0xff) << 8) | dim(rgb & 0xff);
}
