#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu/Debian interactive VLESS + REALITY + TCP entry server.
# One entry server may use multiple independent WireGuard exits.

umask 077

readonly ROOT_DIR="/etc/xray-wireguard-exit"
readonly BASE_FILE="${ROOT_DIR}/inbounds-base.env"
readonly EXIT_DIR="${ROOT_DIR}/inbound-exits"
readonly USER_DIR="${ROOT_DIR}/vless-users"
readonly REMOVED_DIR="${ROOT_DIR}/removed"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly MANAGED_MARKER="${ROOT_DIR}/inbounds-v3.managed"

log() { printf '[inbounds] %s\n' "$*"; }
die() { printf '[inbounds] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo ./inbounds.sh

Commands:
  init        Initialize/reconfigure Xray
  add-exit    Add a WireGuard exit
  update-exit Select and update an existing WireGuard exit
  add-user    Add a VLESS user and select its exit
  update-user Select and update an existing VLESS user
  del-user    Remove a VLESS user
  del-exit    Remove an unused WireGuard exit
  list        Show WireGuard exits and VLESS connection links
  show-links  Show VLESS connection links
EOF
}

require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行"; }

check_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || die "仅支持 Ubuntu 和 Debian"
}

ask() {
  local prompt=$1 default=${2:-} value=""
  if [[ -n $default ]]; then
    read -r -p "${prompt} [${default}]: " value
  else
    read -r -p "${prompt}: " value
  fi
  printf '%s' "${value:-$default}"
}

yesno() {
  local prompt=$1 default=${2:-y} value
  if [[ $default == y ]]; then
    read -r -p "${prompt} [Y/n]: " value
    value=${value:-y}
  else
    read -r -p "${prompt} [y/N]: " value
    value=${value:-n}
  fi
  [[ ${value,,} == y || ${value,,} == yes ]]
}

select_existing_file() {
  local directory=$1 label=$2 choice i
  local files=()
  shopt -s nullglob
  files=("$directory"/*.env)
  shopt -u nullglob
  ((${#files[@]} > 0)) || die "没有可更新的${label}"
  printf '\n已有%s：\n' "$label"
  for ((i=0; i<${#files[@]}; i++)); do
    printf '%d) %s\n' "$((i + 1))" "$(basename "${files[$i]}" .env)"
  done
  read -r -p "请选择 [1-${#files[@]}]: " choice
  [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#files[@]})) || die "选择无效"
  SELECTED_FILE=${files[$((choice - 1))]}
}

valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,16}$ ]]; }
valid_key() { [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535)); }

install_packages() {
  check_os
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    wireguard-tools iproute2 iptables curl ca-certificates openssl jq
}

install_xray() {
  command -v xray >/dev/null 2>&1 && return
  local temp
  temp=$(mktemp -d)
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
    -o "${temp}/install.sh"
  bash "${temp}/install.sh" install
  rm -rf "$temp"
}

load_base() {
  [[ -r $BASE_FILE ]] || die "请先选择 '初始化入口机'"
  # shellcheck disable=SC1090
  source "$BASE_FILE"
  # Migrate configurations created by the earlier XHTTP version.
  REALITY_SPX=${REALITY_SPX:-${XHTTP_PATH:-}}
}

save_base() {
  mkdir -p "$ROOT_DIR"
  local temp
  temp=$(mktemp "${ROOT_DIR}/base.XXXXXX")
  {
    printf 'PUBLIC_HOST=%q\n' "$PUBLIC_HOST"
    printf 'XRAY_PORT=%q\n' "$XRAY_PORT"
    printf 'REALITY_SNI=%q\n' "$REALITY_SNI"
    printf 'REALITY_PRIVATE=%q\n' "$REALITY_PRIVATE"
    printf 'REALITY_PUBLIC=%q\n' "$REALITY_PUBLIC"
    printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
    printf 'REALITY_SPX=%q\n' "$REALITY_SPX"
  } >"$temp"
  chmod 600 "$temp"
  mv -f "$temp" "$BASE_FILE"
}

load_exit() {
  local file=$1
  EXIT_NAME="" EXIT_ID="" WG_ADDRESS="" WG_PORT="" PEER_PUBLIC_KEY=""
  # shellcheck disable=SC1090
  source "$file"
  WG_INTERFACE="wgx${EXIT_ID}"
  WG_MARK=$((1000 + EXIT_ID))
  WG_TABLE=$((20000 + EXIT_ID))
}

save_exit() {
  local file=$1 temp
  mkdir -p "$EXIT_DIR"
  temp=$(mktemp "${EXIT_DIR}/exit.XXXXXX")
  {
    printf 'EXIT_NAME=%q\n' "$EXIT_NAME"
    printf 'EXIT_ID=%q\n' "$EXIT_ID"
    printf 'WG_ADDRESS=%q\n' "$WG_ADDRESS"
    printf 'WG_PORT=%q\n' "$WG_PORT"
    printf 'PEER_PUBLIC_KEY=%q\n' "$PEER_PUBLIC_KEY"
  } >"$temp"
  chmod 600 "$temp"
  mv -f "$temp" "$file"
}

load_user() {
  local file=$1
  USER_NAME="" USER_LABEL="" USER_UUID="" USER_EXIT=""
  # shellcheck disable=SC1090
  source "$file"
  USER_LABEL=${USER_LABEL:-$USER_NAME}
}

save_user() {
  local file=$1 temp
  mkdir -p "$USER_DIR"
  temp=$(mktemp "${USER_DIR}/user.XXXXXX")
  {
    printf 'USER_NAME=%q\n' "$USER_NAME"
    printf 'USER_LABEL=%q\n' "$USER_LABEL"
    printf 'USER_UUID=%q\n' "$USER_UUID"
    printf 'USER_EXIT=%q\n' "$USER_EXIT"
  } >"$temp"
  chmod 600 "$temp"
  mv -f "$temp" "$file"
}

next_exit_id() {
  local id file used
  for ((id=1; id<=99; id++)); do
    used=0
    shopt -s nullglob
    for file in "$EXIT_DIR"/*.env; do
      load_exit "$file"
      [[ $EXIT_ID -eq $id ]] && used=1
    done
    shopt -u nullglob
    ((used == 0)) && { printf '%s' "$id"; return; }
  done
  die "WireGuard 出口数量已达到上限"
}

reality_keys() {
  local output
  output=$(xray x25519)
  REALITY_PRIVATE=$(printf '%s\n' "$output" | sed -nE \
    's/^(PrivateKey|Private key):[[:space:]]*//p' | head -n 1)
  REALITY_PUBLIC=$(printf '%s\n' "$output" | sed -nE \
    's/^(Password \(PublicKey\)|PublicKey|Public key):[[:space:]]*//p' | head -n 1)
  [[ -n $REALITY_PRIVATE && -n $REALITY_PUBLIC ]] || die "REALITY 密钥生成失败"
}

ensure_xray_service() {
  if ! id xray-wg-exit >/dev/null 2>&1; then
    useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin xray-wg-exit
  fi
  if ! systemctl cat xray.service >/dev/null 2>&1; then
    cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network-online.target

[Service]
ExecStart=$(command -v xray) run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  fi
  mkdir -p /etc/systemd/system/xray.service.d
  cat >/etc/systemd/system/xray.service.d/20-wg-exits.conf <<'EOF'
[Service]
User=xray-wg-exit
Group=xray-wg-exit
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
EOF
}

write_wg_config() {
  local exit_file=$1 private_file private_key peer="" config temp_dir temp_file
  load_exit "$exit_file"
  private_file="${EXIT_DIR}/${EXIT_NAME}.key"
  [[ -s $private_file ]] || { wg genkey >"$private_file"; chmod 600 "$private_file"; }
  private_key=$(<"$private_file")
  [[ -z $PEER_PUBLIC_KEY ]] || peer=$(cat <<EOF

[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0
EOF
)
  mkdir -p /etc/wireguard
  config="/etc/wireguard/${WG_INTERFACE}.conf"
  temp_dir=$(mktemp -d "/etc/wireguard/.${WG_INTERFACE}.XXXXXX")
  temp_file="${temp_dir}/${WG_INTERFACE}.conf"
  cat >"$temp_file" <<EOF
[Interface]
Address = ${WG_ADDRESS}
ListenPort = ${WG_PORT}
PrivateKey = ${private_key}
Table = off
FwMark = 0xca6c
PostUp = ip rule add fwmark ${WG_MARK}/0xffffffff table ${WG_TABLE} priority ${WG_MARK} 2>/dev/null || true
PostUp = ip route replace blackhole default table ${WG_TABLE} metric 32767
PostUp = ip route replace default dev %i src ${WG_ADDRESS%/*} table ${WG_TABLE} metric 10
PostUp = sysctl -qw net.ipv4.conf.%i.rp_filter=0
PostDown = ip route del default dev %i table ${WG_TABLE} 2>/dev/null || true
${peer}
EOF
  chmod 600 "$temp_file"
  wg-quick strip "$temp_file" >/dev/null
  mv -f "$temp_file" "$config"
  rmdir "$temp_dir"
  systemctl daemon-reload
  systemctl enable "wg-quick@${WG_INTERFACE}" >/dev/null
  if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"; then
    systemctl restart "wg-quick@${WG_INTERFACE}"
  else
    systemctl start "wg-quick@${WG_INTERFACE}"
  fi
}

compile_xray() {
  load_base
  local temp clients routes outbounds file exit_tag
  temp=$(mktemp -d)
  clients="${temp}/clients.jsonl"
  routes="${temp}/routes.jsonl"
  outbounds="${temp}/outbounds.jsonl"
  : >"$clients"; : >"$routes"; : >"$outbounds"

  jq -cn '{tag:"direct",protocol:"freedom",settings:{domainStrategy:"UseIPv4"}}' >>"$outbounds"
  jq -cn '{type:"field",ip:["geoip:private"],outboundTag:"block"}' >>"$routes"

  shopt -s nullglob
  for file in "$EXIT_DIR"/*.env; do
    load_exit "$file"
    exit_tag="exit-${EXIT_NAME}"
    jq -cn --arg tag "$exit_tag" --arg interface "$WG_INTERFACE" --argjson mark "$WG_MARK" \
      '{tag:$tag,protocol:"freedom",settings:{domainStrategy:"UseIPv4"},streamSettings:{sockopt:{mark:$mark,interface:$interface}}}' \
      >>"$outbounds"
  done
  jq -cn '{tag:"block",protocol:"blackhole",settings:{}}' >>"$outbounds"

  for file in "$USER_DIR"/*.env; do
    load_user "$file"
    jq -cn --arg id "$USER_UUID" --arg email "$USER_NAME" '{id:$id,email:$email}' >>"$clients"
    exit_tag=direct
    [[ $USER_EXIT == direct ]] || exit_tag="exit-${USER_EXIT}"
    jq -cn --arg email "$USER_NAME" --arg tag "$exit_tag" \
      '{type:"field",user:[$email],outboundTag:$tag}' >>"$routes"
  done
  shopt -u nullglob

  local clients_json routes_json outbounds_json new_config
  clients_json=$(jq -s '.' "$clients")
  routes_json=$(jq -s '.' "$routes")
  outbounds_json=$(jq -s '.' "$outbounds")
  new_config="${temp}/config.json"
  jq -n \
    --argjson clients "$clients_json" --argjson rules "$routes_json" \
    --argjson outbounds "$outbounds_json" --argjson port "$XRAY_PORT" \
    --arg sni "$REALITY_SNI" --arg target "${REALITY_SNI}:443" \
    --arg private "$REALITY_PRIVATE" --arg sid "$REALITY_SHORT_ID" '
    {
      log:{loglevel:"warning"},
      inbounds:[{
        tag:"vless-in",listen:"0.0.0.0",port:$port,protocol:"vless",
        settings:{clients:$clients,decryption:"none"},
        streamSettings:{network:"tcp",security:"reality",
          tcpSettings:{header:{type:"none"}},
          realitySettings:{show:false,target:$target,xver:0,serverNames:[$sni],privateKey:$private,
            shortIds:[$sid],minClientVer:"0.0.0"}}
      }],
      outbounds:$outbounds,
      routing:{domainStrategy:"IPIfNonMatch",rules:$rules}
    }' >"$new_config"
  xray run -test -config "$new_config" >/dev/null
  mkdir -p "$(dirname "$XRAY_CONFIG")"
  ensure_xray_service
  cp "$new_config" "$XRAY_CONFIG"
  chown root:xray-wg-exit "$XRAY_CONFIG"
  chmod 640 "$XRAY_CONFIG"
  rm -rf "$temp"
  systemctl daemon-reload
  systemctl enable xray >/dev/null
  systemctl restart xray
}

open_port() {
  local port=$1 protocol=$2
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow "${port}/${protocol}" >/dev/null
  fi
}

init_mode() {
  require_root
  local had_xray_config=0
  [[ -s $XRAY_CONFIG ]] && had_xray_config=1
  install_packages
  if [[ -r $BASE_FILE ]]; then
    load_base
  else
    PUBLIC_HOST="" XRAY_PORT=443 REALITY_SNI=www.microsoft.com
    REALITY_PRIVATE="" REALITY_PUBLIC="" REALITY_SHORT_ID="" REALITY_SPX=""
    if ((had_xray_config)) && [[ ! -f $MANAGED_MARKER ]]; then
      yesno "发现已有 Xray 配置，备份并覆盖吗？" n || return
      cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.bak-$(date +%Y%m%d%H%M%S)"
    fi
  fi
  install_xray
  PUBLIC_HOST=$(ask "入口机公网域名或 IPv4（不要带协议）" "$PUBLIC_HOST")
  [[ -n $PUBLIC_HOST && $PUBLIC_HOST != *://* && $PUBLIC_HOST != */* ]] || die "公网地址格式无效"
  XRAY_PORT=$(ask "VLESS 客户端端口" "$XRAY_PORT")
  valid_port "$XRAY_PORT" || die "端口无效"
  REALITY_SNI=$(ask "REALITY 伪装域名" "$REALITY_SNI")
  [[ -n $REALITY_SNI ]] || die "REALITY 伪装域名不能为空"
  [[ -n $REALITY_PRIVATE ]] || reality_keys
  REALITY_SHORT_ID=${REALITY_SHORT_ID:-$(openssl rand -hex 8)}
  REALITY_SPX=${REALITY_SPX:-/$(openssl rand -hex 8)}
  save_base
  touch "$MANAGED_MARKER"
  compile_xray
  open_port "$XRAY_PORT" tcp
  log "入口机初始化完成"
  if yesno "现在添加一个 VLESS 用户吗？" y; then
    add_user_mode
  fi
}

configure_exit_mode() {
  local file=$1 private_file public
  WG_ADDRESS=$(ask "本入口在该隧道的地址" "$WG_ADDRESS")
  WG_PORT=$(ask "本入口监听的 UDP 端口" "$WG_PORT")
  valid_port "$WG_PORT" || die "端口无效"
  PEER_PUBLIC_KEY=$(ask "出口机 WireGuard 公钥（尚未获得可直接回车）" "$PEER_PUBLIC_KEY")
  [[ -z $PEER_PUBLIC_KEY ]] || valid_key "$PEER_PUBLIC_KEY" || die "公钥格式无效"
  save_exit "$file"
  write_wg_config "$file"
  compile_xray
  # compile_xray iterates through every exit and changes the shared EXIT_*/WG_*
  # variables. Restore the exit being edited before opening its port and
  # printing its connection details.
  load_exit "$file"
  open_port "$WG_PORT" udp
  private_file="${EXIT_DIR}/${EXIT_NAME}.key"
  public=$(wg pubkey <"$private_file")
  cat <<EOF

出口 ${EXIT_NAME} 已保存：
  入口 WireGuard endpoint : ${PUBLIC_HOST}:${WG_PORT}
  入口 WireGuard 公钥     : ${public}
  入口隧道 IP             : ${WG_ADDRESS%/*}/32

在对应出口机运行 outbounds.sh，添加以上入口；取得出口机公钥后，
再次运行 '更新 WireGuard 出口'，选择 ${EXIT_NAME} 并粘贴公钥。
EOF
}

add_exit_mode() {
  require_root; load_base
  local name file third
  name=$(ask "新出口名称，例如 att 或 dmit" "")
  valid_name "$name" || die "名称只能包含字母、数字、_、-，最多16位"
  file="${EXIT_DIR}/${name}.env"
  [[ ! -e $file ]] || die "出口 ${name} 已存在，请使用‘更新 WireGuard 出口’"
  EXIT_NAME=$name
  EXIT_ID=$(next_exit_id)
  third=$((65 + EXIT_ID))
  WG_ADDRESS="10.66.${third}.1/24"
  WG_PORT=$((51819 + EXIT_ID))
  PEER_PUBLIC_KEY=""
  configure_exit_mode "$file"
}

update_exit_mode() {
  require_root; load_base
  select_existing_file "$EXIT_DIR" "WireGuard 出口"
  load_exit "$SELECTED_FILE"
  configure_exit_mode "$SELECTED_FILE"
}

list_exit_names() {
  local file
  printf 'direct（入口机直出）\n'
  shopt -s nullglob
  for file in "$EXIT_DIR"/*.env; do load_exit "$file"; printf '%s\n' "$EXIT_NAME"; done
  shopt -u nullglob
}

configure_user_mode() {
  local file=$1 selected
  USER_LABEL=$(ask "节点显示名称，例如 日本-加州-31741" "$USER_LABEL")
  [[ -n $USER_LABEL ]] || die "节点显示名称不能为空"
  printf '\n可选出口：\n'; list_exit_names
  selected=$(ask "该用户使用的出口" "$USER_EXIT")
  if [[ $selected != direct && ! -r ${EXIT_DIR}/${selected}.env ]]; then
    die "出口 ${selected} 不存在"
  fi
  USER_EXIT=$selected
  save_user "$file"
  compile_xray
  print_user_link "$file"
}

add_user_mode() {
  require_root; load_base
  local name file
  name=$(ask "新 VLESS 用户名称" "")
  valid_name "$name" || die "用户名格式无效"
  file="${USER_DIR}/${name}.env"
  [[ ! -e $file ]] || die "用户 ${name} 已存在，请使用‘更新 VLESS 用户’"
  USER_NAME=$name USER_LABEL=$name USER_UUID=$(xray uuid) USER_EXIT=direct
  configure_user_mode "$file"
}

update_user_mode() {
  require_root; load_base
  select_existing_file "$USER_DIR" "VLESS 用户"
  load_user "$SELECTED_FILE"
  configure_user_mode "$SELECTED_FILE"
}

print_user_link() {
  local file=$1 encoded_spx encoded_label
  load_base; load_user "$file"
  encoded_spx=$(jq -rn --arg value "$REALITY_SPX" '$value|@uri')
  encoded_label=$(jq -rn --arg value "$USER_LABEL" '$value|@uri')
  printf '\n名称：%s\n用户：%s\n出口：%s\nVLESS 连接：\n' \
    "$USER_LABEL" "$USER_NAME" "$USER_EXIT"
  printf 'vless://%s@%s:%s?encryption=none&fp=chrome&pbk=%s&security=reality&sid=%s&sni=%s&spx=%s&type=tcp#%s\n' \
    "$USER_UUID" "$PUBLIC_HOST" "$XRAY_PORT" "$REALITY_PUBLIC" \
    "$REALITY_SHORT_ID" "$REALITY_SNI" "$encoded_spx" "$encoded_label"
}

show_links_mode() {
  require_root; load_base
  local file found=0
  printf '\n=== VLESS 连接 ===\n'
  shopt -s nullglob
  for file in "$USER_DIR"/*.env; do
    print_user_link "$file"
    found=1
  done
  shopt -u nullglob
  ((found == 1)) || printf '尚未创建 VLESS 用户。\n'
}

delete_user_mode() {
  require_root; load_base
  local name file destination
  name=$(ask "要删除的 VLESS 用户" "")
  file="${USER_DIR}/${name}.env"; [[ -r $file ]] || die "用户不存在"
  yesno "确认删除 ${name}？" n || return
  mkdir -p "$REMOVED_DIR"
  destination="${REMOVED_DIR}/user-${name}-$(date +%Y%m%d%H%M%S).env"
  mv "$file" "$destination"
  compile_xray
}

delete_exit_mode() {
  require_root; load_base
  local name file user_file destination interface id mark table
  name=$(ask "要删除的 WireGuard 出口" "")
  file="${EXIT_DIR}/${name}.env"; [[ -r $file ]] || die "出口不存在"
  shopt -s nullglob
  for user_file in "$USER_DIR"/*.env; do
    load_user "$user_file"
    [[ $USER_EXIT != "$name" ]] || die "仍有用户 ${USER_NAME} 使用该出口，请先修改用户出口"
  done
  shopt -u nullglob
  load_exit "$file"; interface=$WG_INTERFACE; id=$EXIT_ID; mark=$WG_MARK; table=$WG_TABLE
  yesno "确认删除出口 ${name}？" n || return
  systemctl disable --now "wg-quick@${interface}" 2>/dev/null || true
  while ip rule del fwmark "${mark}/0xffffffff" table "$table" priority "$mark" 2>/dev/null; do :; done
  ip route flush table "$table" 2>/dev/null || true
  mkdir -p "$REMOVED_DIR"
  destination="${REMOVED_DIR}/exit-${name}-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$destination"
  mv "$file" "$destination/"
  [[ ! -e ${EXIT_DIR}/${name}.key ]] || mv "${EXIT_DIR}/${name}.key" "$destination/"
  [[ ! -e /etc/wireguard/wgx${id}.conf ]] || mv "/etc/wireguard/wgx${id}.conf" "$destination/"
  compile_xray
}

list_mode() {
  require_root; load_base
  local file
  printf '\n=== WireGuard 出口 ===\n'
  shopt -s nullglob
  for file in "$EXIT_DIR"/*.env; do
    load_exit "$file"
    printf '%-16s interface=%-6s address=%-18s peer=%s\n' \
      "$EXIT_NAME" "$WG_INTERFACE" "$WG_ADDRESS" "$([[ -n $PEER_PUBLIC_KEY ]] && echo yes || echo no)"
    wg show "$WG_INTERFACE" latest-handshakes 2>/dev/null || true
  done
  printf '\n=== VLESS 用户 ===\n'
  for file in "$USER_DIR"/*.env; do print_user_link "$file"; done
  shopt -u nullglob
}

menu() {
  require_root; [[ -t 0 ]] || die "需要交互式终端"
  while true; do
    cat <<'EOF'

=== 入口机菜单 ===
1) 初始化入口机
2) 添加 WireGuard 出口
3) 更新 WireGuard 出口
4) 添加 VLESS 用户并选择出口
5) 更新 VLESS 用户
6) 删除 VLESS 用户
7) 删除 WireGuard 出口
8) 查看 WireGuard 出口和 VLESS 连接
9) 仅显示 VLESS 连接
0) 退出
EOF
    read -r -p "请选择 [0-9]: " choice
    case $choice in
      1) init_mode;; 2) add_exit_mode;; 3) update_exit_mode;;
      4) add_user_mode;; 5) update_user_mode;; 6) delete_user_mode;;
      7) delete_exit_mode;; 8) list_mode;; 9) show_links_mode;;
      0) return;; *) printf '无效选项。\n';;
    esac
  done
}

case ${1:-menu} in
  menu) menu;; init) init_mode;; add-exit) add_exit_mode;; update-exit) update_exit_mode;;
  add-user) add_user_mode;; update-user) update_user_mode;;
  del-user) delete_user_mode;; del-exit) delete_exit_mode;; list|status) list_mode;;
  show-links) show_links_mode;;
  -h|--help|help) usage;; *) usage >&2; exit 2;;
esac
