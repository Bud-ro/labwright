import 'package:flutter/material.dart';

/// The monospace font family used across the inspector's code/data views — one
/// documented source so every fixed-width listing stays consistent (and the
/// app's mono font can be changed in a single place).
const monoFamily = 'monospace';

/// The base monospace text style for inspector listings (12pt). Compose variants
/// with `copyWith` (color/size/weight); styles that intentionally omit a size
/// (so they inherit one) use [monoFamily] directly instead of this.
const monoStyle = TextStyle(fontFamily: monoFamily, fontSize: 12);

/// The standard corner radius for the inspector's small tinted surfaces (info
/// boxes, sequence cards, adapter chips) — one documented source so they round
/// consistently.
const cornerRadius = 6.0;
