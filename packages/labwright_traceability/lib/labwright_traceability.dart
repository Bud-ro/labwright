/// Requirement traceability for Labwright.
///
/// Load the org's requirements with [parseRequirements] (validate the file first
/// with [lintRequirements]), run tests whose phases and measurements carry
/// `RequirementRef`s, then [buildTraceMatrix] for a [TraceMatrix] reporting
/// coverage, hash drift, and unknown references. Render it with [traceReport]
/// (text) or [traceMatrixToJson] (machine-readable for CI/dashboards).
library;

export 'src/requirements.dart';
export 'src/trace.dart';
