//! Internal profiling access; the public query module/API does not expose this.
pub const Program = @import("root.zig").Program;
pub const Diagnostic = @import("diagnostic.zig").Diagnostic;
pub const Execution = @import("execution.zig");
pub const input = @import("input.zig");
pub const Evaluator = @import("evaluator.zig").Evaluator;
pub const RowOps = @import("rows.zig");
pub const JsonOrder = @import("json_order.zig");
