const std = @import("std");

// See https://www.anthropicstudios.com/2020/03/30/symmetric-matrices/
// TODO(mason): packed?
pub fn SymmetricMatrix(comptime Enum: type, comptime Value: type) type {
    // The length is equal to the upper right half of the matrix, ounding up. We calculate it by
    // dividing the full size of the matrix by two, and then adding back the half of the diagonal
    // that we lost to integer rounding.
    const fields = @typeInfo(Enum).Enum.fields.len;
    const len = (fields * fields + fields) / 2;

    return struct {
        values: [len]Value,

        pub fn init(default: Value) @This() {
            return .{
                .values = [_]Value{default} ** len,
            };
        }

        fn index(a: Enum, b: Enum) usize {
            // Get the low and high indices
            const a_int: usize = @enumToInt(a);
            const b_int: usize = @enumToInt(b);

            const low = std.math.min(a_int, b_int);
            const high = std.math.max(a_int, b_int);

            // Calculate the index (triangle number + offset into the row)
            const tri = high * (high + 1) / 2;
            const col = low;

            // Calculate the resulting index and return it
            return tri + col;
        }

        pub fn get(self: *const @This(), a: Enum, b: Enum) Value {
            return self.values[index(a, b)];
        }

        pub fn set(self: *@This(), a: Enum, b: Enum, value: Value) void {
            self.values[index(a, b)] = value;
        }
    };
}

test "symmetric matrix" {
    // Set up a matrix and fill it with ordered indices
    const Four = enum { zero, one, two, three };
    var matrix = SymmetricMatrix(Four, u8).init(0);
    try std.testing.expectEqual(10, matrix.values.len);

    const inputs = .{
        .{ .zero, .zero },
        .{ .one, .zero },
        .{ .one, .one },
        .{ .two, .zero },
        .{ .two, .one },
        .{ .two, .two },
        .{ .three, .zero },
        .{ .three, .one },
        .{ .three, .two },
        .{ .three, .three },
    };
    inline for (inputs, 0..) |input, i| {
        matrix.set(input[0], input[1], i);
    }
    inline for (inputs, 0..) |input, i| {
        try std.testing.expect(matrix.get(input[0], input[1]) == i);
        try std.testing.expect(matrix.get(input[1], input[0]) == i);
    }
    inline for (inputs, 0..) |input, i| {
        matrix.set(input[1], input[0], i);
    }
    inline for (inputs, 0..) |input, i| {
        try std.testing.expect(matrix.get(input[0], input[1]) == i);
        try std.testing.expect(matrix.get(input[1], input[0]) == i);
    }
}
