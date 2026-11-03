# shellcheck shell=bash disable=SC1090
# ~/.bash_profile

export PATH="$HOME/.local/bin:$PATH"

# Load interactive shell config
[[ -f ~/.bashrc ]] && . ~/.bashrc

# Start X only from an interactive tty1 login shell, if not already inside X
if [[ $- == *i* && -z $DISPLAY && $(tty) == /dev/tty1 ]] && command -v startx >/dev/null 2>&1; then
    exec startx
fi
