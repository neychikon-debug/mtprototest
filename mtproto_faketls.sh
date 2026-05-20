#!/bin/bash

# =============================================
# MTProto Proxy с FakeTLS для Docker
# Работает в России без блокировок
# =============================================

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Конфигурация
CONTAINER_NAME="mtproto-proxy"
DEFAULT_PORT=443
IMAGE="telegrammessenger/proxy:latest"

# Функция для вывода сообщений
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Проверка наличия Docker
check_docker() {
    print_info "Проверка наличия Docker..."
    if ! command -v docker &> /dev/null; then
        print_error "Docker не установлен. Установите Docker:"
        echo "  Ubuntu/Debian: sudo apt update && sudo apt install docker.io"
        echo "  CentOS/RHEL:   sudo yum install docker-ce"
        echo "  Docker Desktop: https://docs.docker.com/desktop/"
        exit 1
    fi

    if ! docker info &> /dev/null; then
        print_error "Docker запущен, но нет прав доступа."
        echo "Попробуйте: sudo usermod -aG docker \$USER"
        echo "Или запустите этот скрипт с sudo"
        exit 1
    fi

    print_success "Docker найден и работает"
}

# Определение внешнего IP адреса
get_external_ip() {
    print_info "Определение внешнего IP адреса..."

    # Пытаемся получить IP через несколько сервисов
    EXTERNAL_IP=""

    # Способ 1: через curl
    if command -v curl &> /dev/null; then
        EXTERNAL_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null) || \
                     EXTERNAL_IP=$(curl -s --max-time 5 https://icanhazip.com 2>/dev/null) || \
                     EXTERNAL_IP=$(curl -s --max-time 5 http://ifconfig.me 2>/dev/null)
    fi

    # Способ 2: через wget
    if [ -z "$EXTERNAL_IP" ] && command -v wget &> /dev/null; then
        EXTERNAL_IP=$(wget -qO- --timeout=5 https://api.ipify.org 2>/dev/null) || \
                     EXTERNAL_IP=$(wget -qO- --timeout=5 https://icanhazip.com 2>/dev/null)
    fi

    # Способ 3: через ip команды
    if [ -z "$EXTERNAL_IP" ]; then
        # Получаем IP через основной интерфейс
        EXTERNAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    fi

    if [ -z "$EXTERNAL_IP" ]; then
        print_warning "Не удалось определить внешний IP автоматически"
        print_info "Введите IP адрес вашего сервера вручную:"
        read -p "IP адрес: " EXTERNAL_IP
    fi

    if [ -z "$EXTERNAL_IP" ]; then
        print_error "Не удалось определить IP адрес"
        exit 1
    fi

    print_success "Внешний IP: $EXTERNAL_IP"
}

# Генерация секретов для MTProto с FakeTLS
generate_secrets() {
    print_info "Генерация секретов для MTProto..."

    # Генерируем секрет в формате hex (32 байта = 64 символа)
    SECRET=$(openssl rand -hex 32)

    # Генерируем секрет для FakeTLS (обычно тот же секрет)
    FAKE_TLS_SECRET=$SECRET

    print_success "Секреты сгенерированы"
    echo "  MTProto Secret: $SECRET"
    echo "  FakeTLS Secret: $FAKE_TLS_SECRET"
}

# Выбор порта
select_port() {
    print_info "Выбор порта для MTProto..."

    echo ""
    echo "Выберите порт:"
    echo "  1) 443 (рекомендуется - HTTPS порт, лучшая маскировка)"
    echo "  2) 8443 (альтернативный)"
    echo "  3)  другой (введите свой)"
    echo ""
    read -p "Ваш выбор [1]: " PORT_CHOICE

    case $PORT_CHOICE in
        2)
            MTPROTO_PORT=8443
            ;;
        3)
            read -p "Введите порт: " MTPROTO_PORT
            ;;
        *)
            MTPROTO_PORT=$DEFAULT_PORT
            ;;
    esac

    # Проверка порта
    if ! [[ "$MTPROTO_PORT" =~ ^[0-9]+$ ]] || [ "$MTPROTO_PORT" -lt 1 ] || [ "$MTPROTO_PORT" -gt 65535 ]; then
        print_error "Неверный порт. Используем порт по умолчанию: $DEFAULT_PORT"
        MTPROTO_PORT=$DEFAULT_PORT
    fi

    print_success "Порт: $MTPROTO_PORT"
}

# Остановка и удаление старого контейнера
cleanup_old_container() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_warning "Удаление старого контейнера..."
        docker stop $CONTAINER_NAME 2>/dev/null || true
        docker rm $CONTAINER_NAME 2>/dev/null || true
        print_success "Старый контейнер удален"
    fi
}

# Запуск MTProto прокси с FakeTLS
start_mtproto_proxy() {
    print_info "Запуск MTProto Proxy с FakeTLS..."

    # Формируем ссылку для подключения
    # Формат: tg://proxy?server=IP&port=PORT&secret=SECRET
    # Для FakeTLS секрет начинается с ee
    FAKE_TLS_SECRET="ee${SECRET}"

    print_info "Создание контейнера..."

    # Запускаем контейнер с FakeTLS
    docker run -d \
        --name $CONTAINER_NAME \
        --restart always \
        -p $MTPROTO_PORT:443 \
        -e SECRET=$SECRET \
        -e FAKE_TLS_SECRET=$FAKE_TLS_SECRET \
        $IMAGE

    sleep 2

    if docker ps | grep -q $CONTAINER_NAME; then
        print_success "MTProto Proxy успешно запущен!"
    else
        print_error "Ошибка при запуске контейнера"
        docker logs $CONTAINER_NAME
        exit 1
    fi
}

# Генерация ссылки для подключения
generate_connection_link() {
    echo ""
    echo "============================================="
    echo -e "${GREEN}  MTProto Proxy с FakeTLS готов!${NC}"
    echo "============================================="
    echo ""
    echo -e "${BLUE}Информация о подключении:${NC}"
    echo ""
    echo -e "${YELLOW}  Сервер:${NC}  $EXTERNAL_IP"
    echo -e "${YELLOW}  Порт:${NC}    $MTPROTO_PORT"
    echo -e "${YELLOW}  Secret:${NC}  $SECRET"
    echo ""
    echo -e "${BLUE}Ссылка для подключения (MTProto + FakeTLS):${NC}"
    echo ""
    echo -e "${GREEN}tg://proxy?server=${EXTERNAL_IP}&port=${MTPROTO_PORT}&secret=ee${SECRET}${NC}"
    echo ""
    echo -e "${BLUE}Ссылка для Telegram (http):${NC}"
    echo ""
    echo -e "https://t.me/proxy?server=${EXTERNAL_IP}&port=${MTPROTO_PORT}&secret=ee${SECRET}"
    echo ""
    echo -e "${BLUE}QR код для быстрого подключения:${NC}"
    echo ""
    echo "  Откройте Telegram -> Настройки -> Данные и память -> Proxy"
    echo "  Нажмите 'Добавить Proxy' и вставьте ссылку выше"
    echo ""
    echo "============================================="
    echo ""
    echo -e "${YELLOW}Важно:${NC}"
    echo "  - FakeTLS маскирует трафик под обычный HTTPS"
    echo "  - Используйте секрет начинающийся с 'ee' для FakeTLS"
    echo "  - Порт 443 лучше всего работает с FakeTLS"
    echo "  - QR код можно сгенерировать на: https://t.me/proxy"
    echo ""
}

# Проверка статуса
check_status() {
    print_info "Проверка статуса контейнера..."

    if docker ps | grep -q $CONTAINER_NAME; then
        print_success "Контейнер работает"
        docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    else
        print_warning "Контейнер не работает"
    fi
}

# Основная функция
main() {
    clear
    echo "============================================="
    echo -e "${GREEN}  MTProto Proxy с FakeTLS Setup${NC}"
    echo "     Docker Edition v1.0"
    echo "============================================="
    echo ""

    check_docker
    get_external_ip
    generate_secrets
    select_port
    cleanup_old_container
    start_mtproto_proxy
    generate_connection_link

    echo ""
    print_info "Для просмотра логов: docker logs $CONTAINER_NAME"
    print_info "Для остановки:       docker stop $CONTAINER_NAME"
    print_info "Для удаления:        docker rm $CONTAINER_NAME"
    echo ""
}

# Обработка аргументов командной строки
case "${1:-}" in
    start)
        if docker ps | grep -q $CONTAINER_NAME; then
            print_success "Контейнер уже запущен"
            check_status
        else
            print_info "Запуск остановленного контейнера..."
            docker start $CONTAINER_NAME
            print_success "Контейнер запущен"
            check_status
        fi
        ;;
    stop)
        print_info "Остановка контейнера..."
        docker stop $CONTAINER_NAME
        print_success "Контейнер остановлен"
        ;;
    restart)
        print_info "Перезапуск контейнера..."
        docker restart $CONTAINER_NAME
        print_success "Контейнер перезапущен"
        check_status
        ;;
    status)
        check_status
        ;;
    logs)
        docker logs -f $CONTAINER_NAME
        ;;
    link)
        # Показать ссылку для запущенного контейнера
        CONTAINER_IP=$(docker exec $CONTAINER_NAME cat /etc/hosts 2>/dev/null | grep -v "^#" | awk '{print $1}' | head -1)
        if [ -z "$CONTAINER_IP" ]; then
            CONTAINER_IP=$EXTERNAL_IP
        fi
        SECRET=$(docker inspect $CONTAINER_NAME --format '{{.Config.Env}}' 2>/dev/null | grep -oP 'SECRET=\K[^ ]+' || echo "$SECRET")
        echo -e "${GREEN}tg://proxy?server=${EXTERNAL_IP}&port=${MTPROTO_PORT:-443}&secret=ee${SECRET}${NC}"
        ;;
    uninstall)
        print_warning "Удаление MTProto Proxy..."
        docker stop $CONTAINER_NAME 2>/dev/null || true
        docker rm $CONTAINER_NAME 2>/dev/null || true
        print_success "MTProto Proxy удален"
        ;;
    help|--help|-h)
        echo "Использование: $0 [команда]"
        echo ""
        echo "Команды:"
        echo "  (без аргументов)  - Запуск/настройка MTProto Proxy"
        echo "  start             - Запуск существующего контейнера"
        echo "  stop              - Остановка контейнера"
        echo "  restart           - Перезапуск контейнера"
        echo "  status            - Проверка статуса"
        echo "  logs              - Просмотр логов"
        echo "  link              - Показать ссылку для подключения"
        echo "  uninstall         - Удалить MTProto Proxy"
        echo "  help              - Показать эту справку"
        echo ""
        ;;
    *)
        main
        ;;
esac
