#!/bin/bash
# ============================================
#  Oracle Cloud / Debian - SSH 安全配置脚本
#  功能：改端口 / 禁密码登录 / 允许root密钥登录 / 重新生成密钥
#  用法：
#    交互模式：bash orcalesafe.sh
#    参数模式：bash orcalesafe.sh -p 1022 -r yes
#    一键模式：curl -fsSL https://raw.githubusercontent.com/zhenzhenjunzilu/orcalesafe/main/orcalesafe.sh | bash -s -- -p 1022 -r yes
# ============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── 必须 root 执行 ──────────────────────────
if [ "$EUID" -ne 0 ]; then
  error "请用 root 执行：sudo bash $0  或  su - root 后再执行"
fi

# ── 检测普通用户（ubuntu 或第一个非 root 用户）──
NORMAL_USER=""
if id "ubuntu" &>/dev/null; then
  NORMAL_USER="ubuntu"
else
  # 找 /home 下第一个有目录的普通用户
  NORMAL_USER=$(ls /home 2>/dev/null | head -1)
fi
if [ -n "$NORMAL_USER" ]; then
  info "检测到普通用户：$NORMAL_USER"
else
  warn "未检测到普通用户，密钥仅部署到 root"
fi

# ── 解析参数 ────────────────────────────────
TARGET_PORT=""
ROOT_CHOICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)
      TARGET_PORT="$2"
      shift 2
      ;;
    -r|--root)
      ROOT_CHOICE="$2"
      shift 2
      ;;
    -h|--help)
      echo "用法: bash orcalesafe.sh [-p 端口] [-r yes/no]"
      echo "  -p, --port   SSH 端口（默认 1022）"
      echo "  -r, --root   是否允许 root 密钥登录 yes/no（默认 yes）"
      echo ""
      echo "示例："
      echo "  bash orcalesafe.sh -p 1022 -r yes"
      echo "  curl -fsSL https://raw.githubusercontent.com/zhenzhenjunzilu/orcalesafe/main/orcalesafe.sh | bash -s -- -p 1022 -r yes"
      exit 0
      ;;
    *)
      error "未知参数：$1，使用 -h 查看帮助"
      ;;
  esac
done

echo ""
echo "============================================"
echo "   Oracle Cloud SSH 安全配置脚本"
echo "============================================"
echo ""

# ── 1. 是否重新生成密钥对 ────────────────────
echo "是否需要重新生成 SSH 密钥对？"
echo "  1) 否（已有密钥，跳过）"
echo "  2) 是（私钥丢失或需要更换）"
read -p "请选择 [1/2]（默认 1）: " KEY_INPUT </dev/tty
KEY_INPUT=${KEY_INPUT:-1}
echo ""

if [ "$KEY_INPUT" = "2" ]; then
  info "开始生成新的 SSH 密钥对..."
  KEY_NAME="oracle_key_$(date +%Y%m%d%H%M%S)"
  TMP_DIR="/tmp/$KEY_NAME"
  mkdir -p "$TMP_DIR"

  # 生成密钥
  ssh-keygen -t rsa -b 4096 -f "$TMP_DIR/$KEY_NAME" -N "" -C "$KEY_NAME" &>/dev/null
  success "密钥生成完毕：$KEY_NAME"

  # 部署公钥到 root
  mkdir -p /root/.ssh
  cp "$TMP_DIR/${KEY_NAME}.pub" /root/.ssh/authorized_keys
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys
  success "公钥已部署到 root"

  # 部署公钥到普通用户（如果存在）
  if [ -n "$NORMAL_USER" ]; then
    NORMAL_HOME=$(eval echo "~$NORMAL_USER")
    mkdir -p "$NORMAL_HOME/.ssh"
    cp "$TMP_DIR/${KEY_NAME}.pub" "$NORMAL_HOME/.ssh/authorized_keys"
    chmod 700 "$NORMAL_HOME/.ssh"
    chmod 600 "$NORMAL_HOME/.ssh/authorized_keys"
    chown -R "$NORMAL_USER:$NORMAL_USER" "$NORMAL_HOME/.ssh"
    success "公钥已部署到 $NORMAL_USER"
  fi

  # 保存私钥到 root 目录
  cp "$TMP_DIR/$KEY_NAME" "/root/${KEY_NAME}.pem"
  chmod 600 "/root/${KEY_NAME}.pem"
  success "私钥已保存到 /root/${KEY_NAME}.pem"

  # 保存私钥到普通用户目录（如果存在）
  if [ -n "$NORMAL_USER" ]; then
    NORMAL_HOME=$(eval echo "~$NORMAL_USER")
    cp "$TMP_DIR/$KEY_NAME" "$NORMAL_HOME/${KEY_NAME}.pem"
    chmod 600 "$NORMAL_HOME/${KEY_NAME}.pem"
    chown "$NORMAL_USER:$NORMAL_USER" "$NORMAL_HOME/${KEY_NAME}.pem"
    success "私钥已保存到 $NORMAL_HOME/${KEY_NAME}.pem"
  fi

  # 打印私钥内容
  echo ""
  echo -e "${CYAN}============================================${NC}"
  echo -e "${CYAN}  ⬇️  请立即复制并保存以下私钥内容！${NC}"
  echo -e "${CYAN}============================================${NC}"
  cat "$TMP_DIR/$KEY_NAME"
  echo -e "${CYAN}============================================${NC}"
  echo -e "${YELLOW}私钥文件位置（可用 scp 下载）：${NC}"
  echo "  /root/${KEY_NAME}.pem"
  [ -n "$NORMAL_USER" ] && echo "  $(eval echo ~$NORMAL_USER)/${KEY_NAME}.pem"
  echo ""
  echo -e "${YELLOW}下载命令（在本地终端执行）：${NC}"
  echo "  scp -P 22 root@你的IP:/root/${KEY_NAME}.pem ./"
  echo -e "${CYAN}============================================${NC}"
  echo ""

  # 清理临时目录
  rm -rf "$TMP_DIR"

  # 标记已处理 root 密钥，后续跳过
  ROOT_CHOICE="skip"
fi

# ── 2. 确定 SSH 端口 ────────────────────────
if [ -z "$TARGET_PORT" ]; then
  read -p "请输入新的 SSH 端口（直接回车默认 1022）: " INPUT_PORT </dev/tty
  TARGET_PORT=${INPUT_PORT:-1022}
else
  info "使用参数端口：$TARGET_PORT"
fi

if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] || [ "$TARGET_PORT" -lt 1 ] || [ "$TARGET_PORT" -gt 65535 ]; then
  error "端口号无效：$TARGET_PORT"
fi
info "SSH 端口将设置为：$TARGET_PORT"
echo ""

# ── 3. 确定是否允许 root 密钥登录 ───────────
if [ "$ROOT_CHOICE" = "skip" ]; then
  info "密钥已在上一步部署到 root，跳过此步"
elif [ -z "$ROOT_CHOICE" ]; then
  echo "是否将 ${NORMAL_USER:-普通用户} 的公钥复制给 root（允许 root 密钥登录）？"
  echo "  1) 是（推荐，和 ${NORMAL_USER:-普通用户} 用同一把密钥）"
  echo "  2) 否"
  read -p "请选择 [1/2]（默认 1）: " ROOT_INPUT </dev/tty
  ROOT_INPUT=${ROOT_INPUT:-1}
  [ "$ROOT_INPUT" = "2" ] && ROOT_CHOICE="no" || ROOT_CHOICE="yes"
else
  info "root 密钥登录：$ROOT_CHOICE"
fi
echo ""

# ── 4. 检测当前 SSH 端口 ─────────────────────
OLD_PORT=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -1)
OLD_PORT=${OLD_PORT:-22}
info "当前 SSH 端口：$OLD_PORT"

# ── 5. 备份 ─────────────────────────────────
info "备份原始配置文件..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
success "已备份 → /etc/ssh/sshd_config.bak"

DROPIN_DIR="/etc/ssh/sshd_config.d"
TARGET_CONF=""

# ── 6. 检测 drop-in 配置文件 ────────────────
info "检测 drop-in 配置目录..."
if [ -d "$DROPIN_DIR" ] && ls "$DROPIN_DIR"/*.conf &>/dev/null; then
  HIGHEST_CONF=$(ls "$DROPIN_DIR"/*.conf 2>/dev/null | sort -V | tail -1)
  ALL_CONFS=$(ls "$DROPIN_DIR"/*.conf 2>/dev/null)
  CONF_COUNT=$(ls "$DROPIN_DIR"/*.conf 2>/dev/null | wc -l)

  info "发现 $CONF_COUNT 个 drop-in 文件："
  for f in $ALL_CONFS; do echo "    $f"; done

  if [ "$CONF_COUNT" -gt 1 ]; then
    warn "存在多个配置文件，将删除低优先级文件，只保留 $HIGHEST_CONF"
    for f in $ALL_CONFS; do
      if [ "$f" != "$HIGHEST_CONF" ]; then
        cp "$f" "${f}.bak"
        rm "$f"
        info "已删除并备份：$f"
      fi
    done
  fi

  TARGET_CONF="$HIGHEST_CONF"
  cp "$TARGET_CONF" "${TARGET_CONF}.bak"
  success "使用 drop-in 文件：$TARGET_CONF"
else
  info "未发现 drop-in 配置，将直接修改主配置文件"
  TARGET_CONF="/etc/ssh/sshd_config"
fi

# ── 7. 写入新配置 ────────────────────────────
info "写入新配置到 $TARGET_CONF ..."
cat > "$TARGET_CONF" << CONF
Port $TARGET_PORT
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM yes
CONF
success "配置已写入"

# ── 8. 注释主配置文件中所有 Port 行 ──────────
info "检查主配置文件中的 Port 配置..."
if grep -qE "^Port " /etc/ssh/sshd_config; then
  sed -i 's/^Port /#Port /' /etc/ssh/sshd_config
  success "已注释主配置文件中的 Port 行"
else
  info "主配置文件中无 Port 行，跳过"
fi

# ── 9. root 密钥配置 ─────────────────────────
if [ "$ROOT_CHOICE" = "yes" ] && [ -n "$NORMAL_USER" ]; then
  info "配置 root 密钥登录..."
  NORMAL_HOME=$(eval echo "~$NORMAL_USER")
  NORMAL_KEYS="$NORMAL_HOME/.ssh/authorized_keys"
  if [ ! -f "$NORMAL_KEYS" ]; then
    error "找不到 ${NORMAL_USER} 的公钥文件：$NORMAL_KEYS"
  fi
  mkdir -p /root/.ssh
  cp "$NORMAL_KEYS" /root/.ssh/authorized_keys
  chmod 700 /root/.ssh
  chmod 600 /root/.ssh/authorized_keys
  success "已将 ${NORMAL_USER} 公钥复制到 root"
elif [ "$ROOT_CHOICE" = "no" ]; then
  info "跳过 root 密钥配置"
fi

# ── 10. 语法检查 ─────────────────────────────
echo ""
info "检查 SSH 配置语法..."
if sshd -t; then
  success "语法检查通过"
else
  error "配置有误！请检查后手动修复，备份文件在 *.bak"
fi

# ── 11. 防火墙同时放行新旧端口（保险）────────
echo ""
info "防火墙放行新端口 $TARGET_PORT 和旧端口 $OLD_PORT（保险）..."
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow "$TARGET_PORT/tcp"
  success "UFW 已放行新端口 $TARGET_PORT"
elif command -v iptables &>/dev/null; then
  iptables -I INPUT -p tcp --dport "$TARGET_PORT" -j ACCEPT
  iptables -I INPUT -p tcp --dport "$OLD_PORT" -j ACCEPT
  if command -v netfilter-persistent &>/dev/null; then
    netfilter-persistent save
    success "iptables 已放行并持久化端口 $OLD_PORT 和 $TARGET_PORT"
  else
    warn "iptables 已放行，但 netfilter-persistent 未安装，重启后可能失效"
    warn "建议执行：apt install -y iptables-persistent"
  fi
else
  warn "未检测到防火墙工具，请手动放行端口 $TARGET_PORT"
fi

# ── 12. 重启 sshd ────────────────────────────
echo ""
info "重启 sshd 服务..."
systemctl restart sshd
success "sshd 已重启，新端口 $TARGET_PORT 已生效"

# ── 13. 输出最终生效配置 ─────────────────────
echo ""
info "最终生效配置："
sshd -T | grep -E "^port|passwordauth|pubkeyauth|permitroot"

# ── 完成提示 ─────────────────────────────────
echo ""
echo "============================================"
echo -e "${GREEN}✅ 配置完成！sshd 已重启！${NC}"
echo "============================================"
echo -e "${YELLOW}⚠️  请按以下顺序操作：${NC}"
echo ""
echo "   【第一步】登录 Oracle 控制台放行新端口"
echo "      网络 → VCN → 子网 → 安全列表"
echo "      添加入站规则：TCP 端口 $TARGET_PORT"
echo ""
echo "   【第二步】新开终端测试新端口（不要关闭当前会话！）"
if [ "$ROOT_CHOICE" = "yes" ] || [ "$ROOT_CHOICE" = "skip" ]; then
echo "      ssh -i 你的私钥 -p $TARGET_PORT root@你的IP"
fi
[ -n "$NORMAL_USER" ] && echo "      ssh -i 你的私钥 -p $TARGET_PORT ${NORMAL_USER}@你的IP"
echo ""
echo "   【第三步】确认新端口登录成功后，关闭旧端口 $OLD_PORT"
echo "      Oracle 控制台安全列表删除端口 $OLD_PORT 的入站规则"
echo "      然后执行以下命令关闭系统防火墙旧端口："
echo ""
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
echo "      sudo ufw delete allow $OLD_PORT/tcp"
else
echo "      iptables -D INPUT -p tcp --dport $OLD_PORT -j ACCEPT && netfilter-persistent save"
fi
echo ""
echo "   ⚡ 旧端口 $OLD_PORT 暂时保留，新端口 $TARGET_PORT 已生效"
echo "      测试成功再关旧端口，不会锁门！"
echo "============================================"
