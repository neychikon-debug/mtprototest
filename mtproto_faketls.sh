#!/bin/bash

# ══════════════════════════════════════════
# Проверка прав
# ══════════════════════════════════════════
if [[ $EUID -ne 0 ]]; then
   echo "Запустите скрипт с правами root (sudo)."
   exit 1
fi

# ══════════════════════════════════════════
# Настройки (можно менять)
# ══════════════════════════════════════════
FAKE_TLS_DOMAIN="ya.ru"          # Домен для маскировки фейк‑TLS
TLS_PORT="443"                   # Порт для фейк‑TLS
PLAIN_PORT="8443"                # Порт для обычного прокси
ALT_TLS_PORT="8444"              # Запасные порты, если основные заняты
ALT_PLAIN_PORT="9443"

# ══════════════════════════════════════════
# Цветной вывод
# ══════════════════════════════════════════
print_color() {
    case $1 in
        green)  echo -e "\033[0;32m$2\033[0m" ;;
        red)    echo -e "\033[0;31m$2\033[0m" ;;
        yellow) echo -e "\033[1;33m$2\033[0m" ;;
        blue)   echo -e "\033[0;34m$2\033[0m" ;;
        *)      echo "$2" ;;
    esac
}

# ══════════════════════════════════════════
# 1. Установка Docker
# ══════════════════════════════════════════
if ! command -v docker &>/dev/null; then
    print_color yellow "🐳 Docker не найден. Устанавливаем..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    systemctl enable --now docker
    print_color green "✅ Docker установлен."
else
    print_color green "🐳 Docker уже присутствует."
fi

# ══════════════════════════════════════════
# 2. Внешний IP
# ══════════════════════════════════════════
print_color yellow "🌐 Определяем внешний IP..."
SERVER_IP=$(curl -s ifconfig.me)
if [[ -z "$SERVER_IP" ]]; then
    print_color red "❌ Не удалось определить IP. Проверьте интернет."
    exit 1
fi
print_color blue "   IP: $SERVER_IP"

# ══════════════════════════════════════════
# 3. Проверка и выбор портов
# ══════════════════════════════════════════
check_port() {
    # $1 = порт, $2 = описание
    if ss -tuln | grep -q ":${1} "; then
        return 1  # занят
    else
        return 0  # свободен
    fi
}

# Проверяем TLS порт
print_color yellow "🔌 Проверяем порт для фейк‑TLS ($TLS_PORT)..."
if check_port $TLS_PORT; then
    FINAL_TLS_PORT=$TLS_PORT
    print_color green "   ✅ Порт $TLS_PORT свободен."
else
    print_color yellow "   ⚠️  Порт $TLS_PORT занят. Используем $ALT_TLS_PORT."
    FINAL_TLS_PORT=$ALT_TLS_PORT
    if ! check_port $FINAL_TLS_PORT; then
        print_color red "❌ И запасной порт $ALT_TLS_PORT занят. Освободите один из портов."
        exit 1
    fi
fi

# Проверяем обычный порт
print_color yellow "🔌 Проверяем порт для обычного прокси ($PLAIN_PORT)..."
if check_port $PLAIN_PORT; then
    FINAL_PLAIN_PORT=$PLAIN_PORT
    print_color green "   ✅ Порт $PLAIN_PORT свободен."
else
    print_color yellow "   ⚠️  Порт $PLAIN_PORT занят. Используем $ALT_PLAIN_PORT."
    FINAL_PLAIN_PORT=$ALT_PLAIN_PORT
    if ! check_port $FINAL_PLAIN_PORT; then
        print_color red "❌ И запасной порт $ALT_PLAIN_PORT занят. Освободите порт."
        exit 1
    fi
fi

# ══════════════════════════════════════════
# 4. Генерация секрета (один для обоих)
# ══════════════════════════════════════════
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
print_color blue "🔑 Секрет: $SECRET"

# ══════════════════════════════════════════
# 5. Запуск контейнеров
# ══════════════════════════════════════════
print_color yellow "🛠️  Загружаем официальный образ Telegram..."
docker pull telegrammessenger/proxy:latest

# Контейнер с фейк‑TLS
print_color yellow "🔒 Запускаем фейк‑TLS прокси (порт $FINAL_TLS_PORT)..."
docker run -d \
    --name mtproto-tls \
    --restart always \
    -p ${FINAL_TLS_PORT}:443 \
    -e SECRET=${SECRET} \
    -e TLS_DOMAIN=${FAKE_TLS_DOMAIN} \
    telegrammessenger/proxy:latest

if [ $? -ne 0 ]; then
    print_color red "❌ Ошибка запуска фейк‑TLS контейнера."
    exit 1
fi

# Контейнер без шифрования (обычный)
print_color yellow "🔓 Запускаем обычный прокси (порт $FINAL_PLAIN_PORT)..."
docker run -d \
    --name mtproto-plain \
    --restart always \
    -p ${FINAL_PLAIN_PORT}:443 \
    -e SECRET=${SECRET} \
    telegrammessenger/proxy:latest

if [ $? -ne 0 ]; then
    print_color red "❌ Ошибка запуска обычного контейнера."
    exit 1
fi

# ══════════════════════════════════════════
# 6. Формирование информации для подключения
# ══════════════════════════════════════════
PLAIN_LINK="tg://proxy?server=${SERVER_IP}&port=${FINAL_PLAIN_PORT}&secret=${SECRET}"
TLS_LINK="tg://proxy?server=${SERVER_IP}&port=${FINAL_TLS_PORT}&secret=${SECRET}"

echo ""
print_color green "══════════════════════════════════════════════"
print_color green "  Оба прокси успешно запущены!"
print_color green "══════════════════════════════════════════════"
echo ""

print_color blue "🔵 Обычный прокси (без шифрования):"
echo "   Сервер: $SERVER_IP"
echo "   Порт:   $FINAL_PLAIN_PORT"
echo "   Секрет: $SECRET"
echo "   Ссылка: $PLAIN_LINK"
echo ""

print_color blue "🟢 Фейк‑TLS прокси (маскировка под $FAKE_TLS_DOMAIN):"
echo "   Сервер: $SERVER_IP"
echo "   Порт:   $FINAL_TLS_PORT"
echo "   Секрет: $SECRET"
echo "   Ссылка: $TLS_LINK"
echo ""

print_color yellow "📋 Как подключить в Telegram:"
echo "   Настройки → Продвинутые настройки → Тип соединения →"
echo "   Использовать собственный прокси → Добавить прокси"
echo "   и вставить соответствующую ссылку из списка выше."
echo ""
print_color yellow "📝 Просмотр логов:"
echo "   docker logs mtproto-tls"
echo "   docker logs mtproto-plain"
echo ""
