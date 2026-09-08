///|
/// Root package of moon-ical.
///
/// The implementation lives in the subpackages: `ical/text` (RFC 5545 folding,
/// content lines, escaping) and `ical/model` (component tree, date-time, zone
/// table). This root package will become a re-export facade before the module
/// is published to mooncakes.io (plan step S9); until then it stays empty on
/// purpose so nothing half-finished leaks into the public API.
