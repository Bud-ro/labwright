/// `CPST` / `CPSP` - Polymorphic Instance Menu and Selector Names: [ViPolymorphicNames]
///
/// A polymorphic VI ([ViKind.polymorphic]) is a collection of VI instances with the same connector
/// pane pattern: https://www.ni.com/docs/en-US/bundle/labview/page/polymorphic-vis.html
/// The chosen VI can depend on the wire type when [ViOptionFlag.allowPolymorphicTypeAdapt] is set
/// otherwise it is chosen by the user using a dropdown selector.
///
/// The file keeps the instances in three places that are not redundant:
///
///   - `LIvi`: one `VIVI` link per instance, naming the instance VI's file and path, in link
///     order.
///   - `BDHb`: The polymorphic VI has no real diagram. Its heap holds one sub-VI node per
///     instance, all at the same position, under one frame whose child references list the
///     instances in menu order.
///   - `CPST` and `CPSP`: One caption per instance, in that menu order, the two columns of the
///     Edit Polymorphic VI dialog. Both are optional, since an instance's file name can stand-in.
///
/// `CPST` is the Menu Name: the entry in the node's right-click Select Type menu, where `:`
/// nests submenus, so `Compare:Equal:Value` reads Select Type > Compare > Equal > Value. `CPSP`
/// is the Selector Name: the text drawn in the polymorphic VI selector, the ring under the node
/// shown when [ViOptionFlag.showPolymorphicSelector] is set or the user shows it, so the same
/// instance reads `Equal (Value)` there.
///
/// ```text
/// offset  size  field    type        meaning
/// 0       4     count    u32
/// 4       …     strings  pstr[count] One name per instance.
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import '../byte_layout.dart';
import '../byte_record.dart';
import 'LVSR_save_record.dart';

final class ViPolymorphicNames extends ByteRecord {
  ViPolymorphicNames(Uint8List bytes) : super(bytes, layout) {
    final count = _count.read(view);
    assert(count <= view.lengthInBytes - _strings.offset, 'the count fits the payload');
    _stringOffsets = List<int>.filled(count, 0);
    var at = _strings.offset;
    for (var i = 0; i < count; i++) {
      assert(at < view.lengthInBytes, 'string $i has a length byte');
      _stringOffsets[i] = at;
      at = PStr.endAt(view, at);
    }
    assert(at == view.lengthInBytes, 'the strings tile the payload');
  }

  /// Number of instances.
  int get length => _stringOffsets.length;

  /// One instance's name, decoded byte for byte.
  String operator [](int index) {
    final at = _stringOffsets[index];
    return latin1.decode(Uint8List.sublistView(view, at + 1, PStr.endAt(view, at)));
  }

  List<String> get names => [for (var i = 0; i < length; i++) this[i]];

  late final List<int> _stringOffsets;

  static const _count = U32(0);
  static const _strings = PStrList(4, count: _count); // One name per instance.

  static const layout = ByteLayout([_count, _strings]);
}
