# AnyTLS-Go 一键安装脚本指南

>  AnyTLS是一个试图专注于缓解 "TLS in TLS" 问题的 TLS 代理协议，主打极致隐匿。通过模拟正常的 HTTPS 流量来绕过防火墙检测，适合高封锁环境。

> [!IMPORTANT]
> 使用 `anytls-go` 搭建的服务端采用自签名证书，因此在客户端配置时，通常需要启用“允许不安全连接”或“跳过证书验证”等选项。


## 功能说明

1. 一键部署：支持 Debian / Ubuntu / CentOS / RHEL / AlmaLinux / Rocky Linux，自动检测环境并安装依赖
2. 服务管理：一键启动、停止、重启服务，查看运行状态与日志
3. 配置修改：快速更改连接密码与服务端口，自动更新配置文件并重载服务
4. 卸载功能：一键彻底卸载 AnyTLS 与相关配置
5. 高性能支持：基于 AnyTLS 协议，提供低延迟、高速、安全的代理通道，适用于科学上网、远程访问
6. 兼容 arm64 和 amd64 系统架构

---

## 快速开始

### 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Ymshub/AnyTLS/main/AnyTLS.sh)
```

### 管理命令

```bash
anytls
```

---

## 官方资料

### [AnyTLS原仓库](https://github.com/anytls/anytls-go)

### [AnyTLS官方FAQ](https://github.com/anytls/anytls-go/blob/main/docs/faq.md)

### [AnyTLS协议说明](https://github.com/anytls/anytls-go/blob/main/docs/protocol.md)
