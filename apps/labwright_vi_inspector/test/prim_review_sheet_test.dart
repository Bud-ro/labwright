import 'package:flutter_test/flutter_test.dart';
import 'package:labwright_vi_inspector/src/prim_icon_catalog.dart';

import '../tool/prim_review_sheet.dart' show kReviewSheetRows;

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
