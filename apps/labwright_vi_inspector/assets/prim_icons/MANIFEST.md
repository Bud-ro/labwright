# Primitive icon assets

Generated from LabVIEW's own renders in the snippet corpus (see
test/extract_prim_icons_test.dart): per identity, the samples are
aligned and consensus-voted per pixel (attached wires and neighbour
ink vanish where the samples disagree), edge-touching wire stubs are
erased, the result is trimmed to its ink and the exterior background
made transparent. Hand-edits welcome — the painter stamps these at
natural size.

| asset | op | size | sources |
|---|---|---|---|

Palette (9 colours — every icon pixel is one of these): #000000 #0000ff #333333 #444444 #4c4c3d #666666 #aaaaaa #ffffcc #ffffff

| class147 | (verified — committed asset authoritative) | | border-exact rect (2/2 ring samples agree byte-for-byte): example, Excel_Read_XLSX |
| class370.png | class 0x172 | 32x18 | border-exact rect (1/1 ring samples agree byte-for-byte): Excel_Variant_Elements |
| class389.png | class 0x185 | 41x49 | border-exact rect (1/1 ring samples agree byte-for-byte): GenerateTree |
| class52.png | class 0x34 | 32x41 | border-exact rect (1/1 ring samples agree byte-for-byte): Excel_Variant_Elements |
| class68 | (verified — committed asset authoritative) | | border-exact rect (7/7 ring samples agree byte-for-byte): ClassChildren, Config_Dump2 |
| prim1050_add.png | Add | 29x28 | GenerateTree, IconHeader, MD5, basic — single-sample fallback (0/8 agreeing) |
| prim1052_multiply.png | Multiply | 35x25 | Config_Load2, Config_Load, Excel_Read_XLSX, IconHeader, MD5 — single-sample fallback (0/8 agreeing) |
| prim1061_and.png | And | 30x20 | large, MD5 — pair-seeded consensus (3/5 agreeing) |
| prim1063 | (verified — committed asset authoritative) | | MD5, crc8, crc16 — single-sample fallback after edge fusion (2/8 agreeing) |
| prim1064_not.png | Not | 29x19 | Excel_Read_XLSX, ClassChildren, GenerateTree, MD5 — single-sample fallback (0/7 agreeing) |
| prim1070_random-number-0-1.png | Random Number (0-1) | 19x21 | Excel_Read_XLSX, IconHeader — single-sample fallback (0/4 agreeing) |
| prim1077_path-to-string.png | Path To String | 25x11 | Export Palette Image WMF, Excel_Read_XLSX, large — single-sample fallback (0/5 agreeing) |
| prim1082.png | (uncatalogued) | 37x15 | MD5 — single-sample fallback (0/1 agreeing) |
| prim1102_equal.png | Equal? | 21x21 | Excel_Read_XLSX, ClassChildren, GenerateTree — single-sample fallback (0/6 agreeing) |
| prim1103.png | (uncatalogued) | 21x21 | Read VI Blocks, Config_Escape — single-sample fallback (0/2 agreeing) |
| prim1105_not-equal.png | Not Equal? | 22x21 | large — single-sample fallback (0/2 agreeing) |
| prim1110_greater.png | Greater? | 32x25 | example — single-sample fallback (0/1 agreeing) |
| prim1112_empty-string-path.png | Empty String/Path? | 21x29 | Config_Load2, Config_Load, Config_Dump, Config_Dump2 — pair-seeded consensus (2/8 agreeing) |
| prim1114_greater-or-equal-to-0.png | Greater Or Equal To 0? | 26x21 | Config_Load2, Config_Load, ClassChildren, Read Library Version — single-sample fallback after edge fusion (2/4 agreeing) |
| prim1118_less-than-0.png | Less Than 0? | 20x21 | Tokenize URL, Excel_Cell_to_Value — single-sample fallback (0/2 agreeing) |
| prim1120_sort-1d-array.png | Sort 1D Array | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): GenerateTree |
| prim1124.png | (uncatalogued) | 20x22 | Read Library Version — single-sample fallback (0/1 agreeing) |
| prim1127_in-range-and-coerce.png | In Range and Coerce | 32x24 | IconHeader, Read VI Blocks — single-sample fallback (0/2 agreeing) |
| prim1143 | (verified — committed asset authoritative) | | IconHeader, Page1, crc8, crc16 — single-sample fallback (0/7 agreeing) |
| prim1156.png | (uncatalogued) | 25x11 | MD5 — single-sample fallback (0/1 agreeing) |
| prim1162.png | (uncatalogued) | 32x32 | border-exact rect (5/5 ring samples agree byte-for-byte): MD5 |
| prim1163.png | (uncatalogued) | 32x32 | border-exact rect (5/5 ring samples agree byte-for-byte): MD5 |
| prim1166_type-cast.png | Type Cast | 32x32 | Excel_Cell_to_Value, Config_Escape — pair-seeded consensus (3/8 agreeing) |
| prim1171.png | (uncatalogued) | 34x18 | IconHeader, Config_Escape, crc16 — pair-seeded consensus (3/6 agreeing) |
| prim1180_number-to-decimal-string.png | Number To Decimal String | 32x32 | border-exact rect (2/2 ring samples agree byte-for-byte): Excel_Variant_Elements |
| prim1181.png | (uncatalogued) | 32x32 | border-exact rect (4/4 ring samples agree byte-for-byte): MD5 |
| prim1185.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Config_Escape |
| prim1189_to-lower-case.png | To Lower Case | 27x22 | ClassesInMemory, ClassChildren, large — single-sample fallback after edge fusion (3/8 agreeing) |
| prim1302_wait-ms.png | Wait (ms) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): VISA_Query |
| prim1419 | (verified — committed asset authoritative) | | border-exact rect (5/7 ring samples agree byte-for-byte): Excel_Read_XLSX |
| prim1420_strip-path.png | Strip Path | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Read Library Version |
| prim1502_string-length.png | String Length | 32x17 | Config_Load2, Config_Load, MD5 — single-sample fallback after edge fusion (2/8 agreeing) |
| prim1503_string-subset.png | String Subset | 32x32 | border-exact rect (2/2 ring samples agree byte-for-byte): Config_Load2, Config_Load |
| prim1516_select.png | Select | 27x27 | Excel_Variant_Elements, Config_Dump, Config_Dump2, large — pair-seeded consensus (8/8 agreeing) |
| prim1534.png | (uncatalogued) | 32x32 | border-exact rect (8/8 ring samples agree byte-for-byte): Excel_Cell_to_Value |
| prim1535_match-pattern.png | Match Pattern | 32x32 | border-exact rect (8/8 ring samples agree byte-for-byte): ClassesInMemory, Config_Dump, ClassChildren, Config_Dump2 |
| prim1539_spreadsheet-string-to-array.png | Spreadsheet String To Array | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Excel_Variant_Elements |
| prim1606 | (verified — committed asset authoritative) | | crc8, crc16 — pair-seeded consensus (2/2 agreeing) |
| prim1608 | (verified — committed asset authoritative) | | Read Library Version, Config_Escape, MD5, crc8, crc16 — single-sample fallback after edge fusion (4/6 agreeing) |
| prim1809_array-size.png | Array Size | 32x21 | Config_Load2, Config_Load, ClassChildren, large, Config_Escape — pair-seeded consensus (5/8 agreeing) |
| prim1900 | (verified — committed asset authoritative) | | large, MD5 — pair-seeded consensus (2/2 agreeing) |
| prim1901_search-1d-array.png | Search 1D Array | 32x32 | border-exact rect (7/7 ring samples agree byte-for-byte): ClassesInMemory, ClassChildren, Config_Dump2, Excel_Cell_to_Value |
| prim1907_array-max-min.png | Array Max & Min | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): ClassChildren |
| prim1908.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Excel_Read_XLSX |
| prim1922.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): VISA_Open2 |
| prim1925.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): VISA_Query |
| prim1926.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): VISA_Query |
| prim1927.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): VISA_Open2 |
| prim2073_create-user-event.png | Create User Event | 32x32 | border-exact rect (2/2 ring samples agree byte-for-byte): Pages |
| prim2074_generate-user-event.png | Generate User Event | 32x32 | border-exact rect (2/2 ring samples agree byte-for-byte): Pages, Page1 |
| prim2302.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): VISA_Open2 |
| prim23063_empty-array.png | Empty Array? | 21x21 | Excel_Variant_Elements, Export Palette Image WMF, ClassChildren, Excel_Cell_to_Value, GenerateTree, large — single-sample fallback (0/8 agreeing) |
| prim2308.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): VISA_Open2 |
| prim2452.png | (uncatalogued) | 32x32 | border-exact rect (2/2 ring samples agree byte-for-byte): GenerateTree |
| prim2457.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): GenerateTree |
| prim2458.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): GenerateTree |
| prim8010_open-vi-reference.png | Open VI Reference | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Pages |
| prim8011_close-reference.png | Close Reference | 32x32 | border-exact rect (2/2 ring samples agree byte-for-byte): Resolve Library Path |
| prim8018.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): ClassChildren |
| prim8050_open-create-replace-file.png | Open/Create/Replace File | 32x32 | border-exact rect (3/3 ring samples agree byte-for-byte): Read Library Version, Read VI Blocks |
| prim8051.png | (uncatalogued) | 32x32 | border-exact rect (2/2 ring samples agree byte-for-byte): Read Library Version, Read VI Blocks |
| prim8052 | (verified — committed asset authoritative) | | border-exact rect (3/3 ring samples agree byte-for-byte): Excel_Read_XLSX, Read Library Version, Read VI Blocks |
| prim8055_create-folder.png | Create Folder | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Excel_Read_XLSX |
| prim8056 | (verified — committed asset authoritative) | | border-exact rect (2/2 ring samples agree byte-for-byte): Export Palette Image WMF, Excel_Read_XLSX |
| prim8065.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): FileReadOnly |
| prim8070_read-from-text-file.png | Read from Text File | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Excel_Read_XLSX |
| prim8073_set-file-position.png | Set File Position | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Read Library Version |
| prim8076.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): FileReadOnly |
| prim8082 | (verified — committed asset authoritative) | | border-exact rect (1/2 ring samples agree byte-for-byte): Excel_Read_XLSX |
| prim8083 | (verified — committed asset authoritative) | | border-exact rect (2/3 ring samples agree byte-for-byte): large |
| prim8101.png | (uncatalogued) | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Tokenize URL |
| prim8203_variant-to-flattened-string.png | Variant To Flattened String | 32x32 | border-exact rect (1/1 ring samples agree byte-for-byte): Excel_Variant_Elements |
| prim8204_set-variant-attribute.png | Set Variant Attribute | 32x32 | border-exact rect (2/2 ring samples agree byte-for-byte): Pages, Page1 |

## Identities without a usable asset (kept visible, never hidden)

- class108: no agreeing consensus and no centred sample survived cleaning (5 samples)
- class58: class key carries 2 distinct border-exact arts (3x from ClassesInMemory+ClassChildren | 2x from large) — a per-node identity is needed, no single asset can be right
- class62: class key carries 2 distinct border-exact arts (4x from ClassesInMemory+Config_Dump+ClassChildren | 1x from missing_terminal) — a per-node identity is needed, no single asset can be right
- prim1051: cleaned ink still reaches the crop edge (wire fusion; 8 samples)
- prim1056: cleaned ink still reaches the crop edge (wire fusion; 6 samples)
- prim1057: cleaned ink still reaches the crop edge (wire fusion; 8 samples)
- prim1058: cleaned ink still reaches the crop edge (wire fusion; 8 samples)
- prim1062: cleaned ink still reaches the crop edge (wire fusion; 8 samples)
- prim1069: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1078: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1081: cleaned ink still reaches the crop edge (wire fusion; 2 samples)
- prim1108: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1113: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim1116: every sample came from a low-registration snippet
- prim1128: no agreeing consensus and no centred sample survived cleaning (2 samples)
- prim1141: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1142: no agreeing consensus and no centred sample survived cleaning (8 samples)
- prim1145: every sample came from a low-registration snippet
- prim1147: every sample came from a low-registration snippet
- prim1155: cleaned ink still reaches the crop edge (wire fusion; 8 samples)
- prim1164: no agreeing consensus and no centred sample survived cleaning (2 samples)
- prim1167: cleaned ink still reaches the crop edge (wire fusion; 4 samples)
- prim1170: no agreeing consensus and no centred sample survived cleaning (2 samples)
- prim1184: cleaned ink still reaches the crop edge (wire fusion; 7 samples)
- prim1188: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim1213: every sample came from a low-registration snippet
- prim1303: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1421: every sample came from a low-registration snippet
- prim1435: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1537: every sample came from a low-registration snippet
- prim1609: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim1814: every sample came from a low-registration snippet
- prim1815: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1904: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim2075: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim2076: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim3914: no agreeing consensus and no centred sample survived cleaning (3 samples)
- prim8003: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim8063: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim8205: no agreeing consensus and no centred sample survived cleaning (3 samples)

Snippets excluded from harvesting (registration below the 0.7 placement gate): PNG CRC32.png, broken_wires_only.png, crc32_lookup_table.png, decorations_only.png, Excel_Cell_to_RowCol.png, Resolve Path.png, ReverseBitsVim.png, crc32.png

