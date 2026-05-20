#!/bin/bash

# --- Проверка прав суперпользователя ---
if [[ $EUID -ne 0 ]]; then
   echo "Этот скрипт нужно запускать с правами root (sudo)." 
   exit 1
fi

# --- Настройки (можно менять) ---
CONTAINER_NAME="mtproto-proxy"
FAKE_TLS_DOMAIN="ya.ru" # Домен для маскировки трафика (ya.ru, 1c.ru и т.д.)
HOST_PORT="443"         # Желаемый порт
ALT_PORT="8443"         # Альтернативный порт, если основной занят

# --- Вспомогательные функции ---
# Функция для цветного вывода
print_color() {
    local color=$1
    local message=$2
    case $color in
        "green") echo -e "\033[0;32m${message}\033[0m" ;;
        "red") echo -e "\033[0;31m${message}\033[0m" ;;
        "yellow") echo -e "\033[1;33m${message}\033[0m" ;;
        "blue") echo -e "\033[0;34m${message}\033[0m" ;;
        *) echo "${message}" ;;
    esac
}

# --- Шаг 1: Установка Docker ---
if ! command -v docker &> /dev/null; then
    print_color "yellow" "🐳 Docker не найден. Устанавливаем..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
    systemctl enable --now docker
    print_color "green" "✅ Docker установлен."
else
    print_color "green" "🐳 Docker уже установлен."
fi

# --- Шаг 2: Получение внешнего IP-адреса ---
print_color "yellow" "🌐 Определяем внешний IP-адрес..."
SERVER_IP=$(curl -s ifconfig.me)
if [[ -z "$SERVER_IP" ]]; then
    print_color "red" "❌ Не удалось определить IP-адрес. Проверьте интернет-соединение."
    exit 1
fi
print_color "blue" "   Ваш IP: ${SERVER_IP}"

# --- Шаг 3: Выбор порта ---
print_color "yellow" "🔌 Проверяем доступность порта ${HOST_PORT}..."
if ss -tuln | grep -q ":${HOST_PORT} "; then
    print_color "yellow" "⚠️ Порт ${HOST_PORT} занят. Будет использован порт ${ALT_PORT}."
    PORT_TO_USE=$ALT_PORT
else
    print_color "green" "✅ Порт ${HOST_PORT} свободен."
    PORT_TO_USE=$HOST_PORT
fi

# --- Шаг 4: Генерация секрета ---
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
print_color "blue" "🔑 Секрет для подключения: ${SECRET}"

# --- Шаг 5: Настройка и запуск контейнера ---
print_color "yellow" "🛠️ Запускаем Docker-контейнер..."
docker pull arm64builds/mtproxy:latest
docker run -d \
    --name ${CONTAINER_NAME} \
    --restart always \
    -p ${PORT_TO_USE}:8888 \
    -e SECRET=${SECRET} \
    -e FAKE_TLS_DOMAIN=${FAKE_TLS_DOMAIN} \
    arm64builds/mtproxy:latest

if [ $? -eq 0 ]; then
    print_color "green" "✅ Прокси-сервер успешно запущен."
else
    print_color "red" "❌ Ошибка при запуске контейнера. Проверьте логи: docker logs ${CONTAINER_NAME}"
    exit 1
fi

# --- Шаг 6: Формирование и вывод ссылки для подключения ---
# Ссылка формата: tg://proxy?server=<IP>&port=<PORT>&secret=<SECRET>
CONNECTION_URL="tg://proxy?server=${SERVER_IP}&port=${PORT_TO_USE}&secret=${SECRET}"

echo ""
print_color "green" "🎉 Ваш MTProto прокси с FakeTLS готов к работе!"
echo "----------------------------------------"
print_color "blue" "🔗 Ссылка для подключения:"
echo "   ${CONNECTION_URL}"
echo ""
print_color "yellow" "📋 Как подключиться:"
echo "   1. Откройте Telegram."
echo "   2. Перейдите в: Настройки -> Продвинутые настройки -> Тип соединения -> Использовать собственный прокси."
echo "   3. Нажмите 'Добавить прокси' и вставьте скопированную ссылку."
echo ""
print_color "yellow" "📝 Для просмотра логов: docker logs ${CONTAINER_NAME}"
echo ""
