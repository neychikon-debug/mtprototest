#!/bin/bash
set -e

# ─── Цвета ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ─── Конфигурация ────────────────────────────────────────
PORT=${1:-443}
TAG=${2:-""}          # FakeTLS домен (например: google.com)
SECRET=${3:-""}       # Если пустой — генерируем

# ─── Определение внешнего IP ─────────────────────────────
detect_ip() {
    local ip
    ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) \
    || ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null) \
    || ip=$(curl -s --max-time 5 https://icanhazip.com 2>/dev/null) \
    || err "Не удалось определить внешний IP"
    echo "$ip"
}

# ─── Генерация секрета ───────────────────────────────────
generate_secret() {
    openssl rand -hex 16
}

# ─── Проверка зависимостей ───────────────────────────────
check_deps() {
    command -v docker &>/dev/null || err "Docker не установлен"
    command -v curl   &>/dev/null || err "curl не установлен"
    command -v openssl &>/dev/null || err "openssl не установлен"
}

# ─── Основная логика ─────────────────────────────────────
main() {
    echo -e "\n${BLUE}══════════════════════════════════════${NC}"
    echo -e "${BLUE}      MTProxy + FakeTLS Setup          ${NC}"
    echo -e "${BLUE}══════════════════════════════════════${NC}\n"

    check_deps

    # IP
    info "Определяем внешний IP..."
    EXT_IP=$(detect_ip)
    log "Внешний IP: ${EXT_IP}"

    # Секрет
    if [[ -z "$SECRET" ]]; then
        SECRET=$(generate_secret)
        warn "Секрет сгенерирован автоматически"
    fi

    # FakeTLS домен
    if [[ -z "$TAG" ]]; then
        TAG="google.com"
        warn "FakeTLS домен не указан, используем: ${TAG}"
    fi

    # FakeTLS секрет = ee + hex(domain) + secret
    DOMAIN_HEX=$(echo -n "$TAG" | xxd -p | tr -d '\n')
    FAKETLS_SECRET="ee${DOMAIN_HEX}${SECRET}"

    info "Порт: ${PORT}"
    info "FakeTLS домен: ${TAG}"
    info "Секрет (raw): ${SECRET}"
    info "FakeTLS секрет: ${FAKETLS_SECRET}"

    # ─── Остановка старого контейнера ────────────────────
    if docker ps -a --format '{{.Names}}' | grep -q '^mtproxy$'; then
        warn "Останавливаем старый контейнер mtproxy..."
        docker rm -f mtproxy
    fi

    # ─── Запуск контейнера ───────────────────────────────
    log "Запускаем MTProxy контейнер..."
    docker run -d \
        --name mtproxy \
        --restart always \
        -p "${PORT}:443" \
        -e "SECRET=${SECRET}" \
        telegrammessenger/proxy:latest \
        > /dev/null

    sleep 3

    # Проверка
    if docker ps --format '{{.Names}}' | grep -q '^mtproxy$'; then
        log "Контейнер успешно запущен!"
    else
        err "Контейнер не запустился. Проверьте: docker logs mtproxy"
    fi

    # ─── Генерация ссылок ────────────────────────────────
    LINK_PLAIN="https://t.me/proxy?server=${EXT_IP}&port=${PORT}&secret=${SECRET}"
    LINK_FAKETLS="https://t.me/proxy?server=${EXT_IP}&port=${PORT}&secret=${FAKETLS_SECRET}"

    echo -e "\n${GREEN}══════════════════════════════════════${NC}"
    echo -e "${GREEN}         Готово! Данные прокси         ${NC}"
    echo -e "${GREEN}══════════════════════════════════════${NC}"
    echo -e "  ${YELLOW}IP:${NC}            ${EXT_IP}"
    echo -e "  ${YELLOW}Порт:${NC}          ${PORT}"
    echo -e "  ${YELLOW}Raw секрет:${NC}    ${SECRET}"
    echo -e "  ${YELLOW}FakeTLS секрет:${NC} ${FAKETLS_SECRET}"
    echo -e ""
    echo -e "  ${BLUE}Обычная ссылка:${NC}"
    echo -e "  ${LINK_PLAIN}"
    echo -e ""
    echo -e "  ${BLUE}FakeTLS ссылка (рекомендуется для РФ):${NC}"
    echo -e "  ${LINK_FAKETLS}"
    echo -e ""
    echo -e "  ${YELLOW}Логи:${NC} docker logs -f mtproxy"
    echo -e "${GREEN}══════════════════════════════════════${NC}\n"

    # Сохраняем конфиг
    cat > mtproxy.conf <<EOF
IP=${EXT_IP}
PORT=${PORT}
SECRET=${SECRET}
FAKETLS_SECRET=${FAKETLS_SECRET}
FAKETLS_DOMAIN=${TAG}
LINK_PLAIN=${LINK_PLAIN}
LINK_FAKETLS=${LINK_FAKETLS}
EOF
    log "Конфигурация сохранена в mtproxy.conf"
}

main
