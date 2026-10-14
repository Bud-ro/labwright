import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';

import 'vilib.dart';

const LvVilibVi lvTrimWhitespaceVi = LvVilibVi(
  'Trim Whitespace.vi',
  function: lvTrimWhitespace,
  dartName: 'lvTrimWhitespace',
  terminals: [
    LvVilibTerminal(0, 'string', type: lvVilibText, isIndicator: false),
    LvVilibTerminal(1, 'location', type: lvVilibU32, isIndicator: false, runtimeEnum: 'LvTrimLocation'),
    LvVilibTerminal(2, 'trimmed string', type: lvVilibText, isIndicator: true),
  ],
);
