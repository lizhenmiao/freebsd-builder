#!/bin/sh

# 如果通过管道运行（stdin 不是终端），从 /dev/tty 读取输入
if [ ! -t 0 ]; then
    exec < /dev/tty
fi

#===============================================================================
# Sub2API FreeBSD 一键部署脚本
# 功能：安装、更新、启动 Sub2API 服务
#===============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GITHUB_REPO="lizhenmiao/freebsd-builder"

# 命令行参数（非交互模式）
CLI_MODE=false
CLI_REDIS_HOST=""
CLI_REDIS_PORT=""
CLI_REDIS_PASSWORD=""
CLI_PG_HOST=""
CLI_PG_PORT=""
CLI_PG_USER=""
CLI_PG_PASSWORD=""
CLI_PG_DBNAME=""
CLI_SUB2API_HOST=""
CLI_SUB2API_PORT=""
CLI_ADMIN_EMAIL=""
CLI_ADMIN_PASSWORD=""
CLI_TARGET_VERSION=""
CLI_FORCE_BUILD=""

#===============================================================================
# 工具函数
#===============================================================================

# 颜色定义
COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_CYAN='\033[0;36m'

# 打印带颜色的消息
print_info() {
    printf "${COLOR_BLUE}==> %s${COLOR_RESET}\n" "$1"
}

print_success() {
    printf "${COLOR_GREEN}✅ %s${COLOR_RESET}\n" "$1"
}

print_error() {
    printf "${COLOR_RED}❌ %s${COLOR_RESET}\n" "$1" >&2
}

print_warning() {
    printf "${COLOR_YELLOW}⚠️  %s${COLOR_RESET}\n" "$1"
}

# 检查命令是否存在
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        print_error "缺少必要命令: $1"
        print_error "请先安装 $1"
        exit 1
    fi
}

# 检查端口是否被占用
check_port() {
    local port=$1
    sockstat -4l 2>/dev/null | grep ":${port}" >/dev/null 2>&1
    return $?
}

# 检查进程是否运行
check_process() {
    local pattern=$1
    pgrep -f "$pattern" >/dev/null 2>&1
    return $?
}

# 生成 JWT Secret
generate_jwt_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 32 2>/dev/null
    else
        head -c 32 /dev/urandom | base64
    fi
}

# 判断 PostgreSQL SSL 模式
detect_pg_sslmode() {
    local host=$1
    # 本地连接和内网地址：localhost, 127.0.0.1, ::1, 10.x.x.x, 172.16-31.x.x, 192.168.x.x
    case "$host" in
        localhost|127.0.0.1|::1)
            echo "disable"
            ;;
        10.*|192.168.*)
            # 内网 A 类和 C 类地址
            echo "disable"
            ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
            # 内网 B 类地址 172.16.0.0 - 172.31.255.255
            echo "disable"
            ;;
        *.ct8.pl|*.serv00.com)
            # ct8.pl 和 serv00.com 免费托管服务
            echo "disable"
            ;;
        *)
            # 远程连接：使用 disable（pq 驱动不支持 prefer）
            echo "disable"
            ;;
    esac
}

# 比较两个版本号大小
# 返回 0 表示 ver1 > ver2，返回 1 表示 ver1 <= ver2
is_version_greater() {
    local ver1=$1
    local ver2=$2

    # 如果版本号相同，返回 1
    if [ "$ver1" = "$ver2" ]; then
        return 1
    fi

    # 使用 sort -rV 降序排序，如果 ver1 排在第一位，说明 ver1 > ver2
    higher=$(printf "%s\n%s" "$ver1" "$ver2" | sort -rV | head -n 1)
    [ "$higher" = "$ver1" ]
}

# 获取可用版本列表（最新的 N 个）
get_available_versions() {
    local count=${1:-5}

    # 使用代理加速访问 GitHub API
    GITHUB_API_PROXY="https://ghfast.top/"
    curl -s "${GITHUB_API_PROXY}api.github.com/repos/${GITHUB_REPO}/releases?per_page=100" \
        | grep '"tag_name":' \
        | grep 'sub2api-' \
        | cut -d '"' -f 4 \
        | sort -rV \
        | head -n "$count"
}

# 获取比指定版本新的版本列表
get_newer_versions() {
    local current_version=$1
    local count=${2:-5}

    # 获取所有版本
    all_versions=$(get_available_versions 100)

    # 过滤出比当前版本新的版本
    newer_versions=""
    for version in $all_versions; do
        # 去掉 sub2api- 前缀进行比较
        clean_ver=$(echo "$version" | sed 's/^sub2api-//')
        if is_version_greater "$clean_ver" "$current_version"; then
            if [ -z "$newer_versions" ]; then
                newer_versions="$version"
            else
                newer_versions="$newer_versions
$version"
            fi
        fi
    done

    # 返回最新的 N 个
    if [ -n "$newer_versions" ]; then
        echo "$newer_versions" | head -n "$count"
    fi
}

# 验证版本号格式
validate_version_format() {
    local version=$1

    if ! echo "$version" | grep -qE '^sub2api-v[0-9]+\.[0-9]+\.[0-9]+$'; then
        return 1
    fi
    return 0
}

# 交互式选择版本（用于安装）
select_version_for_install() {
    # 如果命令行指定了版本，验证格式后直接返回
    if [ -n "$CLI_TARGET_VERSION" ]; then
        if ! validate_version_format "$CLI_TARGET_VERSION"; then
            print_error "版本号格式错误: $CLI_TARGET_VERSION"
            print_error "正确格式: sub2api-vX.Y.Z（如 sub2api-v0.0.138）"
            exit 1
        fi

        echo "$CLI_TARGET_VERSION"
        return 0
    fi

    print_info "获取可用版本..."

    VERSIONS=$(get_available_versions 5)

    if [ -z "$VERSIONS" ]; then
        print_error "获取版本列表失败"
        return 1
    fi

    echo ""
    printf "${COLOR_CYAN}可用版本：${COLOR_RESET}\n"
    echo "  0) 最新版本（推荐）"

    i=1
    echo "$VERSIONS" | while read -r version; do
        echo "  $i) $version"
        i=$((i + 1))
    done
    echo "  6) 自定义版本号"
    echo ""

    while true; do
        read -p "请选择 [0-6]: " choice

        case $choice in
            0)
                echo "$VERSIONS" | head -n 1
                return 0
                ;;
            [1-5])
                selected=$(echo "$VERSIONS" | sed -n "${choice}p")
                if [ -n "$selected" ]; then
                    echo "$selected"
                    return 0
                else
                    print_error "无效选项"
                fi
                ;;
            6)
                while true; do
                    read -p "请输入版本号（格式: sub2api-vX.Y.Z）: " custom_version
                    if [ -z "$custom_version" ]; then
                        print_error "版本号不能为空"
                        continue
                    fi

                    if ! validate_version_format "$custom_version"; then
                        print_error "版本号格式错误，应为: sub2api-vX.Y.Z（如 sub2api-v0.0.138）"
                        continue
                    fi

                    echo "$custom_version"
                    return 0
                done
                ;;
            *)
                print_error "无效选项，请输入 0-6"
                ;;
        esac
    done
}

# 交互式选择版本（用于更新）
select_version_for_update() {
    local current_version=$1

    # 如果命令行指定了版本，验证后直接返回
    if [ -n "$CLI_TARGET_VERSION" ]; then
        if ! validate_version_format "$CLI_TARGET_VERSION"; then
            print_error "版本号格式错误: $CLI_TARGET_VERSION"
            print_error "正确格式: sub2api-vX.Y.Z（如 sub2api-v0.0.138）"
            exit 1
        fi

        # 检查是否比当前版本新
        clean_ver=$(echo "$CLI_TARGET_VERSION" | sed 's/^sub2api-//')
        if ! is_version_greater "$clean_ver" "$current_version"; then
            print_error "指定版本 ($clean_ver) 不高于当前版本 ($current_version)"
            exit 1
        fi

        echo "$CLI_TARGET_VERSION"
        return 0
    fi

    print_info "获取可用更新..."

    VERSIONS=$(get_newer_versions "$current_version" 5)

    if [ -z "$VERSIONS" ]; then
        print_success "已经是最新版本" >&2
        return 1
    fi

    echo ""
    printf "${COLOR_CYAN}可更新版本：${COLOR_RESET}\n"
    echo "  0) 最新版本（推荐）"

    i=1
    echo "$VERSIONS" | while read -r version; do
        echo "  $i) $version"
        i=$((i + 1))
    done
    echo "  6) 自定义版本号"
    echo ""

    while true; do
        read -p "请选择 [0-6]: " choice

        case $choice in
            0)
                echo "$VERSIONS" | head -n 1
                return 0
                ;;
            [1-5])
                selected=$(echo "$VERSIONS" | sed -n "${choice}p")
                if [ -n "$selected" ]; then
                    echo "$selected"
                    return 0
                else
                    print_error "无效选项"
                fi
                ;;
            6)
                while true; do
                    read -p "请输入版本号（格式: sub2api-vX.Y.Z）: " custom_version
                    if [ -z "$custom_version" ]; then
                        print_error "版本号不能为空"
                        continue
                    fi

                    if ! validate_version_format "$custom_version"; then
                        print_error "版本号格式错误，应为: sub2api-vX.Y.Z（如 sub2api-v0.0.138）"
                        continue
                    fi

                    # 检查是否比当前版本新
                    clean_ver=$(echo "$custom_version" | sed 's/^sub2api-//')
                    if ! is_version_greater "$clean_ver" "$current_version"; then
                        print_error "指定版本 ($clean_ver) 不高于当前版本 ($current_version)"
                        continue
                    fi

                    echo "$custom_version"
                    return 0
                done
                ;;
            *)
                print_error "无效选项，请输入 0-6"
                ;;
        esac
    done
}

# 检查 Sub2API 是否已安装
check_installation() {
    # 检查 sub2api 二进制文件是否存在
    if [ ! -f "./sub2api" ]; then
        print_error "未找到 sub2api 二进制文件"
        print_error "请先运行安装功能或重新下载"
        return 1
    fi

    # 检查 config.yaml 是否存在
    if [ ! -f "./config.yaml" ]; then
        print_error "未检测到已安装的 Sub2API"
        print_error "config.yaml 文件不存在"
        print_error "请先运行安装功能"
        return 1
    fi

    # 检查 Redis 配置文件是否存在
    if [ ! -f "./redis.conf" ]; then
        print_warning "redis.conf 文件不存在，Redis 可能无法启动"
    fi

    return 0
}

# 测试 Redis 连接
test_redis_connection() {
    local redis_host=$1
    local redis_port=$2
    local redis_password=$3

    print_info "测试 Redis 连接..."

    if command -v redis-cli >/dev/null 2>&1; then
        local error_msg
        if [ -n "$redis_password" ]; then
            error_msg=$(redis-cli -h "$redis_host" -p "$redis_port" -a "$redis_password" --no-auth-warning ping 2>&1) || true
        else
            error_msg=$(redis-cli -h "$redis_host" -p "$redis_port" ping 2>&1) || true
        fi

        if echo "$error_msg" | grep -q "PONG"; then
            print_success "Redis 连接成功"
            return 0
        else
            print_error "Redis 连接失败"
            echo "错误信息: $error_msg"
            echo ""
            echo "可能的原因："
            echo "  - Redis 服务未启动"
            echo "  - 主机地址或端口错误"
            echo "  - 密码错误"
            echo "  - 防火墙阻止连接"
            return 1
        fi
    else
        print_warning "未找到 redis-cli 命令，跳过 Redis 连接测试"
        return 0
    fi
}

# 测试 PostgreSQL 连接
test_pg_connection() {
    local pg_host=$1
    local pg_port=$2
    local pg_user=$3
    local pg_password=$4
    local pg_dbname=$5

    print_info "测试 PostgreSQL 连接..."

    if ! command -v psql >/dev/null 2>&1; then
        print_warning "未找到 psql 命令，跳过 PostgreSQL 连接测试"
        return 0
    fi

    # 测试连接到 postgres 数据库
    local error_msg
    error_msg=$(PGPASSWORD="$pg_password" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_dbname" -c '\q' 2>&1) || true

    if echo "$error_msg" | grep -qE "FATAL|ERROR"; then
        print_error "PostgreSQL 连接失败"
        echo "错误信息: $error_msg"
        echo ""
        echo "可能的原因："
        echo "  - PostgreSQL 服务未启动"
        echo "  - 主机地址或端口错误"
        echo "  - 用户名或密码错误"
        echo "  - 数据库不允许远程连接（检查 pg_hba.conf）"
        echo "  - 防火墙阻止连接"
        return 1
    else
        print_success "PostgreSQL 连接成功"
        return 0
    fi
}

# 检查数据库是否有用户数据
check_database_data() {
    local pg_host=$1
    local pg_port=$2
    local pg_user=$3
    local pg_password=$4
    local pg_dbname=$5

    if ! command -v psql >/dev/null 2>&1; then
        return 0
    fi

    # 检查数据库是否存在
    DB_EXISTS=$(PGPASSWORD="$pg_password" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_dbname" -tAc "SELECT 1 FROM pg_database WHERE datname='$pg_dbname'" 2>/dev/null) || true

    if [ "$DB_EXISTS" != "1" ]; then
        # 数据库不存在，返回 0（无数据）
        return 0
    fi

    # 数据库存在，检查是否有 users 表和数据
    USER_COUNT=$(PGPASSWORD="$pg_password" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_dbname" -tAc "SELECT COUNT(*) FROM users" 2>/dev/null) || true

    if [ -z "$USER_COUNT" ]; then
        # 查询失败（可能表不存在），返回 0
        return 0
    fi

    if [ "$USER_COUNT" -gt 0 ] 2>/dev/null; then
        # 有用户数据，返回用户数量
        echo "$USER_COUNT"
        return 1
    fi

    return 0
}

# 清空数据库（删除所有表，而不是删除整个数据库）
clear_database() {
    local pg_host=$1
    local pg_port=$2
    local pg_user=$3
    local pg_password=$4
    local pg_dbname=$5

    print_info "清空数据库..."

    # 删除数据库中所有表
    local drop_result
    drop_result=$(PGPASSWORD="$pg_password" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_dbname" -c "
        DO \$\$ DECLARE
            r RECORD;
        BEGIN
            FOR r IN (SELECT tablename FROM pg_tables WHERE schemaname = 'public') LOOP
                EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.tablename) || ' CASCADE';
            END LOOP;
        END \$\$;
    " 2>&1) || true

    if echo "$drop_result" | grep -qE "FATAL|ERROR"; then
        print_error "数据库清空失败"
        echo "错误信息: $drop_result"
        return 1
    else
        print_success "数据库已清空"
        return 0
    fi
}

#===============================================================================
# 安装功能
#===============================================================================

install_sub2api() {
    print_info "开始安装 Sub2API"
    echo ""

    # 检查是否已安装
    if [ -f "./sub2api" ] && [ -f "./config.yaml" ]; then
        print_warning "检测到 Sub2API 已安装"
        return
    fi

    # 检查必要命令
    check_command curl
    check_command tar
    check_command redis-server

    # 收集配置信息
    if [ "$CLI_MODE" = false ]; then
        print_info "请输入配置信息："
        echo ""

        read -p "工作目录 [$(pwd)]: " WORK_DIR
        WORK_DIR=${WORK_DIR:-$(pwd)}
    else
        WORK_DIR=$(pwd)
    fi

    # Redis 配置（只收集信息，不测试连接）
    if [ "$CLI_MODE" = false ]; then
        print_info "请输入 Redis 配置信息："
        echo ""

        read -p "Redis 主机 [localhost]: " REDIS_HOST
        REDIS_HOST=${REDIS_HOST:-localhost}

        read -p "Redis 端口 [6379]: " REDIS_PORT
        REDIS_PORT=${REDIS_PORT:-6379}

        while true; do
            read -p "Redis 密码: " REDIS_PASSWORD
            if [ -n "$REDIS_PASSWORD" ]; then
                break
            fi
            print_error "Redis 密码不能为空，请重新输入"
        done
    else
        # 命令行模式，使用传入的参数
        REDIS_HOST=${CLI_REDIS_HOST:-localhost}
        REDIS_PORT=${CLI_REDIS_PORT:-6379}
        REDIS_PASSWORD=$CLI_REDIS_PASSWORD

        if [ -z "$REDIS_PASSWORD" ]; then
            print_error "Redis 密码不能为空（--redis_password）"
            exit 1
        fi
    fi

    # PostgreSQL 配置循环，直到连接成功
    if [ "$CLI_MODE" = false ]; then
        echo ""
        print_info "请输入 PostgreSQL 配置信息："
        echo ""

        while true; do
            read -p "PostgreSQL 主机 [localhost]: " PG_HOST
            PG_HOST=${PG_HOST:-localhost}

            read -p "PostgreSQL 端口 [5432]: " PG_PORT
            PG_PORT=${PG_PORT:-5432}

            while true; do
                read -p "PostgreSQL 用户: " PG_USER
                if [ -n "$PG_USER" ]; then
                    break
                fi
                print_error "PostgreSQL 用户不能为空，请重新输入"
            done

            while true; do
                read -p "PostgreSQL 密码: " PG_PASSWORD
                if [ -n "$PG_PASSWORD" ]; then
                    break
                fi
                print_error "PostgreSQL 密码不能为空，请重新输入"
            done

            while true; do
                read -p "PostgreSQL 数据库名: " PG_DBNAME
                if [ -n "$PG_DBNAME" ]; then
                    break
                fi
                print_error "PostgreSQL 数据库名不能为空，请重新输入"
            done

            # 测试 PostgreSQL 连接
            echo ""
            PG_SSLMODE=$(detect_pg_sslmode "$PG_HOST")
            if test_pg_connection "$PG_HOST" "$PG_PORT" "$PG_USER" "$PG_PASSWORD" "$PG_DBNAME"; then
                break
            else
                echo ""
                print_warning "请重新输入 PostgreSQL 配置"
                echo ""
            fi
        done
    else
        # 命令行模式
        PG_HOST=${CLI_PG_HOST:-localhost}
        PG_PORT=${CLI_PG_PORT:-5432}
        PG_USER=$CLI_PG_USER
        PG_PASSWORD=$CLI_PG_PASSWORD
        PG_DBNAME=$CLI_PG_DBNAME

        if [ -z "$PG_USER" ] || [ -z "$PG_PASSWORD" ] || [ -z "$PG_DBNAME" ]; then
            print_error "PostgreSQL 配置不完整（需要 --pg_user, --pg_password, --pg_dbname）"
            exit 1
        fi

        PG_SSLMODE=$(detect_pg_sslmode "$PG_HOST")
        if ! test_pg_connection "$PG_HOST" "$PG_PORT" "$PG_USER" "$PG_PASSWORD" "$PG_DBNAME"; then
            print_error "PostgreSQL 连接失败，请检查配置"
            exit 1
        fi
    fi

    # 检查数据库是否有现有数据
    echo ""
    set +e  # 临时关闭 set -e
    DB_USER_COUNT=$(check_database_data "$PG_HOST" "$PG_PORT" "$PG_USER" "$PG_PASSWORD" "$PG_DBNAME")
    DB_HAS_DATA=$?
    set -e  # 恢复 set -e

    # 声明变量，避免后续未定义
    ADMIN_EMAIL=""
    ADMIN_PASSWORD=""
    USE_EXISTING_ADMIN=false

    if [ $DB_HAS_DATA -eq 1 ]; then
        # 数据库有数据
        if [ "$CLI_MODE" = false ]; then
            print_warning "⚠️  警告：数据库 '$PG_DBNAME' 中已存在 $DB_USER_COUNT 个用户"
            echo ""
            echo "可能的原因："
            echo "  - 之前安装过 Sub2API"
            echo "  - 数据库未清理"
            echo ""
            echo "请选择操作："
            echo "  1) 继续安装（使用现有数据，管理员账号不变）"
            echo "  2) 清空数据库并继续安装（重新创建管理员）"
            echo "  3) 取消安装"
            echo ""

            while true; do
                read -p "请选择 [1-3]: " db_choice
                case $db_choice in
                    1)
                        print_info "将使用现有数据库，不会创建新管理员"
                        USE_EXISTING_ADMIN=true
                        break
                        ;;
                    2)
                        if clear_database "$PG_HOST" "$PG_PORT" "$PG_USER" "$PG_PASSWORD" "$PG_DBNAME"; then
                            print_success "数据库已清空，将创建新管理员"
                            break
                        else
                            print_error "数据库清空失败"
                            return
                        fi
                        ;;
                    3)
                        print_info "安装已取消"
                        return
                        ;;
                    *)
                        print_error "无效选项，请输入 1-3"
                        ;;
                esac
            done
        else
            # 命令行模式：默认使用现有数据
            print_warning "⚠️  数据库中已存在数据，将使用现有管理员账号"
            USE_EXISTING_ADMIN=true
        fi
    fi

    if [ "$CLI_MODE" = false ]; then
        echo ""
        read -p "Sub2API 监听地址 [0.0.0.0]: " SUB2API_HOST
        SUB2API_HOST=${SUB2API_HOST:-0.0.0.0}

        while true; do
            read -p "Sub2API 监听端口 [8080]: " SUB2API_PORT
            SUB2API_PORT=${SUB2API_PORT:-8080}

            # 检查端口是否被占用
            if check_port "$SUB2API_PORT"; then
                print_error "端口 $SUB2API_PORT 已被占用"
                echo "请使用以下命令查看占用情况："
                echo "  sockstat -4l | grep :$SUB2API_PORT"
            else
                print_success "端口 $SUB2API_PORT 可用"
                break
            fi
        done
    else
        SUB2API_HOST=${CLI_SUB2API_HOST:-0.0.0.0}
        SUB2API_PORT=${CLI_SUB2API_PORT:-8080}
        if check_port "$SUB2API_PORT"; then
            print_error "端口 $SUB2API_PORT 已被占用"
            exit 1
        fi
    fi

    # 只有在不使用现有管理员时才询问管理员信息
    if [ "$USE_EXISTING_ADMIN" = false ]; then
        if [ "$CLI_MODE" = false ]; then
            echo ""
            print_info "请设置管理员账号信息："

            while true; do
                read -p "管理员邮箱: " ADMIN_EMAIL
                if [ -n "$ADMIN_EMAIL" ]; then
                    break
                fi
                print_error "管理员邮箱不能为空，请重新输入"
            done

            while true; do
                read -p "管理员密码: " ADMIN_PASSWORD
                if [ -z "$ADMIN_PASSWORD" ]; then
                    print_error "管理员密码不能为空，请重新输入"
                elif [ ${#ADMIN_PASSWORD} -lt 8 ]; then
                    print_error "管理员密码至少需要8位，请重新输入"
                else
                    break
                fi
            done
        else
            ADMIN_EMAIL=$CLI_ADMIN_EMAIL
            ADMIN_PASSWORD=$CLI_ADMIN_PASSWORD

            if [ -z "$ADMIN_EMAIL" ] || [ -z "$ADMIN_PASSWORD" ]; then
                print_error "管理员信息不完整（需要 --admin_email, --admin_password）"
                exit 1
            fi

            if [ ${#ADMIN_PASSWORD} -lt 8 ]; then
                print_error "管理员密码至少需要8位"
                exit 1
            fi
        fi
    fi

    # 确认配置
    if [ "$CLI_MODE" = false ]; then
        echo ""
        print_info "配置信息确认："
        echo "工作目录: $WORK_DIR"
        echo "Redis 主机: $REDIS_HOST"
        echo "Redis 端口: $REDIS_PORT"
        echo "Redis 密码: ******"
        echo "PostgreSQL 主机: $PG_HOST"
        echo "PostgreSQL 端口: $PG_PORT"
        echo "PostgreSQL 用户: $PG_USER"
        echo "PostgreSQL 密码: ******"
        echo "PostgreSQL 数据库: $PG_DBNAME"
        echo "Sub2API 端口: $SUB2API_PORT"
        if [ "$USE_EXISTING_ADMIN" = true ]; then
            echo "管理员配置: 使用现有数据库中的管理员账号"
        else
            echo "管理员邮箱: $ADMIN_EMAIL"
            echo "管理员密码: ******"
        fi
        echo ""

        read -p "确认安装？(y/n) [y]: " CONFIRM
        CONFIRM=${CONFIRM:-y}

        if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
            print_info "安装已取消"
            return
        fi
    fi

    # 生成 JWT Secret
    print_info "生成 JWT Secret..."
    JWT_SECRET=$(generate_jwt_secret)
    if [ -z "$JWT_SECRET" ]; then
        print_error "生成 JWT Secret 失败"
        exit 1
    fi
    print_success "JWT Secret 已生成"

    # 创建目录
    print_info "创建目录结构..."
    REDIS_DATA_DIR="$WORK_DIR/redis_data"
    mkdir -p "$WORK_DIR/logs"
    mkdir -p "$REDIS_DATA_DIR"
    print_success "目录创建完成"

    # 生成 Redis 配置文件
    print_info "生成 Redis 配置文件..."
    cat > "$WORK_DIR/redis.conf" <<EOF
# Redis 配置文件
bind 0.0.0.0
port $REDIS_PORT
requirepass $REDIS_PASSWORD
protected-mode no
daemonize no
loglevel notice
dir $REDIS_DATA_DIR
save ""
appendonly no
EOF
    print_success "Redis 配置文件生成完成"

    # 选择版本并下载
    SELECTED_VERSION=$(select_version_for_install)
    if [ $? -ne 0 ] || [ -z "$SELECTED_VERSION" ]; then
        print_error "版本选择失败"
        exit 1
    fi

    print_info "将安装版本: $SELECTED_VERSION"

    if ! download_sub2api "$WORK_DIR" "$SELECTED_VERSION"; then
        print_error "下载失败"
        exit 1
    fi

    # 保存版本号
    CLEAN_VERSION=$(echo "$SELECTED_VERSION" | sed 's/^sub2api-//')
    save_version "$CLEAN_VERSION" "$WORK_DIR"

    # 启动 Redis
    start_redis "$WORK_DIR"

    # 验证 Redis 连接
    echo ""
    if ! test_redis_connection "$REDIS_HOST" "$REDIS_PORT" "$REDIS_PASSWORD"; then
        print_error "Redis 启动后连接失败"
        echo ""
        echo "可能的原因："
        echo "  - Redis 配置错误（主机/端口/密码）"
        echo "  - Redis 服务未正常启动"
        echo ""
        echo "请查看日志："
        echo "  tail -f $WORK_DIR/logs/redis.log"
        exit 1
    fi

    # 启动 Sub2API（Auto Setup 模式）
    start_sub2api_with_setup "$WORK_DIR" "$SUB2API_HOST" "$SUB2API_PORT" \
        "$PG_HOST" "$PG_PORT" "$PG_USER" "$PG_PASSWORD" "$PG_DBNAME" "$PG_SSLMODE" \
        "$REDIS_HOST" "$REDIS_PORT" "$REDIS_PASSWORD" \
        "$ADMIN_EMAIL" "$ADMIN_PASSWORD" \
        "$JWT_SECRET"

    # 检查启动结果
    if ! is_service_running "$WORK_DIR/sub2api.pid" || ! check_port "$SUB2API_PORT"; then
        echo ""
        print_error "Sub2API 启动失败"
        echo ""
        echo "可能的原因："
        echo "  1. 数据库连接失败"
        echo "  2. Redis 连接失败"
        echo "  3. 配置错误"
        echo "  4. 端口被占用"
        echo ""
        echo "请查看日志排查问题："
        echo "  tail -f $WORK_DIR/logs/sub2api.log"
        exit 1
    fi

    echo ""
    echo "=========================================="
    echo "服务信息："
    echo "  访问地址: http://localhost:$SUB2API_PORT"
    echo "  工作目录: $WORK_DIR"
    echo ""
    if [ "$USE_EXISTING_ADMIN" = true ]; then
        print_warning "注意：使用现有数据库，请使用原管理员账号登录"
    else
        echo "管理员登录信息："
        echo "  邮箱: $ADMIN_EMAIL"
        echo "  密码: $ADMIN_PASSWORD"
        echo ""
    fi
    echo "日志文件："
    echo "  Redis: $WORK_DIR/logs/redis.log"
    echo "  Sub2API: $WORK_DIR/logs/sub2api.log"
    echo ""
    echo "常用命令："
    echo "  管理服务: sh $SCRIPT_DIR/install.sh"
    echo "=========================================="
}

#===============================================================================
# 服务管理函数
#===============================================================================

# 带旋转动画的等待
# 参数：$1=提示文本, $2=最大等待秒数, $3=检查命令（成功返回0）
wait_with_spinner() {
    local message=$1
    local max_wait=$2
    local check_cmd=$3
    local wait_time=0
    local spin_chars='|/-\'
    local spin_idx=0
    local char

    while [ $wait_time -lt $max_wait ]; do
        if eval "$check_cmd" >/dev/null 2>&1; then
            printf "\r\033[K"
            return 0
        fi
        char=$(echo "$spin_chars" | cut -c $((spin_idx + 1)))
        printf "\r  %s %s (%ds)" "$char" "$message" "$wait_time"
        spin_idx=$(( (spin_idx + 1) % 4 ))
        sleep 1
        wait_time=$((wait_time + 1))
    done

    printf "\r\033[K"
    return 1
}

# 检查进程是否运行（通过 PID 文件）
is_service_running() {
    local pid_file=$1

    if [ ! -f "$pid_file" ]; then
        return 1
    fi

    local pid=$(cat "$pid_file" 2>/dev/null)
    if [ -z "$pid" ]; then
        return 1
    fi

    # 检查进程是否存在
    if ps -p "$pid" >/dev/null 2>&1; then
        return 0
    else
        # PID 文件存在但进程不存在，删除过期的 PID 文件
        rm -f "$pid_file"
        return 1
    fi
}

# 停止服务（通过 PID 文件）
stop_service() {
    local service_name=$1
    local pid_file=$2

    if ! is_service_running "$pid_file"; then
        return 0
    fi

    print_info "停止 $service_name..."
    local pid=$(cat "$pid_file")
    kill -9 "$pid" 2>/dev/null
    rm -f "$pid_file"
    sleep 1
    print_success "$service_name 已停止"
}

# 启动 Redis
start_redis() {
    local work_dir=$1
    local pid_file="$work_dir/redis.pid"

    if is_service_running "$pid_file"; then
        print_info "Redis 已在运行"
        return 0
    fi

    print_info "启动 Redis..."
    cd "$work_dir" || exit 1
    redis-server "$work_dir/redis.conf" > "$work_dir/logs/redis.log" 2>&1 &
    echo $! > "$pid_file"

    # 从配置文件读取端口
    local redis_port=$(grep "^port " "$work_dir/redis.conf" | awk '{print $2}')
    if [ -z "$redis_port" ]; then
        redis_port=6379
    fi

    # 等待 Redis 进程启动并监听端口（最多 10 秒）
    if wait_with_spinner "等待 Redis 启动" 10 "is_service_running '$pid_file' && check_port '$redis_port'"; then
        print_success "Redis 启动完成"
        return 0
    else
        print_error "Redis 启动失败"
        return 1
    fi
}

# 停止 Redis
stop_redis() {
    local work_dir=$1
    stop_service "Redis" "$work_dir/redis.pid"
}

# 启动 Sub2API（Auto Setup 模式，带环境变量）
start_sub2api_with_setup() {
    local work_dir=$1
    local sub2api_host=$2
    local sub2api_port=$3
    local pg_host=$4
    local pg_port=$5
    local pg_user=$6
    local pg_password=$7
    local pg_dbname=$8
    local pg_sslmode=$9
    shift 9
    local redis_host=$1
    local redis_port=$2
    local redis_password=$3
    local admin_email=$4
    local admin_password=$5
    local jwt_secret=$6
    local pid_file="$work_dir/sub2api.pid"

    if is_service_running "$pid_file"; then
        print_info "Sub2API 已在运行"
        return 0
    fi

    cd "$work_dir" || exit 1

    print_info "启动 Sub2API（Auto Setup 模式）..."
    env AUTO_SETUP=true \
        DATA_DIR="$work_dir" \
        DATABASE_HOST="$pg_host" \
        DATABASE_PORT="$pg_port" \
        DATABASE_USER="$pg_user" \
        DATABASE_PASSWORD="$pg_password" \
        DATABASE_DBNAME="$pg_dbname" \
        DATABASE_SSLMODE="$pg_sslmode" \
        REDIS_HOST="$redis_host" \
        REDIS_PORT="$redis_port" \
        REDIS_PASSWORD="$redis_password" \
        ADMIN_EMAIL="$admin_email" \
        ADMIN_PASSWORD="$admin_password" \
        SERVER_HOST="$sub2api_host" \
        SERVER_PORT="$sub2api_port" \
        SERVER_MODE="release" \
        JWT_SECRET="$jwt_secret" \
        ./sub2api > "$work_dir/logs/sub2api.log" 2>&1 &
    echo $! > "$pid_file"
    echo "⏳ 首次启动需初始化数据库，可能需要 10-60 秒，请稍候..."

    # 等待 Sub2API 监听端口（最多 60 秒）
    if wait_with_spinner "等待 Sub2API 启动" 60 "check_port '$sub2api_port'"; then
        print_success "Sub2API 启动完成"
        return 0
    else
        print_error "Sub2API 启动失败（超时）"
        return 1
    fi
}

# 启动 Sub2API（常规模式，读取 config.yaml）
start_sub2api() {
    local work_dir=$1
    local sub2api_port=$2
    local pid_file="$work_dir/sub2api.pid"

    if is_service_running "$pid_file"; then
        print_info "Sub2API 已在运行"
        return 0
    fi

    cd "$work_dir" || exit 1

    print_info "启动 Sub2API..."
    DATA_DIR="$work_dir" ./sub2api > "$work_dir/logs/sub2api.log" 2>&1 &
    echo $! > "$pid_file"

    # 等待 Sub2API 监听端口（最多 30 秒）
    if wait_with_spinner "等待 Sub2API 启动" 30 "check_port '$sub2api_port'"; then
        print_success "Sub2API 启动完成"
        return 0
    else
        print_error "Sub2API 启动失败"
        return 1
    fi
}

# 停止 Sub2API
stop_sub2api() {
    local work_dir=$1
    stop_service "Sub2API" "$work_dir/sub2api.pid"
}

# 停止所有服务（Redis + Sub2API）
# 返回 0=有服务被停止，1=本来就没有服务在运行
stop_all_services() {
    local work_dir=$1
    local redis_running=false
    local sub2api_running=false

    if is_service_running "$work_dir/redis.pid"; then
        redis_running=true
    fi

    if is_service_running "$work_dir/sub2api.pid"; then
        sub2api_running=true
    fi

    if [ "$redis_running" = false ] && [ "$sub2api_running" = false ]; then
        return 1
    fi

    # 先停 Sub2API，再停 Redis（Sub2API 依赖 Redis）
    if [ "$sub2api_running" = true ]; then
        stop_sub2api "$work_dir"
    fi

    if [ "$redis_running" = true ]; then
        stop_redis "$work_dir"
    fi

    return 0
}

# 读取配置文件中的端口
get_port_from_config() {
    local config_file=${1:-./config.yaml}
    grep "port:" "$config_file" | head -n 1 | awk '{print $2}'
}

#===============================================================================
# 下载 Sub2API 二进制
#===============================================================================

# 获取最新版本号
get_latest_version() {
    # 将提示信息输出到 stderr，避免污染返回值
    print_info "检查最新版本..." >&2

    # 使用代理加速访问 GitHub API
    GITHUB_API_PROXY="https://ghfast.top/"
    VERSION=$(curl -s "${GITHUB_API_PROXY}api.github.com/repos/${GITHUB_REPO}/releases?per_page=100" \
        | grep '"tag_name":' \
        | grep 'sub2api-' \
        | cut -d '"' -f 4 \
        | sort -rV \
        | head -n 1)

    if [ -z "$VERSION" ]; then
        print_error "获取版本号失败" >&2
        return 1
    fi

    print_info "最新版本: $VERSION" >&2
    echo "$VERSION"
}

# 获取当前版本号（从版本文件读取）
get_current_version() {
    if [ -f "./.version" ]; then
        cat "./.version"
    else
        echo "unknown"
    fi
}

# 保存版本号到文件
save_version() {
    local version=$1
    local work_dir=${2:-$(pwd)}
    echo "$version" > "$work_dir/.version"
}

# 下载 Sub2API 二进制文件
download_sub2api() {
    local work_dir=$1
    local version=$2

    if [ -z "$version" ]; then
        version=$(get_latest_version)
        if [ $? -ne 0 ]; then
            return 1
        fi
    else
        # 如果已经提供了版本号，只显示信息，不再调用 get_latest_version
        print_info "使用版本: $version"
    fi

    # 去掉 sub2api- 前缀，得到上游版本号
    UPSTREAM_VERSION=$(echo "$version" | sed 's/^sub2api-//')

    # 使用加速代理
    GITHUB_PROXY="https://ghfast.top/"
    URL="${GITHUB_PROXY}github.com/${GITHUB_REPO}/releases/download/${version}/sub2api_${UPSTREAM_VERSION}_freebsd_amd64.tar.gz"

    print_info "下载地址: $URL"

    TMPDIR=$(mktemp -d)

    if ! curl -L -f -o "${TMPDIR}/sub2api.tar.gz" "$URL"; then
        print_error "下载失败"
        echo ""
        echo "可能的原因："
        echo "  1. 版本 $version 不存在或没有对应的构建产物"
        echo "  2. 网络连接失败或代理不可用"
        echo ""
        echo "查看所有可用版本："
        echo "  https://github.com/${GITHUB_REPO}/releases"
        rm -rf "${TMPDIR}"
        return 1
    fi

    print_info "解压文件..."
    if ! tar -xzf "${TMPDIR}/sub2api.tar.gz" -C "${TMPDIR}"; then
        print_error "解压失败，下载的文件可能不是有效的压缩包"
        echo ""
        echo "可能的原因："
        echo "  1. 版本 $version 不存在（下载到的是错误页面）"
        echo "  2. 下载过程中文件损坏"
        echo ""
        echo "查看所有可用版本："
        echo "  https://github.com/${GITHUB_REPO}/releases"
        rm -rf "${TMPDIR}"
        return 1
    fi

    SUB_BIN=$(find "${TMPDIR}" -type f -name "sub2api" | head -n 1)

    if [ -z "$SUB_BIN" ] || [ ! -f "$SUB_BIN" ]; then
        print_error "未找到 sub2api 二进制文件"
        echo ""
        echo "可能的原因："
        echo "  1. 该版本没有 FreeBSD amd64 的构建产物"
        echo "  2. 压缩包结构异常"
        rm -rf "${TMPDIR}"
        return 1
    fi

    cp -f "$SUB_BIN" "$work_dir/sub2api"
    chmod +x "$work_dir/sub2api"

    rm -rf "${TMPDIR}"

    print_success "下载完成"
    return 0
}

#===============================================================================
# 启动服务（首次安装时使用，带环境变量）
#===============================================================================

#===============================================================================
# 更新功能
#===============================================================================

update_sub2api() {
    print_info "开始更新 Sub2API"
    echo ""

    # 检查是否已安装
    if ! check_installation; then
        return
    fi

    WORK_DIR=$(pwd)

    # 检查当前版本
    CURRENT_VERSION=$(get_current_version)
    print_info "当前版本: $CURRENT_VERSION"

    # 选择版本（临时关闭 set -e 允许函数返回 1）
    set +e
    SELECTED_VERSION=$(select_version_for_update "$CURRENT_VERSION")
    select_result=$?
    set -e

    if [ $select_result -ne 0 ] || [ -z "$SELECTED_VERSION" ]; then
        # 已经是最新版本或选择失败
        return
    fi

    LATEST_VERSION=$(echo "$SELECTED_VERSION" | sed 's/^sub2api-//')

    print_info "将更新到版本: $SELECTED_VERSION"

    # 确认更新
    if [ "$CLI_MODE" = false ]; then
        echo ""
        read -p "确认更新到 $LATEST_VERSION？(y/n) [y]: " CONFIRM
        CONFIRM=${CONFIRM:-y}

        if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
            print_info "更新已取消"
            return
        fi
    fi

    # 读取配置获取端口
    SUB2API_PORT=$(get_port_from_config)
    if [ -z "$SUB2API_PORT" ]; then
        print_error "无法读取 Sub2API 端口配置"
        exit 1
    fi

    # 备份当前版本
    print_info "备份当前版本..."
    if [ -f "./sub2api" ]; then
        cp -f "./sub2api" "./sub2api.bak"
        print_success "备份完成"
    fi

    # 停止服务（只停止运行中的服务）
    echo ""
    stop_sub2api "$WORK_DIR"

    # 下载新版本
    if ! download_sub2api "$WORK_DIR" "$SELECTED_VERSION"; then
        print_error "下载失败"
        # 恢复备份
        if [ -f "./sub2api.bak" ]; then
            cp -f "./sub2api.bak" "./sub2api"
            print_info "已恢复到旧版本"
        fi
        return
    fi

    # 保存版本号
    save_version "$LATEST_VERSION" "$WORK_DIR"

    # 启动服务
    echo ""
    if start_sub2api "$WORK_DIR" "$SUB2API_PORT"; then
        echo ""
        print_success "更新成功！"
        echo "版本: $CURRENT_VERSION → $LATEST_VERSION"
        rm -f "./sub2api.bak"
    else
        print_error "启动失败，正在回滚..."
        # 恢复备份并重启
        if [ -f "./sub2api.bak" ]; then
            cp -f "./sub2api.bak" "./sub2api"
            if start_sub2api "$WORK_DIR" "$SUB2API_PORT"; then
                print_warning "已回滚到旧版本"
            else
                print_error "回滚失败，请手动检查"
            fi
        fi
        print_error "更新失败，请查看日志: $WORK_DIR/logs/sub2api.log"
        exit 1
    fi
}

#===============================================================================
# 启动功能
#===============================================================================

#===============================================================================
# 启动功能（菜单选项）
#===============================================================================

start_sub2api_menu() {
    # 检查是否已安装
    if ! check_installation; then
        return
    fi

    WORK_DIR=$(pwd)

    # 读取配置获取端口
    SUB2API_PORT=$(get_port_from_config)
    if [ -z "$SUB2API_PORT" ]; then
        print_error "无法读取 Sub2API 端口配置"
        exit 1
    fi

    # 检查服务运行状态
    REDIS_RUNNING=false
    SUB2API_RUNNING=false

    if is_service_running "$WORK_DIR/redis.pid"; then
        REDIS_RUNNING=true
    fi

    if is_service_running "$WORK_DIR/sub2api.pid"; then
        SUB2API_RUNNING=true
    fi

    # 根据状态决定启动哪些服务
    if [ "$REDIS_RUNNING" = true ] && [ "$SUB2API_RUNNING" = true ]; then
        print_success "所有服务已在运行"
        echo "  Redis: 运行中"
        echo "  Sub2API: 运行中 (端口: $SUB2API_PORT)"
        return
    fi

    # 启动 Redis（如果未运行）
    if [ "$REDIS_RUNNING" = false ]; then
        start_redis "$WORK_DIR"
    else
        print_info "Redis 已在运行"
    fi

    # 启动 Sub2API（如果未运行）
    if [ "$SUB2API_RUNNING" = false ]; then
        if start_sub2api "$WORK_DIR" "$SUB2API_PORT"; then
            echo ""
            print_success "服务启动成功！"
            echo "访问地址: http://localhost:$SUB2API_PORT"
        else
            print_error "启动失败，请查看日志: $WORK_DIR/logs/sub2api.log"
        fi
    else
        print_info "Sub2API 已在运行"
    fi
}

#===============================================================================
# 停止功能（菜单选项）
#===============================================================================

stop_sub2api_menu() {
    # 检查是否已安装
    if ! check_installation; then
        return
    fi

    WORK_DIR=$(pwd)

    if stop_all_services "$WORK_DIR"; then
        echo ""
        print_success "所有服务已停止"
    else
        print_info "服务未在运行"
    fi
}

#===============================================================================
# 卸载功能（菜单选项）
#===============================================================================

uninstall_sub2api() {
    print_info "卸载 Sub2API"
    echo ""

    # 检查是否已安装
    if ! check_installation; then
        return
    fi

    WORK_DIR=$(pwd)

    print_warning "⚠️  将删除以下文件和目录："
    echo "  - sub2api（二进制文件）"
    echo "  - sub2api.bak（备份）"
    echo "  - config.yaml（配置文件）"
    echo "  - redis.conf（Redis 配置）"
    echo "  - redis_data/（Redis 数据）"
    echo "  - logs/（日志文件）"
    echo "  - data/（sub2api 数据）"
    echo "  - .version, .installed（状态文件）"
    echo "  - redis.pid, sub2api.pid（PID 文件）"
    echo ""
    print_warning "注意：数据库中的数据不会被删除"
    echo ""

    read -p "确认卸载？(y/n) [n]: " CONFIRM
    CONFIRM=${CONFIRM:-n}

    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        print_info "卸载已取消"
        return
    fi

    # 停止服务
    echo ""
    if stop_all_services "$WORK_DIR"; then
        echo ""
    fi

    # 删除文件
    print_info "删除文件..."
    rm -f "$WORK_DIR/sub2api"
    rm -f "$WORK_DIR/sub2api.bak"
    rm -f "$WORK_DIR/config.yaml"
    rm -f "$WORK_DIR/redis.conf"
    rm -f "$WORK_DIR/.version"
    rm -f "$WORK_DIR/.installed"
    rm -f "$WORK_DIR/redis.pid"
    rm -f "$WORK_DIR/sub2api.pid"
    rm -rf "$WORK_DIR/redis_data"
    rm -rf "$WORK_DIR/logs"
    rm -rf "$WORK_DIR/data"

    print_success "卸载完成"
}

#===============================================================================
# 命令行参数解析
#===============================================================================

show_usage() {
    printf "${COLOR_CYAN}使用方法:${COLOR_RESET}\n"
    printf "  sh install.sh [命令] [选项]\n\n"

    printf "${COLOR_CYAN}命令:${COLOR_RESET}\n"
    printf "  install         安装 Sub2API\n"
    printf "  update          更新 Sub2API\n"
    printf "  start           启动服务\n"
    printf "  stop            停止服务\n"
    printf "  uninstall       卸载 Sub2API\n\n"

    printf "${COLOR_CYAN}安装选项 (install):${COLOR_RESET}\n"
    printf "  --redis_host=HOST           Redis 主机地址 [localhost]\n"
    printf "  --redis_port=PORT           Redis 端口 [6379]\n"
    printf "  --redis_password=PASS       Redis 密码（必需）\n"
    printf "  --pg_host=HOST              PostgreSQL 主机地址 [localhost]\n"
    printf "  --pg_port=PORT              PostgreSQL 端口 [5432]\n"
    printf "  --pg_user=USER              PostgreSQL 用户（必需）\n"
    printf "  --pg_password=PASS          PostgreSQL 密码（必需）\n"
    printf "  --pg_dbname=DBNAME          PostgreSQL 数据库名（必需）\n"
    printf "  --host=HOST                 Sub2API 监听地址 [0.0.0.0]\n"
    printf "  --port=PORT                 Sub2API 监听端口 [8080]\n"
    printf "  --admin_email=EMAIL         管理员邮箱（必需）\n"
    printf "  --admin_password=PASS       管理员密码（必需，至少8位）\n"
    printf "  --version=VERSION           指定版本号（可选，如 sub2api-v0.0.138）\n\n"

    printf "${COLOR_CYAN}更新选项 (update):${COLOR_RESET}\n"
    printf "  --version=VERSION           指定版本号（可选，如 sub2api-v0.0.138）\n\n"

    printf "${COLOR_CYAN}示例:${COLOR_RESET}\n"
    printf "  # 交互式安装（显示菜单）\n"
    printf "  sh install.sh\n\n"

    printf "  # 自动化安装\n"
    printf "  sh install.sh install \\\\\n"
    printf "    --redis_host=localhost \\\\\n"
    printf "    --redis_password=myredispass \\\\\n"
    printf "    --pg_host=localhost \\\\\n"
    printf "    --pg_user=postgres \\\\\n"
    printf "    --pg_password=mydbpass \\\\\n"
    printf "    --pg_dbname=sub2api \\\\\n"
    printf "    --admin_email=admin@example.com \\\\\n"
    printf "    --admin_password=admin12345\n\n"

    printf "  # 安装指定版本\n"
    printf "  sh install.sh install \\\\\n"
    printf "    --redis_password=xxx \\\\\n"
    printf "    --pg_user=postgres \\\\\n"
    printf "    --pg_password=xxx \\\\\n"
    printf "    --pg_dbname=sub2api \\\\\n"
    printf "    --admin_email=admin@example.com \\\\\n"
    printf "    --admin_password=admin12345 \\\\\n"
    printf "    --version=sub2api-v0.0.138\n\n"

    printf "  # 更新到最新版本\n"
    printf "  sh install.sh update\n\n"

    printf "  # 更新到指定版本\n"
    printf "  sh install.sh update --version=sub2api-v0.0.138\n\n"

    printf "  # 启动服务\n"
    printf "  sh install.sh start\n\n"

    printf "  # 停止服务\n"
    printf "  sh install.sh stop\n\n"

    printf "  # 卸载\n"
    printf "  sh install.sh uninstall\n\n"

    printf "${COLOR_CYAN}注意事项:${COLOR_RESET}\n"
    printf "  - 密码参数会暴露在命令行历史中，建议仅在自动化脚本中使用\n"
    printf "  - 无参数运行时将进入交互式菜单模式\n"
    printf "  - start/stop/uninstall 命令不接受额外参数\n"
}

parse_install_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --redis_host=*)
                CLI_REDIS_HOST="${1#*=}"
                ;;
            --redis_port=*)
                CLI_REDIS_PORT="${1#*=}"
                ;;
            --redis_password=*)
                CLI_REDIS_PASSWORD="${1#*=}"
                ;;
            --pg_host=*)
                CLI_PG_HOST="${1#*=}"
                ;;
            --pg_port=*)
                CLI_PG_PORT="${1#*=}"
                ;;
            --pg_user=*)
                CLI_PG_USER="${1#*=}"
                ;;
            --pg_password=*)
                CLI_PG_PASSWORD="${1#*=}"
                ;;
            --pg_dbname=*)
                CLI_PG_DBNAME="${1#*=}"
                ;;
            --host=*)
                CLI_SUB2API_HOST="${1#*=}"
                ;;
            --port=*)
                CLI_SUB2API_PORT="${1#*=}"
                ;;
            --admin_email=*)
                CLI_ADMIN_EMAIL="${1#*=}"
                ;;
            --admin_password=*)
                CLI_ADMIN_PASSWORD="${1#*=}"
                ;;
            --version=*)
                CLI_TARGET_VERSION="${1#*=}"
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                echo ""
                show_usage
                exit 1
                ;;
        esac
        shift
    done
}

parse_update_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --version=*)
                CLI_TARGET_VERSION="${1#*=}"
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                print_error "未知参数: $1"
                echo ""
                show_usage
                exit 1
                ;;
        esac
        shift
    done
}

validate_no_extra_args() {
    if [ $# -gt 0 ]; then
        print_error "此命令不接受额外参数: $*"
        echo ""
        show_usage
        exit 1
    fi
}

show_menu() {
    local work_dir=$(pwd)
    local redis_status
    local sub2api_status
    local version="未安装"

    if [ -f "$work_dir/.version" ]; then
        version=$(cat "$work_dir/.version")
    fi

    if is_service_running "$work_dir/redis.pid"; then
        local redis_pid=$(cat "$work_dir/redis.pid")
        redis_status=$(printf "${COLOR_GREEN}运行中${COLOR_RESET} (PID: %s)" "$redis_pid")
    else
        redis_status=$(printf "${COLOR_RED}未运行${COLOR_RESET}")
    fi

    if is_service_running "$work_dir/sub2api.pid"; then
        local sub2api_pid=$(cat "$work_dir/sub2api.pid")
        local sub2api_port=$(get_port_from_config 2>/dev/null)
        if [ -n "$sub2api_port" ]; then
            sub2api_status=$(printf "${COLOR_GREEN}运行中${COLOR_RESET} (PID: %s, 端口: %s, 版本: %s)" "$sub2api_pid" "$sub2api_port" "$version")
        else
            sub2api_status=$(printf "${COLOR_GREEN}运行中${COLOR_RESET} (PID: %s, 版本: %s)" "$sub2api_pid" "$version")
        fi
    else
        sub2api_status=$(printf "${COLOR_RED}未运行${COLOR_RESET} (版本: %s)" "$version")
    fi

    echo ""
    printf "${COLOR_CYAN}==========================================${COLOR_RESET}\n"
    printf "${COLOR_CYAN}  Sub2API FreeBSD 管理脚本${COLOR_RESET}\n"
    printf "${COLOR_CYAN}==========================================${COLOR_RESET}\n"
    printf "  Redis:   %b\n" "$redis_status"
    printf "  Sub2API: %b\n" "$sub2api_status"
    printf "${COLOR_CYAN}==========================================${COLOR_RESET}\n"
    echo "请选择操作："
    printf "  1) 安装 Sub2API\n"
    printf "  2) 更新 Sub2API\n"
    printf "  3) 启动 Sub2API\n"
    printf "  ${COLOR_YELLOW}4) 停止 Sub2API${COLOR_RESET}\n"
    printf "  ${COLOR_RED}5) 卸载 Sub2API${COLOR_RESET}\n"
    printf "  ${COLOR_CYAN}0) 退出${COLOR_RESET}\n"
    printf "${COLOR_CYAN}==========================================${COLOR_RESET}\n"
    echo ""
}

#===============================================================================
# 主程序
#===============================================================================

main() {
    # 无参数时进入菜单模式
    if [ $# -eq 0 ]; then
        while true; do
            show_menu
            read -p "请输入选项 [0-5]: " choice

            case $choice in
                1)
                    install_sub2api
                    ;;
                2)
                    update_sub2api
                    ;;
                3)
                    start_sub2api_menu
                    ;;
                4)
                    stop_sub2api_menu
                    ;;
                5)
                    uninstall_sub2api
                    ;;
                0)
                    print_info "退出"
                    exit 0
                    ;;
                *)
                    print_error "无效选项，请输入 0-5"
                    ;;
            esac

            echo ""
            read -p "按回车键继续..." dummy
        done
    fi

    # 命令行模式
    CLI_MODE=true
    COMMAND=$1
    shift

    case $COMMAND in
        install)
            parse_install_args "$@"
            install_sub2api
            ;;
        update)
            parse_update_args "$@"
            update_sub2api
            ;;
        start)
            validate_no_extra_args "$@"
            start_sub2api_menu
            ;;
        stop)
            validate_no_extra_args "$@"
            stop_sub2api_menu
            ;;
        uninstall)
            validate_no_extra_args "$@"
            uninstall_sub2api
            ;;
        --help|-h|help)
            show_usage
            exit 0
            ;;
        *)
            print_error "未知命令: $COMMAND"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# 运行主程序
main "$@"
