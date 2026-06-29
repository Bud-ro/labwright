# Labwright

Labwright is an open, cross-platform, Dart-based framework intended for writing End to End (E2E) 
tests with hardware in the loop (HIL). The design is similar to that of the `integration_test`
package, but with additional concerns such as traceability (E2E tests are often written to verify
a specific requirement), DAQ awareness, sharding of tests, refined data capturing and test reports,
etc.

Additionally, this project aims to create software that increases the openness of existing
lab and testing software. For this reason, a variety of formats and libraries have clean-room
parsers/viewers/implementations developed. The main one being National Instruments' (NI)
TestStand™ `.seq` sequence format, and--consequently due to the tie in--the LabVIEW™ `.vi`
format. The main benefit to doing this is allowing for the partial or even complete export of
TestStand™ sequence logic to an equivalent Labwright framework code representation (or even
the other way around!).

Interpretation/compilation/running of `.vi` is out of scope for this project. Instead we 
opt for wrapping the libraries a necessary `.vi` wraps, or for writing our own device drivers.

## Development

Requires Dart 3.10. The packages share one native [pub workspace](pubspec.yaml).

```sh
dart pub get
dart analyze
dart test packages # Run all tests
```

## Why Dart

It might be more interesting to first ask why Dart, Python, TypeScript, etc. are not
expressly _disallowed_ when looking at solutions to E2E testing:
- E2E tests occupy the space of tests which take the longest to run and are 
  not CPU-bound. This inherently is due to waiting on results from real 
  world processes that generally take milliseconds or more to execute. 
  Any sub-millisecond work is performed by dedicated hardware with buffering.

This leads to asking what the more dynamic languages offer:
- E2E testing involves doing a LOT. It's extremely helpful to be able to pull 
  mature and useful 3rd party dependencies for things functions that aren't our focus. 
  Package managers make this easy.
- Easier to write/read. Important for when matching requirements is a must,
  and where users won't necessarily have a strong software background.
- Cross-platform development and execution

So what does Dart offer _specifically_?:
- Every package in Dart is a library. This pushes developers to write code
  in such a way that they are users of their own library, and thus it is easy to
  depend on that library from other packages/apps later.
- Dart analyzer: The tooling is phenomenal. The default lints are helpful,
  and you can opt into stronger and stronger subsets of the language by using
  more built-in lints. At the limit you can write an [analyzer plugin](https://dart.dev/tools/analyzer-plugins)
  (or use one built by someone else) to add custom diagnostics. As Labwright grows
  there will inevitably be edge cases or discovered abuses of the API that can't
  be written away (maybe not even with a breaking change). The ability to encode
  those programmatically, and automatically discover them are game-changing.

  The biggest benefit here is that developers can learn how the language works simply
  by reading and fixing analyzer warnings.
- The type system is not bolted on like TypeScript's or Python's
- The package manager `pub.dev` is on par with `npm`. We don't talk about Python's package management...
  Plus the upside here is that micro-packages are not an epidemic like on `npm`. This partially comes
  from Dart having an actual standard library that doesn't need to work around JavaScript's weirdness.
  e.g.: dealing with byte data is annoying, and something we need to do often in this space. `package:typed_data`
  does it extremely well. 
- Developers and QA will want to build dashboards, interfaces, etc. Flutter is fantastic for this.
- Generally the solutions here are lighter than comparative JS ones.

## Legal

All files unless otherwise noted are provided under the BSD three clause license. See [LICENSE](LICENSE).

TestStand™ and LabVIEW™ are trademarks of National Instruments. Neither Labwright, nor any
software programs or other goods or services offered by Labwright, are affiliated with,
endorsed by, or sponsored by National Instruments. References to these products throughout
this project are nominative — used only to identify the file formats and tools that Labwright
reads and interoperates with. No package, app, or logo in this repository is named after an
NI trademark. See NI's [trademark and logo guidelines](https://www.ni.com/en/about-ni/legal/trademarks-and-logo-guidelines.html).
