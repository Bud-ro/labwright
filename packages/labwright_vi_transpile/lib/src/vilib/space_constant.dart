import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';

import 'vilib.dart';

const LvVilibVi lvSpaceConstantVi = LvVilibVi(
  'Space Constant.vi',
  function: lvSpaceConstant,
  dartName: 'lvSpaceConstant',
  terminals: [LvVilibTerminal(0, 'space', type: lvVilibText, isIndicator: true)],
);
