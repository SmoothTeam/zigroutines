
const std = @import("std");
const zr = @import("zigroutines");

test "cancel: starts clear and can fire" {
    var token = zr.CancelToken.init();
    defer token.deinit();
    try token.check();
    token.cancel();
    try std.testing.expect(token.isCanceled());
    try std.testing.expectError(error.Canceled, token.check());
}
