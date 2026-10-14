/// `Color to RGB.vi`: the red, green and blue bytes of a LabVIEW colour word, `0x00RRGGBB`.
({int red, int green, int blue}) lvColorToRgb({required int color}) =>
    (red: (color >> 16) & 0xff, green: (color >> 8) & 0xff, blue: color & 0xff);
