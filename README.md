# FreeBSD Builder

FreeBSD 多项目自动构建平台，为 Serv00 等 FreeBSD 主机提供预编译二进制文件。

## 特性

- 🚀 每天自动检查上游更新并构建
- 📦 提供编译好的 FreeBSD amd64 二进制文件
- 🛠️ Sub2API 一键安装脚本，零配置部署
- 🔄 智能更新，支持自动回滚
- 🇨🇳 完全中文化的用户体验
- 🏗️ FreeBSD VM 原生编译，确保兼容性
- 🔧 Composite Actions 架构，易于扩展

## 支持项目

### Sub2API
- 上游：[Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api)
- 构建时间：每天 18:00 UTC（北京时间凌晨 2:00）
- 提供一键安装脚本

### New-API
- 上游：[QuantumNous/new-api](https://github.com/QuantumNous/new-api)
- 构建时间：每天 18:00 UTC（北京时间凌晨 2:00）

---

## Sub2API 快速开始

### 一键安装（推荐）

```bash
# 下载安装脚本
curl -O https://raw.githubusercontent.com/lizhenmiao/freebsd-builder/master/install.sh

# 运行安装脚本
sh install.sh
```

安装脚本会引导你：
1. 输入配置信息（Redis、PostgreSQL、端口等）
2. 自动生成配置文件
3. 下载最新版本的 Sub2API
4. 启动服务并验证

### 手动安装 Sub2API

```bash
# 1. 下载最新版本
VERSION="v0.1.137"  # 替换为最新版本
curl -LO https://github.com/lizhenmiao/freebsd-builder/releases/download/${VERSION}/sub2api_${VERSION#v}_freebsd_amd64.tar.gz

# 2. 解压
tar -xzf sub2api_${VERSION#v}_freebsd_amd64.tar.gz

# 3. 配置 Redis 和 Sub2API（参考配置说明）

# 4. 启动服务
redis-server ./redis.conf
./sub2api
```

---

## New-API 快速开始

### 手动安装

```bash
# 1. 下载最新版本
VERSION="v1.0.0"  # 替换为最新版本
curl -LO https://github.com/lizhenmiao/freebsd-builder/releases/download/${VERSION}/new-api_${VERSION#v}_freebsd_amd64.tar.gz

# 2. 解压
tar -xzf new-api_${VERSION#v}_freebsd_amd64.tar.gz

# 3. 运行
chmod +x new-api
./new-api
```

---

## 使用管理脚本（Sub2API）

安装完成后，使用 `install.sh` 管理服务：

```bash
sh install.sh
```

菜单选项：
- **1) 安装 Sub2API** - 首次安装，收集配置并部署
- **2) 更新 Sub2API** - 更新到最新版本，支持自动回滚
- **3) 启动 Sub2API** - 启动服务（如果未运行）
- **4) 退出** - 退出脚本

---

## Sub2API 配置说明

### Redis 配置

配置文件：`redis.conf`（由 install.sh 自动生成）

关键配置项：
- `port` - Redis 端口（默认 6379）
- `requirepass` - Redis 密码
- `dir` - 数据目录

### Sub2API 配置

配置文件：`config.yaml`（由 install.sh 自动生成）

主要配置项：
```yaml
server:
  port: 8080          # Sub2API 监听端口

database:             # PostgreSQL 配置
  host: localhost
  port: 5432
  user: postgres
  password: your_password
  dbname: sub2api

redis:                # Redis 配置
  host: localhost
  port: 6379
  password: your_password

jwt:
  secret: auto-generated  # 由安装脚本自动生成
```

### 目录结构

```
工作目录/
├── sub2api              # Sub2API 可执行文件
├── config.yaml          # Sub2API 配置文件
├── redis.conf           # Redis 配置文件
├── logs/                # 日志目录
│   ├── redis.log        # Redis 日志
│   └── sub2api.log      # Sub2API 日志
└── redis_data/          # Redis 数据目录
```

---

## 常见问题

### 如何查看日志？

```bash
# Redis 日志
tail -f logs/redis.log

# Sub2API 日志
tail -f logs/sub2api.log
```

### 如何检查服务状态？

```bash
# 检查端口是否监听（FreeBSD）
sockstat -4l | grep :8080

# 检查进程是否运行
pgrep -f sub2api
pgrep -f redis-server
```

### Sub2API 更新失败怎么办？

更新脚本内置自动回滚功能，如果新版本启动失败，会自动恢复到旧版本。

如果回滚也失败，手动恢复：
```bash
# 如果备份文件存在
cp sub2api.bak sub2api
sh install.sh  # 选择"启动 Sub2API"
```

### 如何完全重新安装？

```bash
# 1. 停止服务
pkill -f sub2api
pkill -f redis-server

# 2. 删除所有文件
rm -rf sub2api config.yaml redis.conf logs/ redis_data/

# 3. 重新运行安装
sh install.sh  # 选择"安装 Sub2API"
```

### PostgreSQL 在哪里？

Sub2API 需要 PostgreSQL 数据库，但安装脚本**不会**自动安装 PostgreSQL。

你需要：
1. 自己安装并配置 PostgreSQL
2. 创建数据库：`CREATE DATABASE sub2api;`
3. 在安装脚本中输入连接信息

---

## 技术细节

### 构建流程

GitHub Actions 每天自动检查上游项目是否有新版本：
- 如果有新版本，自动构建 FreeBSD 二进制
- 使用 FreeBSD VM 原生编译（不是交叉编译）
- 创建 Release 并上传编译好的文件
- 支持手动触发和指定版本构建

### 系统要求

- FreeBSD 13.2 或更高版本
- amd64 架构
- 已安装 Redis（Sub2API）
- 已安装 PostgreSQL（Sub2API）
- 基本工具：curl, tar, sh

### 架构说明

本项目使用 Composite Actions 架构：
- `check-version`: 版本检查和对比
- `package-release`: 打包 tar.gz + 校验和
- `create-release`: 创建 GitHub Release

新增项目只需编写特定的构建步骤，其他逻辑复用。

