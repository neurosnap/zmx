const std = @import("std");

pub const Shell = enum {
    bash,
    zsh,
    fish,

    pub fn fromString(s: []const u8) ?Shell {
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
        if (std.mem.eql(u8, s, "fish")) return .fish;

        return null;
    }

    pub fn getCompletionScript(self: Shell) []const u8 {
        return switch (self) {
            .bash => bash_completions,
            .zsh => zsh_completions,
            .fish => fish_completions,
        };
    }
};

const bash_completions =
    \\_zmx_completions() {
    \\  local cur prev words cword
    \\  COMPREPLY=()
    \\  cur="${COMP_WORDS[COMP_CWORD]}"
    \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\
    \\  local commands="attach run detach list completions kill history wait version help"
    \\
    \\  if [[ $COMP_CWORD -eq 1 ]]; then
    \\    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    \\    return 0
    \\  fi
    \\
    \\  case "$prev" in
    \\    attach|run|kill|history|wait)
    \\      local sessions=$(zmx list --short 2>/dev/null | tr '\n' ' ')
    \\      COMPREPLY=($(compgen -W "$sessions" -- "$cur"))
    \\      ;;
    \\    completions)
    \\      COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
    \\      ;;
    \\    list)
    \\      COMPREPLY=($(compgen -W "--short" -- "$cur"))
    \\      ;;
    \\    *)
    \\      ;;
    \\  esac
    \\}
    \\
    \\complete -o bashdefault -o default -F _zmx_completions zmx
;

const zsh_completions =
    \\_zmx() {
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
    \\        'attach:Attach to session, creating if needed'
    \\        'run:Send command without attaching'
    \\        'detach:Detach all clients from current session'
    \\        'list:List active sessions'
    \\        'completions:Shell completion scripts'
    \\        'kill:Kill a session'
    \\        'history:Output session scrollback'
    \\        'wait:Wait for session tasks to complete'
    \\        'version:Show version'
    \\        'help:Show help message'
    \\      )
    \\      _describe 'command' commands
    \\      ;;
    \\    args)
    \\      case $words[2] in
    \\        attach|a|kill|k|run|r|history|hi|wait|w)
    \\          _zmx_sessions
    \\          ;;
    \\        completions|c)
    \\          _values 'shell' 'bash' 'zsh' 'fish'
    \\          ;;
    \\        list|l)
    \\          _values 'options' '--short'
    \\          ;;
    \\      esac
    \\      ;;
    \\    trailing)
    \\      # Additional args for commands like 'attach' or 'run'
    \\      ;;
    \\  esac
    \\}
    \\
    \\_zmx_sessions() {
    \\  local -a sessions
    \\
    \\  local local_sessions=$(zmx list --short 2>/dev/null)
    \\  if [[ -n "$local_sessions" ]]; then
    \\    sessions+=(${(f)local_sessions})
    \\  fi
    \\
    \\  _describe 'local session' sessions
    \\}
    \\
    \\compdef _zmx zmx
;

const fish_completions =
    \\complete -c zmx -f
    \\
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'a attach' -d 'Attach to session, creating if needed'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'r run' -d 'Send command without attaching'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'd detach' -d 'Detach all clients from current session'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'l list' -d 'List active sessions'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'c completions' -d 'Shell completion scripts'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'k kill' -d 'Kill a session'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'hi history' -d 'Output session scrollback'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'v version' -d 'Show version'
    \\complete -c zmx -s v -l version -d 'Show version'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'w wait' -d 'Wait for session tasks to complete'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a 'h help' -d 'Show help message'
    \\complete -c zmx -s h -d 'Show help message'
    \\
    \\complete -c zmx -n "__fish_is_nth_token 2; and __fish_seen_subcommand_from a attach r run k kill hi history w wait" -a '(zmx list --short 2>/dev/null)' -d 'Session name'
    \\
    \\complete -c zmx -n "__fish_is_nth_token 2; and __fish_seen_subcommand_from c completions" -a 'bash zsh fish' -d Shell
    \\
    \\complete -c zmx -n "__fish_seen_subcommand_from l list" -l short -d 'Short output'
    \\complete -c zmx -n "__fish_seen_subcommand_from hi history" -l vt -d 'History format for escape sequences'
    \\complete -c zmx -n "__fish_seen_subcommand_from hi history" -l html -d 'History format for escape sequences'
;
