const std = @import("std");
const Writer = std.Io.Writer;
const cli = @import("../cli.zig");
const Ctx = @import("../Ctx.zig");

pub const command: cli.Command = .{
    .name = "completion",
    .summary = "Print a shell completion script for bash, zsh or fish.",
    .usage = "<bash|zsh|fish>",
    .min_args = 1,
    .max_args = 1,
    .run = run,
};

fn run(ctx: *Ctx, args: *const cli.Args) !u8 {
    const root = &@import("../app.zig").root;
    const shell = args.arg(0).?;
    if (std.mem.eql(u8, shell, "bash")) {
        try bash(ctx.out, root);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try ctx.out.writeAll("#compdef smith\nautoload -U +X bashcompinit && bashcompinit\n");
        try bash(ctx.out, root);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try fish(ctx.out, root);
    } else return ctx.fail("unsupported shell \"{s}\"; use bash, zsh or fish", .{shell});
    return 0;
}

const Visit = *const fn (w: *Writer, path: []const u8, cmd: *const cli.Command) Writer.Error!void;

fn walk(w: *Writer, buf: []u8, len: usize, cmd: *const cli.Command, visit: Visit) Writer.Error!void {
    try visit(w, buf[0..len], cmd);
    for (cmd.subs) |*sub| {
        var n = len;
        buf[n] = ' ';
        n += 1;
        @memcpy(buf[n..][0..sub.name.len], sub.name);
        n += sub.name.len;
        try walk(w, buf, n, sub, visit);
    }
}

fn bash(w: *Writer, root: *const cli.Command) !void {
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..root.name.len], root.name);
    try w.writeAll("declare -A _smith_subs _smith_flags\n");
    try walk(w, &buf, root.name.len, root, bashEntry);
    try w.writeAll(
        \\_smith() {
        \\    local cur=${COMP_WORDS[COMP_CWORD]} path=smith w i
        \\    for ((i = 1; i < COMP_CWORD; i++)); do
        \\        w=${COMP_WORDS[i]}
        \\        [[ $w == -* ]] && continue
        \\        [[ -n ${_smith_flags["$path $w"]+x} ]] || break
        \\        path="$path $w"
        \\    done
        \\    if [[ $cur == -* ]]; then
        \\        COMPREPLY=($(compgen -W "${_smith_flags[$path]} --help" -- "$cur"))
        \\    else
        \\        COMPREPLY=($(compgen -W "${_smith_subs[$path]}" -- "$cur"))
        \\    fi
        \\}
        \\complete -o default -F _smith smith
        \\
    );
}

fn bashEntry(w: *Writer, path: []const u8, cmd: *const cli.Command) Writer.Error!void {
    try w.print("_smith_subs[\"{s}\"]=\"", .{path});
    for (cmd.subs, 0..) |s, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", s.name });
    try w.print("\"\n_smith_flags[\"{s}\"]=\"", .{path});
    for (cmd.flags, 0..) |f, i| {
        try w.print("{s}--{s}", .{ if (i > 0) " " else "", f.long });
        if (f.short) |s| try w.print(" -{c}", .{s});
    }
    try w.writeAll("\"\n");
}

fn fish(w: *Writer, root: *const cli.Command) !void {
    var buf: [256]u8 = undefined;
    try w.writeAll(
        \\function __smith_path
        \\    set -l known
    );
    try walk(w, &buf, 0, root, fishKnown);
    try w.writeAll(
        \\
        \\    set -l toks (commandline -opc)
        \\    set -e toks[1]
        \\    set -l path ""
        \\    for t in $toks
        \\        string match -q -- '-*' $t; and continue
        \\        set -l next (string trim -- "$path $t")
        \\        contains -- $next $known; or break
        \\        set path $next
        \\    end
        \\    echo $path
        \\end
        \\complete -c smith -f
        \\
    );
    try walk(w, &buf, 0, root, fishEntry);
}

fn trimPath(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, " ");
}

fn fishKnown(w: *Writer, path: []const u8, cmd: *const cli.Command) Writer.Error!void {
    _ = cmd;
    if (trimPath(path).len > 0) try w.print(" \"{s}\"", .{trimPath(path)});
}

fn fishEntry(w: *Writer, path: []const u8, cmd: *const cli.Command) Writer.Error!void {
    const p = trimPath(path);
    for (cmd.subs) |s| {
        try w.print("complete -c smith -n 'test \"(__smith_path)\" = \"{s}\"' -a {s} -d '", .{ p, s.name });
        try fishQuoted(w, s.summary);
        try w.writeAll("'\n");
    }
    for (cmd.flags) |f| {
        try w.print("complete -c smith -n 'test \"(__smith_path)\" = \"{s}\"' -l {s}", .{ p, f.long });
        if (f.short) |s| try w.print(" -s {c}", .{s});
        if (f.value != null) try w.writeAll(" -r");
        try w.writeAll(" -d '");
        try fishQuoted(w, f.help);
        try w.writeAll("'\n");
    }
}

fn fishQuoted(w: *Writer, s: []const u8) !void {
    for (s) |c| {
        if (c == '\'' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
}
