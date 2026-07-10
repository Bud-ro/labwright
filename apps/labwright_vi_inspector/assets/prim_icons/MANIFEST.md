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
| class108.png | class 0x6c | 26x24 | Excel_Read_XLSX, MD5, Read VI Blocks |
| class147.png | class 0x93 | 26x20 | example, Config_Escape, Excel_Read_XLSX, Excel_Variant_Elements |
| class370.png | class 0x172 | 34x14 | Excel_Cell_to_Value, Excel_Read_XLSX, Excel_Variant_Elements |
| class52.png | class 0x34 | 34x41 | Excel_Variant_Elements |
| class58.png | class 0x3a | 32x17 | large, ClassChildren, ClassesInMemory |
| class62.png | class 0x3e | 33x17 | missing_terminal, ClassChildren, ClassesInMemory, Config_Dump |
| class68.png | class 0x44 | 33x27 | PNG CRC32, ClassChildren |
| prim1050.png | Add | 21x21 | basic, Excel_Cell_to_RowCol, GenerateTree, IconHeader |
| prim1051.png | Subtract | 34x30 | Config_Load, Config_Load2, Excel_Cell_to_RowCol, Excel_Read_XLSX |
| prim1052.png | Multiply | 26x24 | Config_Load, Config_Load2, Excel_Cell_to_RowCol, Excel_Read_XLSX, IconHeader, MD5 |
| prim1056.png | (uncatalogued) | 23x24 | Config_Load, Config_Load2, IconHeader, MD5 |
| prim1057.png | Increment | 34x28 | Config_Escape |
| prim1058.png | Decrement | 34x19 | Config_Load, Config_Load2, Excel_Read_XLSX |
| prim1061.png | And | 33x16 | PNG CRC32, crc32_lookup_table, large, FileReadOnly, MD5 |
| prim1062.png | Or | 16x16 | Config_Load, Config_Load2, Excel_Read_XLSX, MD5, Read Library Version, Read VI Blocks |
| prim1063.png | Exclusive Or | 34x16 | PNG CRC32, crc32_lookup_table, MD5, crc16 |
| prim1064.png | Not | 21x19 | ClassChildren, Excel_Read_XLSX, GenerateTree, MD5 |
| prim1069.png | (uncatalogued) | 34x21 | GenerateTree |
| prim1070.png | Random Number (0-1) | 25x27 | Excel_Read_XLSX, IconHeader |
| prim1077.png | Path To String | 22x9 | large, Excel_Read_XLSX, Export Palette Image WMF |
| prim1078.png | String To Path | 31x10 | Excel_Cell_to_Value, GetCurrentDirectory, Resolve Path |
| prim1081.png | Logical Shift | 34x15 | PNG CRC32, crc32_lookup_table, MD5, crc16, crc32 |
| prim1082.png | (uncatalogued) | 34x24 | MD5 |
| prim1102.png | Equal? | 21x21 | ClassChildren, Excel_Read_XLSX, GenerateTree, Resolve Path |
| prim1103.png | (uncatalogued) | 34x28 | Config_Escape, Read VI Blocks |
| prim1105.png | Not Equal? | 32x28 | large |
| prim1110.png | Greater? | 33x21 | example |
| prim1112.png | Empty String/Path? | 25x21 | Config_Dump, Config_Dump2, Config_Load |
| prim1113.png | Equal To 0? | 6x34 | crc32_lookup_table, Config_Load, Config_Load2, MD5, Pages |
| prim1114.png | Greater Or Equal To 0? | 28x28 | ClassChildren, Config_Load, Config_Load2, Read Library Version |
| prim1116.png | Not Equal To 0? | 33x21 | WriteConsole |
| prim1118.png | Less Than 0? | 32x21 | Excel_Cell_to_Value, Tokenize URL |
| prim1120.png | Sort 1D Array | 34x32 | GenerateTree |
| prim1124.png | (uncatalogued) | 34x28 | Read Library Version |
| prim1127.png | In Range and Coerce | 34x24 | IconHeader, Read VI Blocks |
| prim1128.png | Not A Number/Path/Refnum? | 34x27 | Excel_Read_XLSX, Read VI Blocks |
| prim1141.png | To Word Integer | 34x29 | Symbols1Bit |
| prim1142.png | To Long Integer | 31x11 | PNG CRC32, Excel_Cell_to_RowCol, MD5, Page1, Read VI Blocks, ReverseBitsVim |
| prim1143.png | To Unsigned Byte Integer | 29x11 | IconHeader, Page1, ReverseBitsVim, crc16 |
| prim1145.png | To Unsigned Long Integer | 34x34 | PNG CRC32, crc32_lookup_table |
| prim1147.png | To Double Precision Float | 34x25 | Excel_Cell_to_RowCol |
| prim1155.png | (uncatalogued) | 12x9 | MD5, Read VI Blocks |
| prim1156.png | (uncatalogued) | 34x11 | MD5 |
| prim1162.png | (uncatalogued) | 34x34 | MD5 |
| prim1163.png | (uncatalogued) | 34x34 | MD5 |
| prim1166.png | Type Cast | 31x27 | Config_Escape, Excel_Cell_to_Value |
| prim1167.png | Boolean To (0,1) | 32x32 | Config_Load, Config_Load2 |
| prim1170.png | (uncatalogued) | 33x18 | crc16, crc32 |
| prim1171.png | (uncatalogued) | 32x18 | Config_Escape, IconHeader, crc16, crc32 |
| prim1180.png | Number To Decimal String | 34x32 | Excel_Variant_Elements |
| prim1181.png | (uncatalogued) | 34x34 | MD5 |
| prim1184.png | Decimal String To Number | 34x19 | Excel_Cell_to_RowCol, Excel_Read_XLSX |
| prim1185.png | (uncatalogued) | 34x32 | Config_Escape |
| prim1188.png | (uncatalogued) | 33x11 | Config_Dump2, Excel_Cell_to_RowCol, Excel_Cell_to_Value |
| prim1189.png | To Lower Case | 34x28 | large, ClassChildren, ClassesInMemory |
| prim1213.png | (uncatalogued) | 34x32 | Excel_Cell_to_RowCol |
| prim1302.png | Wait (ms) | 33x32 | VISA_Query |
| prim1303.png | Get Date/Time In Seconds | 34x5 | Page1 |
| prim1419.png | Build Path | 30x30 | large, Excel_Read_XLSX, Resolve Path |
| prim1420.png | Strip Path | 33x33 | large, Excel_Read_XLSX, Read Library Version |
| prim1421.png | (uncatalogued) | 34x34 | Resolve Path |
| prim1435.png | (uncatalogued) | 29x18 | Excel_Read_XLSX |
| prim1502.png | String Length | 32x25 | Config_Load, Config_Load2, MD5 |
| prim1503.png | String Subset | 29x23 | Config_Load, Config_Load2, Excel_Read_XLSX |
| prim1516.png | Select | 29x27 | PNG CRC32, crc32_lookup_table, large, Config_Dump, Config_Dump2 |
| prim1534.png | (uncatalogued) | 34x32 | Excel_Cell_to_Value |
| prim1535.png | Match Pattern | 34x32 | ClassChildren, ClassesInMemory, Config_Dump, Config_Dump2 |
| prim1537.png | (uncatalogued) | 34x13 | Excel_Cell_to_RowCol |
| prim1539.png | Spreadsheet String To Array | 34x9 | Excel_Read_XLSX, Excel_Variant_Elements |
| prim1606.png | Rotate Left With Carry | 34x25 | crc16, crc32, crc8 |
| prim1608.png | String To Byte Array | 34x11 | PNG CRC32, Config_Escape, Excel_Cell_to_RowCol, MD5, Read Library Version, crc16, crc32 |
| prim1609.png | Byte Array To String | 34x11 | GetCurrentDirectory, Read Library Version, Read VI Blocks |
| prim1809.png | Array Size | 33x21 | large, ClassChildren, Config_Escape, Config_Load, Config_Load2 |
| prim1814.png | Number To Boolean Array | 33x11 | ReverseBitsVim, crc16, crc32, crc8 |
| prim1815.png | Boolean Array To Number | 33x23 | Config_Dump2, ReverseBitsVim, crc16, crc32, crc8 |
| prim1900.png | Reverse 1D Array | 32x23 | large, MD5, ReverseBitsVim, crc16, crc32, crc8 |
| prim1901.png | Search 1D Array | 31x30 | large, ClassChildren, ClassesInMemory, Config_Dump2, Excel_Cell_to_Value |
| prim1904.png | (uncatalogued) | 34x26 | Symbols1Bit |
| prim1907.png | Array Max & Min | 34x32 | ClassChildren |
| prim1922.png | (uncatalogued) | 33x32 | VISA_Open2 |
| prim1925.png | (uncatalogued) | 34x32 | VISA_Query |
| prim1926.png | (uncatalogued) | 34x32 | VISA_Query |
| prim1927.png | (uncatalogued) | 34x32 | VISA_Open2 |
| prim2073.png | Create User Event | 34x32 | Pages |
| prim2074.png | Generate User Event | 34x30 | Page1, Pages |
| prim2075.png | Destroy User Event | 30x28 | Pages |
| prim2076.png | Unregister For Events | 27x29 | Pages |
| prim2302.png | (uncatalogued) | 34x32 | VISA_Open2 |
| prim23063.png | Empty Array? | 25x21 | PNG CRC32, large, ClassChildren, Excel_Cell_to_Value, Excel_Variant_Elements, Export Palette Image WMF |
| prim2308.png | (uncatalogued) | 34x32 | VISA_Open2 |
| prim2452.png | (uncatalogued) | 34x32 | GenerateTree |
| prim2457.png | (uncatalogued) | 34x32 | GenerateTree |
| prim2458.png | (uncatalogued) | 34x32 | GenerateTree |
| prim3914.png | Search and Replace String | 19x34 | Excel_Read_XLSX |
| prim8003.png | Variant To Data | 30x3 | Excel_Variant_Elements, Pages |
| prim8010.png | Open VI Reference | 34x33 | Pages |
| prim8011.png | Close Reference | 34x32 | Pages, Resolve Library Path |
| prim8018.png | (uncatalogued) | 34x33 | ClassChildren |
| prim8050.png | Open/Create/Replace File | 34x32 | Read Library Version, Read VI Blocks |
| prim8051.png | (uncatalogued) | 29x3 | Read Library Version, Read VI Blocks |
| prim8052.png | Close File | 12x3 | Excel_Read_XLSX, Read Library Version, Read VI Blocks |
| prim8055.png | Create Folder | 34x32 | Excel_Read_XLSX |
| prim8056.png | Delete | 34x17 | Excel_Read_XLSX, Export Palette Image WMF |
| prim8063.png | Get File Size | 34x26 | Read VI Blocks |
| prim8065.png | (uncatalogued) | 34x32 | FileReadOnly |
| prim8070.png | Read from Text File | 34x25 | Excel_Read_XLSX, Read Library Version |
| prim8073.png | Set File Position | 30x3 | Read Library Version, Read VI Blocks |
| prim8076.png | (uncatalogued) | 34x32 | FileReadOnly |
| prim8082.png | File/Directory Info | 30x30 | large, Excel_Read_XLSX |
| prim8083.png | (uncatalogued) | 34x32 | large, Excel_Read_XLSX |
| prim8101.png | (uncatalogued) | 34x32 | Tokenize URL |
| prim8203.png | Variant To Flattened String | 34x34 | Excel_Variant_Elements |
| prim8204.png | Set Variant Attribute | 33x32 | Page1, Pages |
