const std = @import("std");
const testing = std.testing;
const ztoml = @import("ztoml");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

test "parse -> stringify -> parse is stable (Cargo.toml-shaped document)" {
    const allocator = testing.allocator;
    const src =
        \\name = "app"
        \\version = "1.0.0"
        \\
        \\[server]
        \\host = "localhost"
        \\port = 8080
        \\
        \\[[fruit]]
        \\name = "apple"
        \\
        \\[[fruit]]
        \\name = "banana"
    ;
    var doc1 = try ztoml.parse(allocator, src);
    defer doc1.deinit();

    const out = try ztoml.stringify(allocator, doc1);
    defer allocator.free(out);

    var doc2 = try ztoml.parse(allocator, out);
    defer doc2.deinit();

    try testing.expectEqualStrings("app", doc2.asObject().value.get("name").?.asString().value.data);
    try testing.expectEqualStrings("1.0.0", doc2.asObject().value.get("version").?.asString().value.data);
    const server = doc2.asObject().value.get("server").?;
    try testing.expectEqualStrings("localhost", server.asObject().value.get("host").?.asString().value.data);
    try testing.expectEqual(@as(f64, 8080), server.asObject().value.get("port").?.asNumber());
    const fruit = doc2.asObject().value.get("fruit").?.asArray().value.toSlice();
    try testing.expectEqual(@as(usize, 2), fruit.len);
    try testing.expectEqualStrings("apple", fruit[0].asObject().value.get("name").?.asString().value.data);
    try testing.expectEqualStrings("banana", fruit[1].asObject().value.get("name").?.asString().value.data);
}
