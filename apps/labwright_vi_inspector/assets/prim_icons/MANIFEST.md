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

Palette (13 colours — every icon pixel is one of these): #000000 #0000ff #333333 #444444 #4c4c3d #660066 #666666 #777777 #999966 #aaaaaa #ff00ff #ffffcc #ffffff

| class108.png | class 0x6c | 34x23 | Excel_Read_XLSX, MD5, Read VI Blocks |
| class147.png | class 0x93 | 30x21 | example, Config_Escape, Excel_Read_XLSX, Excel_Variant_Elements |
| class370.png | class 0x172 | 39x18 | Excel_Cell_to_Value, Excel_Read_XLSX, Excel_Variant_Elements |
| class52.png | class 0x34 | 32x41 | Excel_Variant_Elements |
| class58.png | class 0x3a | 32x17 | large, ClassChildren, ClassesInMemory |
| class62.png | class 0x3e | 32x17 | missing_terminal, ClassChildren, ClassesInMemory, Config_Dump |
| class68.png | class 0x44 | 32x27 | PNG CRC32, ClassChildren |
| prim1050_add.png | Add | 21x21 | basic, Excel_Cell_to_RowCol, GenerateTree, IconHeader |
| prim1051_subtract.png | Subtract | 42x27 | Config_Load, Config_Load2, Excel_Cell_to_RowCol, Excel_Read_XLSX |
| prim1052_multiply.png | Multiply | 20x17 | Config_Load, Config_Load2, Excel_Cell_to_RowCol, Excel_Read_XLSX, IconHeader, MD5 |
| prim1056.png | (uncatalogued) | 14x18 | Config_Load, Config_Load2, IconHeader, MD5 |
| prim1057_increment.png | Increment | 35x32 | Config_Escape |
| prim1058_decrement.png | Decrement | 34x25 | Config_Load, Config_Load2, Excel_Read_XLSX |
| prim1061_and.png | And | 30x16 | PNG CRC32, crc32_lookup_table, large, MD5 |
| prim1062_or.png | Or | 4x8 | Config_Load, Config_Load2, Excel_Read_XLSX, MD5, Read Library Version, Read VI Blocks |
| prim1063_exclusive-or.png | Exclusive Or | 29x16 | PNG CRC32, crc32_lookup_table, MD5, crc16 |
| prim1064_not.png | Not | 21x19 | ClassChildren, Excel_Read_XLSX, GenerateTree, MD5 |
| prim1069.png | (uncatalogued) | 39x21 | GenerateTree |
| prim1070_random-number-0-1.png | Random Number (0-1) | 19x21 | Excel_Read_XLSX, IconHeader |
| prim1077_path-to-string.png | Path To String | 22x9 | large, Excel_Read_XLSX, Export Palette Image WMF |
| prim1078_string-to-path.png | String To Path | 25x11 | Excel_Cell_to_Value, Resolve Path |
| prim1081_logical-shift.png | Logical Shift | 32x21 | PNG CRC32, crc32_lookup_table, MD5, crc16, crc32 |
| prim1082.png | (uncatalogued) | 37x15 | MD5 |
| prim1102_equal.png | Equal? | 21x21 | ClassChildren, Excel_Read_XLSX, GenerateTree, Resolve Path |
| prim1103.png | (uncatalogued) | 21x21 | Config_Escape, Read VI Blocks |
| prim1105_not-equal.png | Not Equal? | 31x31 | large |
| prim1110_greater.png | Greater? | 32x25 | example |
| prim1112_empty-string-path.png | Empty String/Path? | 21x21 | Config_Dump, Config_Dump2, Config_Load, Config_Load2 |
| prim1113_equal-to-0.png | Equal To 0? | 42x27 | crc32_lookup_table, Config_Load, Config_Load2, MD5, Pages |
| prim1114_greater-or-equal-to-0.png | Greater Or Equal To 0? | 26x14 | ClassChildren, Config_Load, Config_Load2, Read Library Version |
| prim1118_less-than-0.png | Less Than 0? | 20x21 | Excel_Cell_to_Value, Tokenize URL |
| prim1120_sort-1d-array.png | Sort 1D Array | 32x32 | GenerateTree |
| prim1124.png | (uncatalogued) | 20x22 | Read Library Version |
| prim1127_in-range-and-coerce.png | In Range and Coerce | 32x24 | IconHeader, Read VI Blocks |
| prim1128_not-a-number-path-refnum.png | Not A Number/Path/Refnum? | 23x31 | Excel_Read_XLSX, Read VI Blocks |
| prim1141_to-word-integer.png | To Word Integer | 42x33 | Symbols1Bit |
| prim1142_to-long-integer.png | To Long Integer | 31x11 | PNG CRC32, Excel_Cell_to_RowCol, MD5, Page1, Read VI Blocks, ReverseBitsVim |
| prim1143_to-unsigned-byte-integer.png | To Unsigned Byte Integer | 34x11 | IconHeader, Page1, crc16, crc32, crc8 |
| prim1145_to-unsigned-long-integer.png | To Unsigned Long Integer | 42x27 | PNG CRC32, crc32_lookup_table |
| prim1147_to-double-precision-float.png | To Double Precision Float | 42x29 | Excel_Cell_to_RowCol |
| prim1155.png | (uncatalogued) | 18x11 | MD5, Read VI Blocks |
| prim1156.png | (uncatalogued) | 25x11 | MD5 |
| prim1162.png | (uncatalogued) | 32x42 | MD5 |
| prim1163.png | (uncatalogued) | 32x42 | MD5 |
| prim1166_type-cast.png | Type Cast | 30x24 | Config_Escape, Excel_Cell_to_Value |
| prim1167_boolean-to-0-1.png | Boolean To (0,1) | 38x32 | Config_Load, Config_Load2 |
| prim1170.png | (uncatalogued) | 40x18 | crc16, crc32 |
| prim1171.png | (uncatalogued) | 31x18 | Config_Escape, IconHeader, crc16, crc32 |
| prim1180_number-to-decimal-string.png | Number To Decimal String | 32x32 | Excel_Variant_Elements |
| prim1181.png | (uncatalogued) | 32x42 | MD5 |
| prim1184_decimal-string-to-number.png | Decimal String To Number | 41x14 | Excel_Read_XLSX |
| prim1185.png | (uncatalogued) | 37x32 | Config_Escape |
| prim1188.png | (uncatalogued) | 26x11 | Config_Dump2, Excel_Cell_to_RowCol, Excel_Cell_to_Value |
| prim1189_to-lower-case.png | To Lower Case | 26x11 | large, ClassChildren, ClassesInMemory |
| prim1213.png | (uncatalogued) | 37x32 | Excel_Cell_to_RowCol |
| prim1302_wait-ms.png | Wait (ms) | 32x32 | VISA_Query |
| prim1419_build-path.png | Build Path | 30x30 | large, Excel_Read_XLSX |
| prim1420_strip-path.png | Strip Path | 32x32 | large, Excel_Read_XLSX, Read Library Version |
| prim1421.png | (uncatalogued) | 37x42 | Resolve Path |
| prim1435.png | (uncatalogued) | 33x18 | Excel_Read_XLSX |
| prim1502_string-length.png | String Length | 32x17 | Config_Load, Config_Load2, MD5 |
| prim1503_string-subset.png | String Subset | 30x30 | Config_Load, Config_Load2, Excel_Read_XLSX |
| prim1516_select.png | Select | 27x27 | PNG CRC32, crc32_lookup_table, large, Config_Dump, Config_Dump2 |
| prim1534.png | (uncatalogued) | 32x32 | Excel_Cell_to_Value |
| prim1535_match-pattern.png | Match Pattern | 32x32 | ClassChildren, ClassesInMemory, Config_Dump, Config_Dump2 |
| prim1537.png | (uncatalogued) | 36x13 | Excel_Cell_to_RowCol |
| prim1539_spreadsheet-string-to-array.png | Spreadsheet String To Array | 40x9 | Excel_Read_XLSX, Excel_Variant_Elements |
| prim1606_rotate-left-with-carry.png | Rotate Left With Carry | 27x17 | crc16, crc32, crc8 |
| prim1608_string-to-byte-array.png | String To Byte Array | 33x11 | PNG CRC32, Config_Escape, Excel_Cell_to_RowCol, MD5, Read Library Version, crc16, crc32 |
| prim1609_byte-array-to-string.png | Byte Array To String | 36x11 | Read Library Version, Read VI Blocks |
| prim1809_array-size.png | Array Size | 32x21 | large, ClassChildren, Config_Escape, Config_Load, Config_Load2 |
| prim1815_boolean-array-to-number.png | Boolean Array To Number | 35x11 | Config_Dump2 |
| prim1900_reverse-1d-array.png | Reverse 1D Array | 32x23 | large, MD5, ReverseBitsVim |
| prim1901_search-1d-array.png | Search 1D Array | 32x32 | large, ClassChildren, ClassesInMemory, Config_Dump2, Excel_Cell_to_Value |
| prim1904.png | (uncatalogued) | 42x42 | Symbols1Bit |
| prim1907_array-max-min.png | Array Max & Min | 37x32 | ClassChildren |
| prim1922.png | (uncatalogued) | 32x32 | VISA_Open2 |
| prim1925.png | (uncatalogued) | 32x32 | VISA_Query |
| prim1926.png | (uncatalogued) | 32x32 | VISA_Query |
| prim1927.png | (uncatalogued) | 32x32 | VISA_Open2 |
| prim2073_create-user-event.png | Create User Event | 37x32 | Pages |
| prim2074_generate-user-event.png | Generate User Event | 39x32 | Page1, Pages |
| prim2075_destroy-user-event.png | Destroy User Event | 16x27 | Pages |
| prim2076_unregister-for-events.png | Unregister For Events | 6x12 | Pages |
| prim2302.png | (uncatalogued) | 32x32 | VISA_Open2 |
| prim23063_empty-array.png | Empty Array? | 21x21 | PNG CRC32, large, ClassChildren, Excel_Cell_to_Value, Excel_Variant_Elements, Export Palette Image WMF |
| prim2308.png | (uncatalogued) | 32x32 | VISA_Open2 |
| prim2452.png | (uncatalogued) | 32x32 | GenerateTree |
| prim2457.png | (uncatalogued) | 36x32 | GenerateTree |
| prim2458.png | (uncatalogued) | 33x32 | GenerateTree |
| prim8003_variant-to-data.png | Variant To Data | 39x39 | Excel_Variant_Elements, Pages |
| prim8010_open-vi-reference.png | Open VI Reference | 32x32 | Pages |
| prim8011_close-reference.png | Close Reference | 37x32 | Pages, Resolve Library Path |
| prim8018.png | (uncatalogued) | 32x32 | ClassChildren |
| prim8050_open-create-replace-file.png | Open/Create/Replace File | 32x32 | Read Library Version, Read VI Blocks |
| prim8051.png | (uncatalogued) | 32x32 | Read Library Version, Read VI Blocks |
| prim8052_close-file.png | Close File | 36x32 | Excel_Read_XLSX, Read Library Version, Read VI Blocks |
| prim8055_create-folder.png | Create Folder | 37x32 | Excel_Read_XLSX |
| prim8056_delete.png | Delete | 7x4 | Excel_Read_XLSX, Export Palette Image WMF |
| prim8065.png | (uncatalogued) | 32x32 | FileReadOnly |
| prim8070_read-from-text-file.png | Read from Text File | 42x37 | Excel_Read_XLSX, Read Library Version |
| prim8073_set-file-position.png | Set File Position | 36x32 | Read Library Version, Read VI Blocks |
| prim8076.png | (uncatalogued) | 32x32 | FileReadOnly |
| prim8082_file-directory-info.png | File/Directory Info | 30x30 | large, Excel_Read_XLSX |
| prim8083.png | (uncatalogued) | 32x32 | large, Excel_Read_XLSX |
| prim8101.png | (uncatalogued) | 32x32 | Tokenize URL |
| prim8203_variant-to-flattened-string.png | Variant To Flattened String | 32x23 | Excel_Variant_Elements |
| prim8204_set-variant-attribute.png | Set Variant Attribute | 32x32 | Page1, Pages |
