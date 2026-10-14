import 'package:labwright_rsrc_parse/labwright_rsrc_parse.dart';
import 'package:labwright_vi_transpile/labwright_vi_transpile.dart';
import 'package:test/test.dart';

void main() {
  test('a diagram built from the API computes what its signature says', () {
    final model = ViModel.empty();
    final editor = model.blockDiagram;
    final add = editor.diagram.add(
      BdPrimitive.create(editor, PrimOp.add, at: const HeapRect(top: 40, left: 40, bottom: 72, right: 72)),
    );
    final times = editor.diagram.add(
      BdPrimitive.create(editor, PrimOp.multiply, at: const HeapRect(top: 40, left: 140, bottom: 72, right: 172)),
    );
    editor.connect(add.terminal('x+y'), times.terminal('x'), type: 0x103);
    editor.write();
    final flow = buildLvDataflow(model.primaryBlockDiagram!, pool: model.types);
    expect(flow.refusal, isNull);
    expect(lvDataflowSignature(flow.dataflow!), 'u0 prim add\nu1 prim multiply\nu0.out0 -> u1.in0 : int\n');
  });
}
