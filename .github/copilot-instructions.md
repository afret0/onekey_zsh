# onekey_zsh 仓库说明

一键安装脚本集合, 目标环境是 Linux 服务器 (apt-get / dnf / yum), 分支 master。每个脚本必须在 README.md 有对应 usage 段落 (一键命令 + 默认值表 + 环境变量表)。

## 脚本风格

- 新脚本文件用 snake_case (如 `onekey_webdav.sh`); 既有 `onekey-omzsh.sh` 保持原名。
- `onekey_webdav.sh` 的形态对齐 afret0/v2ray 的 `onekey_xray.sh`: `set -Eeuo pipefail`、readonly 常量、`step/info/fail` 彩色输出、ERR trap 报行号、cleanup trap 清临时文件。
- 参数三通道: `WEBDAV_*` 环境变量 > `/dev/tty` 交互 (带默认值) > 默认值; 无 tty 时静默取默认值 (供 `curl | bash` 用)。
- 幂等重装: 安装状态存 `/etc/webdav/webdav.env` (chmod 600), 重跑时作为默认值沿用; `update` 子命令只换镜像/容器, 不动配置。
- Docker 部署: host 网络、`--restart always`、json-file 日志轮转 10m×3; 启动后必须健康检查 (容器状态 + RestartCount + HTTP 探活), 失败打印 `docker logs --tail 20` 再退出。
- 改已有 Caddy 的 Caddyfile 必须: 先备份 → 改 → `caddy validate` → reload, 任一步失败还原备份。写文件用 `cat tmp > file` 保留 inode, 不用 `sed -i` / `mv` / `cp -p` 覆盖已有文件 (docker 单文件 bind mount 认 inode, 换了 inode 容器内看不到新内容; busybox 的 `cp -p` 实测会重建目标文件换 inode, 还原备份也要 `cat backup > file`)。
- bash 正则的字符区间 (如 `[!-~]`) 按 locale 排序规则解释: glibc + `en_US.UTF-8` 下会把 `*` 等符号判为区间外 (真实服务器踩过, 密码 `QPZM2745*1` 被误拒); 校验函数内必须 `local LC_ALL=C` 再 `[[ =~ ]]`。dind/alpine (musl 按字节序) 与 `C.UTF-8` 复现不了, 验证此类改动要用 glibc 容器: `docker run --rm ubuntu:24.04` 内 `apt-get install locales && locale-gen en_US.UTF-8`, 以 `LC_ALL=en_US.UTF-8` 跑。
- dind 的 `/tmp` 是 tmpfs: `docker cp` 到 `/tmp` 显示成功但容器内看不到 (写进了被挂载遮蔽的底层), 测试脚本要拷到 `/root`; dind 内 apk 走 dl-cdn 可能卡死, 换 `mirrors.aliyun.com` 源。

## 验证命令 (本机 macOS 可跑)

```bash
bash -n onekey_webdav.sh
docker run --rm -v "$PWD/onekey_webdav.sh:/mnt/onekey_webdav.sh:ro" koalaman/shellcheck:stable /mnt/onekey_webdav.sh
```

端到端冒烟用 dind (本机 docker 可用时): `docker run --privileged -d --name webdav-smoke docker:27-dind`, 把脚本 `docker cp` 进去后 `docker exec` 跑安装/重装/update; alpine 无 ss/systemd, 脚本会走对应的跳过分支。完整 HTTPS 签证流程需要真实域名解析, 本地只能验证到 Caddy 启动与端口监听。