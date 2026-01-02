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
    \\  local commands="attach run detach list completions kill history version help"
    \\
    \\  if [[ $COMP_CWORD -eq 1 ]]; then
    \\    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    \\    return 0
    \\  fi
    \\
    \\  case "$prev" in
    \\    attach|run|kill|history)
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
    \\        'version:Show version'
    \\        'help:Show help message'
    \\      )
    \\      _describe 'command' commands
    \\      ;;
    \\    args)
    \\      case $words[2] in
    \\        attach|a|kill|k|run|r|history|hi)
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
    \\set -l subcommands attach run detach list completions kill history version help
    \\set -l no_subcmd "not __fish_seen_subcommand_from $subcommands"
    \\
    \\complete -c zmx -n $no_subcmd -a attach -d 'Attach to session, creating if needed'
    \\complete -c zmx -n $no_subcmd -a run -d 'Send command without attaching'
    \\complete -c zmx -n $no_subcmd -a detach -d 'Detach all clients from current session'
    \\complete -c zmx -n $no_subcmd -a list -d 'List active sessions'
    \\complete -c zmx -n $no_subcmd -a completions -d 'Shell completion scripts'
    \\complete -c zmx -n $no_subcmd -a kill -d 'Kill a session'
    \\complete -c zmx -n $no_subcmd -a history -d 'Output session scrollback'
    \\complete -c zmx -n $no_subcmd -a version -d 'Show version'
    \\complete -c zmx -n $no_subcmd -a help -d 'Show help message'
    \\
    \\complete -c zmx -n "__fish_seen_subcommand_from attach run kill history" -a '(zmx list --short 2>/dev/null)' -d 'Session name'
    \\
    \\complete -c zmx -n "__fish_seen_subcommand_from completions" -a 'bash zsh fish' -d 'Shell'
    \\
    \\complete -c zmx -n "__fish_seen_subcommand_from list" -l short -d 'Short output'
;
