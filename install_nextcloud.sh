#!/bin/bash
# Improved Nextcloud install script for Raspberry Pi (Debian-based)
# Enhanced security, error handling, and configuration options
set -euo pipefail

#########################
# CONFIGURATION
#########################
# Nextcloud version (specify for reproducible installs)
NEXTCLOUD_VERSION="28.0.2"
NEXTCLOUD_URL="https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"

# Admin credentials (will be prompted for)
NEXTCLOUD_ADMIN_USER=""
NEXTCLOUD_ADMIN_PASS=""

# Database configuration
DB_NAME="nextcloud"
DB_USER="nextclouduser"
DB_PASS=""
DB_ROOT_PASS=""

# Web directory
WEB_DIR="/var/www/html"
NEXTCLOUD_DIR="$WEB_DIR/nextcloud"

# PHP settings
PHP_MEMORY_LIMIT="512M"
PHP_UPLOAD_LIMIT="1G"
PHP_POST_LIMIT="1G"
PHP_EXECUTION_TIME="300"

# Backup directory
BACKUP_DIR="/tmp/nextcloud_install_backup_$(date +%Y%m%d_%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#########################
# FUNCTIONS
#########################
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

generate_password() {
    openssl rand -base64 16 | tr -d "=+/" | cut -c1-12
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root for security reasons"
    fi
}

check_dependencies() {
    log "Checking dependencies..."
    command -v sudo >/dev/null 2>&1 || error "sudo is required but not installed"
    command -v wget >/dev/null 2>&1 || sudo apt install -y wget
    command -v openssl >/dev/null 2>&1 || sudo apt install -y openssl
}

backup_existing_configs() {
    log "Creating backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    # Backup existing Apache configs
    if [[ -f /etc/apache2/sites-available/nextcloud.conf ]]; then
        warn "Existing Nextcloud Apache config found, backing up..."
        sudo cp /etc/apache2/sites-available/nextcloud.conf "$BACKUP_DIR/"
    fi
    
    # Backup PHP config
    local php_ini=$(php -i 2>/dev/null | grep "Loaded Configuration" | awk '{print $5}' || echo "")
    if [[ -n "$php_ini" && -f "$php_ini" ]]; then
        sudo cp "$php_ini" "$BACKUP_DIR/php.ini.backup"
    fi
}

prompt_credentials() {
    echo
    echo "🔐 Nextcloud Admin Account Setup"
    echo "================================"
    
    # Get admin username
    while [[ -z "$NEXTCLOUD_ADMIN_USER" ]]; do
        echo -n "Enter admin username (default: admin): "
        read -r input_user
        NEXTCLOUD_ADMIN_USER="${input_user:-admin}"
        
        if [[ ! "$NEXTCLOUD_ADMIN_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            warn "Username can only contain letters, numbers, hyphens, and underscores"
            NEXTCLOUD_ADMIN_USER=""
        fi
    done
    
    # Get admin password
    while [[ -z "$NEXTCLOUD_ADMIN_PASS" ]]; do
        echo -n "Enter admin password (visible): "
        read -r NEXTCLOUD_ADMIN_PASS
        
        if [[ ${#NEXTCLOUD_ADMIN_PASS} -lt 8 ]]; then
            warn "Password must be at least 8 characters long"
            NEXTCLOUD_ADMIN_PASS=""
            continue
        fi
        
        echo -n "Confirm admin password: "
        read -r confirm_pass
        
        if [[ "$NEXTCLOUD_ADMIN_PASS" != "$confirm_pass" ]]; then
            warn "Passwords do not match, please try again"
            NEXTCLOUD_ADMIN_PASS=""
        fi
    done
    
    success "Admin credentials set for user: $NEXTCLOUD_ADMIN_USER"
    echo
}

generate_credentials() {
    log "Setting up remaining credentials..."
    
    if [[ -z "$DB_PASS" ]]; then
        DB_PASS=$(generate_password)
        warn "Generated database password: $DB_PASS"
    fi
    
    if [[ -z "$DB_ROOT_PASS" ]]; then
        DB_ROOT_PASS=$(generate_password)
        warn "Generated MariaDB root password: $DB_ROOT_PASS"
    fi
    
    # Save credentials securely
    cat > "$BACKUP_DIR/credentials.txt" <<EOF
Nextcloud Admin User: $NEXTCLOUD_ADMIN_USER
Nextcloud Admin Password: $NEXTCLOUD_ADMIN_PASS
Database Name: $DB_NAME
Database User: $DB_USER
Database Password: $DB_PASS
MariaDB Root Password: $DB_ROOT_PASS
Installation Date: $(date)
EOF
    chmod 600 "$BACKUP_DIR/credentials.txt"
    success "All credentials saved to: $BACKUP_DIR/credentials.txt"
}

install_packages() {
    log "Updating system packages..."
    sudo apt update && sudo apt upgrade -y
    
    log "Installing required packages..."
    sudo DEBIAN_FRONTEND=noninteractive apt install -y \
        apache2 \
        mariadb-server \
        libapache2-mod-php \
        php \
        php-gd \
        php-json \
        php-mysql \
        php-curl \
        php-mbstring \
        php-intl \
        php-imagick \
        php-xml \
        php-zip \
        php-bcmath \
        php-gmp \
        php-redis \
        php-apcu \
        php-opcache \
        unzip \
        curl \
        certbot \
        python3-certbot-apache
    
    success "Packages installed successfully"
}

secure_mariadb() {
    log "Securing MariaDB installation..."
    
    # Set root password and secure installation
    sudo mysql -u root <<EOF
UPDATE mysql.user SET Password=PASSWORD('$DB_ROOT_PASS') WHERE User='root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF
    
    success "MariaDB secured"
}

setup_database() {
    log "Creating Nextcloud database and user..."
    
    mysql -u root -p"$DB_ROOT_PASS" <<EOF
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    
    success "Database configured"
}

download_nextcloud() {
    log "Downloading Nextcloud $NEXTCLOUD_VERSION..."
    
    cd /tmp
    rm -f nextcloud-*.tar.bz2*
    
    wget "$NEXTCLOUD_URL"
    wget "$NEXTCLOUD_URL.sha256"
    
    # Verify checksum
    if sha256sum -c "nextcloud-${NEXTCLOUD_VERSION}.tar.bz2.sha256"; then
        success "Nextcloud download verified"
    else
        error "Nextcloud download verification failed"
    fi
    
    log "Extracting Nextcloud..."
    tar -xjf "nextcloud-${NEXTCLOUD_VERSION}.tar.bz2"
}

install_nextcloud() {
    log "Installing Nextcloud files..."
    
    # Remove existing installation if present
    if [[ -d "$NEXTCLOUD_DIR" ]]; then
        warn "Existing Nextcloud installation found, backing up..."
        sudo mv "$NEXTCLOUD_DIR" "$BACKUP_DIR/nextcloud_old"
    fi
    
    sudo mv /tmp/nextcloud "$NEXTCLOUD_DIR"
    
    log "Setting file permissions..."
    sudo chown -R www-data:www-data "$NEXTCLOUD_DIR"
    sudo find "$NEXTCLOUD_DIR" -type d -exec chmod 750 {} \;
    sudo find "$NEXTCLOUD_DIR" -type f -exec chmod 640 {} \;
    
    success "Nextcloud files installed"
}

configure_apache() {
    log "Configuring Apache..."
    
    # Create Nextcloud Apache configuration
    sudo tee /etc/apache2/sites-available/nextcloud.conf > /dev/null <<EOF
<VirtualHost *:80>
    DocumentRoot $NEXTCLOUD_DIR
    ServerName $(hostname -I | awk '{print $1}')
    
    <Directory $NEXTCLOUD_DIR/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
        
        SetEnv HOME $NEXTCLOUD_DIR
        SetEnv HTTP_HOME $NEXTCLOUD_DIR
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF
    
    # Enable site and required modules
    sudo a2ensite nextcloud.conf
    sudo a2enmod rewrite headers env dir mime setenvif ssl
    
    # Disable default site to avoid conflicts
    sudo a2dissite 000-default
    
    sudo systemctl reload apache2
    success "Apache configured"
}

configure_php() {
    log "Configuring PHP..."
    
    local php_version=$(php -v | head -n1 | cut -d' ' -f2 | cut -d'.' -f1-2)
    local php_ini="/etc/php/$php_version/apache2/php.ini"
    
    if [[ ! -f "$php_ini" ]]; then
        error "PHP configuration file not found: $php_ini"
    fi
    
    # Create PHP configuration for Nextcloud
    sudo tee "/etc/php/$php_version/apache2/conf.d/99-nextcloud.ini" > /dev/null <<EOF
; Nextcloud PHP Configuration
memory_limit = $PHP_MEMORY_LIMIT
upload_max_filesize = $PHP_UPLOAD_LIMIT
post_max_size = $PHP_POST_LIMIT
max_execution_time = $PHP_EXECUTION_TIME
max_input_time = 300
max_input_vars = 3000
file_uploads = On

; OPcache settings
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=1
opcache.save_comments=1

; APCu settings
apc.enable_cli=1
EOF
    
    sudo systemctl restart apache2
    success "PHP configured"
}

run_nextcloud_installer() {
    log "Running Nextcloud installation..."
    
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" maintenance:install \
        --database "mysql" \
        --database-name "$DB_NAME" \
        --database-user "$DB_USER" \
        --database-pass "$DB_PASS" \
        --database-host "localhost" \
        --admin-user "$NEXTCLOUD_ADMIN_USER" \
        --admin-pass "$NEXTCLOUD_ADMIN_PASS" \
        --data-dir "$NEXTCLOUD_DIR/data"
    
    success "Nextcloud installation completed"
}

configure_nextcloud() {
    log "Applying additional Nextcloud configuration..."
    
    # Set trusted domains
    local server_ip=$(hostname -I | awk '{print $1}')
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set trusted_domains 0 --value="localhost"
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set trusted_domains 1 --value="$server_ip"
    
    # Configure caching
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set memcache.local --value="\\OC\\Memcache\\APCu"
    
    # Set default phone region (adjust as needed)
    sudo -u www-data php "$NEXTCLOUD_DIR/occ" config:system:set default_phone_region --value="US"
    
    success "Nextcloud configured"
}

setup_firewall() {
    log "Configuring firewall..."
    
    if command -v ufw >/dev/null 2>&1; then
        sudo ufw allow 80/tcp
        sudo ufw allow 443/tcp
        success "Firewall rules added for HTTP and HTTPS"
    else
        warn "UFW not installed, skipping firewall configuration"
    fi
}

display_results() {
    echo
    success "=== Nextcloud Installation Complete! ==="
    echo
    echo "📋 Installation Summary:"
    echo "  • Nextcloud Version: $NEXTCLOUD_VERSION"
    echo "  • Installation Directory: $NEXTCLOUD_DIR"
    echo "  • Admin Username: $NEXTCLOUD_ADMIN_USER"
    echo "  • Database Name: $DB_NAME"
    echo "  • Database User: $DB_USER"
    echo
    echo "🌐 Access your Nextcloud:"
    echo "  • Local: http://localhost/nextcloud"
    echo "  • Network: http://$(hostname -I | awk '{print $1}')/nextcloud"
    echo
    echo "🔐 Credentials saved to: $BACKUP_DIR/credentials.txt"
    echo
    echo "🚀 Next Steps:"
    echo "  1. Access Nextcloud in your browser"
    echo "  2. Consider setting up HTTPS with: sudo certbot --apache"
    echo "  3. Configure external access in your router if needed"
    echo "  4. Set up regular backups"
    echo
    warn "Your custom admin credentials have been configured securely!"
    warn "All passwords are saved in: $BACKUP_DIR/credentials.txt"
}

cleanup() {
    log "Cleaning up temporary files..."
    rm -f /tmp/nextcloud-*.tar.bz2*
    rm -rf /tmp/nextcloud
}

#########################
# MAIN EXECUTION
#########################
main() {
    echo "🚀 Starting Improved Nextcloud Installation"
    echo "============================================"
    
    check_root
    check_dependencies
    prompt_credentials
    backup_existing_configs
    generate_credentials
    install_packages
    secure_mariadb
    setup_database
    download_nextcloud
    install_nextcloud
    configure_apache
    configure_php
    run_nextcloud_installer
    configure_nextcloud
    setup_firewall
    cleanup
    display_results
}

# Run main function
main "$@"