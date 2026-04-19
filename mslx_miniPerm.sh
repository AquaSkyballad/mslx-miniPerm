#!/bin/bash

# ==========================================
#  MSLX-Daemon 安装/更新脚本 (标准 Linux 版)
# ==========================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 基础配置
DEFAULT_INSTALL_DIR="/opt/mslx"
DEFAULT_MC_DIR="/opt/mslx/DaemonData/Servers"
SERVICE_NAME="mslx"
DEFAULT_PORT="1027"
API_BASE="https://api.mslmc.cn/v3/download/update"
DEFAULT_USER="mslx_user"
SUDO_FILE="/etc/sudoers.d/mslx-service"

# 检查 Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 权限运行此脚本${NC}"
  exit 1
fi

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}    MSLX-Daemon 安装/更新向导 (Linux)    ${NC}"
echo -e "${BLUE}=========================================${NC}"

# 重定向临时目录到硬盘
echo -e "${YELLOW}[系统检测] 优化临时存储空间...${NC}"
DISK_TMP_DIR="/opt/mslx_temp_setup"
mkdir -p "$DISK_TMP_DIR"
export TMPDIR="$DISK_TMP_DIR"
export TEMP="$DISK_TMP_DIR"
export TMP="$DISK_TMP_DIR"
echo -e ">> 临时目录: $DISK_TMP_DIR"

# 架构检测
SYSTEM_ARCH=$(uname -m)
if [[ "$SYSTEM_ARCH" == "x86_64" ]]; then
    ARCH_PARAM="x64"
elif [[ "$SYSTEM_ARCH" == "aarch64" ]]; then
    ARCH_PARAM="arm64"
else
    echo -e "${RED}不支持的架构: $SYSTEM_ARCH${NC}"
    rm -rf "$DISK_TMP_DIR"
    exit 1
fi

# ==========================================
# 历史安装检测 (一键更新逻辑)
# ==========================================
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SKIP_PROMPTS=false

if [ -f "$SERVICE_FILE" ]; then
    echo -e "\n${CYAN}>>> 检测到本地已安装 MSLX-Daemon，正在读取历史配置...${NC}"
    
    # 从 Systemd 文件中提取历史配置
    EXISTING_DIR=$(grep "^WorkingDirectory=" "$SERVICE_FILE" | cut -d'=' -f2)
    EXISTING_PORT=$(grep "^ExecStart=" "$SERVICE_FILE" | sed -n 's/.*--port \([0-9]*\).*/\1/p')
    EXISTING_HOST=$(grep "^ExecStart=" "$SERVICE_FILE" | sed -n 's/.*--host \([^ ]*\).*/\1/p')
    EXISTING_MC_DIR=$(grep "^Environment=MC_DIR=" "$SERVICE_FILE" | cut -d'=' -f2-)
    EXISTING_USER=$(grep "^User=" "$SERVICE_FILE" | cut -d'=' -f2)

    if [ -n "$EXISTING_DIR" ] && [ -n "$EXISTING_PORT" ]; then
        echo -e "  ● 历史安装目录: ${GREEN}$EXISTING_DIR${NC}"
        echo -e "  ● 历史监听端口: ${GREEN}$EXISTING_PORT${NC}"
        echo -e "  ● 历史监听地址: ${GREEN}$EXISTING_HOST${NC}"
        echo -e "  ● 历史MC目录: ${GREEN}$EXISTING_MC_DIR${NC}"
        echo -e "  ● 历史用户: ${GREEN}$EXISTING_USER${NC}"
        echo ""
        
        if [ -t 0 ]; then read -p "是否保留此配置并直接覆盖更新？[Y/n] (默认Y): " UPDATE_CHOICE; else read -p "是否保留此配置并直接覆盖更新？[Y/n] (默认Y): " UPDATE_CHOICE < /dev/tty; fi
        UPDATE_CHOICE=${UPDATE_CHOICE:-Y}

        if [[ "$UPDATE_CHOICE" =~ ^[Yy]$ ]]; then
            # 用户选择直接更新，跳过后续所有手动输入环节
            SKIP_PROMPTS=true
            INSTALL_DIR="$EXISTING_DIR"
            PORT="$EXISTING_PORT"
            LISTEN_ARG="--host $EXISTING_HOST"
            MC_DIR="$EXISTING_MC_DIR"
            USER="$EXISTING_USER"
            
            # 推算访问 IP
            if [[ "$EXISTING_HOST" == "*" || "$EXISTING_HOST" == "0.0.0.0" ]]; then
                LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
                [ -z "$LOCAL_IP" ] && LOCAL_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | head -n1 | awk '{print $2}' | cut -d/ -f1)
                HOST_IP="${LOCAL_IP}"
            else
                HOST_IP="$EXISTING_HOST"
            fi
            ACCESS_URL="http://${HOST_IP}:${PORT}"
            echo -e "${GREEN}>>> 已开启一键无缝更新模式！${NC}"
        else
            # 用户想要重新配置，将默认值替换为历史值
            DEFAULT_INSTALL_DIR="$EXISTING_DIR"
            DEFAULT_PORT="$EXISTING_PORT"
            DEFAULT_USER="$EXISTING_USER"
            DEFAULT_MC_DIR="$EXISTING_MC_DIR"
            echo -e "${YELLOW}提示: 旧MC实例目录 (${EXISTING_MC_DIR}) 不会被删除，请手动迁移或清理${NC}"
        fi
    fi
fi

# ==========================================
# 交互式配置向导 (如果不是直接更新)
# ==========================================
if [ "$SKIP_PROMPTS" = false ]; then
    echo -e "\n${YELLOW}[配置向导 1/5] 请输入安装目录:${NC}"
    if [ -t 0 ]; then read -p "目录路径 (默认 ${DEFAULT_INSTALL_DIR}): " INPUT_DIR; else read -p "目录路径 (默认 ${DEFAULT_INSTALL_DIR}): " INPUT_DIR < /dev/tty; fi

    if [[ -z "$INPUT_DIR" ]]; then
        INSTALL_DIR="$DEFAULT_INSTALL_DIR"
    else
        INSTALL_DIR="${INPUT_DIR%/}" # 移除路径末尾斜杠
    fi

    echo -e "\n${YELLOW}[配置向导 2/5] 请输入mslx用户名:${NC}"
    if [ -t 0 ]; then read -p "用户名 (默认 ${DEFAULT_USER}): " INPUT_USER; else read -p "用户名 (默认 ${DEFAULT_USER}): " INPUT_USER < /dev/tty; fi
    if [[ -z "$INPUT_USER" ]]; then
        USER="$DEFAULT_USER"
    else
        USER="$INPUT_USER"
    fi

    echo -e "\n${YELLOW}[配置向导 3/5] 请选择监听模式:${NC}"
    echo -e " 1) 监听本机 (127.0.0.1) - 推荐"
    echo -e " 2) 监听全部 (0.0.0.0)"
    if [ -t 0 ]; then read -p "选项 [1-2] (默认1): " CHOICE; else read -p "选项 [1-2] (默认1): " CHOICE < /dev/tty; fi

    if [[ "$CHOICE" == "2" ]]; then
        LISTEN_ARG="--host *"
        LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -z "$LOCAL_IP" ] && LOCAL_IP=$(ip addr show | grep 'inet ' | grep -v '127.0.0.1' | head -n1 | awk '{print $2}' | cut -d/ -f1)
        HOST_IP="${LOCAL_IP}"
    else
        LISTEN_ARG="--host 127.0.0.1"
        HOST_IP="127.0.0.1"
    fi

    echo -e "\n${YELLOW}[配置向导 4/5] 请输入监听端口:${NC}"
    while true; do
        if [ -t 0 ]; then read -p "端口号 (默认 ${DEFAULT_PORT}): " INPUT_PORT; else read -p "端口号 (默认 ${DEFAULT_PORT}): " INPUT_PORT < /dev/tty; fi
        [[ -z "$INPUT_PORT" ]] && PORT="$DEFAULT_PORT" && break
        if [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] && [ "$INPUT_PORT" -ge 1 ] && [ "$INPUT_PORT" -le 65535 ]; then PORT="$INPUT_PORT"; break; fi
        echo -e "${RED}端口无效${NC}"
    done
    ACCESS_URL="http://${HOST_IP}:${PORT}"

    echo -e "\n${YELLOW}[配置向导 5/5] 请输入MC实例安装位置:${NC}"
    echo -e "${YELLOW}仅配置目录权限,之后在面板内新建实例需手动填写该路径!${NC}"
    if [ -t 0 ]; then read -p "实例安装位置 (默认 ${DEFAULT_MC_DIR}): " MC_DIR; else read -p "目录路径 (默认 ${DEFAULT_MC_DIR}): " MC_DIR < /dev/tty; fi
    if [[ -z "$MC_DIR" ]]; then
        MC_DIR="$DEFAULT_MC_DIR"
    else
        MC_DIR="${MC_DIR%/}" # 移除路径末尾斜杠
    fi
fi

# ==========================================
# 自动化执行阶段
# ==========================================

# 安装基础依赖
echo -e "\n${YELLOW}[1/6] 安装系统依赖...${NC}"
if command -v apt-get >/dev/null; then
    apt-get update -qq && apt-get install -y libicu-dev curl wget tar >/dev/null
elif command -v yum >/dev/null; then
    yum install -y libicu curl wget tar >/dev/null
else
    echo -e "${RED}未找到 apt 或 yum，跳过依赖安装。${NC}"
fi

# 智能检测与安装 .NET SDK
echo -e "\n${YELLOW}[2/6] 检测/配置 .NET SDK 环境...${NC}"
DOTNET_CHANNEL="10.0" 

EXISTING_DOTNET=$(command -v dotnet)
if [ -n "$EXISTING_DOTNET" ]; then
    DOTNET_ROOT_DIR="$(dirname "$(readlink -f "$EXISTING_DOTNET")")"
else
    DOTNET_ROOT_DIR="/usr/share/dotnet"
fi

HAS_TARGET_SDK=false
if [ -x "$DOTNET_ROOT_DIR/dotnet" ]; then
    if "$DOTNET_ROOT_DIR/dotnet" --list-sdks | grep -q "^${DOTNET_CHANNEL}"; then
        HAS_TARGET_SDK=true
    fi
fi

if [ "$HAS_TARGET_SDK" = true ]; then
    FINAL_DOTNET_ROOT="$DOTNET_ROOT_DIR"
    FINAL_DOTNET_EXEC="$DOTNET_ROOT_DIR/dotnet"
    echo -e "${GREEN}发现有效的 .NET $DOTNET_CHANNEL SDK: $FINAL_DOTNET_ROOT (跳过安装)${NC}"
else
    echo -e "${BLUE}未检测到 .NET $DOTNET_CHANNEL，准备安装至: $DOTNET_ROOT_DIR ...${NC}"
    
    wget -q https://dot.net/v1/dotnet-install.sh -O dotnet-install.sh
    chmod +x ./dotnet-install.sh
    
    ./dotnet-install.sh --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_ROOT_DIR"
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}SDK 安装失败。请检查网络。${NC}"
        rm dotnet-install.sh && rm -rf "$DISK_TMP_DIR"
        exit 1
    fi
    
    FINAL_DOTNET_ROOT="$DOTNET_ROOT_DIR"
    FINAL_DOTNET_EXEC="$DOTNET_ROOT_DIR/dotnet"
    
    if [ ! -e "/usr/bin/dotnet" ] && [ "$DOTNET_ROOT_DIR" != "/usr/bin" ]; then
        ln -sf "$FINAL_DOTNET_EXEC" /usr/bin/dotnet
    fi
    
    if "$FINAL_DOTNET_EXEC" --list-sdks | grep -q "^${DOTNET_CHANNEL}"; then
        echo -e "${GREEN}.NET $DOTNET_CHANNEL SDK 安装验证成功${NC}"
    else
        echo -e "${RED}严重错误：SDK 安装后仍无法识别目标版本。${NC}"
        rm dotnet-install.sh && rm -rf "$DISK_TMP_DIR"
        exit 1
    fi
    rm dotnet-install.sh
fi

# 下载并安装程序
echo -e "\n${YELLOW}[3/6] 部署/更新 MSLX-Daemon...${NC}"
mkdir -p "$INSTALL_DIR"

if systemctl is-active --quiet $SERVICE_NAME 2>/dev/null; then 
    systemctl stop $SERVICE_NAME
fi

DOWNLOAD_URL="${API_BASE}?software=MSLX&system=Linux&direct=true&arch=${ARCH_PARAM}"
echo "下载链接: $DOWNLOAD_URL"
curl -L "$DOWNLOAD_URL" -o mslx.tar.gz

if [ -f "mslx.tar.gz" ] && [ $(du -k "mslx.tar.gz" | cut -f1) -gt 1 ]; then
    tar --no-same-owner -xzf mslx.tar.gz -C "$INSTALL_DIR"
    chmod +x "$INSTALL_DIR/MSLX-Daemon"
    rm mslx.tar.gz
    echo -e "${GREEN}文件已部署 (覆盖更新完成)${NC}"
else
    echo -e "${RED}下载失败${NC}"
    rm -rf "$DISK_TMP_DIR"
    exit 1
fi

# 创建用户
echo -e "\n${YELLOW}[4/6] 创建用户...${NC}"
if id -u "$USER" >/dev/null 2>&1; then
    echo -e "${GREEN}用户已存在${NC}"
else
    useradd -r -s /usr/sbin/nologin -d "$INSTALL_DIR" "$USER"
    echo -e "${GREEN}用户创建成功${NC}"
fi

# 配置目录权限
echo -e "\n${YELLOW}[5/6] 配置目录权限...${NC}"
if command -v setfacl >/dev/null 2>&1; then
    echo -e "${GREEN}ACL 已安装"
else
    echo -e "${BLUE}安装ACL..."
    apt-get update -qq && apt-get install -y acl >/dev/null
fi
if [ -e "$INSTALL_DIR" ] && \
   [ "$(stat -c %U "$INSTALL_DIR")" = "$USER" ] && \
   [ "$(stat -c %a "$INSTALL_DIR")" = "750" ]; then
    echo -e "${GREEN}安装目录权限已配置${NC}"
else
    chown -R $USER:$USER "$INSTALL_DIR"
    chmod -R 750 "$INSTALL_DIR"
    setfacl -dR -m u:$USER:rwx "$INSTALL_DIR"
    echo -e "${GREEN}安装目录权限配置完成${NC}"
fi
if [ -z "$MC_DIR" ]; then
    echo -e "${RED}MC_DIR 未定义，跳过${NC}"
elif [ ! -d "$MC_DIR" ]; then
    mkdir -p "$MC_DIR"
    chown -R $USER:$USER "$MC_DIR"
    chmod -R 750 "$MC_DIR"
    setfacl -dR -m u:$USER:rwx "$MC_DIR"
    echo -e "${GREEN}MC实例目录权限配置完成${NC}"
else
    if [ "$(stat -c %U "$MC_DIR")" != "$USER" ] || \
       [ "$(stat -c %a "$MC_DIR")" != "750" ]; then
        chown -R $USER:$USER "$MC_DIR"
        chmod -R 750 "$MC_DIR"
        setfacl -dR -m u:$USER:rwx "$MC_DIR"
        echo -e "${GREEN}MC实例目录权限已修复${NC}"
    else
        echo -e "${GREEN}MC实例目录权限已配置${NC}"
    fi
fi

# 配置 Systemd 服务
echo -e "\n${YELLOW}[6/6] 配置 Systemd 服务...${NC}"
EXEC_PATH="$INSTALL_DIR/MSLX-Daemon"

cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=MSLX Daemon Service
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
Environment=DOTNET_ROOT=$FINAL_DOTNET_ROOT
Environment=PATH=$FINAL_DOTNET_ROOT:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=MC_DIR=$MC_DIR
ExecStart=$EXEC_PATH $LISTEN_ARG --port $PORT
Restart=always
RestartSec=10
KillSignal=SIGINT
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null
systemctl start $SERVICE_NAME
echo -e "${GREEN}Systemd 服务已启动。${NC}"

# 清理临时目录
rm -rf "$DISK_TMP_DIR"

# 状态面板
echo -e "\n${YELLOW}正在等待服务初始化 (5s)...${NC}"
sleep 5

PID=$(pgrep -f "MSLX-Daemon")

echo -e "\n${BLUE}=========================================${NC}"
echo -e "${BLUE}        MSLX-Daemon 运行状态             ${NC}"
echo -e "${BLUE}=========================================${NC}"

if [ -n "$PID" ]; then
    echo -e "状态: ${GREEN}● 运行中${NC} (PID: $PID)"
    if command -v netstat >/dev/null; then
        if netstat -tuln | grep -q ":$PORT "; then
            echo -e "端口: ${GREEN}● $PORT 监听正常${NC}"
        else
            echo -e "端口: ${RED}⚠ 未检测到 $PORT 端口 (可能还在启动)${NC}"
        fi
    fi
else
    echo -e "状态: ${RED}● 未运行 (启动失败)${NC}"
fi

echo -e "目录: ${CYAN}${INSTALL_DIR}${NC}"
echo -e "地址: ${CYAN}${ACCESS_URL}${NC}"
echo -e "${BLUE}-----------------------------------------${NC}"

if [ "$SKIP_PROMPTS" = false ]; then
    # 凭证与管理命令 (仅在非一键更新时显示，一键更新密码不变，不用重新抓)
    echo -e "${YELLOW}>>> 初始凭证抓取:${NC}"
    journalctl -u $SERVICE_NAME --since "2 minutes ago" --no-pager | GREP_COLORS='mt=01;33' grep -E --color=always "API Key|管理员|账号|密码|User|Password"
    echo -e "${BLUE}-----------------------------------------${NC}"
fi

echo -e "${YELLOW}>>> 管理命令速查:${NC}"
echo -e "  ${GREEN}启动${NC}: systemctl start $SERVICE_NAME"
echo -e "  ${RED}停止${NC}: systemctl stop $SERVICE_NAME"
echo -e "  ${CYAN}重启${NC}: systemctl restart $SERVICE_NAME"
echo -e "  ${BLUE}日志${NC}: journalctl -u $SERVICE_NAME -f"
echo -e "${BLUE}=========================================${NC}"