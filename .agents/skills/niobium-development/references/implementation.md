# Implementation rules

## Zig 0.17 essentials (pitfalls actually hit in this repository)

| Old form | 0.17 form |
|---|---|
| `@typeInfo(T).@"struct".fields` | `std.meta.fieldNames(T)` and `@FieldType(T, name)`, or `field_names/field_types/field_attrs` |
| `"ab" ** n`, `[1]T{v} ** n` | Fill in a loop, or `@splat(v)` |
| `@intFromEnum` / `@enumFromInt` | `@backingInt` / `@fromBackingInt` |
| `std.builtin.OptimizeMode`, `.ReleaseSafe` | `std.lang.Optimize`, `.safe` |
| `b.pathFromRoot(...)` | Removed: after `setCwd(b.path("."))` on the Run step pass a relative path, or use `addDirectoryArg` |
| `b.findProgram` | `b.findProgramLazy` (does not pollute the configure cache) |
| `if (b.args) \|a\| run.addArgs(a)` | `run.addPassthruArgs()` |
| `linkSystemLibrary("user32", .{})` | `.{ .use_pkg_config = .no }` (0.17 uses pkg-config by default) |
| `@cImport` | Hand-written `extern` in `third_party/<lib>/bindings.zig` |
| `std.fmt.allocPrint(a, ...)` | `a.print(...)` |
| `errdefer \|err\|` | Split the function, then `catch \|err\|` |
| `DebugAllocator` | `SafeAllocator` (`std.testing.allocator` is one) |
| main signature | `pub fn main(init: std.process.Init) !void`; `init.io`, `init.gpa`, `init.arena` |
| Processes | `std.process.spawn(io, .{ .argv, .stdin = .pipe, ... })`, `std.process.run(gpa, io, .{ .timeout })` |
| Files | `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(n))`, `dir.writeFile(io, .{ ... })` |

## Symbols exported by dependencies

The libc hooks for `stb_truetype` are `export`ed by `bindings.zig`. Any artifact that links `ui_render` must reference it in the compilation graph (`libs/ui/render/root.zig` already references it at `comptime`); otherwise linking fails with `undefined symbol: _nb_stbtt_*`.

## Errors and exit codes

- Each module defines its own error set; `engine` merges them, and `core.exit_code.fromError` maps them to the `cli-v1` table. A new error must appear in the mapping, otherwise compilation fails (exhaustive switch).
- C ABI: `nb_status` = `-exit_code`.

## Phases and side effects

- `Prepare` downloads, verifies through TUF, and unpacks into staging before `Execute` starts.
- `Execute` writes only `versions/<seq>` and never touches `current`; `Commit` is the pointer swap ([ADR-0006](../../../../docs/adr/0006-transaction-and-pointer-swap-commit.md)).
- The privilege helper lives inside one transaction. When it is lost, the transaction aborts and recovery takes over ([ADR-0007](../../../../docs/adr/0007-same-binary-privilege-helper.md)).
- Work that can outlive its caller (helper, download, App Bootstrap) has an owner, a bound from `contracts.Limits`, and an outcome that is journaled or reported.

## Platform code

- OS APIs and `@ptrCast` appear only in `libs/platform/<os>/` and `libs/ui/backend/<os>/`.
- Windows paths are always converted to UTF-16 with the `\\?\` prefix; do not use ANSI APIs.
- For the platform pitfall list, see the `niobium-platform-capability` skill.

## Writing tests

- Unit tests sit right next to the implementation; cross-module scenarios go in `tests/<suite>/`.
- Parsers: `std.testing.checkAllAllocationFailures` + a fuzz target.
- Do not sleep; use the controllable clock and failpoints of `platform.virtual`.
