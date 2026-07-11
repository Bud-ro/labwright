/// Review state of the bundled primitive icon assets (assets/prim_icons/).
///
/// Every extracted identity gets an entry — extraction NEVER silently drops
/// or hides an id; one that produced no usable asset still appears in
/// `assets/prim_icons/MANIFEST.md` with the reason. Statuses are the
/// maintainer's incremental verdicts:
///
/// - [PrimIconStatus.verified] — eyeballed against a VI render; stamped.
/// - [PrimIconStatus.verifiedHand] — eyeballed and confirmed, but the pixels
///   are hand-finished (wires shaved, junk cleared) rather than raw pipeline
///   output, so the reproducibility contract keeps the committed asset
///   authoritative instead of byte-comparing it against a fresh extraction.
/// - [PrimIconStatus.unverified] — extracted but not yet reviewed; stamped
///   (that is how it gets reviewed in context) and labelled in the detail
///   card.
/// - [PrimIconStatus.rejected] — reviewed and wrong; never stamped (the node
///   falls back to the plate + operator glyph) until a better extraction or
///   a hand-drawn replacement lands.
///
/// The generator (`test/extract_prim_icons_test.dart`) rewrites the entry
/// list when assets regenerate but PRESERVES the statuses recorded here;
/// only new keys default to [PrimIconStatus.unverified].
enum PrimIconStatus { verified, verifiedHand, unverified, rejected }

// GENERATED-ENTRIES-BEGIN (extract_prim_icons_test.dart rewrites this block;
// statuses are preserved — edit them freely.)
const Map<String, PrimIconStatus> kPrimIconStatus = {
  'class108': PrimIconStatus.unverified,
  'class147': PrimIconStatus.unverified,
  'class185': PrimIconStatus.verifiedHand,
  'class370': PrimIconStatus.unverified,
  'class52': PrimIconStatus.unverified,
  'class58': PrimIconStatus.unverified,
  'class62': PrimIconStatus.unverified,
  'class68': PrimIconStatus.verified,
  'prim1050': PrimIconStatus.unverified,
  'prim1051': PrimIconStatus.unverified,
  'prim1052': PrimIconStatus.unverified,
  'prim1056': PrimIconStatus.unverified,
  'prim1057': PrimIconStatus.unverified,
  'prim1058': PrimIconStatus.unverified,
  'prim1061': PrimIconStatus.unverified,
  'prim1062': PrimIconStatus.unverified,
  'prim1063': PrimIconStatus.verifiedHand,
  'prim1064': PrimIconStatus.unverified,
  'prim1069': PrimIconStatus.unverified,
  'prim1070': PrimIconStatus.unverified,
  'prim1077': PrimIconStatus.unverified,
  'prim1078': PrimIconStatus.unverified,
  'prim1081': PrimIconStatus.unverified,
  'prim1082': PrimIconStatus.unverified,
  'prim1102': PrimIconStatus.unverified,
  'prim1103': PrimIconStatus.unverified,
  'prim1105': PrimIconStatus.unverified,
  'prim1108': PrimIconStatus.unverified,
  'prim1110': PrimIconStatus.unverified,
  'prim1112': PrimIconStatus.unverified,
  'prim1113': PrimIconStatus.unverified,
  'prim1114': PrimIconStatus.unverified,
  'prim1116': PrimIconStatus.unverified,
  'prim1118': PrimIconStatus.unverified,
  'prim1120': PrimIconStatus.unverified,
  'prim1124': PrimIconStatus.unverified,
  'prim1127': PrimIconStatus.unverified,
  'prim1128': PrimIconStatus.unverified,
  'prim1141': PrimIconStatus.unverified,
  'prim1142': PrimIconStatus.verifiedHand,
  'prim1143': PrimIconStatus.verifiedHand,
  'prim1145': PrimIconStatus.unverified,
  'prim1147': PrimIconStatus.unverified,
  'prim1155': PrimIconStatus.unverified,
  'prim1156': PrimIconStatus.unverified,
  'prim1162': PrimIconStatus.unverified,
  'prim1163': PrimIconStatus.unverified,
  'prim1164': PrimIconStatus.unverified,
  'prim1166': PrimIconStatus.unverified,
  'prim1167': PrimIconStatus.unverified,
  'prim1170': PrimIconStatus.unverified,
  'prim1171': PrimIconStatus.unverified,
  'prim1180': PrimIconStatus.unverified,
  'prim1181': PrimIconStatus.unverified,
  'prim1184': PrimIconStatus.unverified,
  'prim1185': PrimIconStatus.unverified,
  'prim1188': PrimIconStatus.unverified,
  'prim1189': PrimIconStatus.unverified,
  'prim1213': PrimIconStatus.unverified,
  'prim1302': PrimIconStatus.unverified,
  'prim1303': PrimIconStatus.unverified,
  'prim1419': PrimIconStatus.unverified,
  'prim1420': PrimIconStatus.unverified,
  'prim1421': PrimIconStatus.unverified,
  'prim1435': PrimIconStatus.unverified,
  'prim1502': PrimIconStatus.unverified,
  'prim1503': PrimIconStatus.unverified,
  'prim1516': PrimIconStatus.unverified,
  'prim1534': PrimIconStatus.unverified,
  'prim1535': PrimIconStatus.unverified,
  'prim1537': PrimIconStatus.unverified,
  'prim1539': PrimIconStatus.unverified,
  'prim1606': PrimIconStatus.verifiedHand,
  'prim1608': PrimIconStatus.verifiedHand,
  'prim1609': PrimIconStatus.unverified,
  'prim1809': PrimIconStatus.unverified,
  'prim1814': PrimIconStatus.verifiedHand,
  'prim1815': PrimIconStatus.verifiedHand,
  'prim1900': PrimIconStatus.verified,
  'prim1901': PrimIconStatus.unverified,
  'prim1904': PrimIconStatus.unverified,
  'prim1907': PrimIconStatus.unverified,
  'prim1908': PrimIconStatus.unverified,
  'prim1922': PrimIconStatus.unverified,
  'prim1925': PrimIconStatus.unverified,
  'prim1926': PrimIconStatus.unverified,
  'prim1927': PrimIconStatus.unverified,
  'prim2073': PrimIconStatus.unverified,
  'prim2074': PrimIconStatus.unverified,
  'prim2075': PrimIconStatus.unverified,
  'prim2076': PrimIconStatus.unverified,
  'prim2302': PrimIconStatus.unverified,
  'prim23063': PrimIconStatus.unverified,
  'prim2308': PrimIconStatus.unverified,
  'prim2452': PrimIconStatus.unverified,
  'prim2457': PrimIconStatus.unverified,
  'prim2458': PrimIconStatus.unverified,
  'prim3914': PrimIconStatus.unverified,
  'prim8003': PrimIconStatus.unverified,
  'prim8010': PrimIconStatus.unverified,
  'prim8011': PrimIconStatus.unverified,
  'prim8018': PrimIconStatus.unverified,
  'prim8050': PrimIconStatus.unverified,
  'prim8051': PrimIconStatus.unverified,
  'prim8052': PrimIconStatus.unverified,
  'prim8055': PrimIconStatus.unverified,
  'prim8056': PrimIconStatus.unverified,
  'prim8063': PrimIconStatus.unverified,
  'prim8065': PrimIconStatus.unverified,
  'prim8070': PrimIconStatus.unverified,
  'prim8073': PrimIconStatus.unverified,
  'prim8076': PrimIconStatus.unverified,
  'prim8082': PrimIconStatus.unverified,
  'prim8083': PrimIconStatus.unverified,
  'prim8101': PrimIconStatus.unverified,
  'prim8203': PrimIconStatus.unverified,
  'prim8204': PrimIconStatus.unverified,
  'prim8205': PrimIconStatus.unverified,
};
// GENERATED-ENTRIES-END

/// Where each icon's art sits within its node box, as the art top-left's
/// offset from the box top-left — MEASURED, not derived: each entry is the
/// unanimous position at which the asset's opaque pixels byte-match
/// LabVIEW's own reference render, censused across every snippet instance
/// (the trailing count). Placement is a fixed per-primitive property; no
/// centering rule reproduces it (25x11 art sits at x=3 in `prim1608` but
/// x=4 in `prim1142`). A negative offset is art overhanging the box
/// (`prim1162`'s 32x37 rises 5 px above it). Keys without an entry fall
/// back to floor-centring until an instance appears in the corpus to
/// measure.
///
/// Regenerate with
/// `flutter test test/placement_census_test.dart --dart-define=PRIM_PLACEMENT_CENSUS=1`.
// GENERATED-PLACEMENT-BEGIN
const Map<String, ({int dx, int dy})> kPrimIconPlacement = {
  'class58': (dx: 0, dy: 0), // x8
  'class62': (dx: 0, dy: 0), // x11
  'class68': (dx: 0, dy: 0), // x24
  'class147': (dx: 0, dy: 0), // x2
  'class185': (dx: 0, dy: 0), // x3
  'class370': (dx: 0, dy: 0), // x3
  'prim1061': (dx: -2, dy: 4), // x1
  'prim1062': (dx: 6, dy: 8), // x4
  'prim1063': (dx: 4, dy: 8), // x15
  'prim1077': (dx: 4, dy: 11), // x2
  'prim1081': (dx: -6, dy: 3), // x1
  'prim1082': (dx: -2, dy: 9), // x1
  'prim1110': (dx: 6, dy: 6), // x1
  'prim1120': (dx: 0, dy: 0), // x1
  'prim1127': (dx: 0, dy: 4), // x1
  'prim1142': (dx: 4, dy: 11), // x15
  'prim1143': (dx: 4, dy: 11), // x15
  'prim1156': (dx: 4, dy: 11), // x1
  'prim1162': (dx: 0, dy: -5), // x3
  'prim1163': (dx: 0, dy: -5), // x3
  'prim1166': (dx: 0, dy: 0), // x16
  'prim1171': (dx: -3, dy: 7), // x4
  'prim1180': (dx: 0, dy: 0), // x2
  'prim1181': (dx: 0, dy: -5), // x3
  'prim1185': (dx: 0, dy: 0), // x1
  'prim1302': (dx: 0, dy: 0), // x1
  'prim1419': (dx: 0, dy: 0), // x2
  'prim1420': (dx: 0, dy: 0), // x1
  'prim1502': (dx: 0, dy: 7), // x3
  'prim1503': (dx: 0, dy: -5), // x1
  'prim1534': (dx: 0, dy: 0), // x1
  'prim1535': (dx: 0, dy: 0), // x38
  'prim1539': (dx: 0, dy: 0), // x1
  'prim1606': (dx: 4, dy: 8), // x3
  'prim1608': (dx: 3, dy: 11), // x8
  'prim1809': (dx: 0, dy: 5), // x9
  'prim1814': (dx: 3, dy: 11), // x4
  'prim1815': (dx: 3, dy: 11), // x5
  'prim1900': (dx: 0, dy: 5), // x5
  'prim1901': (dx: 0, dy: 0), // x9
  'prim1907': (dx: 0, dy: 0), // x1
  'prim1922': (dx: 0, dy: 0), // x1
  'prim1925': (dx: 0, dy: 0), // x1
  'prim1926': (dx: 0, dy: 0), // x1
  'prim1927': (dx: 0, dy: 0), // x1
  'prim2308': (dx: 0, dy: 0), // x1
  'prim2452': (dx: 0, dy: 0), // x2
  'prim8010': (dx: 0, dy: 0), // x1
  'prim8018': (dx: 0, dy: 0), // x1
  'prim8050': (dx: 0, dy: 0), // x2
  'prim8051': (dx: 0, dy: 0), // x2
  'prim8052': (dx: 0, dy: 0), // x2
  'prim8056': (dx: 0, dy: 0), // x1
  'prim8065': (dx: 0, dy: 0), // x1
  'prim8076': (dx: 0, dy: 0), // x1
  'prim8082': (dx: 0, dy: 0), // x1
  'prim8083': (dx: 0, dy: 0), // x2
  'prim8101': (dx: 0, dy: 0), // x1
  'prim8203': (dx: 0, dy: 0), // x1
  'prim8204': (dx: 0, dy: 0), // x2
};
// GENERATED-PLACEMENT-END
