#!/bin/bash
#
# 🚀 MTProto Proxy Manager v2.3 (HYBRID)
# Гибрид: gotelegram UI + v2.2 backend + новые фичи
# Фичи: QR-коды, 25+ доменов, BBR, каскад, веб-панель, статистика
#

set -e

# ==================== КОНФИГУРАЦИЯ ====================
readonly SCRIPT_VERSION="2.3"
readonly CONFIG_FILE="/etc/mtproto.conf"
readonly BASHRC_PROXY="$HOME/.bashrc_proxy"
readonly DOCKER_IMAGE="telegrammessenger/proxy:latest"
readonly SERVER_IP="${PROXY_IP:-$(curl -s https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')}"
readonly CASCADE_CONFIG="/etc/mtproto-cascade.conf"
readonly LOG_FILE="/var/log/mtproto-manager.log"

# Цвета
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# Глобальные переменные
declare -A PROXIES          # [port]="domain:secret"
declare -A CASCADE_RULES    # [local_port]="target_ip:target_port:proto"

# ==================== ЛОГИРОВАНИЕ ====================
log_info()    { echo -e "${BLUE}[ℹ️]${NC} $1" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[✅]${NC} $1" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[⚠️]${NC} $1" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[❌]${NC} $1" | tee -a "$LOG_FILE"; }
log_header()  { 
    echo -e "\n${GREEN}╔════════════════════════════════════╗${NC}" | tee -a "$LOG_FILE"
    echo -e "${GREEN}║${NC} $1 ${GREEN}║${NC}" | tee -a "$LOG_FILE"
    echo -e "${GREEN}╚════════════════════════════════════╝${NC}\n" | tee -a "$LOG_FILE"
}
log_divider() { echo -e "${CYAN}────────────────────────────────────────${NC}"; }

# ==================== СИСТЕМНЫЕ НАСТРОЙКИ ====================

# 🔥 НОВОЕ: Проверка и установка qrencode
check_qrencode() {
    if ! command -v qrencode &>/dev/null; then
        log_info "Установка qrencode для QR-кодов..."
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y qrencode >/dev/null 2>&1 || yum install -y qrencode >/dev/null 2>&1 || true
        if command -v qrencode &>/dev/null; then
            log_success "qrencode установлен ✅"
        else
            log_warn "qrencode не установлен, QR-коды будут недоступны ⚠️"
        fi
    fi
}

# 1. Активация BBR
enable_bbr() {
    log_info "Настройка TCP BBR (ускорение сети)..."
    
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
        log_success "BBR уже активирован"
        return 0
    fi
    
    local bbr_settings=("net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr")
    for setting in "${bbr_settings[@]}"; do
        if ! grep -q "^${setting}$" /etc/sysctl.conf 2>/dev/null; then
            echo "$setting" >> /etc/sysctl.conf
        fi
    done
    sysctl -p >/dev/null 2>&1 || true
    
    if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]]; then
        log_success "BBR успешно активирован 🚀"
    else
        log_warn "BBR не активирован (ядро может не поддерживать)"
    fi
}

# 2. Включение IP Forwarding
enable_ip_forwarding() {
    log_info "Настройка IP Forwarding..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
    if ! grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf 2>/dev/null; then
        echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
    fi
    log_success "IP Forwarding включен ✅"
}

# 3. Оптимизация сетевых параметров
optimize_network() {
    log_info "Оптимизация сетевых параметров..."
    local net_settings=(
        "net.ipv4.tcp_fastopen=3" "net.ipv4.tcp_slow_start_after_idle=0"
        "net.ipv4.tcp_mtu_probing=1" "net.ipv4.tcp_sack=1" "net.ipv4.tcp_dsack=1"
        "net.ipv4.tcp_window_scaling=1" "net.ipv4.tcp_timestamps=1"
        "net.ipv4.tcp_rmem=4096 87380 67108864" "net.ipv4.tcp_wmem=4096 65536 67108864"
        "net.core.rmem_max=67108864" "net.core.wmem_max=67108864" "net.core.netdev_max_backlog=5000"
    )
    for setting in "${net_settings[@]}"; do
        local key="${setting%%=*}"
        if ! grep -q "^${key}=" /etc/sysctl.conf 2>/dev/null; then
            echo "$setting" >> /etc/sysctl.conf
        fi
    done
    sysctl -p >/dev/null 2>&1 || true
    log_success "Сетевые параметры оптимизированы"
}

# 4. Проверка зависимостей
check_dependencies() {
    log_info "Проверка зависимостей..."
    local deps=("curl" "openssl" "iptables" "grep" "awk" "sed" "qrencode")
    local missing=()
    for dep in "${deps[@]}"; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "Установка: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y "${missing[@]}" >/dev/null 2>&1 || true
    fi
    log_success "Все зависимости установлены"
}

# ==================== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ====================
check_root() {
    [ "$EUID" -ne 0 ] && { log_error "Запустите от root: sudo $0"; exit 1; }
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        log_info "Установка Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
        systemctl enable --now docker >/dev/null 2>&1 || true
        log_success "Docker установлен"
    fi
}

check_ufw() {
    if command -v ufw &>/dev/null; then
        ufw status &>/dev/null | grep -q "Status: active" || ufw --force enable >/dev/null 2>&1 || true
    fi
}

get_secret() {
    local container="$1"
    docker inspect "$container" --format='{{range .Config.Env}}{{if hasPrefix . "SECRET="}}{{trimPrefix "SECRET=" .}}{{end}}{{end}}' 2>/dev/null | head -1 || \
    docker inspect "$container" 2>/dev/null | grep -oE "SECRET=[0-9a-f]+" | head -1 | cut -d= -f2
}

get_domain() {
    local container="$1"
    docker inspect "$container" --format='{{range .Config.Env}}{{if hasPrefix . "FAKE_TLS_DOMAIN="}}{{trimPrefix "FAKE_TLS_DOMAIN=" .}}{{end}}{{end}}' 2>/dev/null | head -1
}

is_running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^$1$"; }

generate_secret() { openssl rand -hex 16; }

open_firewall_port() {
    local port="$1" comment="${2:-Telegram Proxy}"
    if command -v ufw &>/dev/null; then
        ufw allow "$port"/tcp comment "$comment" >/dev/null 2>&1 || ufw allow "$port"/tcp >/dev/null 2>&1 || true
        log_info "Порт $port открыт в фаерволе"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --add-port="$port"/tcp --permanent >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_info "Порт $port открыт в firewalld"
    fi
}

close_firewall_port() {
    local port="$1"
    command -v ufw &>/dev/null && ufw delete allow "$port"/tcp >/dev/null 2>&1 && log_info "Порт $port закрыт"
}

get_container_name() { [[ "$1" == "443" ]] && echo "mtproto" || echo "mtproto-$1"; }

# 🔥 НОВОЕ: Генерация и отображение QR-кода
show_qr_code() {
    local link="$1"
    if command -v qrencode &>/dev/null; then
        echo ""; log_header "📱 QR-код для подключения"
        qrencode -t ANSIUTF8 "$link"
        echo ""
    else
        log_warn "qrencode не установлен, показываю ссылку:"
        echo -e "${BLUE}$link${NC}"
    fi
}

# ==================== СКАНИРОВАНИЕ ====================
scan_existing_proxies() {
    log_info "Сканирование прокси..."
    PROXIES=()
    local found=0
    for container in $(docker ps --format '{{.Names}}' 2>/dev/null | grep "^mtproto"); do
        local port=""; [[ "$container" == "mtproto" ]] && port="443"
        [[ "$container" =~ ^mtproto-([0-9]+)$ ]] && port="${BASH_REMATCH[1]}"
        if [ -n "$port" ]; then
            local secret=$(get_secret "$container") domain=$(get_domain "$container")
            [ -n "$secret" ] && { PROXIES["$port"]="${domain:-unknown}:${secret}"; ((found++)); }
        fi
    done
    [ "$found" -eq 0 ] && [ -f "$CONFIG_FILE" ] && while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        [[ "$key" == "port_"* ]] && PROXIES["${key#port_}"]="$value"
    done < "$CONFIG_FILE"
    echo "$found"
}

show_proxy_list() {
    clear
    log_header "📋 Настроенные прокси"
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "Прокси не найдены"; return 1; }
    log_divider
    printf "${CYAN}%-8s %-20s %-35s %s${NC}\n" "ПОРТ" "ДОМЕН" "СЕКРЕТ" "СТАТУС"
    log_divider
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local value="${PROXIES[$port]}" domain="${value%%:*}" secret="${value#*:}"
        local container=$(get_container_name "$port")
        local status=$(is_running "$container" && echo "🟢 UP" || echo "🔴 DOWN")
        printf "%-8s %-20s %-35s %s\n" "$port" "$domain" "${secret:0:32}..." "$status"
    done
    log_divider
}

# ==================== ДОБАВЛЕНИЕ ПРОКСИ (ОБНОВЛЕНО) ====================
add_proxy() {
    clear
    log_header "➕ Добавление нового прокси"
    
    # 🔥 НОВОЕ: Большой список доменов (25+ вариантов как в gotelegram)
    local domains=(
        "google.com" "wikipedia.org" "habr.com" "github.com" "coursera.org" "udemy.com"
        "medium.com" "stackoverflow.com" "bbc.com" "cnn.com" "reuters.com" "nytimes.com"
        "lenta.ru" "rbc.ru" "ria.ru" "kommersant.ru" "stepik.org" "duolingo.com"
        "khanacademy.org" "ted.com" "1c.ru" "vk.com" "yandex.ru" "mail.ru" "ok.ru"
    )
    
    # Ввод порта с валидацией
    local port=""
    while [ -z "$port" ]; do
        echo -n "Введите порт (1024-65535): "
        read -r port
        [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1024 || "$port" -gt 65535 ]] && { log_error "Неверно"; port=""; continue; }
        [ -n "${PROXIES[$port]}" ] && { log_warn "Занят"; port=""; }
    done
    
    # 🔥 НОВОЕ: Красивый выбор домена (2 колонки)
    echo ""; echo -e "${CYAN}=== Выберите домен для маскировки (Fake TLS) ===${NC}"
    for i in "${!domains[@]}"; do
        printf "${YELLOW}%2d)${NC} %-22s " "$((i+1))" "${domains[$i]}"
        [[ $(( (i+1) % 2 )) -eq 0 ]] && echo ""
    done
    echo ""
    
    local domain=""
    while [ -z "$domain" ]; do
        echo -n "Ваш выбор [1-${#domains[@]}]: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#domains[@]}" ]; then
            domain="${domains[$((choice-1))]}"
        elif [[ "$choice" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            domain="$choice"
        else
            log_error "Введите номер или домен"; continue
        fi
    done
    
    local secret=$(generate_secret)
    log_info "Сгенерирован секрет: $secret"
    
    echo ""; echo -e "${YELLOW}Параметры:${NC}"
    echo "  Порт: $port  Домен: $domain  Секрет: $secret  IP: $SERVER_IP"
    echo -n "Запустить? [Y/n]: "; read -r confirm
    [[ "$confirm" =~ ^[Nn]$ ]] && return 0
    
    local container=$(get_container_name "$port")
    log_info "Запуск $container..."
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 \
        -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2
    
    if is_running "$container"; then
        log_success "✅ Прокси запущен"
        open_firewall_port "$port" "Telegram Proxy - $domain"
        PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions
        local link="tg://proxy?server=$SERVER_IP&port=$port&secret=$secret"
        echo ""; log_header "🔗 Новая ссылка"
        printf "${BLUE}%s${NC}\n" "$link"
        show_qr_code "$link"  # 🔥 QR-код!
        log_success "🎉 Готово!"
        echo -n "Нажмите Enter..."; read -r
    else
        log_error "❌ Ошибка запуска"; return 1
    fi
}

# ==================== УДАЛЕНИЕ ПРОКСИ (ИСПРАВЛЕНО) ====================
remove_proxy() {
    clear; log_header "🗑️ Удаление прокси"
    show_proxy_list || return 0
    local port_to_remove=""; echo -n "Порт: "; read -r port_to_remove
    [ -z "${PROXIES[$port_to_remove]}" ] && { log_error "Не найден"; return 1; }
    echo -n "Удалить $port_to_remove? [y/N]: "; read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    local container=$(get_container_name "$port_to_remove")
    is_running "$container" && { docker stop "$container" >/dev/null; docker rm "$container" >/dev/null; }
    local deleted_port="$port_to_remove"  # 🔥 КРИТИЧНО: сохраняем до вызова функций!
    unset "PROXIES[$port_to_remove]"; save_config; regenerate_functions
    echo -n "Закрыть порт $deleted_port в фаерволе? [y/N]: "; read -r fw
    [[ "$fw" =~ ^[Yy]$ ]] && close_firewall_port "$deleted_port"
    log_success "Порт $deleted_port удалён"; echo -n "Enter..."; read -r
}

# ==================== ОБНОВЛЕНИЕ ДОМЕНА ====================
update_domain() {
    clear; log_header "🔄 Обновление домена"
    show_proxy_list || return 0
    local port=""; echo -n "Порт: "; read -r port
    [ -z "${PROXIES[$port]}" ] && { log_error "Не найден"; return 1; }
    local secret="${PROXIES[$port]#*:}"
    local domains=("1c.ru" "vk.com" "yandex.ru" "mail.ru" "ok.ru" "google.com" "github.com" "wikipedia.org")
    echo ""; echo -e "${CYAN}=== Новый домен ===${NC}"
    for i in "${!domains[@]}"; do printf "${YELLOW}%d)${NC} %-15s " "$((i+1))" "${domains[$i]}"; [[ $(( (i+1) % 4 )) -eq 0 ]] && echo ""; done
    echo ""; local domain=""
    while [ -z "$domain" ]; do
        echo -n "Ваш выбор: "; read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#domains[@]}" ]; then
            domain="${domains[$((choice-1))]}"
        elif [[ "$choice" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            domain="$choice"
        else log_error "Неверно"; fi
    done
    echo -n "Обновить? [y/N]: "; read -r confirm; [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 \
        -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2; is_running "$container" && { PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions; log_success "Обновлено"; } || log_error "Ошибка"
    echo -n "Enter..."; read -r
}

# ==================== ГЕНЕРАЦИЯ ФУНКЦИЙ ====================
regenerate_functions() {
    log_info "Генерация функций..."
    cat > "$BASHRC_PROXY" << EOF
#!/bin/bash
PROXY_IP="$SERVER_IP"
EOF
    for port in "${!PROXIES[@]}"; do
        local container=$(get_container_name "$port")
        cat >> "$BASHRC_PROXY" << EOF
link${port}(){ local s=\$(docker inspect $container --format='{{range .Config.Env}}{{if hasPrefix . "SECRET="}}{{trimPrefix "SECRET=" .}}{{end}}{{end}}' 2>/dev/null); [ -n "\$s" ] && printf "tg://proxy?server=%s&port=${port}&secret=%s\n" "\$PROXY_IP" "\$s" || echo "[ERR] ${port}"; }
EOF
    done
    cat >> "$BASHRC_PROXY" << 'EOF'
links(){ echo ""; echo "=== MTProto Links ==="; echo "Server: $PROXY_IP"; echo "";
EOF
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        echo "    printf \"%s: \" \"$port\"; link${port}; echo \"\"" >> "$BASHRC_PROXY"
    done
    cat >> "$BASHRC_PROXY" << 'EOF'
echo ""; }
alias proxy-status='docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep mtproto'
EOF
    for port in "${!PROXIES[@]}"; do
        local container=$(get_container_name "$port")
        echo "alias proxy-logs${port}='docker logs --tail 30 $container 2>/dev/null'" >> "$BASHRC_PROXY"
    done
    grep -q "bashrc_proxy" ~/.bashrc 2>/dev/null || echo -e "\n# MTProto\nsource $BASHRC_PROXY" >> ~/.bashrc
    source "$BASHRC_PROXY" 2>/dev/null || true
    log_success "Функции обновлены"
}

save_config() {
    mkdir -p "$(dirname "$CONFIG_FILE")"
    { echo "# MTProto Config"; echo "server_ip=$SERVER_IP"; for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do echo "port_${port}=${PROXIES[$port]}"; done; } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

show_all_links() {
    clear; log_header "🔗 Ссылки"
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "Нет прокси"; return 1; }
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local value="${PROXIES[$port]}" domain="${value%%:*}" secret="${value#*:}"
        local container=$(get_container_name "$port")
        local status=$(is_running "$container" && echo " 🟢" || echo " 🔴")
        echo -e "${CYAN}Порт $port${NC} ($domain)$status"
        printf "   tg://proxy?server=%s&port=%s&secret=%s\n\n" "$SERVER_IP" "$port" "$secret"
    done
    { echo "# MTProto Links - $(date)"; for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do echo "tg://proxy?server=$SERVER_IP&port=$port&secret=${PROXIES[$port]#*:}"; done; } > "$HOME/mtproto-links.txt"
    log_info "Сохранено: $HOME/mtproto-links.txt"; echo -n "Enter..."; read -r
}

# ==================== КАСКАДНАЯ НАСТРОЙКА (ОБНОВЛЕНО) ====================

save_cascade_config() {
    mkdir -p "$(dirname "$CASCADE_CONFIG")"
    { echo "# MTProto Cascade Config"; echo "server_ip=$SERVER_IP"
      for lp in $(echo "${!CASCADE_RULES[@]}" | tr ' ' '\n' | sort -n); do echo "cascade_${lp}=${CASCADE_RULES[$lp]}"; done
    } > "$CASCADE_CONFIG"; chmod 600 "$CASCADE_CONFIG"
}

load_cascade_config() {
    [ -f "$CASCADE_CONFIG" ] && while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        [[ "$key" == "cascade_"* ]] && CASCADE_RULES["${key#cascade_}"]="$value"
    done < "$CASCADE_CONFIG"
}

# 🔥 НОВОЕ: Логирование изменений iptables
log_iptables_change() {
    local action="$1" local_port="$2" target="$3"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $action: $local_port -> $target" >> "$LOG_FILE"
}

# 🔥 НОВОЕ: Валидация целевого IP
validate_target_ip() {
    local ip="$1"
    # Запрещаем локальные и приватные адреса как цель (защита от петель)
    if [[ "$ip" == "$SERVER_IP" || "$ip" =~ ^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.) ]]; then
        return 1
    fi
    return 0
}

apply_iptables_rules() {
    local local_port="$1" target_ip="$2" target_port="$3" proto="${4:-tcp}"
    local iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -1); [[ -z "$iface" ]] && iface="eth0"
    
    log_info "Применение правил: $local_port -> $target_ip:$target_port/$proto"
    
    # Удаление старых правил
    iptables -t nat -D PREROUTING -p "$proto" --dport "$local_port" -j DNAT --to-destination "$target_ip:$target_port" 2>/dev/null || true
    iptables -D FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p "$proto" --dport "$local_port" -j ACCEPT 2>/dev/null || true
    
    # Добавление новых
    iptables -A INPUT -p "$proto" --dport "$local_port" -j ACCEPT
    iptables -t nat -A PREROUTING -p "$proto" --dport "$local_port" -j DNAT --to-destination "$target_ip:$target_port"
    iptables -A FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -j ACCEPT
    
    # MASQUERADE
    iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
    
    # Сохранение
    command -v netfilter-persistent &>/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
    command -v iptables-save &>/dev/null && iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    
    log_iptables_change "ADD" "$local_port" "$target_ip:$target_port/$proto"
    log_success "Правила применены"
}

remove_iptables_rules() {
    local local_port="$1" target_ip="$2" target_port="$3" proto="${4:-tcp}"
    log_info "Удаление правил: $local_port"
    iptables -t nat -D PREROUTING -p "$proto" --dport "$local_port" -j DNAT --to-destination "$target_ip:$target_port" 2>/dev/null || true
    iptables -D FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p "$proto" --dport "$local_port" -j ACCEPT 2>/dev/null || true
    log_iptables_change "DEL" "$local_port" "$target_ip:$target_port/$proto"
    log_success "Правила удалены"
}

# 🔥 НОВОЕ: Экспорт каскадных правил
export_cascade_rules() {
    local output="${1:-/tmp/cascade-export-$(date +%Y%m%d).txt}"
    { echo "# Cascade Rules Export - $(date)"; echo "# Server: $SERVER_IP"
      for lp in $(echo "${!CASCADE_RULES[@]}" | tr ' ' '\n' | sort -n); do
          local v="${CASCADE_RULES[$lp]}" tip="${v%%:*}" rest="${v#*:}" tport="${rest%%:*}" proto="${rest##*:}"
          echo "iptables -t nat -A PREROUTING -p $proto --dport $lp -j DNAT --to-destination $tip:$tport"
      done
    } > "$output"
    log_success "Экспорт: $output"
    cat "$output"
}

setup_cascade() {
    clear; log_header "🌐 Настройка каскадного прокси"
    echo -e "${CYAN}Этот сервер будет РЕТРАНСЛЯТОРОМ.${NC}\nТрафик: Клиент → Этот сервер → Целевой сервер"
    
    local local_port=""; while [ -z "$local_port" ]; do
        echo -n "ЛОКАЛЬНЫЙ порт [1024-65535]: "; read -r local_port
        [[ ! "$local_port" =~ ^[0-9]+$ || "$local_port" -lt 1024 || "$local_port" -gt 65535 ]] && { log_error "Неверно"; local_port=""; }
    done
    
    local target_ip=""; while [ -z "$target_ip" ]; do
        echo -n "IP ЦЕЛЕВОГО сервера: "; read -r target_ip
        [[ ! "$target_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { log_error "Неверный IP"; target_ip=""; continue; }
        # 🔥 Валидация: не локальный адрес
        if ! validate_target_ip "$target_ip"; then
            log_error "Целевой IP не может быть локальным или приватным!"
            target_ip=""
        fi
    done
    
    local target_port=""; while [ -z "$target_port" ]; do
        echo -n "Порт ЦЕЛЕВОГО сервера [1-65535]: "; read -r target_port
        [[ ! "$target_port" =~ ^[0-9]+$ || "$target_port" -lt 1 || "$target_port" -gt 65535 ]] && { log_error "Неверно"; target_port=""; }
    done
    
    local proto="tcp"; echo -n "Протокол (tcp/udp) [tcp]: "; read -r pi; [[ -n "$pi" ]] && proto="$pi"
    
    echo ""; echo -e "${YELLOW}Параметры:${NC}\n  Локальный: $local_port  Целевой: $target_ip:$target_port  Протокол: $proto"
    echo -n "Применить? [y/N]: "; read -r confirm; [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    
    enable_ip_forwarding
    apply_iptables_rules "$local_port" "$target_ip" "$target_port" "$proto"
    CASCADE_RULES["$local_port"]="${target_ip}:${target_port}:${proto}"; save_cascade_config
    open_firewall_port "$local_port" "Cascade to $target_ip"
    
    log_success "✅ Каскад настроен!"
    echo -e "\n${GREEN}Клиенты подключаются к:${NC}\n  Адрес: $SERVER_IP\n  Порт: $local_port\n  Секрет: (с ЦЕЛЕВОГО сервера)"
    echo -n "Enter..."; read -r
}

show_cascade_rules() {
    clear; [ ${#CASCADE_RULES[@]} -eq 0 ] && { log_warn "Нет каскадных правил"; return 1; }
    log_header "🌊 Активные каскадные правила"
    log_divider; printf "${CYAN}%-8s %-25s %-10s${NC}\n" "ПОРТ" "ЦЕЛЬ" "ПРОТОКОЛ"; log_divider
    for lp in $(echo "${!CASCADE_RULES[@]}" | tr ' ' '\n' | sort -n); do
        local v="${CASCADE_RULES[$lp]}" tip="${v%%:*}" rest="${v#*:}" tport="${rest%%:*}" proto="${rest##*:}"
        printf "%-8s %-25s %-10s\n" "$lp" "$tip:$tport" "$proto"
    done; log_divider
    echo -n "Enter..."; read -r
}

remove_cascade_rule() {
    clear; show_cascade_rules || return 0
    local lp=""; echo -n "Порт для удаления: "; read -r lp
    [ -z "${CASCADE_RULES[$lp]}" ] && { log_error "Не найдено"; return 1; }
    local v="${CASCADE_RULES[$lp]}" tip="${v%%:*}" rest="${v#*:}" tport="${rest%%:*}" proto="${rest##*:}"
    echo -n "Удалить каскад на порту $lp? [y/N]: "; read -r confirm; [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    remove_iptables_rules "$lp" "$tip" "$tport" "$proto"
    unset "CASCADE_RULES[$lp]"; save_cascade_config
    log_success "✅ Каскад удалён"; echo -n "Enter..."; read -r
}

# 🔥 НОВОЕ: Статистика трафика через iptables counters
show_traffic_stats() {
    clear; log_header "📊 Статистика трафика"
    if ! command -v iptables &>/dev/null; then log_warn "iptables не доступен"; return 1; fi
    
    echo -e "${CYAN}=== MTProto прокси ===${NC}"
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local container=$(get_container_name "$port")
        if is_running "$container"; then
            local rx=$(docker stats --no-stream --format "{{.NetIO}}" "$container" 2>/dev/null | cut -d'/' -f1)
            local tx=$(docker stats --no-stream --format "{{.NetIO}}" "$container" 2>/dev/null | cut -d'/' -f2)
            echo -e "Порт $port: 📥 ${rx:-N/A}  📤 ${tx:-N/A}"
        fi
    done
    
    echo -e "\n${CYAN}=== Каскадные правила ===${NC}"
    for lp in $(echo "${!CASCADE_RULES[@]}" | tr ' ' '\n' | sort -n); do
        local v="${CASCADE_RULES[$lp]}" tip="${v%%:*}" rest="${v#*:}" tport="${rest%%:*}" proto="${rest##*:}"
        local pkts=$(iptables -t nat -L PREROUTING -v -n 2>/dev/null | grep "dpt:$lp" | awk '{print $1}' | head -1)
        local bytes=$(iptables -t nat -L PREROUTING -v -n 2>/dev/null | grep "dpt:$lp" | awk '{print $2}' | head -1)
        echo -e "Порт $lp -> $tip:$tport: 📦 ${pkts:-0} пакетов  💾 ${bytes:-0} байт"
    done
    echo -n "Enter..."; read -r
}

# ==================== ВЕБ-ПАНЕЛЬ (ОБНОВЛЕНО) ====================
generate_web_panel() {
    local output="/tmp/mtproto-mini.html"
    local active=0 total=${#PROXIES[@]}
    for port in "${!PROXIES[@]}"; do local c=$(get_container_name "$port"); is_running "$c" && ((active++)); done
    local json="[" first=true
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local v="${PROXIES[$port]}" d="${v%%:*}" s="${v#*:}" c=$(get_container_name "$port")
        local st=$(is_running "$c" && echo up || echo down)
        $first || json+=","; first=false; json+="{\"p\":$port,\"d\":\"$d\",\"s\":\"$s\",\"st\":\"$st\"}"
    done; json+="]"
    
    cat > "$output" << EOF
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>MTProto</title><style>
body{font-family:sans-serif;background:#0a0e1a;color:#e2e8f0;padding:20px}.container{max-width:900px;margin:0 auto}
.header{text-align:center;margin-bottom:25px}h1{color:#a5b4fc}table{width:100%;border-collapse:collapse;background:#141b2b;border-radius:8px}
th,td{padding:12px;border-bottom:1px solid #2d3748}.secret{font-family:monospace;color:#a5b4fc}
.status-up{color:#10b981}.status-up::before{content:'🟢 '}.status-down{color:#ef4444}.status-down::before{content:'🔴 '}
.btn{background:none;border:1px solid #2d3748;color:#8b949e;padding:5px 10px;border-radius:4px;cursor:pointer}
.btn:hover{border-color:#4f6bc4;color:#a5b4fc}.cascade{color:#f59e0b}
</style></head><body><div class="container">
<div class="header"><h1>🚀 MTProto Proxy</h1><p>Server: $SERVER_IP</p><p>Active: <b>$active</b> / Total: <b>$total</b></p></div>
<table><thead><tr><th>Port</th><th>Domain</th><th>Secret</th><th>Status</th><th></th></tr></thead><tbody>
EOF
    for port in $(echo "${!PROXIES[@]}" | tr ' ' '\n' | sort -n); do
        local v="${PROXIES[$port]}" d="${v%%:*}" s="${v#*:}" c=$(get_container_name "$port")
        local st=$(is_running "$c" && echo up || echo down); local lnk="tg://proxy?server=$SERVER_IP&port=$port&secret=$s"
        echo "<tr><td><b>$port</b></td><td>$d</td><td class=\"secret\">${s:0:8}…${s: -4}</td><td class=\"status-$st\">$([ "$st" = up ] && echo Active || echo Down)</td><td><button class=\"btn\" onclick=\"navigator.clipboard.writeText('$lnk').then(()=>alert('✅'))\">📋</button></td></tr>" >> "$output"
    done
    cat >> "$output" << 'EOF'
</tbody></table><p style="color:#6b7a8f;font-size:12px;margin-top:20px">Auto-refresh: 30s</p>
<script>setTimeout(()=>location.reload(),30000)</script></body></html>
EOF
    echo "$output"
}

cli_web_panel() {
    scan_existing_proxies >/dev/null 2>&1 || true
    [ ${#PROXIES[@]} -eq 0 ] && { log_warn "Нет прокси"; return 1; }
    local f=$(generate_web_panel); log_success "Панель: $f"
    echo ""; echo -e "${YELLOW}Откройте:${NC} file://$f"; echo -e "${CYAN}Или через веб-сервер:${NC} http://$SERVER_IP:8080/"
}

# ==================== CLI КОМАНДЫ ====================
cli_add() {
    local port="$1" domain="$2" secret="${3:-$(generate_secret)}"
    [[ -z "$port" || -z "$domain" ]] && { log_error "add <port> <domain>"; exit 1; }
    local container=$(get_container_name "$port")
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker run -d --name="$container" --restart=always -p "$port":443 \
        -e "SECRET=$secret" -e "FAKE_TLS_DOMAIN=$domain" "$DOCKER_IMAGE" >/dev/null
    sleep 2; is_running "$container" || exit 1
    open_firewall_port "$port"; PROXIES["$port"]="${domain}:${secret}"; save_config; regenerate_functions
    local link="tg://proxy?server=$SERVER_IP&port=$port&secret=$secret"; printf "%s\n" "$link"; show_qr_code "$link"
}

cli_remove() {
    local port="$1"; [[ -z "$port" ]] && { log_error "remove <port>"; exit 1; }
    local container=$(get_container_name "$port"); docker rm -f "$container" >/dev/null 2>&1 || true
    unset "PROXIES[$port]"; save_config; regenerate_functions; close_firewall_port "$port"
    log_success "Port $port removed"
}

cli_links() { scan_existing_proxies >/dev/null; show_all_links; }

# ==================== ГЛАВНОЕ МЕНЮ (ОБНОВЛЕНО) ====================
main_menu() {
    clear  # 🔥 Очистка экрана перед каждым показом меню
    log_header "🚀 MTProto Proxy Manager v$SCRIPT_VERSION (HYBRID)"
    echo -e "${MAGENTA}Сервер: ${WHITE}$SERVER_IP${NC}"; echo ""
    local pc=$(scan_existing_proxies); local cc=${#CASCADE_RULES[@]}
    echo -e "${CYAN}📡 MTProto прокси: ${WHITE}$pc${NC}  ${CYAN}🌊 Каскадных правил: ${WHITE}$cc${NC}"; echo ""
    echo -e "${YELLOW}🔧 Выберите действие:${NC}"
    echo -e "   ┌─────────────────────────────────────┐"
    echo -e "   │ 📡 УПРАВЛЕНИЕ ПРОКСИ                 │"
    echo -e "   ├─────────────────────────────────────┤"
    echo -e "   │ 1) 📋 Показать список прокси         │"
    echo -e "   │ 2) ➕ Добавить новый прокси          │"
    echo -e "   │ 3) 🗑️  Удалить прокси               │"
    echo -e "   │ 4) 🔄 Обновить домен маскировки      │"
    echo -e "   │ 5) 🔗 Показать все ссылки            │"
    echo -e "   ├─────────────────────────────────────┤"
    echo -e "   │ 🌊 КАСКАДНАЯ НАСТРОЙКА               │"
    echo -e "   ├─────────────────────────────────────┤"
    echo -e "   │ 6) 🌐 Настроить каскад               │"
    echo -e "   │ 7) 📋 Показать каскадные правила     │"
    echo -e "   │ 8) 🗑️  Удалить каскадное правило    │"
    echo -e "   │ 9) 📤 Экспорт каскадных правил       │"
    echo -e "   ├─────────────────────────────────────┤"
    echo -e "   │ ⚙️  СИСТЕМНЫЕ НАСТРОЙКИ              │"
    echo -e "   ├─────────────────────────────────────┤"
    echo -e "   │ 10) 🚀 Статус BBR                    │"
    echo -e "   │ 11) 📊 Статистика трафика            │"
    echo -e "   │ 12) 🌐 Мини-веб-панель               │"
    echo -e "   │ 13) ❌ Выход                         │"
    echo -e "   └─────────────────────────────────────┘"; echo ""
    echo -n "Ваш выбор (1-13): "; read -r choice
    case "$choice" in
        1) show_proxy_list ;; 2) add_proxy ;; 3) remove_proxy ;; 4) update_domain ;;
        5) show_all_links ;; 6) setup_cascade ;; 7) show_cascade_rules ;;
        8) remove_cascade_rule ;; 9) export_cascade_rules ;; 10) show_bbr_status ;;
        11) show_traffic_stats ;; 12) cli_web_panel ;; 13|*) log_info "Выход"; exit 0 ;;
        *) log_warn "Неверный выбор" ;;
    esac
}

show_bbr_status() {
    clear; log_header "🚀 Статус TCP BBR"
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    echo -e "Алгоритм: ${CYAN}$cc${NC}  qdisc: ${CYAN}$qd${NC}"; echo ""
    if [[ "$cc" == "bbr" ]]; then
        log_success "BBR АКТИВЕН ✅"
        command -v ss &>/dev/null && echo -e "BBR соединений: ${GREEN}$(ss -ti 2>/dev/null | grep -c 'bbr' || echo 0)${NC}"
    else
        log_warn "BBR НЕ АКТИВЕН ❌"; echo -n "Активировать? [y/N]: "; read -r c
        [[ "$c" =~ ^[Yy]$ ]] && enable_bbr
    fi; echo -n "Enter..."; read -r
}

# ==================== ЗАПУСК ====================
main() {
    check_root
    # Системные настройки (только при первом запуске)
    if [ ! -f "/etc/mtproto.system_optimized" ]; then
        log_header "🔧 ПЕРВИЧНАЯ НАСТРОЙКА СИСТЕМЫ"
        check_dependencies; check_qrencode; enable_bbr; enable_ip_forwarding; optimize_network
        touch "/etc/mtproto.system_optimized"; log_success "Системные настройки применены!"
    fi
    check_docker; check_ufw; load_cascade_config
    case "${1:-}" in
        add) cli_add "${@:2}" ;; remove) cli_remove "${@:2}" ;; links) cli_links ;;
        scan) scan_existing_proxies; show_proxy_list ;; web) cli_web_panel ;;
        cascade) setup_cascade ;; bbr) enable_bbr ;; stats) show_traffic_stats ;;
        *) main_menu ;;
    esac
}
main "$@"
