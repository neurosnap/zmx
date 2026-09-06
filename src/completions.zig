const std = @import("std");

pub const Shell = enum {
    bash,
    zsh,
    fish,
    nu,
    yash,

    pub fn fromString(s: []const u8) ?Shell {
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
        if (std.mem.eql(u8, s, "fish")) return .fish;
        if (std.mem.eql(u8, s, "nu")) return .nu;
        if (std.mem.eql(u8, s, "yash")) return .yash;

        return null;
    }

    pub fn getCompletionScript(self: Shell) []const u8 {
        return switch (self) {
            .bash => bash_completions,
            .zsh => zsh_completions,
            .fish => fish_completions,
            .nu => nu_completions,
            .yash => yash_completions,
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
    \\  local commands="attach run send print write detach list kill history get set clear print-env wait tail completions version help"
    \\
    \\  if [[ $COMP_CWORD -eq 1 ]]; then
    \\    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    \\    return 0
    \\  fi
    \\
    \\  case "$prev" in
    \\    attach|run|send|print|write|kill|get|set|clear|print-env|wait|tail)
    \\      local sessions=$(zmx list --short 2>/dev/null | tr '\n' ' ')
    \\      COMPREPLY=($(compgen -W "$sessions" -- "$cur"))
    \\      ;;
    \\    history)
    \\      local sessions=$(zmx list --short 2>/dev/null | tr '\n' ' ')
    \\      COMPREPLY=($(compgen -W "--screen --scrollback --vt --html $sessions" -- "$cur"))
    \\      ;;
    \\    completions)
    \\      COMPREPLY=($(compgen -W "bash zsh fish nu yash" -- "$cur"))
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
    \\#compdef zmx
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
    \\        'send:Send raw input to session PTY'
    \\        'print:Inject text into session display'
    \\        'write:Write stdin to file_path through the session'
    \\        'detach:Detach all clients from current session'
    \\        'list:List active sessions'
    \\        'kill:Kill a session'
    \\        'history:Output session scrollback'
    \\        'wait:Wait for session tasks to complete'
    \\        'tail:Follow session output'
    \\        'completions:Shell completion scripts'
    \\        'get:Get session labels'
    \\        'set:Set session labels'
    \\        'clear:Clear all session labels'
    \\        'print-env:Print tracked environment variables'
    \\        'version:Show version'
    \\        'help:Show help message'
    \\      )
    \\      _describe 'command' commands
    \\      ;;
    \\    args)
    \\      case $words[2] in
    \\        attach|a|kill|k|run|r|send|s|print|p|write|wr|get|g|set|clear|print-env|wait|w|tail|t)
    \\          _zmx_sessions
    \\          ;;
    \\        history|hi)
    \\          _zmx_sessions
    \\          _values 'options' '--screen' '--scrollback' '--vt' '--html'
    \\          ;;
    \\        completions|c)
    \\          _values 'shell' 'bash' 'zsh' 'fish' 'nu' 'yash'
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
    \\# zmx flags
    \\complete -c zmx -x -n '__fish_is_nth_token 1' -s v -l version -d 'Show version'
    \\complete -c zmx -x -n '__fish_is_nth_token 1' -s h -d 'Show help message'
    \\
    \\# zmx subcommands
    \\complete -c zmx -n "__fish_is_nth_token 1" -a attach -d 'Attach to session, creating if needed'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a run -d 'Send command without attaching'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a send -d 'Send raw input to session PTY'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a print -d 'Inject text into session display'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a write -d 'Write stdin to file_path through the session'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a detach -d 'Detach all clients (ctrl+\ for current client)'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a list -d 'List active sessions'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a kill -d 'Kill session and all attached clients'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a history -d 'Output session scrollback'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a wait -d 'Wait for session tasks to complete'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a tail -d 'Follow session output'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a completions -d 'Shell completions (bash, zsh, fish, nu, yash)'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a version -d 'Show version'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a get -d 'Get session labels'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a set -d 'Set session labels'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a clear -d 'Clear all session labels'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a print-env -d 'Print tracked environment variables'
    \\complete -c zmx -n "__fish_is_nth_token 1" -a help -d 'Show help message'
    \\
    \\# Complete session names and shells
    \\complete -c zmx -n "__fish_is_nth_token 2; and __fish_seen_subcommand_from a attach r run s send p print wr write hi history g get se set cl clear print-env" -a '(zmx list --short 2>/dev/null)' -d 'Session name'
    \\complete -c zmx -n "not __fish_is_nth_token 1; and __fish_seen_subcommand_from k kill w wait t tail" -a '(zmx list --short 2>/dev/null)' -d 'Session name'
    \\
    \\complete -c zmx -n "__fish_is_nth_token 2; and __fish_seen_subcommand_from c completions" -a 'bash zsh fish nu yash' -d Shell
    \\
    \\# Subcommand flags
    \\complete -c zmx -n "__fish_seen_subcommand_from a attach" -l labels -d 'Apply "key=value ..." labels as the session is created' -r
    \\complete -c zmx -n "__fish_seen_subcommand_from r run" -s d -d 'Detach from the calling terminal; use `wait` to track its status'
    \\complete -c zmx -n "__fish_seen_subcommand_from r run" -l fish -d 'Required when the session runs fish shell'
    \\complete -c zmx -n "__fish_seen_subcommand_from l list" -l short -d 'Short output'
    \\complete -c zmx -n "__fish_seen_subcommand_from k kill" -l force -d 'Force kill'
    \\complete -c zmx -n "__fish_seen_subcommand_from hi history" -l vt -d 'History format for escape sequences'
    \\complete -c zmx -n "__fish_seen_subcommand_from hi history" -l html -d 'History format for escape sequences'
    \\complete -c zmx -n "__fish_seen_subcommand_from hi history" -l screen -d 'Output only the active screen'
    \\complete -c zmx -n "__fish_seen_subcommand_from hi history" -l scrollback -d 'Rows of scrollback to add above the screen' -r
    \\complete -c zmx -n "__fish_seen_subcommand_from print-env" -s s -l shell -d 'Output POSIX export/unset commands for eval'
;

const nu_completions =
    \\def "nu-complete zmx sessions" [] {
    \\    zmx list --short | lines
    \\}
    \\
    \\def "nu-complete zmx complete" [] {
    \\    [bash fish nu yash zsh]
    \\}
    \\
    \\export extern "zmx attach" [
    \\    name: string@"nu-complete zmx sessions"
    \\    --labels: string
    \\    ...rest: string
    \\]
    \\
    \\export extern "zmx run" [
    \\    name: string@"nu-complete zmx sessions"
    \\    -d
    \\    --fish
    \\    ...rest: string
    \\]
    \\
    \\export extern "zmx send" [
    \\    name: string@"nu-complete zmx sessions"
    \\    text: string
    \\]
    \\
    \\export extern "zmx print" [
    \\    name: string@"nu-complete zmx sessions"
    \\    text: string
    \\]
    \\
    \\export extern "zmx write" [
    \\    name: string@"nu-complete zmx sessions"
    \\    path: path
    \\]
    \\
    \\export extern "zmx kill" [
    \\    --force
    \\    name: string@"nu-complete zmx sessions"
    \\]
    \\
    \\export extern "zmx detach" []
    \\export extern "zmx list" [--short]
    \\export extern "zmx history" [name: string@"nu-complete zmx sessions", --vt, --html, --screen, --scrollback: int]
    \\export extern "zmx wait" [...sessions: string@"nu-complete zmx sessions"]
    \\export extern "zmx tail" [...sessions: string@"nu-complete zmx sessions"]
    \\export extern "zmx version" []
    \\export extern "completions" [shell: string@"nu-complete zmx complete"]
    \\export extern "zmx get" [
    \\    name?: string@"nu-complete zmx sessions"
    \\]
    \\
    \\export extern "zmx set" [
    \\    name?: string@"nu-complete zmx sessions"
    \\    ...pairs: string
    \\]
    \\
    \\export extern "zmx clear" [
    \\    name?: string@"nu-complete zmx sessions"
    \\]
    \\
    \\export extern "zmx print-env" [
    \\    name: string@"nu-complete zmx sessions"
    \\    key?: string
    \\    --shell(-s)
    \\]
    \\
    \\export extern "zmx help" []
;

const yash_completions =
    \\function completion/zmx {
    \\    typeset OPTIONS ARGOPT PREFIX
    \\    OPTIONS=( #>#
    \\        "v --version; show version"
    \\        "h; show help"
    \\    ) #<#
    \\
    \\    command -f completion//parseoptions -e
    \\    case $ARGOPT in
    \\    (-)
    \\        command -f completion//completeoptions
    \\        ;;
    \\    ("")
    \\        if [ ${WORDS[#]} -le 1 ]; then
    \\            command -f completion/zmx::completecmd
    \\        else
    \\            typeset zmxcmd="${WORDS[2]}"
    \\            case $zmxcmd in
    \\            (a|attach)
    \\                command -f completion/zmx::attach:arg
    \\                ;;
    \\            (r|run)
    \\                command -f completion/zmx::run:arg
    \\                ;;
    \\            (s|send)
    \\                command -f completion/zmx::send:arg
    \\                ;;
    \\            (p|print)
    \\                command -f completion/zmx::print:arg
    \\                ;;
    \\            (wr|write)
    \\                command -f completion/zmx::write:arg
    \\                ;;
    \\            (d|detach)
    \\                ;;
    \\            (l|ls|list)
    \\                command -f completion/zmx::list:arg
    \\                ;;
    \\            (g|get)
    \\                command -f completion/zmx::get:arg
    \\                ;;
    \\            (set)
    \\                command -f completion/zmx::set:arg
    \\                ;;
    \\            (cl|clear)
    \\                command -f completion/zmx::clear:arg
    \\                ;;
    \\            (print-env)
    \\                command -f completion/zmx::print-env:arg
    \\                ;;
    \\            (k|kill)
    \\                command -f completion/zmx::kill:arg
    \\                ;;
    \\            (hi|history)
    \\                command -f completion/zmx::history:arg
    \\                ;;
    \\            (w|wait)
    \\                command -f completion/zmx::wait:arg
    \\                ;;
    \\            (t|tail)
    \\                command -f completion/zmx::tail:arg
    \\                ;;
    \\            (c|completions)
    \\                command -f completion/zmx::completions:arg
    \\                ;;
    \\            esac
    \\        fi
    \\        ;;
    \\    esac
    \\}
    \\
    \\function completion/zmx::completecmd {
    \\    complete -P "$PREFIX" -D "Attach to session, creating if needed" attach a
    \\    complete -P "$PREFIX" -D "Send command without attaching" run r
    \\    complete -P "$PREFIX" -D "Send raw input to session PTY" send s
    \\    complete -P "$PREFIX" -D "Inject text into session display" print p
    \\    complete -P "$PREFIX" -D "Write stdin to file_path through the session" write wr
    \\    complete -P "$PREFIX" -D "Detach all clients from current session" detach d
    \\    complete -P "$PREFIX" -D "List active sessions" list ls l
    \\    complete -P "$PREFIX" -D "Get session labels" get g
    \\    complete -P "$PREFIX" -D "Set session labels" set
    \\    complete -P "$PREFIX" -D "Clear all session labels" clear cl
    \\    complete -P "$PREFIX" -D "Print tracked environment variables" print-env
    \\    complete -P "$PREFIX" -D "Kill session and all attached clients" kill k
    \\    complete -P "$PREFIX" -D "Output session scrollback" history hi
    \\    complete -P "$PREFIX" -D "Wait for session tasks to complete" wait w
    \\    complete -P "$PREFIX" -D "Follow session output" tail t
    \\    complete -P "$PREFIX" -D "Shell completion scripts" completions c
    \\    complete -P "$PREFIX" -D "Show version" version v
    \\    complete -P "$PREFIX" -D "Show help message" help h
    \\}
    \\
    \\function completion/zmx::sessions {
    \\    typeset sessions
    \\    typeset IFS='
    \\'
    \\    sessions=($(zmx list --short 2>/dev/null))
    \\    if [ ${sessions[#]} -gt 0 ]; then
    \\        complete -P "$PREFIX" -- "$sessions"
    \\    fi
    \\}
    \\
    \\function completion/zmx::attach:arg {
    \\    OPTIONS=( #>#
    \\        "--labels:; apply labels as session is created"
    \\    ) #<#
    \\    command -f completion//parseoptions -en
    \\    case $ARGOPT in
    \\    (-)
    \\        command -f completion//completeoptions
    \\        ;;
    \\    (--labels)
    \\        ;;
    \\    (*)
    \\        command -f completion//getoperands
    \\        if [ ${WORDS[#]} -eq 1 ]; then
    \\            command -f completion/zmx::sessions
    \\        else
    \\            complete -P "$PREFIX" -c
    \\        fi
    \\        ;;
    \\    esac
    \\}
    \\
    \\function completion/zmx::run:arg {
    \\    OPTIONS=( #>#
    \\        "d; detach from calling terminal"
    \\        "--fish; session runs fish shell"
    \\    ) #<#
    \\    command -f completion//parseoptions -en
    \\    case $ARGOPT in
    \\    (-)
    \\        command -f completion//completeoptions
    \\        ;;
    \\    (*)
    \\        command -f completion//getoperands
    \\        if [ ${WORDS[#]} -eq 1 ]; then
    \\            command -f completion/zmx::sessions
    \\        else
    \\            complete -P "$PREFIX" -c
    \\        fi
    \\        ;;
    \\    esac
    \\}
    \\
    \\function completion/zmx::send:arg {
    \\    command -f completion//getoperands
    \\    if [ ${WORDS[#]} -eq 1 ]; then
    \\        command -f completion/zmx::sessions
    \\    fi
    \\}
    \\
    \\function completion/zmx::print:arg {
    \\    command -f completion//getoperands
    \\    if [ ${WORDS[#]} -eq 1 ]; then
    \\        command -f completion/zmx::sessions
    \\    fi
    \\}
    \\
    \\function completion/zmx::write:arg {
    \\    command -f completion//getoperands
    \\    if [ ${WORDS[#]} -eq 1 ]; then
    \\        command -f completion/zmx::sessions
    \\    elif [ ${WORDS[#]} -eq 2 ]; then
    \\        complete -P "$PREFIX" -f
    \\    fi
    \\}
    \\
    \\function completion/zmx::list:arg {
    \\    OPTIONS=( #>#
    \\        "--short; short output"
    \\    ) #<#
    \\    command -f completion//parseoptions -en
    \\    case $ARGOPT in
    \\    (-)
    \\        command -f completion//completeoptions
    \\        ;;
    \\    esac
    \\}
    \\
    \\function completion/zmx::get:arg {
    \\    command -f completion//getoperands
    \\    if [ ${WORDS[#]} -eq 1 ]; then
    \\        complete -P "$PREFIX" -D "Current session" .
    \\        command -f completion/zmx::sessions
    \\    fi
    \\}
    \\
    \\function completion/zmx::set:arg {
    \\    command -f completion//getoperands
    \\    if [ ${WORDS[#]} -eq 1 ]; then
    \\        complete -P "$PREFIX" -D "Current session" .
    \\        command -f completion/zmx::sessions
    \\    fi
    \\}
    \\
    \\function completion/zmx::clear:arg {
    \\    command -f completion//getoperands
    \\    if [ ${WORDS[#]} -eq 1 ]; then
    \\        complete -P "$PREFIX" -D "Current session" .
    \\        command -f completion/zmx::sessions
    \\    fi
    \\}
    \\
    \\function completion/zmx::print-env:arg {
    \\    OPTIONS=( #>#
    \\        "s --shell; output POSIX export/unset commands for eval"
    \\    ) #<#
    \\    command -f completion//parseoptions -en
    \\    case $ARGOPT in
    \\    (-)
    \\        command -f completion//completeoptions
    \\        ;;
    \\    (*)
    \\        command -f completion//getoperands
    \\        if [ ${WORDS[#]} -eq 1 ]; then
    \\            complete -P "$PREFIX" -D "Current session" .
    \\            command -f completion/zmx::sessions
    \\        fi
    \\        ;;
    \\    esac
    \\}
    \\
    \\function completion/zmx::kill:arg {
    \\    OPTIONS=( #>#
    \\        "--force; force kill"
    \\    ) #<#
    \\    command -f completion//parseoptions -en
    \\    case $ARGOPT in
    \\    (-)
    \\        command -f completion//completeoptions
    \\        ;;
    \\    (*)
    \\        command -f completion/zmx::sessions
    \\        ;;
    \\    esac
    \\}
    \\
    \\function completion/zmx::history:arg {
    \\    OPTIONS=( #>#
    \\        "--vt; history format with escape sequences"
    \\        "--html; history format in HTML"
    \\    ) #<#
    \\    command -f completion//parseoptions -en
    \\    case $ARGOPT in
    \\    (-)
    \\        command -f completion//completeoptions
    \\        ;;
    \\    (*)
    \\        command -f completion//getoperands
    \\        if [ ${WORDS[#]} -eq 1 ]; then
    \\            command -f completion/zmx::sessions
    \\        fi
    \\        ;;
    \\    esac
    \\}
    \\
    \\function completion/zmx::wait:arg {
    \\    command -f completion//getoperands
    \\    command -f completion/zmx::sessions
    \\}
    \\
    \\function completion/zmx::tail:arg {
    \\    command -f completion//getoperands
    \\    command -f completion/zmx::sessions
    \\}
    \\
    \\function completion/zmx::completions:arg {
    \\    command -f completion//getoperands
    \\    if [ ${WORDS[#]} -eq 1 ]; then
    \\        complete -P "$PREFIX" -- bash zsh fish nu yash
    \\    fi
    \\}
;
