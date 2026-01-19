# AnyTLS — AnyTLS-Go 一键安装脚本指南

本仓库提供一个经过重写和增强的 AnyTLS-Go 一键安装脚本（install_anytls.sh），用于在常见 Linux 发行版上快速安装与管理 AnyTLS-Go 服务端（anytls-server）。脚本尽量兼容 Debian/Ubuntu、CentOS/RHEL、Alpine、Arch 等发行版，并实现自动下载匹配平台的 anytls-server 二进制、创建服务账号、systemd 单元、简单防火墙规则、以及可选的 Let's Encrypt TLS 集成。

> 注意：本仓库仅包含安装脚本。anytls-server 二进制来自 upstream 仓库（anytls/anytls-go Releases），脚本会在安装时自动从其 Releases 下载对平台的预编译包。

## 一键安装（推荐）

下面是一键下载并执行安装脚本的命令（请在已创建并推送脚本到本仓库后使用）：

```bash
wget -O install_anytls.sh https://raw.githubusercontent.com/Ymshub/AnyTLS/main/install_anytls.sh && \
chmod +x install_anytls.sh && \
sudo ./install_anytls.sh
```

该命令会：
- 下载仓库根目录下的 install_anytls.sh（main 分支）
- 赋予执行权限
- 使用 sudo 运行安装脚本（脚本会检测并提示需要 root 权限的操作）

## 快速示例

- 使用自定义端口和密码安装：
  ```bash
  sudo ./install_anytls.sh --port 8443 --password your_secure_password
  ```

- 运行交互式管理菜单：
  ```bash
  sudo ./install_anytls.sh --menu
  ```

- 尝试使用 Let's Encrypt 自动申请证书（需已安装 certbot，并且域名已解析到服务器）：
  ```bash
  sudo ./install_anytls.sh --tls
  ```

- 更新已安装的 anytls-server（从 upstream Releases 拉取最新二进制并替换）：
  ```bash
  sudo ./install_anytls.sh --update
  ```

- 卸载服务与配置：
  ```bash
  sudo ./install_anytls.sh --uninstall
  ```

- 查看服务状态（systemd）：
  ```bash
  sudo ./install_anytls.sh --check-status
  # 或者直接:
  systemctl status anytls
  ```

## 脚本功能概览

- 自动检测系统架构（amd64、arm64、armv7、386）并从 anytls/anytls-go Releases 选择合适的包下载。
- 自动安装依赖（curl、wget、unzip、ca-certificates）。可选安装 certbot（在支持的平台上）。
- 解压并安装 anytls-server 到 /usr/local/bin。
- 创建非 root 的运行用户 anytls，并在 /etc/anytls 中写入 anytls.env（PORT/PASSWORD）。
- 安装 systemd 服务文件，启用并立即启动服务。
- 尝试添加防火墙规则（UFW、firewalld、iptables）。
- 提供交互式菜单：安装/更新/卸载、TLS 配置、查看状态与日志、故障排除等。
- 支持命令行参数：--port, --password, --tls, --menu, --update, --uninstall, --check-status, --help。

## 系统服务管理（systemd）

安装完成后，脚本会创建 systemd 单元：`anytls.service`。常用命令：

- 查看状态：
  ```bash
  systemctl status anytls
  ```

- 启动 / 停止 / 重启：
  ```bash
  systemctl start anytls
  systemctl stop anytls
  systemctl restart anytls
  ```

- 查看日志（实时）：
  ```bash
  journalctl -u anytls -f --no-pager
  ```

## Let's Encrypt TLS（可选）

脚本支持通过 certbot 自动申请证书（`--tls` 或菜单中的选项）：

- 前提：
  - certbot 已安装（脚本会尝试安装，但也可能需要你手动安装或按发行版提供方式安装）
  - 绑定域名已解析到本机公网 IP
  - 端口 80/443 可用于 certbot 的 standalone 验证

- 使用（交互式）：
  ```bash
  sudo ./install_anytls.sh --tls
  ```
  脚本会提示输入域名并使用 certbot 以 standalone 模式申请证书。注意：anytls-server 是否能直接使用 cert/key 路径取决于 upstream 二进制是否支持相应参数；脚本会保存证书到 /etc/letsencrypt/live/<domain>/。

## 防火墙配置

脚本会尝试自动为所选端口添加防火墙规则，支持：

- UFW（Ubuntu/Debian）
- firewalld（CentOS/RHEL）
- iptables（回退方式；但不保证持久化）

如果你的系统使用其他防火墙或需要精细化规则，请安装后手动调整。

## 常见问题与故障排除

- 无法自动检测公网 IP：
  - 脚本会尝试调用第三方服务获取 IP（api.ipify.org、ifconfig.me 等）。如果失败，会提示你手动输入服务器公网 IP。

- 未找到 anytls-server 可执行文件：
  - 脚本从 Releases 下载的包可能与预期不同，检查 upstream Releases 是否提供对应平台的二进制。
  - 也可手动将 anytls-server 上传到 /usr/local/bin 并赋予执行权限，然后使用脚本的菜单或 systemctl 创建/启用服务。

- certbot 申请证书失败：
  - 检查域名是否正确解析至本机公网 IP。
  - 确保端口 80 未被占用（或在申请前停止占用端口的服务）。
  - 查看 certbot 输出日志以获取更多信息。

- 服务无法启动：
  - 使用 `journalctl -u anytls -f --no-pager` 查看启动日志与错误信息。
  - 检查 /etc/anytls/anytls.env 中的 PORT/PASSWORD 是否正确、二进制是否存在且可执行。

## 安全建议

- 尽量不要在命令行中明文传输密码给他人或在共享环境暴露密码历史（例如 `bash` 历史）。如果在生产环境，建议使用随机强密码并通过安全渠道保存。
- 脚本默认在 /etc/anytls/anytls.env 中保存 PORT 和 PASSWORD，文件权限设置为 root:anytls 0640。请确保系统用户与权限设置符合你的安全策略。
- 如果使用自签名证书，客户端需要跳过证书验证；使用 Let's Encrypt 可避免此情况。

## 卸载

运行：
```bash
sudo ./install_anytls.sh --uninstall
```
该操作会停止服务、移除 systemd 单元、删除安装的二进制和 /etc/anytls 配置目录。请注意：脚本不会自动移除 anytls 用户的主目录（若创建）以及手动添加的防火墙持久化规则，必要时请手动检查与清理。

## 开发贡献

欢迎提交 issues 或 PR 来改进脚本：
- 调整对更多发行版的兼容性（例如非 systemd 系统 OpenRC）
- 增强 TLS 自动化（直接让 anytls-server 使用证书）
- 增加更多可配置项与更细粒度的防火墙处理

贡献前请阅读并遵循仓库中的贡献指南（若有）。

## 许可证

请在仓库根目录添加适当的 LICENSE 文件以声明使用许可（例如 MIT、Apache-2.0 等）。本 README 与脚本示例不含具体 LICENSE，务必在发布时补充。

---
