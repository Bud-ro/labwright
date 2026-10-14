/// `CPMp` - Connector Pane Map: [ViConnectorPaneMap]
///
/// Which front-panel data item each connector-pane terminal is wired to.
///
/// TODO: It's worth pointing this to our code that does pane terminal ordering once we have it.
/// `terminals` follows pane order (see: https://labviewwiki.org/wiki/Connector_pane).
/// `0xFFFF` means that terminal is unwired. Files saved without this block (4,244 of 7,470)
/// bind each terminal through the control's own `conNum` attribute instead; [connectorPaneTerminals]
/// reads both.
///
/// `count` equals [ViFunctionType.parameterCount] of the pane's type (`CONP`) in every one of
/// the 4127 files that have both, so terminal `i` pairs with parameter `i`. A wired terminal's
/// word is a 0-based index into the panel's data-item cluster, [ViFrontPanelType.panelItemsIn]
/// from `FPTD`: `items.memberIndexAt(word)` is the descriptor of the control or indicator the
/// terminal is wired to, the same descriptor as the parameter in 17954 of 18076 wired
/// terminals and one sharing its label in the other 6. The 116 remaining words, always the
/// first terminal's, are stored big-endian (`00 01` where every other word is `01 00`); read
/// as written they index nothing, read swapped they obey the law. Which saves do that is TODO.
/// The cluster lists every data item, wired or not, in tabbing order; the panel heap stores
/// the same top-level controls last-first, which is why their reversed heap order agrees with
/// the cluster in 4086 of 4106 panels and differs in dialogs with tab controls or several panes.
///
/// ```text
/// offset  size    field     type         meaning
/// 0       2       count     u16le        Number of pane terminals.
/// 2       2·count terminals u16le[count] 0-based member of the FPTD data-item cluster, 0xFFFF when unwired.
/// ```
library;

import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import 'FPTD_front_panel_datalog_type.dart';
import 'VCTP_type_pool.dart';

const _unassignedWord = 0xFFFF;

/// What a pane terminal is wired to.
sealed class ConnectorTerminal {
  const ConnectorTerminal();
}

/// The terminal is not assigned to any panel data item (the word `0xFFFF`).
final class UnassignedTerminal extends ConnectorTerminal {
  const UnassignedTerminal();
}

/// The terminal is wired to the panel data item [index] names, a member of the cluster
/// [ViFrontPanelType.panelItemsIn] returns.
final class PanelObjectTerminal extends ConnectorTerminal {
  const PanelObjectTerminal(this.index);

  final int index;

  @override
  bool operator ==(Object other) => other is PanelObjectTerminal && other.index == index;

  @override
  int get hashCode => index;
}

final class ViConnectorPaneMap extends ByteRecord {
  ViConnectorPaneMap(Uint8List bytes) : super(bytes, layout) {
    assert(_terminals.endIn(view) == view.lengthInBytes, 'the terminals tile the payload');
  }

  /// Number of pane terminals.
  int get length => _count.read(view);

  ConnectorTerminal operator [](int index) {
    final word = _terminals.at(view, index);
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

  /// The terminal words in pane order, 0xFFFF for an unwired one.
  List<int> get words => _terminals.read(view);

  static Uint8List encode(List<int> terminals) {
    final out = Uint8List(_terminals.offset + _terminals.wordSize * terminals.length);
    final view = ByteData.sublistView(out);
    _count.write(view, terminals.length);
    _terminals.write(view, terminals);
    return out;
  }

  // dart format off
  static const _count = U16(0, endian: Endian.little);
  static const _terminals = U16List(2, endian: Endian.little, count: _count); // 0-based member of the FPTD data-item cluster, 0xFFFF when unwired.

  static const layout = ByteLayout([_count, _terminals]);
  // dart format on
}
