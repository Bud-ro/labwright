import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'path_ops.dart';
import 'references.dart';
import 'string_ops.dart';
import 'timing_ops.dart';
import 'values.dart';

/// Open/Create/Replace File's `operation` ring.
enum LvFileOperation {
  open(0),
  replace(1),
  create(2),
  openOrCreate(3),
  replaceOrCreate(4),
  replaceOrCreateWithConfirmation(5);

  const LvFileOperation(this.code);

  final int code;

  static LvFileOperation? ofCode(int code) => values.where((operation) => operation.code == code).firstOrNull;
}

/// Open/Create/Replace File's `access` ring.
enum LvFileAccess {
  readWrite(0),
  readOnly(1),
  writeOnly(2);

  const LvFileAccess(this.code);

  final int code;

  static LvFileAccess? ofCode(int code) => values.where((access) => access.code == code).firstOrNull;
}

/// Set File Position's `from` ring.
enum LvFilePositionFrom {
  start(0),
  end(1),
  current(2);

  const LvFilePositionFrom(this.code);

  final int code;

  static LvFilePositionFrom? ofCode(int code) => values.where((from) => from.code == code).firstOrNull;
}

/// An open file: the handle and the path it was opened at.
final class LvOpenFile {
  LvOpenFile(this.file, this.path);

  final RandomAccessFile file;

  final LvPath path;
}

String _nativePath(LvPath path) => lvPathToString(path);

LvError _ioError(String source, Object error) {
  if (error is PathNotFoundException) return LvErrorCode.fileNotFound.error(source);
  if (error is PathAccessException) return LvErrorCode.filePermission.error(source);
  if (error is PathExistsException) return LvErrorCode.duplicatePath.error(source);
  if (error is FileSystemException) return LvErrorCode.filePermission.error('$source: ${error.message}');
  return LvErrorCode.invalidArgument.error('$source: $error');
}

/// Open/Create/Replace File without a dialog: [filePath] opened as [operation] and [access] say.
/// `cancelled` is always false, since no dialog can show.
({LvRefnum refnum, bool cancelled, LvError errorOut}) lvOpenCreateReplaceFile(
  LvPath filePath, {
  int operation = 0,
  int access = 0,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (refnum: LvRefnum.none, cancelled: false, errorOut: errorIn);
  final mode = LvFileOperation.ofCode(operation), rights = LvFileAccess.ofCode(access);
  if (!filePath.valid || filePath.isEmpty) {
    return (
      refnum: LvRefnum.none,
      cancelled: false,
      errorOut: LvErrorCode.invalidPath.error('Open/Create/Replace File'),
    );
  }
  if (mode == null || rights == null) {
    return (
      refnum: LvRefnum.none,
      cancelled: false,
      errorOut: LvErrorCode.invalidArgument.error('Open/Create/Replace File'),
    );
  }
  final file = File(_nativePath(filePath));
  try {
    final exists = file.existsSync();
    switch (mode) {
      case LvFileOperation.open:
        if (!exists) {
          return (
            refnum: LvRefnum.none,
            cancelled: false,
            errorOut: LvErrorCode.fileNotFound.error('Open/Create/Replace File'),
          );
        }
      case LvFileOperation.create:
        if (exists) {
          return (
            refnum: LvRefnum.none,
            cancelled: false,
            errorOut: LvErrorCode.duplicatePath.error('Open/Create/Replace File'),
          );
        }
      case LvFileOperation.replace:
        if (!exists) {
          return (
            refnum: LvRefnum.none,
            cancelled: false,
            errorOut: LvErrorCode.fileNotFound.error('Open/Create/Replace File'),
          );
        }
      case LvFileOperation.openOrCreate:
      case LvFileOperation.replaceOrCreate:
      case LvFileOperation.replaceOrCreateWithConfirmation:
        break;
    }
    final truncate =
        mode == LvFileOperation.replace ||
        mode == LvFileOperation.replaceOrCreate ||
        mode == LvFileOperation.replaceOrCreateWithConfirmation;
    final fileMode = rights == LvFileAccess.readOnly
        ? FileMode.read
        : truncate
        ? FileMode.write
        : FileMode.append;
    final handle = file.openSync(mode: fileMode);
    if (fileMode == FileMode.append) handle.setPositionSync(0);
    return (refnum: lvRegisterReference(LvOpenFile(handle, filePath)), cancelled: false, errorOut: LvError.none);
  } catch (error) {
    return (refnum: LvRefnum.none, cancelled: false, errorOut: _ioError('Open/Create/Replace File', error));
  }
}

LvOpenFile? _openFile(LvRefnum refnum) => lvReferenceTarget<LvOpenFile>(refnum);

/// The refnum a file function given an incoming error passes on: its file refnum unchanged, or
/// Not A Refnum for a path it would have opened itself.
LvRefnum _passed(Object fileOrPath) => fileOrPath is LvRefnum ? fileOrPath : LvRefnum.none;

/// Close File: closes the handle and returns its path. It runs even when an error came in.
({LvPath path, LvError errorOut}) lvCloseFile(LvRefnum refnum, {LvError errorIn = LvError.none}) {
  final open = _openFile(refnum);
  if (open == null) {
    return (
      path: LvPath.notAPath,
      errorOut: errorIn.status ? errorIn : LvErrorCode.invalidReference.error('Close File'),
    );
  }
  LvReferenceTable.instance.release(refnum);
  try {
    open.file.closeSync();
  } catch (error) {
    return (path: open.path, errorOut: errorIn.status ? errorIn : _ioError('Close File', error));
  }
  return (path: open.path, errorOut: errorIn);
}

/// The open file [fileOrPath] names: the refnum itself, or a path opened read-only for the
/// call and closed by [done].
({LvOpenFile? open, LvRefnum refnum, bool opened, LvError errorOut}) _resolveFile(
  Object fileOrPath,
  String source, {
  bool write = false,
}) {
  if (fileOrPath is LvRefnum) {
    final open = _openFile(fileOrPath);
    if (open == null) {
      return (open: null, refnum: LvRefnum.none, opened: false, errorOut: LvErrorCode.invalidReference.error(source));
    }
    return (open: open, refnum: fileOrPath, opened: false, errorOut: LvError.none);
  }
  if (fileOrPath is! LvPath || !fileOrPath.valid || fileOrPath.isEmpty) {
    return (open: null, refnum: LvRefnum.none, opened: false, errorOut: LvErrorCode.invalidPath.error(source));
  }
  final opened = lvOpenCreateReplaceFile(
    fileOrPath,
    operation: write ? LvFileOperation.openOrCreate.code : LvFileOperation.open.code,
    access: write ? LvFileAccess.readWrite.code : LvFileAccess.readOnly.code,
  );
  if (opened.errorOut.status) return (open: null, refnum: LvRefnum.none, opened: false, errorOut: opened.errorOut);
  return (open: _openFile(opened.refnum), refnum: opened.refnum, opened: true, errorOut: LvError.none);
}

/// Read from Text File: [count] characters from the current position, or the rest of the file
/// when the count is below zero; with [lines] the count is in lines (each with its line ending
/// trimmed and returned as one string joined by line feeds), and with [convertEol] every line
/// ending becomes a line feed. A path opens, reads and closes; a refnum stays open and is
/// returned.
({LvRefnum refnumOut, String text, bool cancelled, LvError errorOut}) lvReadFromTextFile(
  Object fileOrPath, {
  int count = -1,
  bool lines = false,
  bool convertEol = false,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (refnumOut: _passed(fileOrPath), text: '', cancelled: false, errorOut: errorIn);
  final resolved = _resolveFile(fileOrPath, 'Read from Text File');
  final open = resolved.open;
  if (open == null) return (refnumOut: LvRefnum.none, text: '', cancelled: false, errorOut: resolved.errorOut);
  try {
    final remaining = open.file.lengthSync() - open.file.positionSync();
    final bytes = open.file.readSync(remaining < 0 ? 0 : remaining);
    var text = latin1.decode(bytes);
    var error = LvError.none;
    if (lines) {
      final all = text.split(RegExp('\r\n|\n|\r'));
      if (all.isNotEmpty && all.last.isEmpty) all.removeLast();
      final taken = count < 0 ? all : all.take(count).toList();
      if (count >= 0 && all.length < count) error = LvErrorCode.endOfFile.error('Read from Text File');
      text = taken.join('\n');
      final consumed = _lineBytes(bytes, taken.length);
      open.file.setPositionSync(open.file.positionSync() - remaining + consumed);
    } else if (count >= 0) {
      if (text.length > count) {
        text = text.substring(0, count);
        open.file.setPositionSync(open.file.positionSync() - remaining + count);
      } else if (text.length < count) {
        error = LvErrorCode.endOfFile.error('Read from Text File');
      }
    }
    if (convertEol && !lines) text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (resolved.opened) lvCloseFile(resolved.refnum);
    return (
      refnumOut: resolved.opened ? LvRefnum.none : resolved.refnum,
      text: text,
      cancelled: false,
      errorOut: error,
    );
  } catch (error) {
    if (resolved.opened) lvCloseFile(resolved.refnum);
    return (refnumOut: LvRefnum.none, text: '', cancelled: false, errorOut: _ioError('Read from Text File', error));
  }
}

int _lineBytes(Uint8List bytes, int lines) {
  var at = 0;
  for (var line = 0; line < lines && at < bytes.length; line++) {
    while (at < bytes.length && bytes[at] != 0x0a && bytes[at] != 0x0d) {
      at++;
    }
    if (at < bytes.length && bytes[at] == 0x0d && at + 1 < bytes.length && bytes[at + 1] == 0x0a) at++;
    if (at < bytes.length) at++;
  }
  return at;
}

/// Write to Text File: [text] written at the current position. A path opens or creates the
/// file, writes and closes; a refnum stays open and is returned.
({LvRefnum refnumOut, bool cancelled, LvError errorOut}) lvWriteToTextFile(
  Object fileOrPath,
  String text, {
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (refnumOut: _passed(fileOrPath), cancelled: false, errorOut: errorIn);
  final resolved = _resolveFile(fileOrPath, 'Write to Text File', write: true);
  final open = resolved.open;
  if (open == null) return (refnumOut: LvRefnum.none, cancelled: false, errorOut: resolved.errorOut);
  try {
    if (resolved.opened) open.file.truncateSync(0);
    open.file.writeFromSync(latin1.encode(text));
    if (resolved.opened) lvCloseFile(resolved.refnum);
    return (refnumOut: resolved.opened ? LvRefnum.none : resolved.refnum, cancelled: false, errorOut: LvError.none);
  } catch (error) {
    if (resolved.opened) lvCloseFile(resolved.refnum);
    return (refnumOut: LvRefnum.none, cancelled: false, errorOut: _ioError('Write to Text File', error));
  }
}

/// Read From Binary File of a byte string: [count] bytes (a negative count reads the rest) as a
/// Latin-1 string, without a size header.
({LvRefnum refnumOut, String data, bool cancelled, LvError errorOut}) lvReadBytesFromBinaryFile(
  Object fileOrPath, {
  int count = -1,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (refnumOut: _passed(fileOrPath), data: '', cancelled: false, errorOut: errorIn);
  final resolved = _resolveFile(fileOrPath, 'Read From Binary File');
  final open = resolved.open;
  if (open == null) return (refnumOut: LvRefnum.none, data: '', cancelled: false, errorOut: resolved.errorOut);
  try {
    final remaining = open.file.lengthSync() - open.file.positionSync();
    final wanted = count < 0 ? remaining : (count > remaining ? remaining : count);
    final bytes = open.file.readSync(wanted < 0 ? 0 : wanted);
    final error = count >= 0 && bytes.length < count
        ? LvErrorCode.endOfFile.error('Read From Binary File')
        : LvError.none;
    if (resolved.opened) lvCloseFile(resolved.refnum);
    return (
      refnumOut: resolved.opened ? LvRefnum.none : resolved.refnum,
      data: latin1.decode(bytes),
      cancelled: false,
      errorOut: error,
    );
  } catch (error) {
    if (resolved.opened) lvCloseFile(resolved.refnum);
    return (refnumOut: LvRefnum.none, data: '', cancelled: false, errorOut: _ioError('Read From Binary File', error));
  }
}

/// Write To Binary File of flat bytes.
({LvRefnum refnumOut, bool cancelled, LvError errorOut}) lvWriteBytesToBinaryFile(
  Object fileOrPath,
  Uint8List bytes, {
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (refnumOut: _passed(fileOrPath), cancelled: false, errorOut: errorIn);
  final resolved = _resolveFile(fileOrPath, 'Write To Binary File', write: true);
  final open = resolved.open;
  if (open == null) return (refnumOut: LvRefnum.none, cancelled: false, errorOut: resolved.errorOut);
  try {
    if (resolved.opened) open.file.truncateSync(0);
    open.file.writeFromSync(bytes);
    if (resolved.opened) lvCloseFile(resolved.refnum);
    return (refnumOut: resolved.opened ? LvRefnum.none : resolved.refnum, cancelled: false, errorOut: LvError.none);
  } catch (error) {
    if (resolved.opened) lvCloseFile(resolved.refnum);
    return (refnumOut: LvRefnum.none, cancelled: false, errorOut: _ioError('Write To Binary File', error));
  }
}

/// Get File Size, of an open file or a path.
({LvRefnum refnumOut, int size, LvError errorOut}) lvGetFileSize(Object fileOrPath, {LvError errorIn = LvError.none}) {
  if (errorIn.status) return (refnumOut: _passed(fileOrPath), size: 0, errorOut: errorIn);
  if (fileOrPath is LvPath) {
    try {
      return (refnumOut: LvRefnum.none, size: File(_nativePath(fileOrPath)).lengthSync(), errorOut: LvError.none);
    } catch (error) {
      return (refnumOut: LvRefnum.none, size: 0, errorOut: _ioError('Get File Size', error));
    }
  }
  final open = fileOrPath is LvRefnum ? _openFile(fileOrPath) : null;
  if (open == null) {
    return (refnumOut: LvRefnum.none, size: 0, errorOut: LvErrorCode.invalidReference.error('Get File Size'));
  }
  return (refnumOut: fileOrPath as LvRefnum, size: open.file.lengthSync(), errorOut: LvError.none);
}

/// Set File Size: truncates or extends the open file to [size].
({LvRefnum refnumOut, LvError errorOut}) lvSetFileSize(LvRefnum refnum, int size, {LvError errorIn = LvError.none}) {
  if (errorIn.status) return (refnumOut: refnum, errorOut: errorIn);
  final open = _openFile(refnum);
  if (open == null) return (refnumOut: LvRefnum.none, errorOut: LvErrorCode.invalidReference.error('Set File Size'));
  try {
    open.file.truncateSync(size);
    return (refnumOut: refnum, errorOut: LvError.none);
  } catch (error) {
    return (refnumOut: refnum, errorOut: _ioError('Set File Size', error));
  }
}

/// Get File Position.
({LvRefnum refnumOut, int offset, LvError errorOut}) lvGetFilePosition(
  LvRefnum refnum, {
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (refnumOut: refnum, offset: 0, errorOut: errorIn);
  final open = _openFile(refnum);
  if (open == null) {
    return (refnumOut: LvRefnum.none, offset: 0, errorOut: LvErrorCode.invalidReference.error('Get File Position'));
  }
  return (refnumOut: refnum, offset: open.file.positionSync(), errorOut: LvError.none);
}

/// Set File Position: [offset] bytes from the start, the end or the current position.
({LvRefnum refnumOut, LvError errorOut}) lvSetFilePosition(
  LvRefnum refnum, {
  int offset = 0,
  int from = 0,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (refnumOut: refnum, errorOut: errorIn);
  final open = _openFile(refnum);
  final origin = LvFilePositionFrom.ofCode(from);
  if (open == null) {
    return (refnumOut: LvRefnum.none, errorOut: LvErrorCode.invalidReference.error('Set File Position'));
  }
  if (origin == null) return (refnumOut: refnum, errorOut: LvErrorCode.invalidArgument.error('Set File Position'));
  try {
    final base = switch (origin) {
      LvFilePositionFrom.start => 0,
      LvFilePositionFrom.end => open.file.lengthSync(),
      LvFilePositionFrom.current => open.file.positionSync(),
    };
    open.file.setPositionSync(base + offset);
    return (refnumOut: refnum, errorOut: LvError.none);
  } catch (error) {
    return (refnumOut: refnum, errorOut: _ioError('Set File Position', error));
  }
}

/// Create Folder: the directory at [path], with any missing parents; one that exists is
/// [LvErrorCode.duplicatePath].
({LvPath createdPath, bool cancelled, LvError errorOut}) lvCreateFolder(LvPath path, {LvError errorIn = LvError.none}) {
  if (errorIn.status) return (createdPath: LvPath.notAPath, cancelled: false, errorOut: errorIn);
  if (!path.valid || path.isEmpty) {
    return (createdPath: LvPath.notAPath, cancelled: false, errorOut: LvErrorCode.invalidPath.error('Create Folder'));
  }
  try {
    final directory = Directory(_nativePath(path));
    if (directory.existsSync()) {
      return (createdPath: path, cancelled: false, errorOut: LvErrorCode.duplicatePath.error('Create Folder'));
    }
    directory.createSync(recursive: true);
    return (createdPath: path, cancelled: false, errorOut: LvError.none);
  } catch (error) {
    return (createdPath: LvPath.notAPath, cancelled: false, errorOut: _ioError('Create Folder', error));
  }
}

/// Delete: the file or directory at [path]; a directory with contents needs [entireHierarchy].
({LvPath deletedPath, bool cancelled, LvError errorOut}) lvDelete(
  LvPath path, {
  bool entireHierarchy = false,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (deletedPath: LvPath.notAPath, cancelled: false, errorOut: errorIn);
  if (!path.valid || path.isEmpty) {
    return (deletedPath: LvPath.notAPath, cancelled: false, errorOut: LvErrorCode.invalidPath.error('Delete'));
  }
  try {
    final native = _nativePath(path);
    final type = FileSystemEntity.typeSync(native, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return (deletedPath: LvPath.notAPath, cancelled: false, errorOut: LvErrorCode.fileNotFound.error('Delete'));
    }
    if (type == FileSystemEntityType.directory) {
      final directory = Directory(native);
      if (!entireHierarchy && directory.listSync().isNotEmpty) {
        return (
          deletedPath: LvPath.notAPath,
          cancelled: false,
          errorOut: LvErrorCode.filePermission.error('Delete: the folder is not empty'),
        );
      }
      directory.deleteSync(recursive: entireHierarchy);
    } else {
      File(native).deleteSync();
    }
    return (deletedPath: path, cancelled: false, errorOut: LvError.none);
  } catch (error) {
    return (deletedPath: LvPath.notAPath, cancelled: false, errorOut: _ioError('Delete', error));
  }
}

/// Copy: [sourcePath] to [targetPath], refusing an existing target unless [overwrite].
({LvPath newPath, bool cancelled, LvError errorOut}) lvCopy(
  LvPath sourcePath,
  LvPath targetPath, {
  bool overwrite = false,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (newPath: LvPath.notAPath, cancelled: false, errorOut: errorIn);
  if (!sourcePath.valid || !targetPath.valid || sourcePath.isEmpty || targetPath.isEmpty) {
    return (newPath: LvPath.notAPath, cancelled: false, errorOut: LvErrorCode.invalidPath.error('Copy'));
  }
  try {
    final target = _nativePath(targetPath);
    if (!overwrite && FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      return (newPath: LvPath.notAPath, cancelled: false, errorOut: LvErrorCode.duplicatePath.error('Copy'));
    }
    File(_nativePath(sourcePath)).copySync(target);
    return (newPath: targetPath, cancelled: false, errorOut: LvError.none);
  } catch (error) {
    return (newPath: LvPath.notAPath, cancelled: false, errorOut: _ioError('Copy', error));
  }
}

/// Move: [sourcePath] to [targetPath], refusing an existing target unless [overwrite].
({LvPath newPath, bool cancelled, LvError errorOut}) lvMove(
  LvPath sourcePath,
  LvPath targetPath, {
  bool overwrite = false,
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (newPath: LvPath.notAPath, cancelled: false, errorOut: errorIn);
  if (!sourcePath.valid || !targetPath.valid || sourcePath.isEmpty || targetPath.isEmpty) {
    return (newPath: LvPath.notAPath, cancelled: false, errorOut: LvErrorCode.invalidPath.error('Move'));
  }
  try {
    final source = _nativePath(sourcePath), target = _nativePath(targetPath);
    if (!overwrite && FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      return (newPath: LvPath.notAPath, cancelled: false, errorOut: LvErrorCode.duplicatePath.error('Move'));
    }
    if (FileSystemEntity.isDirectorySync(source)) {
      Directory(source).renameSync(target);
    } else {
      File(source).renameSync(target);
    }
    return (newPath: targetPath, cancelled: false, errorOut: LvError.none);
  } catch (error) {
    return (newPath: LvPath.notAPath, cancelled: false, errorOut: _ioError('Move', error));
  }
}

/// File/Directory Info: whether [path] is a directory, its size in bytes (a directory's is its
/// entry count), its last modification time, and the path itself; a symbolic link resolves
/// to its target in `resolvedPath` and sets `shortcut`.
({
  LvPath pathOut,
  bool directory,
  int size,
  LvTimestamp lastMod,
  LvPath resolvedPath,
  bool shortcut,
  LvError errorOut,
})
lvFileDirectoryInfo(LvPath path, {LvError errorIn = LvError.none}) {
  ({
    LvPath pathOut,
    bool directory,
    int size,
    LvTimestamp lastMod,
    LvPath resolvedPath,
    bool shortcut,
    LvError errorOut,
  })
  failed(LvError error) => (
    pathOut: LvPath.notAPath,
    directory: false,
    size: 0,
    lastMod: LvTimestamp.epoch,
    resolvedPath: LvPath.notAPath,
    shortcut: false,
    errorOut: error,
  );
  if (errorIn.status) return failed(errorIn);
  if (!path.valid || path.isEmpty) return failed(LvErrorCode.invalidPath.error('File/Directory Info'));
  try {
    final native = _nativePath(path);
    final type = FileSystemEntity.typeSync(native, followLinks: false);
    if (type == FileSystemEntityType.notFound) return failed(LvErrorCode.fileNotFound.error('File/Directory Info'));
    final shortcut = type == FileSystemEntityType.link;
    final resolved = shortcut ? lvPathOfString(File(native).resolveSymbolicLinksSync()) : path;
    final stat = FileStat.statSync(native);
    final directory = stat.type == FileSystemEntityType.directory;
    final size = directory ? Directory(native).listSync().length : stat.size;
    return (
      pathOut: path,
      directory: directory,
      size: size,
      lastMod: lvTimestampOfDateTime(stat.modified),
      resolvedPath: resolved,
      shortcut: shortcut,
      errorOut: LvError.none,
    );
  } catch (error) {
    return failed(_ioError('File/Directory Info', error));
  }
}

/// List Folder: the file names and folder names directly under [path], each list sorted as
/// Sort 1D Array sorts strings; [pattern] filters the file names with `*` and `?` wildcards.
({LvPath pathOut, List<String> fileNames, List<String> folderNames, LvError errorOut}) lvListFolder(
  LvPath path, {
  String pattern = '',
  LvError errorIn = LvError.none,
}) {
  if (errorIn.status) return (pathOut: LvPath.notAPath, fileNames: const [], folderNames: const [], errorOut: errorIn);
  if (!path.valid) {
    return (
      pathOut: LvPath.notAPath,
      fileNames: const [],
      folderNames: const [],
      errorOut: LvErrorCode.invalidPath.error('List Folder'),
    );
  }
  try {
    final directory = Directory(path.isEmpty ? Directory.current.path : _nativePath(path));
    final files = <String>[], folders = <String>[];
    final matcher = pattern.isEmpty
        ? null
        : RegExp('^${RegExp.escape(pattern).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$');
    for (final entry in directory.listSync(followLinks: false)) {
      final name = entry.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
      if (entry is Directory) {
        folders.add(name);
      } else if (matcher == null || matcher.hasMatch(name)) {
        files.add(name);
      }
    }
    files.sort(lvCompareStrings);
    folders.sort(lvCompareStrings);
    return (pathOut: path, fileNames: files, folderNames: folders, errorOut: LvError.none);
  } catch (error) {
    return (
      pathOut: LvPath.notAPath,
      fileNames: const [],
      folderNames: const [],
      errorOut: _ioError('List Folder', error),
    );
  }
}
