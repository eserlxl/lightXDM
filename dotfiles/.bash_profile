# shellcheck shell=bash disable=SC1090
# ~/.bash_profile

export PATH="$HOME/.local/bin:$PATH"

# Load interactive shell config
[[ -f ~/.bashrc ]] && . ~/.bashrc

# Start X on tty1 only, if not already inside X
if [[ -z $DISPLAY && $(tty) == /dev/tty1 ]]; then
    exec startx
fi
