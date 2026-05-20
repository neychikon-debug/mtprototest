#!/bin/bash

# Скрипт для развертывания SOCKS5 прокси в Docker
# Автор: Assistant
# Использование: chmod +x setup_socks5.sh && ./setup_socks5.sh

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Проверка наличия Docker
if ! command -v docker &> /dev/null; then
    error "Docker не установлен. Установите Docker и повторите попытку."
fi

# Проверка, запущен ли Docker
if ! docker info &> /dev/null; then
    error "Docker демон не запущен. Запустите Docker (systemctl start docker) и повторите попытку."
fi

# Определение публичного IP
get_public_ip() {
    local ip=""
    # Пробуем несколько сервисов
    for service in "ifconfig.me" "icanhazip.com" "ipinfo.io/ip" "api.ipify.org"; do
        ip=$(curl -s --max-time 5 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
}

info "Определяем внешний IP..."
PUBLIC_IP=$(get_public_ip)
if [[ -z "$PUBLIC_IP" ]]; then
    error "Не удалось определить внешний IP. Проверьте интернет-соединение."
fi
info "Ваш внешний IP: $PUBLIC_IP"

# Запрос порта
read -p "Введите порт для прокси (1024-65535, по умолчанию 1080): " PORT
if [[ -z "$PORT" ]]; then
    PORT=1080
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    error "Порт должен быть числом от 1024 до 65535."
fi

# Аутентификация
read -p "Использовать логин/пароль? (y/N): " USE_AUTH
USE_AUTH=${USE_AUTH,,}
if [[ "$USE_AUTH" == "y" || "$USE_AUTH" == "yes" ]]; then
    read -p "Логин: " PROXY_USER
    read -s -p "Пароль: " PROXY_PASS
    echo ""
    if [[ -z "$PROXY_USER" || -z "$PROXY_PASS" ]]; then
        error "Логин и пароль не могут быть пустыми."
    fi
    AUTH_ENABLED=true
else
    AUTH_ENABLED=false
    warn "Прокси будет работать без аутентификации. Любой пользователь может подключиться. Рекомендуется использовать аутентификацию."
fi

# Имя контейнера
CONTAINER_NAME="socks5-proxy-${PORT}"

# Остановка и удаление существующего контейнера с таким же портом
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    warn "Контейнер ${CONTAINER_NAME} уже существует. Останавливаем и удаляем..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1
fi

# Запуск контейнера
info "Запускаем SOCKS5 прокси сервер..."
DOCKER_RUN_ARGS=(
    run -d
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    -p "$PORT:1080"
)

if [[ "$AUTH_ENABLED" == true ]]; then
    DOCKER_RUN_ARGS+=(
        -e PROXY_USER="$PROXY_USER"
        -e PROXY_PASSWORD="$PROXY_PASS"
    )
fi

# Используем официальный образ serjs/go-socks5-proxy
DOCKER_RUN_ARGS+=(
    serjs/go-socks5-proxy
)

# Запуск с возможностью вывода ошибок
if ! docker "${DOCKER_RUN_ARGS[@]}"; then
    error "Не удалось запустить контейнер. Возможно, порт $PORT уже занят."
fi

# Небольшая пауза для инициализации
sleep 2

# Проверка, работает ли контейнер
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    error "Контейнер не запустился. Проверьте логи: docker logs ${CONTAINER_NAME}"
fi

info "Прокси сервер успешно запущен!"

# Формирование строки подключения
if [[ "$AUTH_ENABLED" == true ]]; then
    CONNECTION_STRING="socks5://${PROXY_USER}:${PROXY_PASS}@${PUBLIC_IP}:${PORT}"
    SIMPLE_INFO="IP: ${PUBLIC_IP}\nПорт: ${PORT}\nЛогин: ${PROXY_USER}\nПароль: ${PROXY_PASS}"
else
    CONNECTION_STRING="socks5://${PUBLIC_IP}:${PORT}"
    SIMPLE_INFO="IP: ${PUBLIC_IP}\nПорт: ${PORT}\nБез аутентификации"
fi

# Вывод данных
echo ""
echo "==========================================="
echo -e "${GREEN}Данные для подключения к прокси:${NC}"
echo -e "${YELLOW}${SIMPLE_INFO}${NC}"
echo "Строка подключения: ${CONNECTION_STRING}"
echo "==========================================="
echo ""

# Сохранение в файл
SAVE_FILE="socks5_${PORT}_$(date +%Y%m%d_%H%M%S).txt"
{
    echo "=== SOCKS5 Proxy Connection Info ==="
    echo "Created: $(date)"
    echo "IP: ${PUBLIC_IP}"
    echo "Port: ${PORT}"
    if [[ "$AUTH_ENABLED" == true ]]; then
        echo "Username: ${PROXY_USER}"
        echo "Password: ${PROXY_PASS}"
    else
        echo "Authentication: none"
    fi
    echo "Connection string: ${CONNECTION_STRING}"
} > "$SAVE_FILE"
info "Данные сохранены в файл: $SAVE_FILE"

# Опциональная отправка в Telegram
read -p "Отправить данные в Telegram? (y/N): " SEND_TG
SEND_TG=${SEND_TG,,}
if [[ "$SEND_TG" == "y" || "$SEND_TG" == "yes" ]]; then
    read -p "Введите токен бота (например, 123456:ABC-DEF): " BOT_TOKEN
    read -p "Введите ваш Chat ID: " CHAT_ID
    if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
        warn "Токен или Chat ID не указаны. Отправка отменена."
    else
        MESSAGE="🔐 *Новый SOCKS5 прокси создан!*
📍 *IP:* ${PUBLIC_IP}
🔌 *Порт:* ${PORT}
"
        if [[ "$AUTH_ENABLED" == true ]]; then
            MESSAGE+="👤 *Логин:* ${PROXY_USER}
🔑 *Пароль:* ${PROXY_PASS}
"
        else
            MESSAGE+="⚠️ *Без аутентификации* (небезопасно)
"
        fi
        MESSAGE+="🔗 \`${CONNECTION_STRING}\`"
        
        ENCODED_MESSAGE=$(echo -e "$MESSAGE" | jq -sRr @uri)
        TG_URL="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
        RESPONSE=$(curl -s -X POST "$TG_URL" \
            -d "chat_id=${CHAT_ID}" \
            -d "text=${MESSAGE}" \
            -d "parse_mode=Markdown" \
            -d "disable_web_page_preview=true")
        
        if echo "$RESPONSE" | grep -q '"ok":true'; then
            info "Сообщение отправлено в Telegram!"
        else
            warn "Ошибка отправки в Telegram. Проверьте токен и chat ID."
        fi
    fi
fi

info "Готово! Прокси работает. Остановить контейнер: docker stop $CONTAINER_NAME"
info "Удалить контейнер: docker rm -f $CONTAINER_NAME"
