List<String> addRecent(List<String> current, String path, {int cap = 8}) {
  final out = <String>[path, ...current.where((p) => p != path)];
  if (out.length > cap) out.removeRange(cap, out.length);
  return out;
}
