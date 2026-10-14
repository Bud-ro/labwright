import 'package:labwright_lv_runtime/labwright_lv_runtime.dart';

import 'vilib.dart';

const LvVilibVi lvErrorClusterFromErrorCodeVi = LvVilibVi(
  'Error Cluster From Error Code.vi',
  function: lvErrorClusterFromErrorCode,
  dartName: 'lvErrorClusterFromErrorCode',
  terminals: [
    LvVilibTerminal(0, 'error out', type: lvVilibError, isIndicator: true),
    LvVilibTerminal(5, 'show call chain?', type: lvVilibBoolean, isIndicator: false),
    LvVilibTerminal(6, 'error in', type: lvVilibError, isIndicator: false),
    LvVilibTerminal(8, 'message', type: lvVilibText, isIndicator: false),
    LvVilibTerminal(9, 'error code', type: lvVilibI32, isIndicator: false),
  ],
);
