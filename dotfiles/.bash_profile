# shellcheck shell=bash disable=SC1090
# ~/.bash_profile

export PATH="$HOME/.local/bin:$PATH"

# Start X only from an interactive tty1 login shell, if not already inside X,
# before ~/.bashrc can replace the shell or export tty-only settings
if [[ $- == *i* && -z $DISPLAY && $(tty) == /dev/tty1 ]] && command -v startx >/dev/null 2>&1; then
    exec startx
fi

# Load interactive shell config
[[ -f ~/.bashrc ]] && . ~/.bashrc
