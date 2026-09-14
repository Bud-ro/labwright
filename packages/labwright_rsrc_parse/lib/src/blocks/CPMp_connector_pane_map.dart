/// `CPMp` — connector pane map: for each pane terminal, the panel data item it is wired to.
///
/// ```text
/// offset  size  field                      type     meaning
/// 0       2     count                      u16le    number of pane terminals
/// 2       rest  terminals                  u16le[count] panel data-item index per terminal; 0xFFFF
///                                                       when unassigned
/// ```
///
/// [ViConnectorPaneMap] is a view over the payload whose terminals are [ConnectorTerminal]s;
/// [decodeConnectorPaneMap] requires the count to tile the payload exactly.
library;

import 'dart:typed_data';

import '../block_layout.dart';
import '../block_record.dart';

const _count = BlockField(0, 2, 'count', 'u16le', 'number of pane terminals');
const _terminals = BlockField(
  2,
  null,
  'terminals',
  'u16le[count]',
  'panel data-item index per terminal; 0xFFFF when unassigned',
);

const BlockLayout cpmpLayout = [_count, _terminals];

const _unassignedWord = 0xFFFF;

/// What a pane terminal is wired to.
sealed class ConnectorTerminal {
  const ConnectorTerminal();
}

/// The terminal is not assigned to any panel data item (the word `0xFFFF`).
final class UnassignedTerminal extends ConnectorTerminal {
  const UnassignedTerminal();
}

/// The terminal is wired to the panel data item at [index].
final class PanelObjectTerminal extends ConnectorTerminal {
  const PanelObjectTerminal(this.index);

  final int index;

  @override
  bool operator ==(Object other) => other is PanelObjectTerminal && other.index == index;

  @override
  int get hashCode => index;
}

/// A view over a `CPMp` payload.
class ViConnectorPaneMap implements BlockRecord {
  ViConnectorPaneMap._(this.bytes) : _view = ByteData.sublistView(bytes);

  final Uint8List bytes;

  final ByteData _view;

  int get length => _view.getUint16(_count.offset, Endian.little);

  ConnectorTerminal operator [](int index) {
    final word = _view.getUint16(_terminals.offset + 2 * index, Endian.little);
    return word == _unassignedWord ? const UnassignedTerminal() : PanelObjectTerminal(word);
  }

  List<ConnectorTerminal> get terminals => [for (var i = 0; i < length; i++) this[i]];

  int get assignedCount {
    var n = 0;
    for (var i = 0; i < length; i++) {
      if (this[i] is PanelObjectTerminal) n++;
    }
    return n;
  }

  @override
  Uint8List serialize() => bytes;
}

ViConnectorPaneMap decodeConnectorPaneMap(Uint8List bytes) {
  assert(bytes.length >= _count.end, 'a pane map starts with its count');
  assert(
    _count.end + 2 * ByteData.sublistView(bytes).getUint16(_count.offset, Endian.little) == bytes.length,
    'the terminals tile the payload',
  );
  return ViConnectorPaneMap._(bytes);
}
