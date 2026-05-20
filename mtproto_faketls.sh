#!/bin/bash

# =============================================
# MTProto Proxy с FakeTLS для Docker
# Работает в России без блокировок
# =============================================

# Проверка на sudo
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] Запустите скрипт с sudo: sudo $0"
    exit 1
fi

set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Конфигурация
CONTAINER_NAME="mtproto-proxy"
DEFAULT_PORT=443
IMAGE="telegrammessenger/proxy:latest"

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка Docker
check_docker() {
    print_info "Проверка Docker..."
    if ! command -v docker &> /dev/null; then
        print_error "Docker не установлен!"
        exit 1
    fi
    if ! docker info &> /dev/null; then
        print_error "Нет доступа к Docker. Запустите с sudo."
        exit 1
    fi
    print_success "Docker OK"
}

# Определение IP
get_external_ip() {
    print_info "Определение IP..."
    EXTERNAL_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) || \
                 EXTERNAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    if [ -z "$EXTERNAL_IP" ]; then
        read -p "Введите IP сервера: " EXTERNAL_IP
    fi
    print_success "IP: $EXTERNAL_IP"
}

# Генерация секрета
generate_secret() {
    print_info "Генерация секрета..."
    SECRET=$(openssl rand -hex 32)
    print_success "Secret: $SECRET"
}

# Выбор порта (авто по умолчанию)
select_port() {
    echo ""
    echo "Выберите порт:"
    echo "  1) 443 (рекомендуется)"
    echo "  2) 8443"
    echo "  3) Другой"
    echo ""
    read -p "Выбор [1]: " choice

    case "${choice:-1}" in
        2) MTPROTO_PORT=8443 ;;
        3) read -p "Порт: " MTPROTO_PORT ;;
        *) MTPROTO_PORT=443 ;;
    esac

    if ! [[ "$MTPROTO_PORT" =~ ^[0-9]+$ ]] || [ "$MTPROTO_PORT" -lt 1 ] || [ "$MTPROTO_PORT" -gt 65535 ]; then
        MTPROTO_PORT=443
    fi
    print_success "Порт: $MTPROTO_PORT"
}

# Очистка старого контейнера
cleanup() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_warning "Удаление старого контейнера..."
        docker stop $CONTAINER_NAME 2>/dev/null || true
        docker rm $CONTAINER_NAME 2>/dev/null || true
    fi
}

# Запуск
start_proxy() {
    print_info "Запуск MTProto Proxy..."

    FAKE_SECRET="ee${SECRET}"

    docker run -d \
        --name $CONTAINER_NAME \
        --restart always \
        -p $MTPROTO_PORT:443 \
        -e SECRET=$SECRET \
        -e FAKE_TLS_SECRET=$FAKE_SECRET \
        $IMAGE

    sleep 2

    if docker ps | grep -q $CONTAINER_NAME; then
        print_success "Прокси запущен!"
    else
        print_error "Ошибка запуска!"
        docker logs $CONTAINER_NAME
        exit 1
    fi
}

# Вывод результата
show_result() {
    echo ""
    echo "============================================="
    echo -e "${GREEN}  MTProto Proxy с FakeTLS готов!${NC}"
    echo "============================================="
    echo ""
    echo -e "${YELLOW}Сервер:${NC} $EXTERNAL_IP"
    echo -e "${YELLOW}Порт:${NC}   $MTPROTO_PORT"
    echo -e "${YELLOW}Secret:${NC} $SECRET"
    echo ""
    echo -e "${GREEN}Ссылка для подключения:${NC}"
    echo ""
    echo "tg://proxy?server=${EXTERNAL_IP}&port=${MTPROTO_PORT}&secret=ee${SECRET}"
    echo ""
    echo "https://t.me/proxy?server=${EXTERNAL_IP}&port=${MTPROTO_PORT}&secret=ee${SECRET}"
    echo ""
    echo "============================================="
    echo ""
}

# Команды
case "${1:-}" in
    start)
        docker start $CONTAINER_NAME 2>/dev/null || print_error "Контейнер не найден"
        ;;
    stop)
        docker stop $CONTAINER_NAME
        ;;
    restart)
        docker restart $CONTAINER_NAME
        ;;
    status)
        docker ps --filter "name=$CONTAINER_NAME"
        ;;
    logs)
        docker logs -f $CONTAINER_NAME
        ;;
    link)
        SECRET=$(docker exec $CONTAINER_NAME env | grep SECRET | cut -d= -f2 2>/dev/null)
        if [ -n "$SECRET" ]; then
            echo "tg://proxy?server=${EXTERNAL_IP:-$(curl -s https://api.ipify.org)}&port=${MTPROTO_PORT:-443}&secret=ee${SECRET}"
        fi
        ;;
    uninstall)
        docker stop $CONTAINER_NAME 2>/dev/null || true
        docker rm $CONTAINER_NAME 2>/dev/null || true
        print_success "Удалено"
        ;;
    *)
        clear
        echo "============================================="
        echo -e "${GREEN}  MTProto Proxy с FakeTLS${NC}"
        echo "============================================="
        echo ""
        check_docker
        get_external_ip
        generate_secret
        select_port
        cleanup
        start_proxy
        show_result
        ;;
esac
