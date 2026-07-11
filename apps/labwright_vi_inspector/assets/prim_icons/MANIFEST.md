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

Palette (13 colours — every icon pixel is one of these): #000000 #0000ff #333333 #444444 #4c4c3d #666666 #777777 #999966 #aaaaaa #ff00ff #ff6600 #ffffcc #ffffff

| class147.png | class 0x93 | 32x29 | Excel_Variant_Elements, example, Page1, Config_Escape — single-sample fallback (0/6 agreeing) |
| class370.png | class 0x172 | 32x18 | Excel_Variant_Elements, Excel_Cell_to_Value — single-sample retry after oversized consensus (2/7 agreeing) |
| class52.png | class 0x34 | 32x41 | Excel_Variant_Elements — single-sample fallback (0/1 agreeing) |
| class58 | (verified — committed asset authoritative) | | ClassesInMemory, ClassChildren, large — pair-seeded consensus (5/5 agreeing) |
| class62.png | class 0x3e | 32x17 | missing_terminal, ClassesInMemory, ClassChildren, Config_Dump — pair-seeded consensus (5/5 agreeing) |
| class68 | (verified — committed asset authoritative) | | ClassChildren, Config_Dump2 — pair-seeded consensus (7/7 agreeing) |
| prim1050_add.png | Add | 29x28 | GenerateTree, IconHeader, basic, MD5 — single-sample fallback (0/8 agreeing) |
| prim1051_subtract.png | Subtract | 31x29 | Config_Load, Config_Load2, IconHeader, MD5 — single-sample retry after oversized consensus (2/8 agreeing) |
| prim1052_multiply.png | Multiply | 37x32 | Config_Load, Config_Load2, Read VI Blocks, IconHeader, MD5 — single-sample fallback (0/8 agreeing) |
| prim1056.png | (uncatalogued) | 9x21 | Config_Load, Config_Load2, IconHeader, MD5 — pair-seeded consensus (2/6 agreeing) |
| prim1057_increment.png | Increment | 35x32 | Config_Escape — pair-seeded consensus (7/8 agreeing) |
| prim1058_decrement.png | Decrement | 16x31 | Pages, Config_Load, Config_Load2, MD5 — pair-seeded consensus (2/6 agreeing) |
| prim1061_and.png | And | 30x20 | large, MD5 — pair-seeded consensus (3/5 agreeing) |
| prim1062_or.png | Or | 33x25 | Config_Load, Config_Load2, Read Library Version, Read VI Blocks, MD5 — pair-seeded consensus (2/8 agreeing) |
| prim1063_exclusive-or.png | Exclusive Or | 34x27 | crc8, MD5, crc16 — pair-seeded consensus (2/8 agreeing) |
| prim1064_not.png | Not | 35x31 | ClassChildren, GenerateTree, MD5 — single-sample fallback (0/6 agreeing) |
| prim1070_random-number-0-1.png | Random Number (0-1) | 28x32 | IconHeader — single-sample fallback (0/3 agreeing) |
| prim1077_path-to-string.png | Path To String | 25x11 | Export Palette Image WMF, large — single-sample fallback (0/3 agreeing) |
| prim1081_logical-shift.png | Logical Shift | 33x21 | MD5, crc16 — pair-seeded consensus (2/2 agreeing) |
| prim1082.png | (uncatalogued) | 37x15 | MD5 — single-sample fallback (0/1 agreeing) |
| prim1102_equal.png | Equal? | 21x21 | ClassChildren, GenerateTree — single-sample fallback (0/3 agreeing) |
| prim1103.png | (uncatalogued) | 21x21 | Read VI Blocks, Config_Escape — single-sample fallback (0/2 agreeing) |
| prim1105_not-equal.png | Not Equal? | 31x31 | large — single-sample fallback (0/2 agreeing) |
| prim1110_greater.png | Greater? | 32x25 | example — single-sample fallback (0/1 agreeing) |
| prim1112_empty-string-path.png | Empty String/Path? | 22x29 | Config_Load, Config_Load2, Config_Dump, Config_Dump2 — pair-seeded consensus (2/8 agreeing) |
| prim1114_greater-or-equal-to-0.png | Greater Or Equal To 0? | 32x29 | Config_Load, Config_Load2, ClassChildren, Read Library Version — pair-seeded consensus (2/4 agreeing) |
| prim1118_less-than-0.png | Less Than 0? | 32x31 | Tokenize URL, Excel_Cell_to_Value — single-sample fallback (0/2 agreeing) |
| prim1120_sort-1d-array.png | Sort 1D Array | 32x32 | GenerateTree — single-sample fallback (0/1 agreeing) |
| prim1124.png | (uncatalogued) | 20x22 | Read Library Version — single-sample fallback (0/1 agreeing) |
| prim1127_in-range-and-coerce.png | In Range and Coerce | 32x24 | Read VI Blocks, IconHeader — single-sample fallback (0/2 agreeing) |
| prim1128_not-a-number-path-refnum.png | Not A Number/Path/Refnum? | 23x31 | Read VI Blocks — single-sample fallback (0/1 agreeing) |
| prim1142_to-long-integer.png | To Long Integer | 35x11 | Read VI Blocks, Page1, MD5, crc16 — single-sample fallback (0/8 agreeing) |
| prim1143_to-unsigned-byte-integer.png | To Unsigned Byte Integer | 35x16 | Page1, IconHeader, crc8, crc16 — single-sample fallback (0/7 agreeing) |
| prim1156.png | (uncatalogued) | 25x11 | MD5 — single-sample fallback (0/1 agreeing) |
| prim1162.png | (uncatalogued) | 32x37 | MD5 — single-sample retry after oversized consensus (4/5 agreeing) |
| prim1163.png | (uncatalogued) | 32x37 | MD5 — single-sample retry after oversized consensus (4/5 agreeing) |
| prim1166_type-cast.png | Type Cast | 32x32 | Excel_Cell_to_Value, Config_Escape — pair-seeded consensus (3/8 agreeing) |
| prim1167_boolean-to-0-1.png | Boolean To (0,1) | 33x18 | Config_Load, Config_Load2 — pair-seeded consensus (2/4 agreeing) |
| prim1171.png | (uncatalogued) | 34x18 | IconHeader, Config_Escape, crc16 — pair-seeded consensus (3/6 agreeing) |
| prim1180_number-to-decimal-string.png | Number To Decimal String | 32x32 | Excel_Variant_Elements — pair-seeded consensus (2/2 agreeing) |
| prim1181.png | (uncatalogued) | 32x37 | MD5 — single-sample retry after oversized consensus (4/4 agreeing) |
| prim1185.png | (uncatalogued) | 37x32 | Config_Escape — single-sample fallback (0/1 agreeing) |
| prim1188.png | (uncatalogued) | 33x32 | Config_Dump2, Excel_Cell_to_Value — single-sample fallback (0/4 agreeing) |
| prim1189_to-lower-case.png | To Lower Case | 34x32 | ClassesInMemory, ClassChildren, large — pair-seeded consensus (3/8 agreeing) |
| prim1302_wait-ms.png | Wait (ms) | 32x32 | VISA_Query — single-sample fallback (0/1 agreeing) |
| prim1419_build-path.png | Build Path | 32x32 | large — pair-seeded consensus (2/2 agreeing) |
| prim1420_strip-path.png | Strip Path | 32x32 | Read Library Version, large — single-sample fallback (0/2 agreeing) |
| prim1502_string-length.png | String Length | 32x17 | Config_Load, Config_Load2, MD5 — pair-seeded consensus (2/8 agreeing) |
| prim1503_string-subset.png | String Subset | 32x37 | Config_Load, Config_Load2, Excel_Variant_Elements — single-sample retry after oversized consensus (2/8 agreeing) |
| prim1516_select.png | Select | 27x27 | Excel_Variant_Elements, Config_Dump, Config_Dump2, large — pair-seeded consensus (8/8 agreeing) |
| prim1534 | (verified — committed asset authoritative) | | Excel_Cell_to_Value — pair-seeded consensus (8/8 agreeing) |
| prim1535 | (verified — committed asset authoritative) | | ClassesInMemory, ClassChildren, Config_Dump, Config_Dump2 — pair-seeded consensus (8/8 agreeing) |
| prim1539_spreadsheet-string-to-array.png | Spreadsheet String To Array | 32x32 | Excel_Variant_Elements — single-sample fallback (0/1 agreeing) |
| prim1606_rotate-left-with-carry.png | Rotate Left With Carry | 27x17 | crc8, crc16 — pair-seeded consensus (2/2 agreeing) |
| prim1608_string-to-byte-array.png | String To Byte Array | 34x11 | Read Library Version, Config_Escape, crc8, MD5, crc16 — pair-seeded consensus (4/6 agreeing) |
| prim1809_array-size.png | Array Size | 32x21 | Config_Load, Config_Load2, ClassChildren, large, Config_Escape — pair-seeded consensus (5/8 agreeing) |
| prim1815_boolean-array-to-number.png | Boolean Array To Number | 35x11 | Config_Dump2 — single-sample fallback (0/1 agreeing) |
| prim1900_reverse-1d-array.png | Reverse 1D Array | 32x23 | large, MD5 — pair-seeded consensus (2/2 agreeing) |
| prim1901_search-1d-array.png | Search 1D Array | 32x32 | ClassesInMemory, ClassChildren, Config_Dump2, Excel_Cell_to_Value, large — pair-seeded consensus (7/8 agreeing) |
| prim1907_array-max-min.png | Array Max & Min | 37x32 | ClassChildren — single-sample fallback (0/1 agreeing) |
| prim1922.png | (uncatalogued) | 32x32 | VISA_Open2 — single-sample fallback (0/1 agreeing) |
| prim1925.png | (uncatalogued) | 32x32 | VISA_Query — single-sample fallback (0/1 agreeing) |
| prim1926.png | (uncatalogued) | 32x32 | VISA_Query — single-sample fallback (0/1 agreeing) |
| prim1927.png | (uncatalogued) | 32x32 | VISA_Open2 — single-sample fallback (0/1 agreeing) |
| prim2073_create-user-event.png | Create User Event | 37x32 | Pages — pair-seeded consensus (2/2 agreeing) |
| prim2074_generate-user-event.png | Generate User Event | 35x32 | Pages, Page1 — pair-seeded consensus (2/5 agreeing) |
| prim2302.png | (uncatalogued) | 32x32 | VISA_Open2 — single-sample fallback (0/1 agreeing) |
| prim23063_empty-array.png | Empty Array? | 38x27 | Export Palette Image WMF, Excel_Variant_Elements, ClassChildren, GenerateTree, Excel_Cell_to_Value, large — single-sample fallback (0/8 agreeing) |
| prim2308.png | (uncatalogued) | 32x32 | VISA_Open2 — single-sample fallback (0/1 agreeing) |
| prim2452.png | (uncatalogued) | 32x32 | GenerateTree — pair-seeded consensus (2/2 agreeing) |
| prim2457.png | (uncatalogued) | 36x32 | GenerateTree — single-sample fallback (0/1 agreeing) |
| prim2458.png | (uncatalogued) | 33x32 | GenerateTree — single-sample fallback (0/1 agreeing) |
| prim8010_open-vi-reference.png | Open VI Reference | 32x32 | Pages — single-sample fallback (0/1 agreeing) |
| prim8011_close-reference.png | Close Reference | 37x32 | Resolve Library Path, Pages — pair-seeded consensus (2/5 agreeing) |
| prim8018.png | (uncatalogued) | 32x32 | ClassChildren — single-sample fallback (0/1 agreeing) |
| prim8050_open-create-replace-file.png | Open/Create/Replace File | 32x32 | Read Library Version, Read VI Blocks — pair-seeded consensus (3/3 agreeing) |
| prim8051.png | (uncatalogued) | 32x32 | Read Library Version, Read VI Blocks — pair-seeded consensus (2/8 agreeing) |
| prim8052_close-file.png | Close File | 32x32 | Read Library Version, Read VI Blocks — pair-seeded consensus (2/3 agreeing) |
| prim8056_delete.png | Delete | 32x32 | Export Palette Image WMF — single-sample fallback (0/1 agreeing) |
| prim8065.png | (uncatalogued) | 32x32 | FileReadOnly — single-sample fallback (0/1 agreeing) |
| prim8073_set-file-position.png | Set File Position | 17x32 | Read Library Version, Read VI Blocks — pair-seeded consensus (2/8 agreeing) |
| prim8076.png | (uncatalogued) | 32x32 | FileReadOnly — single-sample fallback (0/1 agreeing) |
| prim8082_file-directory-info.png | File/Directory Info | 32x32 | large — single-sample fallback (0/1 agreeing) |
| prim8083.png | (uncatalogued) | 32x32 | large — pair-seeded consensus (2/2 agreeing) |
| prim8101.png | (uncatalogued) | 32x32 | Tokenize URL — single-sample fallback (0/1 agreeing) |
| prim8203_variant-to-flattened-string.png | Variant To Flattened String | 32x23 | Excel_Variant_Elements — pair-seeded consensus (2/3 agreeing) |
| prim8204_set-variant-attribute.png | Set Variant Attribute | 32x32 | Pages, Page1 — pair-seeded consensus (2/3 agreeing) |

## Identities without a usable asset (kept visible, never hidden)

- class108: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim1069: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1078: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1108: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1113: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim1116: every sample came from a low-registration snippet
- prim1141: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1145: every sample came from a low-registration snippet
- prim1147: every sample came from a low-registration snippet
- prim1155: extracted ink 21x41 exceeds the node box (32x32) — displaced model bounds suspected (sources: Read VI Blocks, MD5)
- prim1164: no agreeing consensus and no centred sample survived cleaning (2 samples)
- prim1170: no agreeing consensus and no centred sample survived cleaning (2 samples)
- prim1184: every sample came from a low-registration snippet
- prim1213: every sample came from a low-registration snippet
- prim1303: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1421: every sample came from a low-registration snippet
- prim1435: every sample came from a low-registration snippet
- prim1537: every sample came from a low-registration snippet
- prim1609: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim1814: every sample came from a low-registration snippet
- prim1904: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim1908: every sample came from a low-registration snippet
- prim2075: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim2076: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim3914: every sample came from a low-registration snippet
- prim8003: no agreeing consensus and no centred sample survived cleaning (4 samples)
- prim8055: every sample came from a low-registration snippet
- prim8063: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim8070: no agreeing consensus and no centred sample survived cleaning (1 samples)
- prim8205: no agreeing consensus and no centred sample survived cleaning (3 samples)

Snippets excluded from harvesting (registration below the 0.7 placement gate): PNG CRC32.png, broken_wires_only.png, crc32_lookup_table.png, decorations_only.png, Excel_Cell_to_RowCol.png, Excel_Read_XLSX.png, Resolve Path.png, ReverseBitsVim.png, crc32.png

