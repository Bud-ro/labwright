import 'dart:typed_data';

class ViHistory {
  const ViHistory({required this.rawLength, required this.words});

  final int rawLength;

  final List<int> words;

  int get formatVersion => words[0];

  int get flags => words[1];

  int get entryCount => words[2];

  bool get reservedAreZero => words[3] == 0 && words[7] == 0 && words[8] == 0;

  Uint8List serialize() {
    final out = Uint8List(_histWords * _wordBytes);
    final data = ByteData.sublistView(out);
    for (var wordIndex = 0; wordIndex < _histWords; wordIndex++) {
      data.setUint32(wordIndex * _wordBytes, words[wordIndex]);
    }
    return out;
  }
}

const int _histWords = 10;

const int _wordBytes = 4;

ViHistory? decodeHistory(Uint8List bytes) {
  if (bytes.length < _histWords * _wordBytes) return null;
  final data = ByteData.sublistView(bytes);
  return ViHistory(
    rawLength: bytes.length,
    words: [for (var wordIndex = 0; wordIndex < _histWords; wordIndex++) data.getUint32(wordIndex * _wordBytes)],
  );
}
