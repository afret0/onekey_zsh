#!/usr/bin/env bash
set -euo pipefail

ZSHRC_URL="https://raw.githubusercontent.com/afret0/onekey_zsh/master/.zshrc"

log() { echo ">>> $*"; }

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1"
    else
        log "curl or wget is required"
        return 1
    fi
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    log "please run as root, or install sudo first"
    exit 1
fi

missing=()
for cmd in git zsh wget curl tmux; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done

if [ "${#missing[@]}" -gt 0 ]; then
    if command -v apt-get >/dev/null 2>&1; then
        log "installing with apt-get: ${missing[*]}"
        as_root apt-get update
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        log "installing with dnf: ${missing[*]}"
        as_root dnf install -y "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then
        log "installing with yum: ${missing[*]}"
        as_root yum install -y "${missing[@]}"
    else
        log "no supported package manager found (apt-get/dnf/yum)"
        exit 1
    fi
else
    log "git/zsh/wget/curl/tmux already installed, skipping package installation"
fi

export ZSH="${ZSH:-$HOME/.oh-my-zsh}"
if [ -d "$ZSH" ]; then
    log "oh-my-zsh already installed at $ZSH, skipping"
else
    log "installing oh-my-zsh"
    download https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh |
        RUNZSH=no CHSH=no sh -s -- --unattended
fi

ZSH_CUSTOM="${ZSH_CUSTOM:-$ZSH/custom}"
for repo in zsh-autosuggestions zsh-syntax-highlighting; do
    if [ -d "$ZSH_CUSTOM/plugins/$repo" ]; then
        log "plugin $repo already installed, skipping"
    else
        log "installing plugin $repo"
        git clone --depth 1 "https://github.com/zsh-users/$repo.git" "$ZSH_CUSTOM/plugins/$repo"
    fi
done

tmp_zshrc="$(mktemp)"
download "$ZSHRC_URL" > "$tmp_zshrc"
if [ -f "$HOME/.zshrc" ] && [ "$(cksum < "$HOME/.zshrc")" = "$(cksum < "$tmp_zshrc")" ]; then
    log ".zshrc already up to date, keeping it"
    rm -f "$tmp_zshrc"
else
    if [ -f "$HOME/.zshrc" ]; then
        backup="$HOME/.zshrc.bk"
        if [ -e "$backup" ]; then
            backup="$HOME/.zshrc.bk.$(date +%Y%m%d%H%M%S)"
        fi
        log "backing up existing .zshrc to $backup"
        mv "$HOME/.zshrc" "$backup"
    fi
    mv "$tmp_zshrc" "$HOME/.zshrc"
    log "installed .zshrc from $ZSHRC_URL"
fi


# # nvim conf
# mkdir /root/.config
# mkdir /root/.config/nvim
# wget -O /root/.confg/nvim/init.vim https://raw.githubusercontent.com/kong5664546498/half_a_wheel/master/wheel/conf/init.vim


# # tmux 
# git clone https://github.com/tmux/tmux.git
# cd tmux
# sh autogen.sh
# ./configure && make

# # tmux conf
# cd /root
# git clone https://github.com/gpakosz/.tmux.git
# ln -s -f .tmux/.tmux.conf
# cp .tmux/.tmux.conf.local .


# ============== gotop ==============
# git clone --depth 1 https://github.com/cjbassi/gotop /tmp/gotop

# /tmp/gotop/scripts/download.sh

# mv ./gotop /usr/bin
# ===================================

# autojump
#git clone git://github.com/wting/autojump.git
#cd autojump
#./install.py

# the fuck
# pip3 install thefuck

# nvim-pulg
# curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs \
#     https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim


zsh_path="$(command -v zsh)"
if [ "$(basename "${SHELL:-}")" = "zsh" ]; then
    log "default shell is already zsh"
elif command -v chsh >/dev/null 2>&1 && as_root chsh -s "$zsh_path" "$(id -un)"; then
    log "default shell changed to $zsh_path (re-login to take effect)"
else
    log "could not change default shell automatically, run: chsh -s $zsh_path"
fi

if [ -t 0 ] && [ -t 1 ]; then
    log "done, starting zsh"
    exec zsh
fi
log "done, run 'zsh' or re-login to start using zsh"


