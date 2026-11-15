#!/usr/bin/env bash
set -Eeuo pipefail

# PrecioInbox VPS installer
# Tested on: Ubuntu 24.04 LTS
# Run: sudo bash install-vps.sh
# Safe by default: never deletes Docker volumes or existing application data.
#
# IMPORTANT - SSH ACCESS:
# Before using this installer on a server, make sure you can connect securely
# through SSH using the 'deploy' account. If SSH access is not configured yet,
# those steps are NOT performed by this installer: create the 'deploy' user,
# set its password, grant the required sudo access, and install your SSH public
# key in /home/deploy/.ssh/authorized_keys before continuing.
# After installation, use 'deploy' for Docker and project administration.

DEPLOY_USER="${DEPLOY_USER:-deploy}"
APP_DIR="/opt/apps/precioinbox/backend"
INFRA_DIR="/opt/infra/caddy"
APP_REPO="https://github.com/umiphos/shelfy.git"
INFRA_REPO="https://github.com/umiphos/infra-server-a.git"

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Ejecuta como root: sudo bash install-vps.sh"
[[ -f /etc/os-release ]] || die "No se pudo identificar el sistema operativo."
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  warn "Este sistema (${PRETTY_NAME:-desconocido}) no es Ubuntu. El instalador fue probado en Ubuntu 24.04 LTS; en tu sistema no está garantizado su funcionamiento. Se intentará continuar."
elif [[ "${VERSION_ID:-}" != "24.04" ]]; then
  warn "Versión detectada: ${PRETTY_NAME:-desconocida}. El instalador fue probado en Ubuntu 24.04 LTS; en esta versión no está garantizado su funcionamiento. Se intentará continuar."
fi

id "$DEPLOY_USER" >/dev/null 2>&1 || die "No existe el usuario '${DEPLOY_USER}'. Antes de continuar, créalo, configura su contraseña y acceso SSH con llave pública. Consulta las instrucciones indicadas al inicio del instalador."

log "Instalando dependencias base."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl git openssl gnupg

log "Configurando el repositorio oficial de Docker."
install -m 0755 -d /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
cat >/etc/apt/sources.list.d/docker.sources <<EODOCKER
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EODOCKER

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "$DEPLOY_USER"
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin no está disponible."

log "Preparando directorios."
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" /opt/infra /opt/apps /opt/apps/precioinbox

clone_or_validate() {
  local repo="$1" dir="$2"
  if [[ -d "$dir/.git" ]]; then
    log "Repositorio existente: $dir (no se modifica ni se actualiza)."
    return
  fi
  if [[ -e "$dir" ]] && [[ -n "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    die "El directorio $dir ya existe y no está vacío, pero no es un repositorio Git. No se sobrescribirá."
  fi
  install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$dir"
  log "Clonando $repo"
  runuser -u "$DEPLOY_USER" -- git clone "$repo" "$dir"
}

clone_or_validate "$INFRA_REPO" "$INFRA_DIR"
clone_or_validate "$APP_REPO" "$APP_DIR"

[[ -f "$INFRA_DIR/docker-compose.yml" ]] || die "No se encontró docker-compose.yml en $INFRA_DIR."
[[ -f "$INFRA_DIR/Caddyfile" ]] || die "No se encontró Caddyfile en $INFRA_DIR."
[[ -f "$APP_DIR/docker-compose.yml" ]] || die "No se encontró docker-compose.yml en $APP_DIR."
[[ -f "$APP_DIR/Dockerfile" ]] || die "No se encontró Dockerfile en $APP_DIR."

log "Configurando la red Docker compartida."
if ! docker network inspect proxy_network >/dev/null 2>&1; then
  docker network create proxy_network >/dev/null
fi

log "Configurando correo ACME para Caddy."
if [[ ! -f "$INFRA_DIR/.env" ]]; then
  read -r -p "Correo para certificados TLS de Let's Encrypt: " ACME_EMAIL
  [[ "$ACME_EMAIL" == *@*.* ]] || die "El correo no parece válido."
  umask 077
  printf 'ACME_EMAIL=%s\n' "$ACME_EMAIL" > "$INFRA_DIR/.env"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$INFRA_DIR/.env"
  chmod 600 "$INFRA_DIR/.env"
else
  log "Se conserva el archivo existente $INFRA_DIR/.env."
fi

log "Configurando variables de PrecioInbox."
if [[ ! -f "$APP_DIR/.env" ]]; then
  DB_PASSWORD="$(openssl rand -hex 32)"
  umask 077
  cat >"$APP_DIR/.env" <<EOENV
POSTGRES_DB=catalogo
POSTGRES_USER=catalogo
POSTGRES_PASSWORD=${DB_PASSWORD}
CORS_ORIGINS=https://precioinbox.com
EOENV
  chown "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
  unset DB_PASSWORD
else
  log "Se conserva el archivo existente $APP_DIR/.env. No se reemplazan credenciales."
fi

chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR" "$INFRA_DIR"
[[ ! -f "$APP_DIR/.env" ]] || chmod 600 "$APP_DIR/.env"
[[ ! -f "$INFRA_DIR/.env" ]] || chmod 600 "$INFRA_DIR/.env"

log "Validando Compose antes de iniciar."
runuser -u "$DEPLOY_USER" -- bash -lc "cd '$INFRA_DIR' && docker compose config -q"
runuser -u "$DEPLOY_USER" -- bash -lc "cd '$APP_DIR' && docker compose config -q"

log "Iniciando Caddy."
runuser -u "$DEPLOY_USER" -- bash -lc "cd '$INFRA_DIR' && docker compose up -d"

log "Construyendo e iniciando PrecioInbox."
runuser -u "$DEPLOY_USER" -- bash -lc "cd '$APP_DIR' && docker compose up -d --build"

log "Instalación terminada. Estado de contenedores:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

cat <<EONEXT

Siguientes comprobaciones manuales:
  1. Confirmar DNS A de api.precioinbox.com hacia la IP pública del VPS.
  2. Confirmar que Cloudflare permite HTTPS hacia el origen.
  3. Probar https://api.precioinbox.com/
  4. Probar registro, login, catálogo y carga de imágenes desde el frontend.

IMPORTANTE:
  - Este script no elimina volúmenes ni bases de datos.
  - Si los repositorios ya existen, no ejecuta git pull.
  - A partir de ahora, utiliza el usuario '${DEPLOY_USER}' para Docker y la
    administración de los proyectos. Cierra la sesión SSH actual y vuelve a
    entrar como '${DEPLOY_USER}' para aplicar su pertenencia al grupo docker.
  - Este instalador configura PrecioInbox; no despliega todavía Turismo.
EONEXT
