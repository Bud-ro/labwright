import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/prim_icon_catalog.dart';

import '../tool/prim_review_sheet.dart' show kReviewSheetRows;

/// The contact sheet's rows ([kReviewSheetRows]) against the icon catalogue:
/// every row names a corpus VI to open, and a row claiming bundled icon art
/// must match the catalogue's own key, so a renamed asset cannot silently
/// blank a row. The sheet itself is exported by tool/prim_review_sheet.dart.
void main() {
  test(
    'every sheet row names an identity the icon catalogue can be asked about',
    () {
      for (final row in kReviewSheetRows) {
        expect(
          row.example,
          isNotEmpty,
          reason: '${row.identity} names no example VI',
        );
        if (row.primResId == null) continue;
        // A bundled icon is not required, but a row claiming one must match the
        // catalogue's own key, so a renamed asset cannot silently blank a row.
        final key = 'prim${row.primResId}';
        expect(
          row.hasIcon,
          kPrimIconStatus.containsKey(key) &&
              kPrimIconStatus[key] != PrimIconStatus.rejected,
          reason: '$key disagrees with the icon catalogue',
        );
      }
    },
  );
}
