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

# onekey webdav

一键安装 WebDAV 服务 (dufs, Docker 部署), 形态同 [afret0/v2ray](https://github.com/afret0/v2ray) 的一键脚本: 交互输入 + 环境变量免交互、重装沿用已安装值、`update` 一条命令更新。

以 root 登录服务器后执行:

`bash <(curl -fsSL https://raw.githubusercontent.com/afret0/onekey_zsh/master/onekey_webdav.sh)`

按提示依次输入, 直接回车取默认值:

| 提示 | 默认值 |
| --- | --- |
| 监听端口 | `5000` (重装时为已安装值); 指定后即时查占用, 被占用会提示更换并重新输入 |
| 用户名 / 密码 | `admin` / `admin` (重装时为已安装值, 公网建议改强密码) |
| 数据目录 | `/data/webdav` (重装时为已安装值) |
| 是否开启 HTTPS (Caddy 自动证书) | `n` (重装时为已安装状态) |
| HTTPS 域名 (开启后追问) | 需已解析到本机, 重装时为已安装值 |
| HTTPS 对外端口 (开启后追问) | `443`, 可输入 `r` 随机挑一个空闲端口; 自带 Caddy 时指定后即时查占用, 被占用会提示更换 (接入已有 Caddy 时由它监听, 不查) |
| 检测到已有 Caddy 时: 如何接入 | `2` 只给配置片段, 你手动加到 Caddyfile; `1` 自动合并配置并热加载 (先备份 + 校验, 失败自动还原) |

安装完成后打印 WebDAV 地址、账号密码与客户端接入方法 (Finder / Windows / rclone), 保存在 `/etc/webdav/client-info.txt`。

## 免交互安装

`WEBDAV_PORT=5000 WEBDAV_USER=admin WEBDAV_PASS=admin bash <(curl -fsSL https://raw.githubusercontent.com/afret0/onekey_zsh/master/onekey_webdav.sh)`

| 环境变量 | 说明 | 默认值 |
| --- | --- | --- |
| `WEBDAV_PORT` | dufs 监听端口, 1-65535 | `5000`, 重装时为已安装值 |
| `WEBDAV_USER` / `WEBDAV_PASS` | 用户名: 字母/数字/`_.-`, 1-64 位; 密码: 额外允许符号 (如 `QPZM2745*1`, 全部可见 ASCII 字符, 不含空格, 1-64 位) | `admin` / `admin`, 重装时为已安装值 |
| `WEBDAV_DIR` | 数据目录 (绝对路径, 不含空格和冒号) | `/data/webdav`, 重装时为已安装值 |
| `WEBDAV_TLS` | 是否开启 HTTPS, `y` / `n` | `n`, 重装时为已安装状态 |
| `WEBDAV_DOMAIN` | HTTPS 域名, 开启 HTTPS 时必填 (需解析到本机) | 重装时为已安装值 |
| `WEBDAV_HTTPS_PORT` | HTTPS 对外端口 | `443`, 重装时为已安装值 |
| `WEBDAV_CADDY_MODE` | 检测到已有 Caddy 时的接入方式: `merge` 自动合并 / `manual` 只给片段 | `manual` (默认不动已有 Caddy, 只给配置) |

## HTTPS 与已有 Caddy

- 开启 HTTPS 需要域名解析到本机; 证书为 Let's Encrypt 免费证书, 由 Caddy 自动申请/续期, 80 端口用于签证与自动跳转。
- 服务器上没有别的 Caddy 时, 脚本起自己的 `webdav-caddy` 容器 (host 网络); dufs 只绑 `127.0.0.1`, 公网只能走 HTTPS。
- 检测到已有 Caddy (其它容器或主机进程) 时不抢占 80/443, 交互选择 (默认手动):
  - **手动 (默认)**: 打印站点片段 (存 `/etc/webdav/caddy-snippet.txt`) 与热加载命令, 由你自己加到 Caddyfile, 脚本不改动已有 Caddy 的任何文件。
  - **自动合并 (选项 1)**: 把本站点块写进已有 Caddyfile (带 `# BEGIN/END onekey_webdav` 标记, 重装时原地替换), 先备份、`caddy validate` 校验、热加载; 任一步失败自动还原原配置并降级为手动模式, 不影响已有站点。已有 Caddy 的配置不是 Caddyfile 格式 (如 JSON) 或定位不到文件时, 自动降级为手动模式。
- 已有 Caddy 跑在 docker bridge 网络时, dufs 改绑宿主机网桥网关 IP (如 `172.17.0.1`, 公网不可达), 片段里的反代地址同步给出。
- 切回 HTTP 或换接入方式时, 自动从原 Caddyfile 移除带标记的站点块 (同样备份 + 校验 + 热加载)。

## 更新

`bash <(curl -fsSL https://raw.githubusercontent.com/afret0/onekey_zsh/master/onekey_webdav.sh) update`

拉取最新 dufs 镜像 (自带 HTTPS 时连同 caddy 镜像), 有新版本才重建容器; 端口、账号、数据目录、HTTPS 设置全部不变, 客户端无需改动。接入已有 Caddy 时, `update` 不改动外部 Caddy。