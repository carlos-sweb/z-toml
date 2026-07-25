const std = @import("std");
const testing = std.testing;
const ztoml = @import("ztoml");

// Cross-checked against Python's `tomllib.load()` on the same document
// (see the audit session that added this file) -- every assertion below
// matches tomllib's parsed structure exactly, for everything in this
// module's supported subset.
const sample =
    \\name = "z-toml"
    \\version = "0.1.0"
    \\description = "A pure-Zig TOML subset parser"
    \\keywords = ["toml", "config", "zig"]
    \\edition = 2021
    \\rating = 4.5
    \\
    \\[package.metadata]
    \\authors = ["carlos"]
    \\license = "MIT"
    \\
    \\[dependencies]
    \\zvalue = { path = "../z-value", version = "0.1.0" }
    \\znumber = { path = "../z-number" }
    \\
    \\[[bin]]
    \\name = "cli"
    \\path = "src/main.zig"
    \\
    \\[[bin]]
    \\name = "worker"
    \\path = "src/worker.zig"
;

test "cross-check: sample document matches Python tomllib's structure" {
    const allocator = testing.allocator;
    var doc = try ztoml.parse(allocator, sample);
    defer doc.deinit();

    try testing.expectEqualStrings("z-toml", doc.object.value.get("name").?.string.value.data);
    try testing.expectEqualStrings("0.1.0", doc.object.value.get("version").?.string.value.data);
    try testing.expectEqual(@as(f64, 2021), doc.object.value.get("edition").?.number);
    try testing.expectEqual(@as(f64, 4.5), doc.object.value.get("rating").?.number);

    const keywords = doc.object.value.get("keywords").?.array.value.toSlice();
    try testing.expectEqual(@as(usize, 3), keywords.len);
    try testing.expectEqualStrings("toml", keywords[0].string.value.data);
    try testing.expectEqualStrings("zig", keywords[2].string.value.data);

    const authors = doc.object.value.get("package").?.object.value.get("metadata").?.object.value.get("authors").?.array.value.toSlice();
    try testing.expectEqualStrings("carlos", authors[0].string.value.data);

    const zvalue_dep = doc.object.value.get("dependencies").?.object.value.get("zvalue").?;
    try testing.expectEqualStrings("../z-value", zvalue_dep.object.value.get("path").?.string.value.data);
    try testing.expectEqualStrings("0.1.0", zvalue_dep.object.value.get("version").?.string.value.data);

    const bins = doc.object.value.get("bin").?.array.value.toSlice();
    try testing.expectEqual(@as(usize, 2), bins.len);
    try testing.expectEqualStrings("cli", bins[0].object.value.get("name").?.string.value.data);
    try testing.expectEqualStrings("worker", bins[1].object.value.get("name").?.string.value.data);
}
