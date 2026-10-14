import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';

import 'vilib.dart';

const LvVilibVi lvApplicationDirectoryVi = LvVilibVi(
  'Application Directory.vi',
  function: lvApplicationDirectory,
  dartName: 'lvApplicationDirectory',
  terminals: [LvVilibTerminal(0, 'path', type: lvVilibPath, isIndicator: true)],
);
