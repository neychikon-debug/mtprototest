#!/bin/bash
set -e

# ========== Цвета для вывода ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ========== Проверка Docker ==========
if ! command -v docker &> /dev/null; then
    error "Docker не установлен. Установите Docker: curl -fsSL https://get.docker.com | sh"
fi
if ! docker info &> /dev/null; then
    error "Docker не запущен. Запустите: systemctl start docker"
fi

# ========== Внешний IP ==========
get_public_ip() {
    for service in ifconfig.me icanhazip.com ipinfo.io/ip api.ipify.org; do
        ip=$(curl -s --max-time 5 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        [[ -n "$ip" ]] && echo "$ip" && return
    done
    echo ""
}
info "Определяем внешний IP..."
PUBLIC_IP=$(get_public_ip)
[[ -z "$PUBLIC_IP" ]] && error "Не удалось определить внешний IP. Проверьте интернет."
info "Ваш IP: $PUBLIC_IP"

# ========== Порт ==========
read -p "Введите порт для прокси (1024-65535, по умолчанию 1080): " PORT
PORT=${PORT:-1080}
[[ ! "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ] && error "Порт должен быть числом от 1024 до 65535."

# ========== Аутентификация (исправлено) ==========
read -p "Использовать логин/пароль? (y/N): " USE_AUTH
USE_AUTH=${USE_AUTH,,}
AUTH_ENABLED=false
PROXY_USER=""
PROXY_PASS=""
if [[ "$USE_AUTH" == "y" || "$USE_AUTH" == "yes" ]]; then
    AUTH_ENABLED=true
    while [[ -z "$PROXY_USER" ]]; do
        read -p "Логин: " PROXY_USER
        [[ -z "$PROXY_USER" ]] && warn "Логин не может быть пустым"
    done
    while [[ -z "$PROXY_PASS" ]]; do
        read -s -p "Пароль: " PROXY_PASS
        echo ""
        [[ -z "$PROXY_PASS" ]] && warn "Пароль не может быть пустым"
    done
    info "Аутентификация включена (логин: $PROXY_USER)"
else
    warn "Прокси будет без аутентификации. Это небезопасно!"
fi

# ========== Запуск контейнера ==========
CONTAINER_NAME="socks5-proxy-${PORT}"
docker stop "$CONTAINER_NAME" 2>/dev/null && docker rm "$CONTAINER_NAME" 2>/dev/null || true

DOCKER_OPTS=(
    run -d
    --name "$CONTAINER_NAME"
    --restart unless-stopped
    -p "$PORT:1080"
)

if $AUTH_ENABLED; then
    DOCKER_OPTS+=(-e PROXY_USER="$PROXY_USER" -e PROXY_PASSWORD="$PROXY_PASS")
fi

DOCKER_OPTS+=(serjs/go-socks5-proxy)

if ! docker "${DOCKER_OPTS[@]}"; then
    error "Не удалось запустить контейнер. Возможно, порт $PORT уже занят."
fi

sleep 2
if ! docker ps | grep -q "$CONTAINER_NAME"; then
    error "Контейнер не запустился. Логи: docker logs $CONTAINER_NAME"
fi

info "✅ SOCKS5 прокси запущен!"

# ========== Формирование данных подключения ==========
if $AUTH_ENABLED; then
    CONNECTION_STRING="socks5://${PROXY_USER}:${PROXY_PASS}@${PUBLIC_IP}:${PORT}"
    INFO_TEXT="IP: $PUBLIC_IP\nПорт: $PORT\nЛогин: $PROXY_USER\nПароль: $PROXY_PASS"
else
    CONNECTION_STRING="socks5://${PUBLIC_IP}:${PORT}"
    INFO_TEXT="IP: $PUBLIC_IP\nПорт: $PORT\nБез аутентификации"
fi

echo ""
echo "==========================================="
echo -e "${GREEN}📡 Данные для подключения:${NC}"
echo -e "${YELLOW}$INFO_TEXT${NC}"
echo "Строка подключения: $CONNECTION_STRING"
echo "==========================================="
echo ""

# Сохраняем в файл
FILENAME="socks5_${PORT}_$(date +%Y%m%d_%H%M%S).txt"
cat > "$FILENAME" <<EOF
SOCKS5 Proxy Info
Created: $(date)
IP: $PUBLIC_IP
Port: $PORT
$(if $AUTH_ENABLED; then echo "Username: $PROXY_USER\nPassword: $PROXY_PASS"; else echo "Authentication: none"; fi)
Connection string: $CONNECTION_STRING
EOF
info "Данные сохранены в $FILENAME"

# ========== Telegram бот (управление) ==========
read -p "📱 Настроить управление через Telegram-бота? (y/N): " SETUP_BOT
SETUP_BOT=${SETUP_BOT,,}
if [[ "$SETUP_BOT" != "y" && "$SETUP_BOT" != "yes" ]]; then
    info "Готово! Прокси работает. Для остановки: docker stop $CONTAINER_NAME"
    exit 0
fi

# Проверяем Python
if ! command -v python3 &> /dev/null; then
    warn "Python3 не найден. Устанавливаем..."
    apt update && apt install -y python3 python3-pip
fi

# Устанавливаем библиотеку для бота
pip3 install pyTelegramBotAPI --quiet

# Запрашиваем токен бота
read -p "Введите токен бота (от @BotFather): " BOT_TOKEN
[[ -z "$BOT_TOKEN" ]] && error "Токен обязателен"

# Запрашиваем admin chat_id (тот, кто сможет управлять)
read -p "Введите ваш Telegram Chat ID (получить у @userinfobot): " ADMIN_CHAT_ID
[[ -z "$ADMIN_CHAT_ID" ]] && error "Chat ID обязателен"

# Создаём Python бота с админ-листом и функциями управления прокси
BOT_SCRIPT="/opt/socks5_bot.py"
sudo tee "$BOT_SCRIPT" > /dev/null <<EOF
#!/usr/bin/env python3
import telebot
import subprocess
import os
import time

BOT_TOKEN = "$BOT_TOKEN"
ADMIN_IDS = [$ADMIN_CHAT_ID]  # можно добавлять других через команду
CONTAINER_NAME = "$CONTAINER_NAME"
PORT = "$PORT"
PUBLIC_IP = "$PUBLIC_IP"
AUTH_ENABLED = $AUTH_ENABLED
PROXY_USER = "$PROXY_USER"
PROXY_PASS = "$PROXY_PASS"

bot = telebot.TeleBot(BOT_TOKEN)

def is_admin(chat_id):
    return chat_id in ADMIN_IDS

def send_status(chat_id):
    cmd = ["docker", "ps", "--filter", f"name={CONTAINER_NAME}", "--format", "{{.Status}}"]
    try:
        status = subprocess.check_output(cmd).decode().strip()
        if "Up" in status:
            text = f"✅ Прокси работает\nСтатус: {status}\n"
            text += f"🔗 {PUBLIC_IP}:{PORT}\n"
            if AUTH_ENABLED:
                text += f"👤 {PROXY_USER}:{PROXY_PASS}"
            else:
                text += "⚠️ Без пароля"
        else:
            text = f"❌ Прокси остановлен\nСтатус: {status}"
    except:
        text = "❌ Контейнер не найден"
    bot.send_message(chat_id, text)

@bot.message_handler(commands=['start'])
def start_cmd(message):
    if not is_admin(message.chat.id):
        bot.reply_to(message, "⛔ Доступ запрещён")
        return
    bot.reply_to(message, "🔐 SOCKS5 Manager\n/status — статус\n/restart — перезапустить\n/stop — остановить\n/start — запустить\n/setpass логин пароль — сменить пароль\n/addadmin id — добавить админа\n/removeadmin id — удалить админа")

@bot.message_handler(commands=['status'])
def status_cmd(message):
    if not is_admin(message.chat.id):
        return
    send_status(message.chat.id)

@bot.message_handler(commands=['restart'])
def restart_cmd(message):
    if not is_admin(message.chat.id):
        return
    subprocess.run(["docker", "restart", CONTAINER_NAME])
    time.sleep(2)
    send_status(message.chat.id)

@bot.message_handler(commands=['stop'])
def stop_cmd(message):
    if not is_admin(message.chat.id):
        return
    subprocess.run(["docker", "stop", CONTAINER_NAME])
    bot.reply_to(message, "⏹️ Прокси остановлен")

@bot.message_handler(commands=['start'])
def start_container(message):
    if not is_admin(message.chat.id):
        return
    subprocess.run(["docker", "start", CONTAINER_NAME])
    time.sleep(2)
    send_status(message.chat.id)

@bot.message_handler(commands=['setpass'])
def setpass_cmd(message):
    if not is_admin(message.chat.id):
        return
    args = message.text.split()
    if len(args) != 3:
        bot.reply_to(message, "Использование: /setpass логин пароль")
        return
    new_user, new_pass = args[1], args[2]
    # Обновляем контейнер
    subprocess.run(["docker", "stop", CONTAINER_NAME])
    subprocess.run(["docker", "rm", CONTAINER_NAME])
    cmd = ["docker", "run", "-d", "--name", CONTAINER_NAME, "--restart", "unless-stopped", "-p", f"{PORT}:1080", "-e", f"PROXY_USER={new_user}", "-e", f"PROXY_PASSWORD={new_pass}", "serjs/go-socks5-proxy"]
    subprocess.run(cmd)
    time.sleep(2)
    bot.reply_to(message, f"✅ Пароль изменён на {new_user}:{new_pass}\nПерезапуск...")
    # Обновляем глобальные переменные (просто для информации)
    global PROXY_USER, PROXY_PASS
    PROXY_USER = new_user
    PROXY_PASS = new_pass

@bot.message_handler(commands=['addadmin'])
def addadmin_cmd(message):
    if not is_admin(message.chat.id):
        return
    args = message.text.split()
    if len(args) != 2:
        bot.reply_to(message, "Использование: /addadmin chat_id")
        return
    new_id = int(args[1])
    if new_id not in ADMIN_IDS:
        ADMIN_IDS.append(new_id)
        bot.reply_to(message, f"✅ Админ {new_id} добавлен")
    else:
        bot.reply_to(message, "Уже в списке")

@bot.message_handler(commands=['removeadmin'])
def removeadmin_cmd(message):
    if not is_admin(message.chat.id):
        return
    args = message.text.split()
    if len(args) != 2:
        bot.reply_to(message, "Использование: /removeadmin chat_id")
        return
    remove_id = int(args[1])
    if remove_id in ADMIN_IDS and remove_id != ADMIN_IDS[0]:
        ADMIN_IDS.remove(remove_id)
        bot.reply_to(message, f"❌ Админ {remove_id} удалён")
    else:
        bot.reply_to(message, "Нельзя удалить главного админа или такого нет")

print("Бот запущен и слушает команды...")
bot.polling(none_stop=True)
EOF

sudo chmod +x "$BOT_SCRIPT"

# Создаём systemd сервис для автозапуска бота
SERVICE_FILE="/etc/systemd/system/socks5-bot.service"
sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=SOCKS5 Telegram Bot
After=network.target docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/python3 $BOT_SCRIPT
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable socks5-bot.service
sudo systemctl start socks5-bot.service

info "✅ Telegram-бот установлен и запущен. Администратор: $ADMIN_CHAT_ID"
info "Бот отвечает на команды: /status, /restart, /stop, /setpass, /addadmin, /removeadmin"
info "Прокси и бот будут автоматически перезапускаться при перезагрузке сервера."

echo ""
info "Всё готово! Данные прокси сохранены в $FILENAME"
