# onekey_zsh

一键安装 zsh 并配置 oh-my-zsh, 下载插件

# usage

root 用户:

`wget https://raw.githubusercontent.com/afret0/onekey_zsh/master/onekey-omzsh.sh && bash onekey-omzsh.sh`

普通用户(需要 sudo):

`wget https://raw.githubusercontent.com/afret0/onekey_zsh/master/onekey-omzsh.sh && bash onekey-omzsh.sh`

或管道一键执行:

`curl -fsSL https://raw.githubusercontent.com/afret0/onekey_zsh/master/onekey-omzsh.sh | bash`

> 支持 apt-get / dnf / yum 的 Linux; 可重复执行(已装的包/oh-my-zsh/插件自动跳过); 已存在的 `.zshrc` 会备份为 `.zshrc.bk` 再替换.



> 默认主题为 `avit`, 酷炫的主题都要安装字体, 试过好多次, 可能命里欠烤吧, 就没装成功过一次. 所以选了个不需要字体, 兼容所有 `terminal` 的主题.



# plugin

- zsh-autosuggestions
- zsh-syntax-highlighting
- command-not-found