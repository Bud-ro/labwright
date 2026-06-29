# labwright_vi_inspector

Flutter-based clean-room VI viewer. Supports `.vi` / `.ctl` / `.llb` files.
Shows the full list of resource-blocks, as well as the front panels and
block diagrams. Each resource-block presents a hex editor style viewer,
with hex on one side and its parsed interpretation on the right.

This app is more of a novelty than anything. Executing, and in general, rescuing any logic
from `.vi` files is a non-necessary goal of Labwright. Instead this is simply being done to
explore the format in case other projects want to serve this justice. It seems very under-served as of right now
(see [this LabVIEW Idea Exchange post](https://forums.ni.com/t5/LabVIEW-Idea-Exchange/LabVIEW-Viewer/idi-p/1088985)).

A web version of this is planned.

## Running Locally

```sh
cd apps/labwright_vi_inspector
flutter pub get
flutter run -d linux  # (or -d macos / -d windows / -d chrome)
flutter analyze
flutter test
```

## Trademarks

LabVIEW™ is a trademark of National Instruments. Neither Labwright, nor any software programs
or other goods or services offered by Labwright, are affiliated with, endorsed by, or sponsored
by National Instruments. This app is a clean-room viewer for the `.vi` / `.ctl` / `.llb` file
formats and is not an NI product.

## License
BSD-3-Clause.
