const testing = @import("std").testing;
pub const sdk = @import("./sdk/sdk.zig");

test {
    testing.refAllDecls(sdk);
}
