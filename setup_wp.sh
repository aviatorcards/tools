#!/bin/bash

if [ "$EUID" -ne 0 ]; then 
  echo "Please run as root (use sudo)"
  exit 1
fi

export PATH="/usr/local/bin:$PATH"

read -p "Enter the domain name (e.g., site.com): " DOMAIN
read -p "Enter admin email (default: tristan@fddl.dev): " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-tristan@fddl.dev}

LAST_PORT=$(grep "^Listen" /etc/httpd/conf.d/ports.conf 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
LAST_PORT=${LAST_PORT:-8079}
PORT=$((LAST_PORT + 1))

echo "------------------------------------------"
echo "Setting up $DOMAIN on Port $PORT"
echo "------------------------------------------"

DB_NAME=$(echo $DOMAIN | tr ".-" "__")
DB_USER="${DB_NAME}_user"
DB_PASS=$(openssl rand -base64 12)

if mysql -e "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DB_NAME'" 2>/dev/null | grep -q "$DB_NAME"; then
    echo "Warning: Database $DB_NAME already exists."
    read -p "Would you like to DROP the existing database and user? (y/N): " CONFIRM_DB
    if [[ "$CONFIRM_DB" =~ ^[Yy]$ ]]; then
        mysql -e "DROP DATABASE \`$DB_NAME\`;"
        mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
        echo "Existing database and user removed."
    else
        echo "Setup aborted to protect existing database."
        exit 1
    fi
fi

mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\`;"
mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 
mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

WEB_DIR="/mnt/storage/www/$DOMAIN"
WP_ARCHIVE_TAR="/mnt/storage/www/latest.tar.gz"
WP_ARCHIVE_ZIP="/mnt/storage/www/latest.zip"

if [ -d "$WEB_DIR" ]; then
    echo "Warning: Directory $WEB_DIR already exists."
    read -p "Would you like to REMOVE the existing directory? (y/N): " CONFIRM_DIR
    if [[ "$CONFIRM_DIR" =~ ^[Yy]$ ]]; then
        rm -rf "$WEB_DIR"
        echo "Existing directory removed."
    else
        echo "Setup aborted to protect existing directory."
        exit 1
    fi
fi

mkdir -p "$WEB_DIR"
if [ -f "$WP_ARCHIVE_TAR" ]; then
    tar -xzf "$WP_ARCHIVE_TAR" -C "$WEB_DIR" --strip-components=1
elif [ -f "$WP_ARCHIVE_ZIP" ]; then
    EXTRACT_TMP=$(mktemp -d)
    unzip -q "$WP_ARCHIVE_ZIP" -d "$EXTRACT_TMP"
    mv "$EXTRACT_TMP"/wordpress/* "$WEB_DIR/"
    rm -rf "$EXTRACT_TMP"
else
    wp core download --path="$WEB_DIR" --allow-root
fi

cd "$WEB_DIR"
wp config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --allow-root --extra-php <<PHP
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
PHP

CONF_FILE="/etc/httpd/conf.d/$DOMAIN.conf"
if [ -f "$CONF_FILE" ]; then
    echo "Warning: Apache config $CONF_FILE already exists."
    read -p "Overwrite? (y/N): " CONFIRM_CONF
    if [[ ! "$CONFIRM_CONF" =~ ^[Yy]$ ]]; then
        echo "Setup aborted to protect existing config."
        exit 1
    fi
fi

cat <<APACHE > "$CONF_FILE"
<VirtualHost *:$PORT>
    ServerName $DOMAIN
    DocumentRoot $WEB_DIR
    <Directory $WEB_DIR>
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog /var/log/httpd/${DOMAIN}_error.log
    CustomLog /var/log/httpd/${DOMAIN}_access.log combined
</VirtualHost>
APACHE

if ! grep -q "Listen $PORT" /etc/httpd/conf.d/ports.conf; then
    echo "Listen $PORT" >> /etc/httpd/conf.d/ports.conf
fi

if command -v semanage > /dev/null; then
    if ! semanage port -l | grep "^http_port_t" | grep -qP "\b$PORT\b"; then
        if semanage port -l | grep -qP "\b$PORT\b"; then
            semanage port -m -t http_port_t -p tcp $PORT
        else
            semanage port -a -t http_port_t -p tcp $PORT
        fi
    fi
fi

ADMIN_PASS=$(openssl rand -base64 16)
wp core install --url="https://$DOMAIN" --title="$DOMAIN" --admin_user="tristan" --admin_password="$ADMIN_PASS" --admin_email="$ADMIN_EMAIL" --skip-email --allow-root

wp plugin install wordfence --activate --allow-root

cat <<WAF > "$WEB_DIR/wordfence-waf.php"
<?php
if (file_exists('$WEB_DIR/wp-content/plugins/wordfence/waf/bootstrap.php')) {
    define('WFWAF_LOG_PATH', '$WEB_DIR/wp-content/wflogs/');
    include_once '$WEB_DIR/wp-content/plugins/wordfence/waf/bootstrap.php';
}
?>
WAF

chown -R apache:apache "$WEB_DIR"
find "$WEB_DIR" -type d -exec chmod 755 {} \;
find "$WEB_DIR" -type f -exec chmod 644 {} \;
restorecon -Rv "$WEB_DIR" > /dev/null

systemctl restart httpd php-fpm

echo "------------------------------------------"
echo "SETUP COMPLETE"
echo "------------------------------------------"
echo "Domain:   https://$DOMAIN"
echo "Port:     $PORT"
echo "DB Name:  $DB_NAME"
echo "DB User:  $DB_USER"
echo "DB Pass:  $DB_PASS"
echo "Admin:    tristan"
echo "Pass:     $ADMIN_PASS"
echo "------------------------------------------"
echo "ACTION REQUIRED: Map $DOMAIN to http://localhost:$PORT in Cloudflare."
