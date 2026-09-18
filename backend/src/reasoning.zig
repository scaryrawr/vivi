const std = @import("std");

pub const Effort = enum {
    off,
    low,
    medium,
    high,
    xhigh,
    max,

    pub fn parse(value: []const u8) !Effort {
        inline for (std.meta.tags(Effort)) |effort| {
            if (std.mem.eql(u8, value, @tagName(effort))) return effort;
        }
        return error.InvalidReasoningEffort;
    }
};
