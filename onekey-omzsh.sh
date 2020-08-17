#!/usr/bin/env bash
# ============== 安装 git zsh wget ==============
cd /root
if [ -x "$(command -v yum)" ]; then
    echo ' use yum'>&2
    yum install git -y
    yum install zsh -y
    yum install wget -y
    yum install curl -y
    yum install tmux -y
    # nvim
    # yum install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
    # yum install -y neovim python3-neovim
    # tmux dependencies
    # yum install autogen automake libevent-dev libncurses5-dev -y
fi

if [ -x "$(command -v apt-get)" ]; then
    echo 'use apt-get'>&2
    apt-get install git -y
    apt-get install zsh -y
    apt-get install wget -y
    apt-get install curl -y
    apt-get install tmux -y
    # nvim
    # apt-get install neovim -y
    # tmux dependencies
    # apt-get install autogen automake libevent-dev libncurses5-dev -y
fi
# ===================================


# ============== 安装配置 oh-my-zsh ==============
wget https://github.com/robbyrussell/oh-my-zsh/raw/master/tools/install.sh -O - | sh
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

if [ -f "/root/.zshrc" ]; then
     mv /root/.zshrc /root/.zshrc.bk
fi

# 下载 .zshrc
wget -P /root https://raw.githubusercontent.com/kong5664546498/half_a_wheel/master/wheel/onekey-omzsh/.zshrc
# ===================================


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


# 修改默认 bash
chsh -s /bin/zsh
zsh

exit 0


