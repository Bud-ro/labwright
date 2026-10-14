import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';

import 'vilib.dart';

const LvVilibVi lvColorToRgbVi = LvVilibVi(
  'Color to RGB.vi',
  function: lvColorToRgb,
  dartName: 'lvColorToRgb',
  terminals: [
    LvVilibTerminal(0, 'color', type: lvVilibU32, isIndicator: false),
    LvVilibTerminal(2, 'red', type: lvVilibU8, isIndicator: true),
    LvVilibTerminal(3, 'green', type: lvVilibU8, isIndicator: true),
    LvVilibTerminal(4, 'blue', type: lvVilibU8, isIndicator: true),
  ],
);
