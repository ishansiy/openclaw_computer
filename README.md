# Hermes Computer — ishansiy 维护版

基于 [TunMax/openclaw_computer](https://github.com/TunMax/openclaw_computer) 的桌面镜像维护 Hermes 分支。
上游的 `hermes_latest` 已停止维护；本分支由 ishansiy 独立维护 Hermes 构建与启动逻辑，保留上游 Apache-2.0 许可证。

## 版本

- 桌面底座：TunMax `20261011.post1` 对应镜像，固定 SHA256 `6ff51015b513931288201f495810c4159d16aba977c7c6c8fb86c2124a9de5c3`。
- Hermes：`0.22.5`，固定官方提交 `bf0203a794a07aac3ff764972ab9087baa4e4f4e`。
- 原生运行环境由该提交的官方 PM 锁文件安装；构建时验证 CLI、Python SDK、SQLite 和 Web 产品。
- 不自动跟随浮动 `latest` 或 Hermes `main` 的新提交。更新时修改明确的版本、提交和安装脚本 SHA256，通过构建和部署验收后再发布。

## ModelScope 部署

将 `hermes` 分支的 Dockerfile 及配套脚本同步到自己的 Docker 创空间，应用端口为 `7860`。
设置 `ROOT_PASSWD`；模型凭据使用创空间 Secret 或 Hermes 自己的受限配置文件。
本仓库不包含任何生产密钥、用户配置、Cookie、会话或数据库。

启动时使用 TunMax 的 KDE/noVNC 桌面实现，运行 Hermes 网关和 Dashboard。
OpenClaw 的配置规范化与默认网关不会执行。
存在 `/root/bz-startup/main.sh` 时，在服务启动前运行该恢复钩子；既有 Hermes 部署可据此恢复自己的插件、WebUI 和独立 Profile。
Tailscale 仅在设置认证参数或已有持久化登录状态时启动，未设置时直接进入桌面流程。

## 数据恢复

- `/mnt/workspace` 保存配置镜像和数据库快照；活跃 SQLite 留在本地容器文件系统。
- 数据库经 Online Backup API、`quick_check`、压缩及 SHA256 校验后保存，保留两个完整代次。
- 普通配置每分钟同步；缓存、运行日志、活动数据库及 WAL/SHM 不进入普通文件同步。
- 自定义恢复钩子存在时，由部署方负责数据库恢复及快照调度；没有自定义钩子时使用镜像内置的数据库快照脚本。
- `/mnt/workspace` 只解决平台重建恢复。生产环境还应维护独立的加密异地备份，并验证下载和解密恢复。
- 升级既有空间前，保存一致数据库快照、配置散列和可回滚的镜像/代码版本；不要直接复制运行中的 SQLite/WAL。

## 维护与验收

`master` 保留上游历史；`hermes` 是本仓库维护分支。
GitHub Actions 验证 shell/Python 语法并构建镜像，生产环境另外验证历史数据数量、QQ/微信连接以及 WebUI 的真实回复和工具调用。
Actions 不读取生产凭据，也不部署到用户空间。

TunMax 原始说明保存在 [README.upstream.md](README.upstream.md)。
