import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_inspector/src/diagram_view.dart';

void main() {
  test(
    'terminals keep LabVIEW datatype colors (orange float, blue int/enum)',
    () {
      expect(
        labviewTypeColor(ViTypeKind.numericFloat),
        const Color(0xFFFF8000),
      );
      expect(labviewTypeColor(ViTypeKind.numericInt), const Color(0xFF0066CC));
      expect(labviewTypeColor(ViTypeKind.enumRing), const Color(0xFF0066CC));
      expect(labviewTypeColor(ViTypeKind.path), const Color(0xFF669900));
      expect(
        labviewTypeColor(ViTypeKind.unknown),
        const Color(0xFF8A8A8A),
        reason: 'unknown stays neutral - never guessed',
      );
    },
  );
}
