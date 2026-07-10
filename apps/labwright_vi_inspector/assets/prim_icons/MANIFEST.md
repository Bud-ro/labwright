# Primitive icon assets

Generated from LabVIEW's own renders in the snippet corpus (see
test/extract_prim_icons_test.dart): the cleanest registered node crop
per primResID, trimmed to its ink, exterior background transparent.
Hand-edits welcome — the painter stamps these at natural size.

| id | op | size | source |
|---|---|---|---|
| 1050 | Add | 34x21 | basic |
| 1051 | Subtract | 34x5 | Config_Load |
| 1052 | Multiply | 34x27 | Excel_Read_XLSX |
| 1056 | (uncatalogued) | 34x28 | MD5 |
| 1057 | Increment | 34x28 | Config_Escape |
| 1058 | Decrement | 34x2 | Excel_Read_XLSX |
| 1061 | And | 33x16 | large |
| 1062 | Or | 34x2 | Config_Load2 |
| 1063 | Exclusive Or | 34x16 | PNG CRC32 |
| 1064 | Not | 34x22 | Excel_Read_XLSX |
| 1069 | (uncatalogued) | 34x27 | GenerateTree |
| 1070 | Random Number (0-1) | 25x21 | Excel_Read_XLSX |
| 1077 | Path To String | 34x9 | Excel_Read_XLSX |
| 1078 | String To Path | 34x11 | GetCurrentDirectory |
| 1081 | Logical Shift | 34x15 | MD5 |
| 1082 | (uncatalogued) | 34x24 | MD5 |
| 1102 | Equal? | 29x19 | Excel_Read_XLSX |
| 1103 | (uncatalogued) | 34x1 | Read VI Blocks |
| 1105 | Not Equal? | 34x31 | large |
| 1110 | Greater? | 33x21 | example |
| 1112 | Empty String/Path? | 34x21 | Config_Dump |
| 1113 | Equal To 0? | 6x34 | Config_Load2 |
| 1114 | Greater Or Equal To 0? | 33x28 | ClassChildren |
| 1116 | Not Equal To 0? | 33x21 | WriteConsole |
| 1118 | Less Than 0? | 34x21 | Excel_Cell_to_Value |
| 1120 | Sort 1D Array | 34x32 | GenerateTree |
| 1124 | (uncatalogued) | 34x28 | Read Library Version |
| 1127 | In Range and Coerce | 34x2 | Read VI Blocks |
| 1128 | Not A Number/Path/Refnum? | 34x27 | Read VI Blocks |
| 1141 | To Word Integer | 34x28 | Symbols1Bit |
| 1142 | To Long Integer | 34x11 | PNG CRC32 |
| 1143 | To Unsigned Byte Integer | 34x11 | IconHeader |
| 1145 | To Unsigned Long Integer | 34x11 | crc32_lookup_table |
| 1147 | To Double Precision Float | 34x34 | Excel_Cell_to_RowCol |
| 1155 | (uncatalogued) | 34x25 | Read VI Blocks |
| 1156 | (uncatalogued) | 34x11 | MD5 |
| 1162 | (uncatalogued) | 34x32 | MD5 |
| 1163 | (uncatalogued) | 34x32 | MD5 |
| 1164 | Flatten To String | 34x3 | Excel_Cell_to_Value |
| 1166 | Type Cast | 34x13 | Config_Escape |
| 1167 | Boolean To (0,1) | 34x14 | Config_Load |
| 1170 | (uncatalogued) | 34x22 | crc32 |
| 1171 | (uncatalogued) | 32x26 | IconHeader |
| 1180 | Number To Decimal String | 34x32 | Excel_Variant_Elements |
| 1181 | (uncatalogued) | 34x33 | MD5 |
| 1184 | Decimal String To Number | 34x19 | Excel_Read_XLSX |
| 1185 | (uncatalogued) | 34x32 | Config_Escape |
| 1188 | (uncatalogued) | 34x22 | Config_Dump2 |
| 1189 | To Lower Case | 34x22 | large |
| 1213 | (uncatalogued) | 34x32 | Excel_Cell_to_RowCol |
| 1302 | Wait (ms) | 33x32 | VISA_Query |
| 1303 | Get Date/Time In Seconds | 34x5 | Page1 |
| 1419 | Build Path | 34x7 | Excel_Read_XLSX |
| 1420 | Strip Path | 34x11 | large |
| 1421 | (uncatalogued) | 34x34 | Resolve Path |
| 1435 | (uncatalogued) | 29x18 | Excel_Read_XLSX |
| 1502 | String Length | 34x6 | Config_Load |
| 1503 | String Subset | 34x5 | Config_Load |
| 1516 | Select | 34x27 | PNG CRC32 |
| 1534 | (uncatalogued) | 34x32 | Excel_Cell_to_Value |
| 1535 | Match Pattern | 34x32 | ClassChildren |
| 1537 | (uncatalogued) | 34x23 | Excel_Cell_to_RowCol |
| 1539 | Spreadsheet String To Array | 34x19 | Excel_Read_XLSX |
| 1606 | Rotate Left With Carry | 34x25 | crc16 |
| 1608 | String To Byte Array | 34x11 | Config_Escape |
| 1609 | Byte Array To String | 34x2 | Read VI Blocks |
| 1809 | Array Size | 34x21 | large |
| 1814 | Number To Boolean Array | 34x11 | ReverseBitsVim |
| 1815 | Boolean Array To Number | 34x22 | Config_Dump2 |
| 1900 | Reverse 1D Array | 34x23 | large |
| 1901 | Search 1D Array | 34x18 | large |
| 1904 | (uncatalogued) | 34x32 | Symbols1Bit |
| 1907 | Array Max & Min | 34x32 | ClassChildren |
| 1908 | (uncatalogued) | 34x3 | Excel_Read_XLSX |
| 1922 | (uncatalogued) | 33x32 | VISA_Open2 |
| 1925 | (uncatalogued) | 34x32 | VISA_Query |
| 1926 | (uncatalogued) | 34x32 | VISA_Query |
| 1927 | (uncatalogued) | 34x32 | VISA_Open2 |
| 2073 | Create User Event | 34x32 | Pages |
| 2074 | Generate User Event | 34x30 | Pages |
| 2075 | Destroy User Event | 34x34 | Pages |
| 2076 | Unregister For Events | 34x34 | Pages |
| 2302 | (uncatalogued) | 34x32 | VISA_Open2 |
| 2308 | (uncatalogued) | 34x32 | VISA_Open2 |
| 2452 | (uncatalogued) | 34x32 | GenerateTree |
| 2457 | (uncatalogued) | 34x32 | GenerateTree |
| 2458 | (uncatalogued) | 34x32 | GenerateTree |
| 3914 | Search and Replace String | 19x34 | Excel_Read_XLSX |
| 8003 | Variant To Data | 34x3 | Pages |
| 8010 | Open VI Reference | 34x33 | Pages |
| 8011 | Close Reference | 34x1 | Resolve Library Path |
| 8018 | (uncatalogued) | 34x33 | ClassChildren |
| 8050 | Open/Create/Replace File | 34x32 | Read Library Version |
| 8051 | (uncatalogued) | 34x19 | Read VI Blocks |
| 8052 | Close File | 34x3 | Excel_Read_XLSX |
| 8055 | Create Folder | 34x32 | Excel_Read_XLSX |
| 8056 | Delete | 34x17 | Excel_Read_XLSX |
| 8063 | Get File Size | 34x26 | Read VI Blocks |
| 8065 | (uncatalogued) | 34x33 | FileReadOnly |
| 8070 | Read from Text File | 34x25 | Excel_Read_XLSX |
| 8073 | Set File Position | 34x19 | Read VI Blocks |
| 8076 | (uncatalogued) | 34x33 | FileReadOnly |
| 8082 | File/Directory Info | 34x2 | Excel_Read_XLSX |
| 8083 | (uncatalogued) | 34x32 | large |
| 8101 | (uncatalogued) | 34x32 | Tokenize URL |
| 8203 | Variant To Flattened String | 34x32 | Excel_Variant_Elements |
| 8204 | Set Variant Attribute | 34x3 | Pages |
| 8205 | Get Variant Attribute | 34x3 | Page1 |
| 23063 | Empty Array? | 34x27 | ClassChildren |
