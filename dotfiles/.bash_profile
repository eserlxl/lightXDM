# shellcheck shell=bash disable=SC1090
# ~/.bash_profile

export PATH="$HOME/.local/bin:$PATH"

# Start the session only from an interactive tty1 login shell, if not already inside X or Wayland,
# before ~/.bashrc can replace the shell or export tty-only settings
if [[ $- == *i* && -z $DISPLAY && -z $WAYLAND_DISPLAY && $(tty) == /dev/tty1 && ! -e $HOME/.config/lightxdm/no-autostart ]]; then
    _lightxdm_launcher=""
    if [[ -f $HOME/.wayland-session && -x $HOME/.wayland-session ]]; then
        _lightxdm_launcher="$HOME/.wayland-session"
    elif command -v startx >/dev/null 2>&1; then
        _lightxdm_launcher="startx"
    fi
    if [[ -n $_lightxdm_launcher ]]; then
        _lightxdm_attempts="${XDG_STATE_HOME:-$HOME/.local/state}/lightxdm/startx-attempts"
        printf -v _lightxdm_now '%(%s)T' -1
        _lightxdm_lines=()
        _lightxdm_recent=()
        if [[ -f "$_lightxdm_attempts" && -r "$_lightxdm_attempts" ]]; then
            mapfile -t _lightxdm_lines 2>/dev/null < "$_lightxdm_attempts" || :
        fi
        for _lightxdm_ts in "${_lightxdm_lines[@]}"; do
            if [[ -n $_lightxdm_ts && ${#_lightxdm_ts} -le 18 && $_lightxdm_ts != *[!0123456789]* ]] &&
                (( _lightxdm_now - 10#$_lightxdm_ts >= 0 && _lightxdm_now - 10#$_lightxdm_ts <= 30 )); then
                _lightxdm_recent+=("$_lightxdm_ts")
            fi
        done
        if (( ${#_lightxdm_recent[@]} >= 3 )); then
            if mkdir -p "$HOME/.config/lightxdm" 2>/dev/null &&
                : 2>/dev/null > "$HOME/.config/lightxdm/no-autostart"; then
                : 2>/dev/null > "$_lightxdm_attempts" || :
            fi
            printf '%s\n' "TTY1 auto-start paused: the session was started 3 times within 30s; run 'rm ~/.config/lightxdm/no-autostart' to resume."
            unset _lightxdm_launcher _lightxdm_attempts _lightxdm_now _lightxdm_lines _lightxdm_recent _lightxdm_ts
        else
            if mkdir -p "${_lightxdm_attempts%/*}" 2>/dev/null; then
                printf '%s\n' "${_lightxdm_recent[@]}" "$_lightxdm_now" 2>/dev/null > "$_lightxdm_attempts" || :
            fi
            unset _lightxdm_attempts _lightxdm_now _lightxdm_lines _lightxdm_recent _lightxdm_ts
            exec "$_lightxdm_launcher"
        fi
    else
        unset _lightxdm_launcher
    fi
fi

# Load interactive shell config
[[ -f ~/.bashrc ]] && . ~/.bashrc
