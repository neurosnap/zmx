const std = @import("std");
const fmt = std.fmt;

pub const Shell = enum {
    bash,
    zsh,
    fish,
    nu,

    pub fn fromString(s: []const u8) ?Shell {
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
        if (std.mem.eql(u8, s, "fish")) return .fish;
        if (std.mem.eql(u8, s, "nu")) return .nu;
        return null;
    }
};

pub fn bashScript(comptime cmds: anytype) []const u8 {
    return comptime blk: {
        var cmdList: []const u8 = "";
        var caseBody: []const u8 = "";
        for (cmds) |m| cmdList = cmdList ++ m.name ++ " ";
        for (cmds) |m| {
            const caseHeader = header: {
                var h: []const u8 = "    " ++ m.name;
                for (m.aliases) |alias| h = h ++ "|" ++ alias;
                break :header h ++ ")\n";
            };
            caseBody = caseBody ++ caseHeader;
            if (m.next_arg == .sessions) {
                const tmp_case_body =
                    \\      local sessions=$(nmux list --short 2>/dev/null | tr '\\n' ' ')
                    \\      COMPREPLY=($(compgen -W \"$sessions\" -- \"$cur\"))
                    \\      ;;
                    \\
                ;
                caseBody = caseBody ++ tmp_case_body;
            } else if (m.next_arg == .shells) {
                caseBody = caseBody ++
                    \\      COMPREPLY=($(compgen -W "bash zsh fish nu" -- "$cur"))
                    \\      ;;
                    \\
                ;
            } else if (m.flags.len > 0) {
                for (m.flags) |flag| {
                    caseBody = caseBody ++ "      COMPREPLY=($(compgen -W \"" ++ flag.name;
                    caseBody = caseBody ++
                        \\" -- "$cur"))
                        \\
                    ;
                }
                caseBody = caseBody ++
                    \\      ;;
                    \\
                ;
            }
        }
        break :blk @as([]const u8, fmt.comptimePrint(
            \\_nmux_completions() {{
            \\  local cur prev words cword
            \\  COMPREPLY=()
            \\  cur="${{COMP_WORDS[COMP_CWORD]}}"
            \\  prev="${{COMP_WORDS[COMP_CWORD-1]}}"
            \\  local commands="{[commands_list]s}"
            \\
            \\  if [[ $COMP_CWORD -eq 1 ]]; then
            \\    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
            \\    return 0
            \\  fi
            \\
            \\  case "$prev" in
            \\{[case_body]s}
            \\    *)
            \\      ;;
            \\  esac
            \\}}
            \\
            \\complete -o bashdefault -o default -F _nmux_completions nmux
        , .{ .commands_list = cmdList, .case_body = caseBody }));
    };
}

pub fn zshScript(comptime cmds: anytype) []const u8 {
    return comptime blk: {
        var entries: []const u8 = "";
        var cases: []const u8 = "";
        for (cmds) |m| {
            entries = entries ++ "        '" ++ m.name ++ ":" ++ m.help_line;
            entries = entries ++
                \\'
                \\
            ;
        }
        for (cmds) |m| {
            const caseHeader = header: {
                var h: []const u8 = "        " ++ m.name;
                for (m.aliases) |alias| h = h ++ "|" ++ alias;
                break :header h ++ ")\n";
            };
            cases = cases ++ caseHeader;
            if (m.next_arg == .sessions) {
                cases = cases ++
                    \\          _nmux_sessions
                    \\          ;;
                    \\
                ;
            } else if (m.next_arg == .shells) {
                cases = cases ++
                    \\          _values 'shell' 'bash' 'zsh' 'fish' 'nu'
                    \\          ;;
                    \\
                ;
            } else if (m.flags.len > 0) {
                cases = cases ++
                    \\          _values 'options'
                    \\
                ;
                for (m.flags) |flag| cases = cases ++ " '" ++ flag.name ++ "'";
                cases = cases ++
                    \\
                    \\          ;;
                    \\
                ;
            }
        }
        break :blk @as([]const u8, fmt.comptimePrint(
            \\#compdef nmux
            \\_nmux() {{
            \\  local context state state_descr line
            \\  typeset -A opt_args
            \\
            \\  _arguments -C \
            \\    '1: :->commands' \
            \\    '2: :->args' \
            \\    '*: :->trailing' \
            \\    && return 0
            \\
            \\  case $state in
            \\    commands)
            \\      local -a commands
            \\      commands=(
            \\
            \\{[command_entries]s}
            \\      )
            \\      _describe 'command' commands
            \\      ;;
            \\    args)
            \\      case $words[2] in
            \\{[cases_body]s}
            \\      esac
            \\      ;;
            \\    trailing)
            \\      ;;
            \\  esac
            \\}}
            \\
            \\_nmux_sessions() {{
            \\  local -a sessions
            \\
            \\  local local_sessions=$(nmux list --short 2>/dev/null)
            \\  if [[ -n "$local_sessions" ]]; then
            \\    sessions+=(${{(f)local_sessions}})
            \\  fi
            \\
            \\  _describe 'local session' sessions
            \\}}
            \\
            \\compdef _nmux nmux
        , .{ .command_entries = entries, .cases_body = cases }));
    };
}

pub fn fishScript(comptime cmds: anytype) []const u8 {
    return comptime blk: {
        var cmdCompl: []const u8 = "";
        var argCompl: []const u8 = "";
        var flagCompl: []const u8 = "";
        for (cmds) |m| {
            cmdCompl = cmdCompl ++ "complete -c nmux -n \"__fish_is_nth_token 1\" -a " ++ m.name ++ " -d '" ++ m.help_line;
            cmdCompl = cmdCompl ++
                \\'
                \\
            ;
            for (m.aliases) |alias| {
                cmdCompl = cmdCompl ++ "complete -c nmux -n \"__fish_is_nth_token 1\" -a " ++ alias ++ " -d '" ++ m.help_line;
                cmdCompl = cmdCompl ++
                    \\'
                    \\
                ;
            }
        }
        for (cmds) |m| {
            if (m.next_arg == .sessions) {
                argCompl = argCompl ++ "complete -c nmux -n \"__fish_is_nth_token 2; and __fish_seen_subcommand_from " ++ m.name ++ "\" -a '(nmux list --short 2>/dev/null)' -d 'Session name'";
                argCompl = argCompl ++
                    \\'
                    \\
                ;
            } else if (m.next_arg == .shells) {
                argCompl = argCompl ++ "complete -c nmux -n \"__fish_is_nth_token 2; and __fish_seen_subcommand_from " ++ m.name ++ "\" -a 'bash zsh fish nu' -d Shell";
                argCompl = argCompl ++
                    \\
                    \\
                ;
            }
        }
        for (cmds) |m| {
            if (m.flags.len == 0) continue;
            for (m.flags) |flag| {
                flagCompl = flagCompl ++ "complete -c nmux -n \"__fish_seen_subcommand_from " ++ m.name ++ "\" -a '" ++ flag.name ++ "' -d '" ++ flag.description;
                flagCompl = flagCompl ++
                    \\'
                    \\
                ;
            }
        }
        break :blk @as([]const u8, fmt.comptimePrint(
            \\complete -c nmux -f
            \\{[command_completions]s}
            \\{[arg_completions]s}
            \\{[flag_completions]s}
        , .{ .command_completions = cmdCompl, .arg_completions = argCompl, .flag_completions = flagCompl }));
    };
}

pub fn nuScript(comptime cmds: anytype) []const u8 {
    return comptime blk: {
        var externs: []const u8 = "";
        for (cmds) |m| {
            externs = externs ++ "export extern \"nmux " ++ m.name;
            externs = externs ++
                \\" [
                \\
            ;
            if (m.next_arg == .sessions) {
                externs = externs ++ "    name: string@\"nu-complete nmux sessions\"";
                externs = externs ++
                    \\
                    \\
                ;
            } else if (m.next_arg == .shells) {
                externs = externs ++ "    shell: string@\"nu-complete nmux complete\"";
                externs = externs ++
                    \\
                    \\
                ;
            }
            for (m.flags) |flag| {
                externs = externs ++ "    --" ++ flag.name;
                externs = externs ++
                    \\
                    \\
                ;
            }
            externs = externs ++ "]";
            externs = externs ++
                \\
                \\
                \\
            ;
        }
        break :blk @as([]const u8, fmt.comptimePrint(
            \\def "nu-complete nmux sessions" [] {{
            \\    nmux list --short | lines
            \\}}
            \\
            \\def "nu-complete nmux complete" [] {{
            \\    [bash fish nu zsh]
            \\}}
            \\
            \\{[command_externs]s}
        , .{ .command_externs = externs }));
    };
}
