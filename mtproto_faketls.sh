#!/bin/bash

# ══════════════════════════════════════════
# Проверка прав
# ══════════════════════════════════════════
if [[ $EUID -ne 0 ]]; then
   echo "Запустите скрипт с правами root (sudo)."
   exit 1
fi

# ══════════════════════════════════════════
# Конфигурационный файл
# ══════════════════════════════════════════
CONFIG_FILE="/etc/mtproxy.conf"

# Значения по умолчанию (будут записаны в конфиг при первом запуске)
DEFAULT_TLS_DOMAIN="ya.ru"
DEFAULT_TLS_PORT="443"
DEFAULT_PLAIN_PORT="8443"
DEFAULT_ALT_TLS_PORT="8444"
DEFAULT_ALT_PLAIN_PORT="9443"
DEFAULT_PROMO_CHANNEL=""        # оставьте пустым, если пока не нужен

# Если конфиг существует — загружаем, иначе создаём с дефолтными значениями
if [[ -f "$CONFIG_FILE" ]]; then
    print_color blue "📄 Загружаем конфигурацию из $CONFIG_FILE"
    source "$CONFIG_FILE"
else
    print_color yellow "⚙️  Конфиг не найден, создаём $CONFIG_FILE со значениями по умолчанию."
    cat > "$CONFIG_FILE" <<EOF
# Настройки MTProto прокси
FAKE_TLS_DOMAIN="${DEFAULT_TLS_DOMAIN}"
TLS_PORT="${DEFAULT_TLS_PORT}"
PLAIN_PORT="${DEFAULT_PLAIN_PORT}"
ALT_TLS_PORT="${DEFAULT_ALT_TLS_PORT}"
ALT_PLAIN_PORT="${DEFAULT_ALT_PLAIN_PORT}"
PROMO_CHANNEL="${DEFAULT_PROMO_CHANNEL}"
# SECRET будет сгенерирован автоматически и записан сюда после первого запуска
SECRET=""
EOF
    source "$CONFIG_FILE"
fi

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
# 4. Генерация или загрузка секрета
# ══════════════════════════════════════════
if [[ -z "$SECRET" ]]; then
    print_color yellow "🔑 Генерируем новый секрет..."
    SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    # Сохраняем секрет в конфиг
    sed -i "s/^SECRET=.*/SECRET=\"${SECRET}\"/" "$CONFIG_FILE"
    print_color green "   Секрет сохранён в $CONFIG_FILE"
else
    print_color blue "🔑 Используем существующий секрет из конфига."
fi
print_color blue "   Секрет: $SECRET"

# ══════════════════════════════════════════
# 5. Проверка промоканала (если задан)
# ══════════════════════════════════════════
if [[ -z "$PROMO_CHANNEL" ]]; then
    print_color red "⚠️  PROMO_CHANNEL не задан!"
    print_color yellow "   Официальный прокси Telegram НЕ будет работать без идентификатора канала."
    print_color yellow "   Создайте канал в Telegram, получите его ID (например, -1001234567890)"
    print_color yellow "   и пропишите в $CONFIG_FILE: PROMO_CHANNEL=\"-1001234567890\""
    print_color yellow "   После этого перезапустите скрипт."
    echo ""
    read -p "Продолжить установку без промоканала? (y/n): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ══════════════════════════════════════════
# 6. Остановка и удаление старых контейнеров (при перезапуске)
# ══════════════════════════════════════════
docker stop mtproto-tls mtproto-plain 2>/dev/null
docker rm mtproto-tls mtproto-plain 2>/dev/null

# ══════════════════════════════════════════
# 7. Запуск контейнеров
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
    -e PROMO_CHANNEL=${PROMO_CHANNEL} \
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
    -e PROMO_CHANNEL=${PROMO_CHANNEL} \
    telegrammessenger/proxy:latest

if [ $? -ne 0 ]; then
    print_color red "❌ Ошибка запуска обычного контейнера."
    exit 1
fi

# ══════════════════════════════════════════
# 8. Формирование информации для подключения
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
print_color yellow "⚙️  Конфигурация хранится в $CONFIG_FILE"
echo "   Вы можете изменить домен маскировки, порты или добавить промоканал"
echo "   и просто перезапустить скрипт."
