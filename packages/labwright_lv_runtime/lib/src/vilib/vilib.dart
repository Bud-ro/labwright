/// The VIs of LabVIEW's own library (`<vilib>`), each implemented as a function that takes the
/// VI's wired connector-pane terminals as named parameters and returns its indicators: one
/// value, or a record of them named as the indicators are.
library;

export 'application_directory.dart';
export 'color_to_rgb.dart';
export 'error_cluster_from_error_code.dart';
export 'space_constant.dart';
export 'trim_whitespace.dart';
