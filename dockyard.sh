#!/usr/bin/env bash

# =============================================================================
# Dockyard - PHP project setup tool with automatic port assignment,
# SSL certificates, local domain configuration, and multi-PHP version support.
# =============================================================================

set -euo pipefail

readonly VERSION="0.1.0"
readonly REGISTRY_DIR="${HOME}/.config/dockyard"
readonly REGISTRY_FILE="${REGISTRY_DIR}/projects.conf"

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# Supported PHP versions (legacy only)
readonly PHP_VERSIONS=("5.6" "7.0" "7.1" "7.2" "7.3")
readonly DEFAULT_PHP_VERSION="7.3"

# Project types
readonly PROJECT_TYPES=("laravel" "cakephp" "generic")

# =============================================================================
# Logging helpers
# =============================================================================

log_info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
log_success() { echo -e "${GREEN}✔${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
log_error()   { echo -e "${RED}✖${NC}  $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}==>${NC}${BOLD} $*${NC}"; }
log_header()  {
    echo ""
    echo -e "${BOLD}${CYAN}┌─────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│           ⚓  Dockyard v${VERSION}             │${NC}"
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────┘${NC}"
    echo ""
}

# =============================================================================
# Utility functions
# =============================================================================

command_exists() { command -v "$1" &>/dev/null; }

is_docker_running() {
    docker info &>/dev/null 2>&1
}

detect_proxy_tool() {
    if command_exists herd; then
        echo "herd"
    elif command_exists valet; then
        echo "valet"
    else
        echo "none"
    fi
}

get_project_name() {
    basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g'
}

port_in_registry() {
    local port="$1"
    [[ -f "$REGISTRY_FILE" ]] && grep -q "=$port$" "$REGISTRY_FILE"
}

port_in_use() {
    local port="$1"
    # Check via /dev/tcp first (bash built-in, no deps)
    if (echo >/dev/tcp/localhost/"$port") 2>/dev/null; then
        return 0
    fi
    # Fallback to lsof
    if command_exists lsof && lsof -Pi :"$port" -sTCP:LISTEN &>/dev/null; then
        return 0
    fi
    return 1
}

find_available_port() {
    local base_port="$1"
    local port="$base_port"

    while port_in_registry "$port" || port_in_use "$port"; do
        port=$((port + 1))
    done

    echo "$port"
}

normalize_port() {
    # Convert standard ports to 4-digit ports ending in 00
    # 80 → 8000, 3306 → 3300, 5432 → 5400, 6379 → 6300, 5173 → 5100
    local port="$1"
    case "$port" in
        80)   echo "8000" ;;
        3306) echo "3300" ;;
        5432) echo "5400" ;;
        6379) echo "6300" ;;
        5173) echo "5100" ;;
        *)    echo "$port" ;;
    esac
}

# =============================================================================
# Registry helpers
# =============================================================================

registry_init() {
    mkdir -p "$REGISTRY_DIR"
    touch "$REGISTRY_FILE"
}

registry_get() {
    local project="$1"
    local key="$2"
    awk "/^\[${project}\]/{found=1} found && /^${key}=/{print; exit} found && /^\[/ && !/^\[${project}\]/{exit}" "$REGISTRY_FILE" \
        | cut -d'=' -f2-
}

registry_set() {
    local project="$1"
    local key="$2"
    local value="$3"

    registry_init

    if grep -q "^\[${project}\]" "$REGISTRY_FILE" 2>/dev/null; then
        # Update existing key or append to section
        if grep -q "^${key}=" <(awk "/^\[${project}\]/{found=1} found{print} found && /^\[/ && !/^\[${project}\]/{exit}" "$REGISTRY_FILE"); then
            # Use Python for reliable multiline sed (works on macOS and Linux)
            python3 -c "
import re, sys
content = open('${REGISTRY_FILE}').read()
pattern = r'(\[${project}\][^\[]*?)^${key}=.*$'
replacement = r'\g<1>${key}=${value}'
result = re.sub(pattern, replacement, content, flags=re.MULTILINE|re.DOTALL)
open('${REGISTRY_FILE}', 'w').write(result)
"
        else
            # Append key to existing section
            python3 -c "
import re
content = open('${REGISTRY_FILE}').read()
# Find end of section
pattern = r'(\[${project}\][^\[]*?)(\n\[|\Z)'
def replacer(m):
    return m.group(1).rstrip() + '\n${key}=${value}\n' + m.group(2)
result = re.sub(pattern, replacer, content, flags=re.DOTALL)
open('${REGISTRY_FILE}', 'w').write(result)
"
        fi
    else
        # Create new section
        printf '\n[%s]\n%s=%s\n' "$project" "$key" "$value" >> "$REGISTRY_FILE"
    fi
}


registry_remove_project() {
    local project="$1"
    [[ ! -f "$REGISTRY_FILE" ]] && return
    python3 -c "
import re
content = open('${REGISTRY_FILE}').read()
result = re.sub(r'\n\[${project}\][^\[]*', '', content, flags=re.DOTALL)
open('${REGISTRY_FILE}', 'w').write(result)
"
}

project_in_registry() {
    local project="$1"
    [[ -f "$REGISTRY_FILE" ]] && grep -q "^\[${project}\]" "$REGISTRY_FILE"
}

# =============================================================================
# Auto-detection
# =============================================================================

detect_php_version() {
    # Try composer.json first
    if [[ -f "composer.json" ]]; then
        local version
        version=$(python3 -c "
import json, re
try:
    data = json.load(open('composer.json'))
    req = data.get('require', {}).get('php', '')
    # Extract version like 7.4, 8.0, etc.
    match = re.search(r'(\d+\.\d+)', req)
    if match:
        print(match.group(1))
except:
    pass
" 2>/dev/null)
        if [[ -n "$version" ]]; then
            echo "$version"
            return
        fi
    fi

    # Try .php-version file
    if [[ -f ".php-version" ]]; then
        head -1 .php-version | tr -d '[:space:]'
        return
    fi

    # Default
    echo "${DEFAULT_PHP_VERSION}"
}

normalize_php_version() {
    local raw="$1"
    if [[ "$raw" =~ ^([0-9]+)\.([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    else
        echo "$raw"
    fi
}

is_supported_php_version() {
    local candidate="$1"
    [[ " ${PHP_VERSIONS[*]} " =~ " ${candidate} " ]]
}

nearest_supported_php_version() {
    local candidate="$1"
    local version

    if is_supported_php_version "$candidate"; then
        echo "$candidate"
        return
    fi

    if [[ ! "$candidate" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        echo "${DEFAULT_PHP_VERSION}"
        return
    fi

    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    local candidate_num=$((major * 100 + minor))

    for version in "${PHP_VERSIONS[@]}"; do
        if [[ "$version" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
            local current_num=$((BASH_REMATCH[1] * 100 + BASH_REMATCH[2]))
            if (( current_num >= candidate_num )); then
                echo "$version"
                return
            fi
        fi
    done

    echo "${DEFAULT_PHP_VERSION}"
}

detect_project_type() {
    if [[ -f "artisan" ]]; then
        echo "laravel"
    elif [[ -f "bin/cake" ]] || [[ -f "app/Console/cake.php" ]] || \
         grep -q '"cakephp/cakephp"' composer.json 2>/dev/null || \
         ([[ -d "Config" ]] && [[ -d "Controller" ]] && [[ -d "Model" ]] && [[ -d "View" ]] && [[ -d "webroot" ]]); then
        echo "cakephp"
    else
        echo "generic"
    fi
}

detect_webroot() {
    local type="$1"
    case "$type" in
        laravel)  echo "public" ;;
        cakephp)  echo "webroot" ;;
        generic)
            # Guess common webroots
            for dir in public webroot web public_html htdocs; do
                [[ -d "$dir" ]] && echo "$dir" && return
            done
            echo "public"
            ;;
    esac
}

detect_services() {
    local type="$1"
    local services=()

    if [[ -f "composer.json" ]]; then
        # MySQL
        if grep -qE '"(mysql|laravel/mysql|doctrine/dbal)"' composer.json 2>/dev/null; then
            services+=("mysql")
        fi
        # Redis
        if grep -qE '"(predis/predis|illuminate/redis)"' composer.json 2>/dev/null; then
            services+=("redis")
        fi
    fi

    # Laravel always gets mysql by default
    if [[ "$type" == "laravel" ]] && [[ ! " ${services[*]} " =~ " mysql " ]]; then
        services+=("mysql")
    fi

    echo "${services[*]}"
}

# =============================================================================
# Docker Compose generation
# =============================================================================

generate_nginx_conf() {
    local type="$1"
    local webroot="$2"
    local project="$3"

    local fastcgi_index="index.php"
    local try_files="try_files \$uri \$uri/ /index.php?\$query_string;"

    if [[ "$type" == "cakephp" ]]; then
        try_files="try_files \$uri \$uri/ /index.php?\$args;"
    fi

    cat <<NGINX
server {
    listen 80;
    server_name localhost;
    root /var/www/html/${webroot};
    index index.php index.html;

    charset utf-8;

    location / {
        ${try_files}
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_pass php:9000;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "error_log=/var/log/php/error.log";
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }
}
NGINX
}

generate_dockerfile_php() {
    local php_version="$1"

    # Composer 2.3+ requires PHP 7.2+; use 2.2 (LTS) for older versions
    local composer_tag="2"
    if [[ "$php_version" == "5.6" ]] || [[ "$php_version" == "7.0" ]] || [[ "$php_version" == "7.1" ]]; then
        composer_tag="2.2"
    fi

    cat <<HEADER
FROM php:${php_version}-fpm

WORKDIR /var/www/html

HEADER

    # Fix EOL Debian apt mirrors — Jessie (5.6), Stretch (7.0/7.1), Buster (7.2/7.3)
    case "$php_version" in
        5.6)
            cat <<'APTFIX'
# Fix EOL Debian Jessie apt mirrors
RUN sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g' /etc/apt/sources.list \
    && sed -i '/jessie-updates/d' /etc/apt/sources.list \
    && sed -i '/security.debian.org/d' /etc/apt/sources.list

APTFIX
            ;;
        7.0|7.1)
            cat <<'APTFIX'
# Fix EOL Debian Stretch apt mirrors
RUN sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g' /etc/apt/sources.list \
    && sed -i 's|security.debian.org|archive.debian.org/debian-security|g' /etc/apt/sources.list \
    && sed -i '/stretch-updates/d' /etc/apt/sources.list

APTFIX
            ;;
        7.2|7.3)
            cat <<'APTFIX'
# Fix EOL Debian Buster apt mirrors
RUN sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g' /etc/apt/sources.list \
    && sed -i 's|security.debian.org|archive.debian.org/debian-security|g' /etc/apt/sources.list \
    && sed -i '/buster-updates/d' /etc/apt/sources.list

APTFIX
            ;;
    esac

    # Extensions — gd flags and mcrypt differ per PHP version
    case "$php_version" in
        5.6)
            # gd uses old --with-*-dir flags; mcrypt is a built-in extension
            cat <<'EXTS'
RUN apt-get update && apt-get install -y \
        libpng-dev libzip-dev libpq-dev zlib1g-dev libfreetype6-dev libjpeg62-turbo-dev libmcrypt-dev \
    && docker-php-ext-configure gd --with-freetype-dir=/usr/include/ --with-jpeg-dir=/usr/include/ \
    && docker-php-ext-install pdo pdo_mysql pdo_pgsql mbstring bcmath gd zip mcrypt

EXTS
            ;;
        7.0|7.1)
            # gd uses old --with-*-dir flags; mcrypt still available as built-in
            cat <<'EXTS'
RUN apt-get update && apt-get install -y \
        libpng-dev libzip-dev libicu-dev libpq-dev zlib1g-dev libfreetype6-dev libjpeg62-turbo-dev libmcrypt-dev \
    && docker-php-ext-configure gd --with-freetype-dir=/usr/include/ --with-jpeg-dir=/usr/include/ \
    && docker-php-ext-install pdo pdo_mysql pdo_pgsql mbstring exif pcntl bcmath gd zip intl opcache mcrypt

EXTS
            ;;
        7.2|7.3)
            # gd uses new --with-freetype / --with-jpeg flags; mcrypt removed in 7.2
            cat <<'EXTS'
RUN apt-get update && apt-get install -y \
        libpng-dev libzip-dev libicu-dev libpq-dev zlib1g-dev libfreetype6-dev libjpeg62-turbo-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install pdo pdo_mysql pdo_pgsql mbstring exif pcntl bcmath gd zip intl opcache

EXTS
            ;;
    esac

    cat <<FOOTER
# Install Composer
COPY --from=composer:${composer_tag} /usr/bin/composer /usr/bin/composer

# Create log directory
RUN mkdir -p /var/log/php && chmod 777 /var/log/php

EXPOSE 9000
FOOTER
}

generate_docker_compose() {
    local project="$1"
    local php_version="$2"
    local type="$3"
    local webroot="$4"
    local app_port="$5"
    local db_port="$6"
    local redis_port="$7"
    local with_mysql="$8"
    local with_redis="$9"

    local mysql_service=""
    local redis_service=""
    local depends_on=""
    local depends_items=""

    if [[ "$with_mysql" == "true" ]]; then
        depends_items+="      - mysql\n"
        mysql_service=$(cat <<MYSQL

  mysql:
    image: mysql:5.7
    container_name: ${project}_mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${DB_PASSWORD:-secret}
      MYSQL_DATABASE: \${DB_DATABASE:-${project}}
      MYSQL_USER: \${DB_USERNAME:-${project}}
      MYSQL_PASSWORD: \${DB_PASSWORD:-secret}
    ports:
      - "\${FORWARD_DB_PORT:-${db_port}}:3306"
    volumes:
      - ${project}_mysql:/var/lib/mysql
    networks:
      - ${project}_network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5
MYSQL
)
    fi

    if [[ "$with_redis" == "true" ]]; then
        depends_items+="      - redis\n"
        redis_service=$(cat <<REDIS

  redis:
    image: redis:alpine
    container_name: ${project}_redis
    restart: unless-stopped
    ports:
      - "\${FORWARD_REDIS_PORT:-${redis_port}}:6379"
    volumes:
      - ${project}_redis:/data
    networks:
      - ${project}_network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
REDIS
)
    fi

    if [[ -n "$depends_items" ]]; then
        depends_on=$(printf "    depends_on:\n%b" "$depends_items")
    fi

    local volumes_section="volumes:"
    [[ "$with_mysql" == "true" ]] && volumes_section+=$'\n'"  ${project}_mysql:"
    [[ "$with_redis" == "true" ]] && volumes_section+=$'\n'"  ${project}_redis:"

    cat <<COMPOSE
# Generated by Dockyard v${VERSION}
# Project: ${project} | PHP: ${php_version} | Type: ${type}

services:
  nginx:
    image: nginx:alpine
    container_name: ${project}_nginx
    restart: unless-stopped
    ports:
      - "\${APP_PORT:-${app_port}}:80"
    volumes:
      - .:/var/www/html
      - ./.dockyard/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certificates/cert.key:/etc/ssl/cert.key:ro
      - ./certificates/cert.crt:/etc/ssl/cert.crt:ro
    networks:
      - ${project}_network
    depends_on:
      - php

  php:
    build:
      context: .
      dockerfile: .dockyard/Dockerfile
    container_name: ${project}_php
    restart: unless-stopped
    working_dir: /var/www/html
    volumes:
      - .:/var/www/html
      - ./.dockyard/php.ini:/usr/local/etc/php/conf.d/custom.ini:ro
    networks:
      - ${project}_network
    environment:
      - APP_ENV=\${APP_ENV:-local}
${depends_on}

  mailpit:
    image: axllent/mailpit
    container_name: ${project}_mailpit
    restart: unless-stopped
    ports:
      - "\${FORWARD_MAILPIT_PORT:-1025}:1025"
      - "\${FORWARD_MAILPIT_DASHBOARD_PORT:-8025}:8025"
    networks:
      - ${project}_network
${mysql_service}${redis_service}

networks:
  ${project}_network:
    driver: bridge

${volumes_section}
COMPOSE
}

generate_php_ini() {
    local php_version="$1"

    cat <<INI
; Dockyard PHP configuration
error_reporting = E_ALL
display_errors = On
display_startup_errors = On
log_errors = On
error_log = /var/log/php/error.log
max_execution_time = 120
memory_limit = 256M
post_max_size = 50M
upload_max_filesize = 50M
date.timezone = Europe/Brussels
INI
}

# =============================================================================
# Herd/Valet proxy & SSL
# =============================================================================

setup_proxy() {
    local proxy_tool="$1"
    local domain="$2"
    local port="$3"
    local secure="$4"

    if [[ "$secure" == "true" ]]; then
        "$proxy_tool" proxy "$domain" "http://localhost:${port}" --secure
    else
        "$proxy_tool" proxy "$domain" "http://localhost:${port}"
    fi
}

setup_ssl_certificates() {
    local proxy_tool="$1"
    local domain="$2"

    mkdir -p certificates

    local cert_dir
    if [[ "$proxy_tool" == "herd" ]]; then
        cert_dir="${HOME}/Library/Application Support/Herd/config/valet/Certificates"
    else
        cert_dir="${HOME}/.config/valet/Certificates"
    fi

    local cert_file="${cert_dir}/${domain}.crt"
    local key_file="${cert_dir}/${domain}.key"

    if [[ -f "$cert_file" ]] && [[ -f "$key_file" ]]; then
        ln -sf "$cert_file" certificates/cert.crt
        ln -sf "$key_file" certificates/cert.key
        log_success "SSL certificates symlinked from ${proxy_tool}"
    else
        log_warn "Certificates not found yet. Run '${proxy_tool} secure ${domain}' first if needed."
        touch certificates/cert.crt certificates/cert.key
    fi
}

create_empty_certificates() {
    mkdir -p certificates
    touch certificates/cert.crt certificates/cert.key
}

update_gitignore() {
    local entry="/certificates"
    if [[ -f ".gitignore" ]]; then
        grep -qF "$entry" .gitignore || echo "$entry" >> .gitignore
    else
        echo "$entry" > .gitignore
    fi

    # Also ignore .dockyard generated files (keep config, ignore generated)
    local dockyard_entry="/.dockyard/Dockerfile"
    if ! grep -qF "$dockyard_entry" .gitignore 2>/dev/null; then
        cat <<GITIGNORE >> .gitignore

# Dockyard generated files
/.dockyard/Dockerfile
/.dockyard/nginx.conf
/.dockyard/php.ini
GITIGNORE
    fi
}

# =============================================================================
# .env helpers
# =============================================================================

env_set() {
    local key="$1"
    local value="$2"
    local file="${3:-.env}"

    [[ ! -f "$file" ]] && touch "$file"

    # Use Python to safely handle values containing sed special characters (|, &, /, etc.)
    python3 -c "
import sys
key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(path).readlines()
except FileNotFoundError:
    lines = []
found = False
result = []
for line in lines:
    if line.startswith(key + '='):
        result.append(key + '=' + value + '\n')
        found = True
    else:
        result.append(line)
if not found:
    result.append(key + '=' + value + '\n')
open(path, 'w').writelines(result)
" "$key" "$value" "$file"
}

env_comment_block() {
    cat <<'BLOCK' >> .env

# Auto-assigned Docker Ports (via dockyard)
BLOCK
}

# =============================================================================
# Interactive prompts
# =============================================================================

prompt_yn() {
    local question="$1"
    local default="${2:-y}"
    local prompt

    if [[ "$default" == "y" ]]; then
        prompt="[Y/n]"
    else
        prompt="[y/N]"
    fi

    while true; do
        read -rp "$(echo -e "${CYAN}?${NC}  ${question} ${prompt}: ")" answer
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) log_warn "Please answer y or n" ;;
        esac
    done
}

prompt_select() {
    local question="$1"
    shift
    local options=("$@")

    echo -e "${CYAN}?${NC}  ${question}"
    for i in "${!options[@]}"; do
        echo -e "   ${BOLD}$((i+1)))${NC} ${options[$i]}"
    done

    while true; do
        read -rp "$(echo -e "   ${CYAN}Enter number [1-${#options[@]}]${NC}: ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return
        fi
        log_warn "Invalid choice, please enter a number between 1 and ${#options[@]}"
    done
}

prompt_input() {
    local question="$1"
    local default="$2"
    local value

    read -rp "$(echo -e "${CYAN}?${NC}  ${question} [${default}]: ")" value
    echo "${value:-$default}"
}

# =============================================================================
# Commands
# =============================================================================

cmd_init() {
    log_header

    # Pre-flight checks
    if ! is_docker_running; then
        log_error "Docker is not running. Please start Docker and try again."
        exit 1
    fi

    local project
    project=$(get_project_name)

    if project_in_registry "$project"; then
        log_warn "Project '${project}' is already registered in Dockyard."
        if ! prompt_yn "Re-initialize and overwrite existing configuration?" "n"; then
            log_info "Aborted. Use 'dockyard list' to see registered projects."
            exit 0
        fi
        registry_remove_project "$project"
    fi

    log_step "Detecting project configuration..."

    # Auto-detect
    local detected_php
    local detected_php_raw
    detected_php_raw=$(normalize_php_version "$(detect_php_version)")
    detected_php=$(nearest_supported_php_version "$detected_php_raw")
    local detected_type
    detected_type=$(detect_project_type)

    log_info "Detected project type: ${BOLD}${detected_type}${NC}"
    log_info "Detected PHP version:  ${BOLD}${detected_php}${NC}"
    if [[ "$detected_php_raw" != "$detected_php" ]]; then
        log_info "Adjusted PHP ${detected_php_raw} to supported legacy version ${BOLD}${detected_php}${NC}"
    fi

    echo ""

    # ── Wizard: collect all input upfront ─────────────────────────────────────

    log_step "Project Setup Wizard"
    echo -e "  ${YELLOW}All questions will be asked upfront, then setup runs unattended.${NC}\n"

    # PHP version
    local php_version
    php_version=$(normalize_php_version "$(prompt_input "PHP version" "$detected_php")")
    while ! is_supported_php_version "$php_version"; do
        local suggested_php
        suggested_php=$(nearest_supported_php_version "$php_version")
        log_warn "PHP ${php_version} is not supported by Dockyard legacy mode."
        log_info "Supported versions: ${PHP_VERSIONS[*]}"
        php_version=$(normalize_php_version "$(prompt_input "Choose a supported PHP version" "${suggested_php}")")
    done

    # Project type
    local project_type
    project_type=$(prompt_select "Project type" "${PROJECT_TYPES[@]}")

    # Webroot
    local default_webroot
    default_webroot=$(detect_webroot "$project_type")
    local webroot
    webroot=$(prompt_input "Document root" "$default_webroot")

    # Services
    local with_mysql=false with_redis=false
    if prompt_yn "Include MySQL service?" "y"; then
        with_mysql=true
    fi
    if prompt_yn "Include Redis service?" "n"; then
        with_redis=true
    fi

    # Proxy / domain
    local proxy_tool
    proxy_tool=$(detect_proxy_tool)
    local use_proxy=false
    local domain="" proxy_secure=false

    if [[ "$proxy_tool" != "none" ]]; then
        if prompt_yn "Register local domain via ${proxy_tool}?" "y"; then
            use_proxy=true
            domain=$(prompt_input "Domain name" "${project}.test")
            if prompt_yn "Enable HTTPS (SSL)?" "y"; then
                proxy_secure=true
            fi
        fi
    else
        log_info "No Herd/Valet detected — skipping domain registration."
    fi

    # docker-compose.yml overwrite check (ask upfront, execute later)
    local overwrite_compose=false
    if [[ -f "docker-compose.yml" ]]; then
        if prompt_yn "docker-compose.yml already exists. Overwrite?" "n"; then
            overwrite_compose=true
        fi
    fi

    # ── Assign ports ──────────────────────────────────────────────────────────

    log_step "Assigning ports..."

    local app_port db_port redis_port mailpit_port mailpit_dash_port

    app_port=$(find_available_port "$(normalize_port 80)")
    db_port=$(find_available_port "$(normalize_port 3306)")
    redis_port=$(find_available_port "$(normalize_port 6379)")
    mailpit_port=$(find_available_port 1025)
    mailpit_dash_port=$(find_available_port 8025)

    log_success "APP_PORT        → ${app_port}"
    [[ "$with_mysql" == "true" ]] && log_success "FORWARD_DB_PORT → ${db_port}"
    [[ "$with_redis" == "true" ]] && log_success "FORWARD_REDIS_PORT → ${redis_port}"
    log_success "MAILPIT         → ${mailpit_port} (dashboard: ${mailpit_dash_port})"

    # ── Generate .dockyard/ config files ──────────────────────────────────────

    log_step "Generating Docker configuration..."

    mkdir -p .dockyard

    # Dockerfile
    generate_dockerfile_php "$php_version" "$project_type" > .dockyard/Dockerfile
    log_success "Generated .dockyard/Dockerfile (PHP ${php_version})"

    # nginx.conf
    generate_nginx_conf "$project_type" "$webroot" "$project" > .dockyard/nginx.conf
    log_success "Generated .dockyard/nginx.conf"

    # php.ini
    generate_php_ini "$php_version" > .dockyard/php.ini
    log_success "Generated .dockyard/php.ini"

    # docker-compose.yml
    if [[ "$overwrite_compose" == "true" ]] || [[ ! -f "docker-compose.yml" ]]; then
        generate_docker_compose "$project" "$php_version" "$project_type" "$webroot" \
            "$app_port" "$db_port" "$redis_port" "$with_mysql" "$with_redis" > docker-compose.yml
        log_success "Generated docker-compose.yml"
    else
        log_info "Keeping existing docker-compose.yml"
    fi

    # dockyard.yml (project config, committed to repo)
    cat > .dockyard/config.yml <<CONFIG
# Dockyard project configuration
# Commit this file to version control.
php: "${php_version}"
type: "${project_type}"
webroot: "${webroot}"
services:
  mysql: ${with_mysql}
  redis: ${with_redis}
  mailpit: true
CONFIG
    log_success "Generated .dockyard/config.yml"

    # ── .env setup ────────────────────────────────────────────────────────────

    log_step "Configuring .env..."

    # Copy .env.example if .env doesn't exist
    if [[ ! -f ".env" ]] && [[ -f ".env.example" ]]; then
        cp .env.example .env
        log_success "Copied .env.example → .env"
    fi

    local app_url="http://localhost:${app_port}"
    [[ -n "$domain" ]] && app_url="http://${domain}"
    [[ "$proxy_secure" == "true" ]] && app_url="https://${domain}"

    env_set "APP_URL"    "$app_url"
    env_set "APP_PORT"   "$app_port"
    env_set "COMPOSE_PROJECT_NAME" "$project"
    env_set "VITE_SERVER_HOST" "${domain:-localhost}"
    env_set "ASSET_URL"  "\${APP_URL}"

    [[ "$with_mysql" == "true" ]] && {
        env_set "DB_CONNECTION" "mysql"
        env_set "DB_HOST"       "mysql"
        env_set "DB_PORT"       "3306"
        env_set "DB_DATABASE"   "$project"
        env_set "DB_USERNAME"   "$project"
        env_set "DB_PASSWORD"   "secret"
        env_set "FORWARD_DB_PORT" "$db_port"
    }

    [[ "$with_redis" == "true" ]] && {
        env_set "REDIS_HOST"    "redis"
        env_set "REDIS_PORT"    "6379"
        env_set "FORWARD_REDIS_PORT" "$redis_port"
    }

    env_set "MAIL_HOST"   "mailpit"
    env_set "MAIL_PORT"   "1025"
    env_set "FORWARD_MAILPIT_PORT" "$mailpit_port"
    env_set "FORWARD_MAILPIT_DASHBOARD_PORT" "$mailpit_dash_port"

    log_success ".env updated"

    # ── SSL / proxy ───────────────────────────────────────────────────────────

    log_step "Configuring SSL & proxy..."

    if [[ "$use_proxy" == "true" ]]; then
        setup_proxy "$proxy_tool" "$domain" "$app_port" "$proxy_secure"
        log_success "Proxy registered: ${app_url}"

        if [[ "$proxy_secure" == "true" ]]; then
            setup_ssl_certificates "$proxy_tool" "$domain"
        else
            create_empty_certificates
        fi
    else
        create_empty_certificates
    fi

    update_gitignore
    log_success ".gitignore updated"

    # ── Registry ──────────────────────────────────────────────────────────────

    log_step "Saving to registry..."

    registry_init
    {
        printf '\n[%s]\n' "$project"
        printf 'path=%s\n' "$(pwd)"
        printf 'php=%s\n' "$php_version"
        printf 'type=%s\n' "$project_type"
        printf 'APP_PORT=%s\n' "$app_port"
        [[ "$with_mysql" == "true" ]] && printf 'FORWARD_DB_PORT=%s\n' "$db_port"
        [[ "$with_redis" == "true" ]] && printf 'FORWARD_REDIS_PORT=%s\n' "$redis_port"
        printf 'FORWARD_MAILPIT_PORT=%s\n' "$mailpit_port"
        printf 'FORWARD_MAILPIT_DASHBOARD_PORT=%s\n' "$mailpit_dash_port"
        [[ -n "$domain" ]] && printf 'domain=%s\n' "$domain"
        [[ -n "$proxy_tool" ]] && [[ "$use_proxy" == "true" ]] && printf 'proxy_service=%s\n' "$proxy_tool"
        printf 'proxy_secure=%s\n' "$proxy_secure"
    } >> "$REGISTRY_FILE"

    log_success "Project registered in ${REGISTRY_FILE}"

    # ── Post-setup ────────────────────────────────────────────────────────────

    log_step "Post-setup actions..."

    if prompt_yn "Build and start Docker containers now?" "y"; then
        docker compose up -d --build
        log_success "Containers started"

        if [[ "$project_type" == "laravel" ]]; then
            if prompt_yn "Run Laravel setup (key:generate, migrate)?" "y"; then
                docker compose exec php php artisan key:generate || true
                docker compose exec php php artisan migrate --force || true
                log_success "Laravel setup complete"
            fi
        fi
    fi

    # ── Summary ───────────────────────────────────────────────────────────────

    echo ""
    echo -e "${BOLD}${GREEN}┌─────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${GREEN}│          ✅ Setup Complete!              │${NC}"
    echo -e "${BOLD}${GREEN}└─────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${BOLD}Project:${NC}  ${project}"
    echo -e "  ${BOLD}PHP:${NC}      ${php_version}"
    echo -e "  ${BOLD}Type:${NC}     ${project_type}"
    echo -e "  ${BOLD}App URL:${NC}  ${CYAN}${app_url}${NC}"
    echo -e "  ${BOLD}Mailpit:${NC}  ${CYAN}http://localhost:${mailpit_dash_port}${NC}"
    [[ "$with_mysql" == "true" ]] && echo -e "  ${BOLD}MySQL:${NC}    localhost:${db_port}"
    [[ "$with_redis" == "true" ]] && echo -e "  ${BOLD}Redis:${NC}    localhost:${redis_port}"
    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    echo -e "    ${CYAN}docker compose up -d${NC}     Start containers"
    echo -e "    ${CYAN}docker compose down${NC}      Stop containers"
    echo -e "    ${CYAN}docker compose exec php bash${NC}  Enter PHP container"
    echo ""
}

cmd_list() {
    log_header

    if [[ ! -f "$REGISTRY_FILE" ]] || [[ ! -s "$REGISTRY_FILE" ]]; then
        log_info "No projects registered yet. Run 'dockyard init' in a project directory."
        return
    fi

    echo -e "${BOLD}Registered projects:${NC}\n"

    local current_project=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            current_project="${BASH_REMATCH[1]}"
            echo -e "  ${BOLD}${CYAN}${current_project}${NC}"
        elif [[ -n "$current_project" ]] && [[ "$line" =~ ^(path|php|type|domain|APP_PORT)=(.+)$ ]]; then
            printf "    %-28s %s\n" "${BASH_REMATCH[1]}:" "${BASH_REMATCH[2]}"
        fi
    done < "$REGISTRY_FILE"

    echo ""
}

cmd_cleanup() {
    log_header
    log_step "Cleaning up stale projects..."

    if [[ ! -f "$REGISTRY_FILE" ]]; then
        log_info "No registry found."
        return
    fi

    local removed=0
    local projects
    projects=$(grep '^\[' "$REGISTRY_FILE" | tr -d '[]' || true)

    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        local path
        path=$(registry_get "$project" "path")
        if [[ -n "$path" ]] && [[ ! -d "$path" ]]; then
            log_warn "Project '${project}' path no longer exists: ${path}"
            if prompt_yn "Remove from registry?" "y"; then
                registry_remove_project "$project"
                log_success "Removed '${project}' from registry"
                ((removed++)) || true
            fi
        fi
    done <<< "$projects"

    if (( removed == 0 )); then
        log_success "No stale projects found."
    else
        log_success "Removed ${removed} stale project(s)."
    fi
}

cmd_info() {
    log_header

    local project
    project=$(get_project_name)

    if ! project_in_registry "$project"; then
        log_warn "Project '${project}' is not registered. Run 'dockyard init' first."
        return 1
    fi

    echo -e "${BOLD}Project: ${CYAN}${project}${NC}\n"
    awk "/^\[${project}\]/{found=1; next} found && /^\[/{exit} found{print}" "$REGISTRY_FILE"
    echo ""
}

cmd_update() {
    log_step "Checking for updates..."
    local latest_url="https://raw.githubusercontent.com/YOUR_USERNAME/dockyard/main/dockyard.sh"
    local tmp_file
    tmp_file=$(mktemp)

    if curl -fsSL --max-time 10 "$latest_url" -o "$tmp_file" 2>/dev/null; then
        local latest_version
        latest_version=$(grep -m1 '^readonly VERSION=' "$tmp_file" | cut -d'"' -f2)

        if [[ "$latest_version" != "$VERSION" ]]; then
            log_info "Update available: ${VERSION} → ${latest_version}"
            if prompt_yn "Update now?" "y"; then
                local script_path="${BASH_SOURCE[0]}"
                cp "$tmp_file" "$script_path"
                chmod +x "$script_path"
                log_success "Updated to v${latest_version}. Please restart dockyard."
            fi
        else
            log_success "Already up to date (v${VERSION})"
        fi
    else
        log_warn "Could not reach update server."
    fi

    rm -f "$tmp_file"
}

usage() {
    cat <<USAGE
$(echo -e "${BOLD}Usage:${NC} dockyard <command>")

$(echo -e "${BOLD}Commands:${NC}")
  init       Initialize project setup wizard
  list       Show all registered projects
  info       Show info for current project
  cleanup    Remove stale projects from registry

$(echo -e "${BOLD}Options:${NC}")
  --version  Show version
  --update   Update to latest version
  --help     Show this help

$(echo -e "${BOLD}Supported PHP versions:${NC}")
  ${PHP_VERSIONS[*]}

$(echo -e "${BOLD}Supported project types:${NC}")
  laravel, cakephp, generic
USAGE
}

# =============================================================================
# Entry point
# =============================================================================

main() {
    local cmd="${1:-}"

    case "$cmd" in
        init)    cmd_init ;;
        list)    cmd_list ;;
        info)    cmd_info ;;
        cleanup) cmd_cleanup ;;
        --version) echo "dockyard v${VERSION}" ;;
        --update)  cmd_update ;;
        --help|help|-h|"") usage ;;
        *)
            log_error "Unknown command: ${cmd}"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
