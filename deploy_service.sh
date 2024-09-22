#!/bin/bash

# Установка версии ASP.NET Core SDK по умолчанию, если не указана
DEFAULT_ASPNETCORE_VERSION="7.0"

# Переменные для аргументов
LISTEN_PORT=""
PROXY_PORT=""
APP_PATH=""
USER=""

# Функция вывода информации о правильном использовании скрипта
usage() {
    echo "Usage: $0 -p LISTEN_PORT PROXY_PORT -d APP_PATH [-u USER] [-v ASPNETCORE_VERSION]"
    echo "Example: sudo $0 -p 80 5000 -d /var/www/myapp/myapp.dll [-u www-data] -v 7.0"
    exit 1
}

# Разбор аргументов
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      LISTEN_PORT="$2"
      PROXY_PORT="$3"
      shift 3
      ;;
    -d)
      APP_PATH="$2"
      shift 2
      ;;
    -u)
      USER="$2"
      shift 2
      ;;
    -v)
      ASPNETCORE_VERSION="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

# Если версия не указана, используем значение по умолчанию
if [ -z "$ASPNETCORE_VERSION" ]; then
    ASPNETCORE_VERSION=$DEFAULT_ASPNETCORE_VERSION
    echo "Версия ASP.NET Core SDK не указана. Используется версия по умолчанию: $ASPNETCORE_VERSION"
fi

# Проверка на наличие всех обязательных аргументов
if [ -z "$LISTEN_PORT" ] || [ -z "$PROXY_PORT" ] || [ -z "$APP_PATH" ]; then
  usage
fi

# Извлечение имени приложения и папки из пути
APP_FOLDER=$(basename "$(dirname "$APP_PATH")")
APP_NAME=$(basename "$APP_PATH" .dll)
USER=$(stat -c '%U' "$APP_PATH")

# Проверка и установка Nginx, если он не установлен
if ! command -v nginx &> /dev/null; then
    echo "Nginx не установлен. Установка Nginx..."
    sudo apt-get update
    sudo apt-get install -y nginx
else
    echo "Nginx уже установлен."
fi

# Проверка, установлен ли .NET SDK или версия отличается
if ! command -v dotnet &> /dev/null || ! dotnet --list-sdks | grep -q "^$ASPNETCORE_VERSION"; then
    echo ".NET SDK не установлен или версия не совпадает. Установка .NET SDK версии $ASPNETCORE_VERSION..."

    # Обновление списка пакетов
    sudo apt-get update
    sudo apt-get install -y apt-transport-https

    # Установка выбранной версии .NET SDK
    sudo apt-get update
    sudo apt-get install -y dotnet-sdk-$ASPNETCORE_VERSION

    # Проверка успешной установки .NET SDK
    if command -v dotnet &> /dev/null && dotnet --list-sdks | grep -q "^$ASPNETCORE_VERSION"; then
        echo ".NET SDK версии $ASPNETCORE_VERSION успешно установлен."
    else
        echo "Ошибка при установке .NET SDK версии $ASPNETCORE_VERSION."
        exit 1
    fi
else
    echo ".NET SDK версии $ASPNETCORE_VERSION уже установлен."
fi

# Настройка Nginx
echo "Настройка Nginx..."

# Создание конфигурационного файла для сайта
NGINX_CONF="/etc/nginx/sites-available/$APP_FOLDER"

# Замена содержимого файла конфигурации Nginx
cat <<EOL > $NGINX_CONF
server {
    listen $LISTEN_PORT;
    server_name --;
    location / {
        proxy_pass http://localhost:$PROXY_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

# Проверка синтаксиса конфигурационного файла Nginx
echo "Проверка конфигурации Nginx..."
nginx -t

# Если конфигурация верна, создание символьной ссылки и перезагрузка Nginx
if [ $? -eq 0 ]; then
  # Проверка наличия символьной ссылки
  if [ -e /etc/nginx/sites-enabled/$APP_FOLDER.conf ]; then
    echo "Символьная ссылка для Nginx уже существует."
  else
    echo "Создание символьной ссылки для Nginx..."
    sudo ln -s $NGINX_CONF /etc/nginx/sites-enabled/$APP_FOLDER.conf
  fi
  
  echo "Перезагрузка Nginx для применения новых настроек..."
  sudo systemctl reload nginx
  echo "Настройки Nginx применены успешно."
else
  echo "Ошибка в конфигурации Nginx. Проверьте файл $NGINX_CONF."
  exit 1
fi

# Создание сервиса для приложения Kestrel
echo "Создание службы Kestrel для приложения..."

# Создание файла службы
cat <<EOL > /etc/systemd/system/kestrel-$APP_FOLDER.service
[Unit]
Description=$APP_FOLDER
[Service]
WorkingDirectory=/var/www/$APP_FOLDER
ExecStart=/usr/bin/dotnet /var/www/$APP_FOLDER/$APP_NAME.dll
Restart=always
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=dotnet-example
User=$USER
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
[Install]
WantedBy=multi-user.target
EOL

# Обновление прав доступа и перезапуск systemd
echo "Обновление системных служб и активация сервиса Kestrel..."

systemctl enable kestrel-$APP_FOLDER.service
systemctl start kestrel-$APP_FOLDER.service

# Проверка статуса службы
if [ $? -eq 0 ]; then
  echo "Сервис Kestrel успешно запущен и работает."
else
  echo "Ошибка при запуске службы Kestrel. Проверьте конфигурацию."
fi