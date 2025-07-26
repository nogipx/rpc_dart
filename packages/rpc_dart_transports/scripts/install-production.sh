#!/bin/bash
# RPC Dart Router - Production Installation Script
# Устанавливает роутер как systemd service

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Конфигурация
ROUTER_USER="rpc-router"
ROUTER_GROUP="rpc-router"
INSTALL_DIR="/opt/rpc-dart-router"
CONFIG_DIR="/etc/rpc-dart-router"
LOG_DIR="/var/log/rpc-dart-router"
RUN_DIR="/var/run/rpc-dart-router"
DATA_DIR="/var/lib/rpc-dart-router"

# Функции для вывода
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Этот скрипт должен запускаться с правами root"
    fi
}

# Проверка системы
check_system() {
    info "Проверка системы..."
    
    if ! command -v systemctl &> /dev/null; then
        error "systemd не найден. Этот скрипт работает только с systemd"
    fi
    
    if ! command -v dart &> /dev/null; then
        error "Dart SDK не найден. Установите Dart SDK перед продолжением"
    fi
    
    success "Система совместима"
}

# Создание пользователя
create_user() {
    info "Создание пользователя $ROUTER_USER..."
    
    if ! id "$ROUTER_USER" &>/dev/null; then
        useradd --system --shell /bin/false --home-dir "$DATA_DIR" --create-home "$ROUTER_USER"
        success "Пользователь $ROUTER_USER создан"
    else
        warning "Пользователь $ROUTER_USER уже существует"
    fi
}

# Создание директорий
create_directories() {
    info "Создание директорий..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$RUN_DIR"
    mkdir -p "$DATA_DIR"
    
    # Установка прав доступа
    chown -R "$ROUTER_USER:$ROUTER_GROUP" "$LOG_DIR"
    chown -R "$ROUTER_USER:$ROUTER_GROUP" "$RUN_DIR"
    chown -R "$ROUTER_USER:$ROUTER_GROUP" "$DATA_DIR"
    
    chmod 755 "$INSTALL_DIR"
    chmod 755 "$CONFIG_DIR"
    chmod 750 "$LOG_DIR"
    chmod 750 "$RUN_DIR"
    chmod 750 "$DATA_DIR"
    
    success "Директории созданы"
}

# Копирование файлов
install_files() {
    info "Установка файлов..."
    
    # Копируем исполняемые файлы
    cp -r bin/ "$INSTALL_DIR/"
    cp -r lib/ "$INSTALL_DIR/"
    cp pubspec.yaml "$INSTALL_DIR/"
    
    # Копируем конфигурацию
    if [[ -f "config/production.yaml" ]]; then
        cp config/production.yaml "$CONFIG_DIR/config.yaml"
        chown root:root "$CONFIG_DIR/config.yaml"
        chmod 644 "$CONFIG_DIR/config.yaml"
    fi
    
    # Устанавливаем права на исполняемые файлы
    chmod +x "$INSTALL_DIR/bin/rpc_dart_router.dart"
    
    success "Файлы установлены"
}

# Установка systemd service
install_service() {
    info "Установка systemd service..."
    
    if [[ -f "scripts/rpc-dart-router.service" ]]; then
        cp scripts/rpc-dart-router.service /etc/systemd/system/
        systemctl daemon-reload
        success "Systemd service установлен"
    else
        error "Файл service не найден: scripts/rpc-dart-router.service"
    fi
}

# Создание wrapper скрипта
create_wrapper() {
    info "Создание wrapper скрипта..."
    
    cat > "$INSTALL_DIR/bin/rpc_dart_router" << 'EOF'
#!/bin/bash
# RPC Dart Router Wrapper Script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROUTER_DIR"
exec dart run bin/rpc_dart_router.dart "$@"
EOF

    chmod +x "$INSTALL_DIR/bin/rpc_dart_router"
    
    # Создаем симлинк в /usr/local/bin
    ln -sf "$INSTALL_DIR/bin/rpc_dart_router" /usr/local/bin/rpc_dart_router
    
    success "Wrapper скрипт создан"
}

# Настройка logrotate
setup_logrotate() {
    info "Настройка logrotate..."
    
    cat > /etc/logrotate.d/rpc-dart-router << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 640 $ROUTER_USER $ROUTER_GROUP
    postrotate
        systemctl reload rpc-dart-router.service > /dev/null 2>&1 || true
    endscript
}
EOF

    success "Logrotate настроен"
}

# Включение и запуск service
enable_service() {
    info "Включение и запуск service..."
    
    systemctl enable rpc-dart-router.service
    systemctl start rpc-dart-router.service
    
    # Проверяем статус
    sleep 2
    if systemctl is-active --quiet rpc-dart-router.service; then
        success "RPC Dart Router запущен и работает"
    else
        error "Не удалось запустить RPC Dart Router. Проверьте логи: journalctl -u rpc-dart-router.service"
    fi
}

# Показать информацию о статусе
show_status() {
    info "Статус установки:"
    echo
    echo "🚀 RPC Dart Router установлен и запущен!"
    echo
    echo "📁 Директории:"
    echo "   • Установка: $INSTALL_DIR"
    echo "   • Конфигурация: $CONFIG_DIR"
    echo "   • Логи: $LOG_DIR"
    echo "   • Runtime: $RUN_DIR"
    echo "   • Данные: $DATA_DIR"
    echo
    echo "🔧 Управление:"
    echo "   • Статус: systemctl status rpc-dart-router"
    echo "   • Запуск: systemctl start rpc-dart-router"
    echo "   • Остановка: systemctl stop rpc-dart-router"
    echo "   • Перезагрузка: systemctl reload rpc-dart-router"
    echo "   • Логи: journalctl -u rpc-dart-router -f"
    echo
    echo "📝 Конфигурация: $CONFIG_DIR/config.yaml"
    echo "📊 Логи: $LOG_DIR/router.log"
    echo
    echo "💡 CLI команды:"
    echo "   • rpc_dart_router --help"
    echo "   • rpc_dart_router --daemon-status"
    echo
}

# Основная функция
main() {
    echo "🚀 RPC Dart Router - Production Installation"
    echo "============================================="
    echo
    
    check_root
    check_system
    create_user
    create_directories
    install_files
    create_wrapper
    install_service
    setup_logrotate
    enable_service
    show_status
    
    success "Установка завершена успешно!"
}

# Запуск
main "$@" 