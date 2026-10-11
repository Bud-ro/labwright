/// `HLPP` / `DLLP` - Help and DLL Paths: [ViPath]
///
/// One `PTH0` path filling the payload, modelled in `pth0.dart`. `HLPP` is the VI's context-help
/// document: an absolute path from the `<helpdir>` symbolic root to a `.chm`, or the relative
/// path `<Not A Path>` when none is set. `DLLP` is the path of a DLL the VI links; the corpus
/// holds one, a relative path climbing six directories.
library;

import '../pth0.dart' show ViPath;
