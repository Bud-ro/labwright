import 'block_diagram.dart';

/// Editing a VI through its model: the diagram's root frame to place in, the panel's
/// controls and indicators, wiring, and [write] to put the heaps back into the sections.
/// Every object id and type slot an edit takes comes from the model, so what is added is
/// consistent with what was loaded.
mixin ViEditing {
  BdEditor get blockDiagram;

  /// The block diagram's root frame.
  BdFrame get diagram => blockDiagram.diagram;

  /// Places [item] on the block diagram.
  T add<T extends BdPlaced>(T item) => diagram.add(item);

  /// A new control of [type] named [name] on the panel, its terminal in [frame], the diagram
  /// itself unless given.
  BdPanelTerminal control(BdType type, String name, {BdFrame? frame}) => blockDiagram.control(type, name, frame: frame);

  /// A new indicator of [type] named [name] on the panel, its terminal in [frame], the
  /// diagram itself unless given.
  BdPanelTerminal indicator(BdType type, String name, {BdFrame? frame}) =>
      blockDiagram.indicator(type, name, frame: frame);

  /// Wires [source] to [sink]; see [BdEditor.connect].
  BdWire connect(BdEndpoint source, BdEndpoint sink, {BdType? type}) => blockDiagram.connect(source, sink, type: type);

  /// Writes the edited heaps back into the model's sections.
  void write() => blockDiagram.write();
}
