# labwright_teststand_inspector

A standalone Flutter **desktop** app for inspecting NI **TestStand** `.seq` files
through the clean-room [`labwright_teststand`](../../packages/labwright_teststand)
reader. It exists to make the reader's output visible — to catch obvious errors
and give inspectability into what the parser actually recovers.

Open a `.seq` (button, drag-and-drop, or `flutter run -- path/to/file.seq`):

- **XML** sequence files render the faithful sequence dump — sequences, steps
  (type, module/adapter binding, flow, limits, mode), parameters and locals.
- **Binary `TOF1`** files render an honest recon view: the decoded header, the
  inflated body size, and the largest recovered string table. The record tree is
  *not yet decoded*, and the view says so.
- Anything else renders the sniffed header plus the parse error.

Not part of the root Dart pub workspace (its Flutter SDK dependency is
incompatible with plain `dart` tooling); it carries its own `analysis_options.yaml`.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos   # or -d linux / -d windows
```
