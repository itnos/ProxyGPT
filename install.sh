#!/usr/bin/env bash
# ProxyGPT: настоящий claude.ai и chatgpt.com через ваш сервер - SNI-прокси + свой DNS (DoH и DoT).
#
# Установка и обновление одной командой (Debian или Ubuntu, от root):
#   curl -fsSL https://raw.githubusercontent.com/itnos/ProxyGPT/main/install.sh | bash -s -- --domain dns.example.com --agree-tos
#
# Подробно - README.md: https://github.com/itnos/ProxyGPT
set -Eeuo pipefail

DIR=/opt/proxygpt
DOMAIN="" IP="" EMAIL="" SITES_ARG="" AGREE=0 UNINSTALL=0
DEFAULT_SITES="claude.ai claude.com anthropic.com claudeusercontent.com chatgpt.com openai.com oaistatic.com oaiusercontent.com"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mОшибка:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
ProxyGPT - SNI-прокси и свой DNS, чтобы claude.ai и chatgpt.com открывались через этот сервер.

Параметры:
  --domain dns.example.com   имя DNS-сервера; его A-запись должна указывать на этот сервер (нужно при первой установке)
  --agree-tos                согласие с условиями Let's Encrypt (нужно при первом выпуске сертификата)
  --email you@example.com    почта для писем Let's Encrypt (необязательно)
  --ip 203.0.113.10          внешний IP сервера, если не определился сам
  --sites "a.com b.com"      какие сайты пускать (по умолчанию Claude и ChatGPT); иначе правьте /opt/proxygpt/sites.txt
  --dir /opt/proxygpt        куда ставить
  --uninstall                удалить (сертификат остаётся)

Повторный запуск без параметров применяет правки sites.txt и обновляет образы.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)    DOMAIN="${2:-}"; shift 2 ;;
    --ip)        IP="${2:-}"; shift 2 ;;
    --email)     EMAIL="${2:-}"; shift 2 ;;
    --sites)     SITES_ARG="${2:-}"; shift 2 ;;
    --dir)       DIR="${2:-}"; shift 2 ;;
    --agree-tos) AGREE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die "неизвестный параметр: $1" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "запустите от root"
command -v apt-get >/dev/null || die "скрипт рассчитан на Debian или Ubuntu (apt)"

# Настройки прошлой установки: параметры командной строки важнее.
if [ -f "$DIR/settings.env" ]; then
  # shellcheck disable=SC1091
  . "$DIR/settings.env"
fi
DOMAIN="${DOMAIN:-${PG_DOMAIN:-}}"
IP="${IP:-${PG_IP:-}}"
EMAIL="${EMAIL:-${PG_EMAIL:-}}"
DOMAIN="$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z')"

# ---------- Docker и Compose ----------

compose() { $COMPOSE -p proxygpt -f "$DIR/compose.yml" "$@"; }

find_compose() {
  if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then COMPOSE="docker-compose"
  else return 1; fi
}

if [ "$UNINSTALL" = 1 ]; then
  [ -d "$DIR" ] || die "в $DIR ничего не установлено"
  find_compose && compose down || true
  rm -f /etc/letsencrypt/renewal-hooks/deploy/proxygpt.sh
  rm -rf "$DIR"
  say "ProxyGPT удалён. Сертификат Let's Encrypt оставлен: certbot delete --cert-name ${DOMAIN:-<имя>}"
  exit 0
fi

pkgs=()
command -v curl    >/dev/null || pkgs+=(curl)
command -v openssl >/dev/null || pkgs+=(openssl)
command -v certbot >/dev/null || pkgs+=(certbot)
command -v docker  >/dev/null || pkgs+=(docker.io)
command -v ss      >/dev/null || pkgs+=(iproute2)
if [ ${#pkgs[@]} -gt 0 ]; then
  say "Ставлю пакеты: ${pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${pkgs[@]}" >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || true
if ! find_compose; then
  say "Ставлю Docker Compose"
  for p in docker-compose-plugin docker-compose-v2 docker-compose; do
    apt-get install -y -qq "$p" >/dev/null 2>&1 && find_compose && break || true
  done
  find_compose || die "не удалось поставить Docker Compose"
fi

# ---------- адрес и имя ----------

if [ -z "$IP" ]; then
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
  case "$IP" in
    ""|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
      IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)" ;;
  esac
fi
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "не удалось узнать внешний IP сервера, укажите --ip"

[ -n "$DOMAIN" ] || { usage; die "укажите имя DNS-сервера: --domain dns.example.com (A-запись -> $IP)"; }
[[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "странное имя: $DOMAIN"

RESOLVED="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR == 1 { print $1 }')"
[ "$RESOLVED" = "$IP" ] || die "$DOMAIN указывает на '${RESOLVED:-ничего}', а нужно на $IP.
Создайте A-запись: $DOMAIN -> $IP (в Cloudflare - серое облако, DNS only) и подождите пару минут."

# ---------- список сайтов ----------

mkdir -p "$DIR/conf" "$DIR/www"
if [ -n "$SITES_ARG" ] || [ ! -f "$DIR/sites.txt" ]; then
  {
    echo "# Сайты, которые идут через этот сервер: по одному корневому домену в строке, поддомены входят сами."
    echo "# После правки запустите установку ещё раз (ту же команду, можно без параметров)."
    for d in ${SITES_ARG:-$DEFAULT_SITES}; do echo "$d"; done
  } > "$DIR/sites.txt"
fi
mapfile -t SITES < <(sed 's/#.*//' "$DIR/sites.txt" | tr 'A-Z' 'a-z' | tr -s ' \t' '\n' | grep -v '^$' | sort -u)
[ ${#SITES[@]} -gt 0 ] || die "список сайтов $DIR/sites.txt пуст"
for d in "${SITES[@]}"; do
  [[ "$d" =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] || die "в sites.txt странная строка: $d"
  [ "$d" != "$DOMAIN" ] || die "имя DNS-сервера не должно быть в sites.txt"
done

# ---------- порты ----------

ours_running() { docker ps --format '{{.Names}}' | grep -q '^proxygpt-'; }
port_busy() { ss -ltnH "sport = :$1" | grep -q .; }
if ! ours_running; then
  for p in 443 853; do
    port_busy "$p" && die "порт $p занят: $(ss -ltnpH "sport = :$p" | sed -E 's/.*users:\(\("([^"]+)".*/\1/' | head -1). Нужен сервер, где 443 и 853 свободны."
  done
fi

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  say "Открываю в ufw порты 80, 443, 853"
  for p in 80 443 853; do ufw allow "$p/tcp" >/dev/null; done
fi

# ---------- сертификат ----------

CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
if [ ! -f "$CERT" ]; then
  [ "$AGREE" = 1 ] || die "нужен сертификат Let's Encrypt для $DOMAIN. Добавьте --agree-tos - это согласие с условиями Let's Encrypt (https://letsencrypt.org/repository/)"
  port_busy 80 && die "порт 80 занят: certbot не сможет подтвердить имя. Освободите его на время выпуска."
  say "Выпускаю сертификат для $DOMAIN"
  if [ -n "$EMAIL" ]; then em=(--email "$EMAIL"); else em=(--register-unsafely-without-email); fi
  certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" --non-interactive --agree-tos "${em[@]}"
fi
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/proxygpt.sh <<EOF
#!/bin/sh
# ProxyGPT: после продления сертификата $DOMAIN перезапустить контейнеры, чтобы они взяли новый.
case " \$RENEWED_DOMAINS " in *" $DOMAIN "*) docker restart proxygpt-nginx proxygpt-dns >/dev/null 2>&1 || true ;; esac
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/proxygpt.sh

# ---------- настройки ----------

PG_UUID1="${PG_UUID1:-$(cat /proc/sys/kernel/random/uuid)}"
PG_UUID2="${PG_UUID2:-$(cat /proc/sys/kernel/random/uuid)}"
cat > "$DIR/settings.env" <<EOF
# ProxyGPT: настройки установки (их читает install.sh при повторном запуске)
PG_DOMAIN=$DOMAIN
PG_IP=$IP
PG_EMAIL=$EMAIL
PG_UUID1=$PG_UUID1
PG_UUID2=$PG_UUID2
EOF

fill() { sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__IP__|$IP|g" -e "s|__UUID1__|$PG_UUID1|g" -e "s|__UUID2__|$PG_UUID2|g"; }

# nginx: SNI-прокси на 443 (без расшифровки) + страница и DoH для имени DNS-сервера
{
  cat <<'EOF'
# Сгенерировано install.sh. Правки - в sites.txt, затем запустить установку ещё раз.
worker_processes auto;
events { worker_connections 4096; }

stream {
    log_format sni '$remote_addr [$time_local] $ssl_preread_server_name -> $up $status $bytes_sent/$bytes_received $session_time';
    access_log /dev/stdout sni;
    error_log  /dev/stderr warn;
    resolver 1.1.1.1 8.8.8.8 valid=300s ipv6=off;
    resolver_timeout 5s;

    # Сайты из sites.txt - на настоящий сайт по его имени; имя DNS-сервера - на страницу и DoH; остальное закрывается.
    map $ssl_preread_server_name $up {
EOF
  printf '        %-46s %s\n' "__DOMAIN__" "127.0.0.1:8445;"
  for d in "${SITES[@]}"; do
    printf '        %-46s %s\n' "~^([a-z0-9-]+\\.)*$(printf '%s' "$d" | sed 's/\./\\./g')\$" '$ssl_preread_server_name:443;'
  done
  cat <<'EOF'
        default                                        127.0.0.1:9;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass $up;
        proxy_connect_timeout 10s;
        proxy_timeout 1h;
    }
}

http {
    server_tokens off;
    access_log off;
    error_log /dev/stderr warn;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    charset utf-8;

    server {
        listen 127.0.0.1:8445 ssl;
        http2 on;
        server_name __DOMAIN__;
        ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;
        root /srv/www;
        index index.html;

        location = /dns-query {
            proxy_pass https://127.0.0.1:8444;
            proxy_http_version 1.1;
            proxy_ssl_server_name on;
            proxy_ssl_name __DOMAIN__;
            proxy_set_header Host __DOMAIN__;
            proxy_buffering off;
        }
        location = /apple.mobileconfig { default_type application/x-apple-aspen-config; }
        location = /windows.ps1        { default_type text/plain; }
    }
}
EOF
} | fill > "$DIR/conf/nginx.conf"

# CoreDNS: сайты из списка -> IP сервера, у них же пустые AAAA и HTTPS (иначе устройство уйдёт напрямую),
# остальное - обычный ответ через Cloudflare DNS по TLS.
ZONES="${SITES[*]}"
cat <<EOF | fill > "$DIR/conf/Corefile"
# Сгенерировано install.sh. Правки - в sites.txt, затем запустить установку ещё раз.
(sites) {
    template IN A $ZONES {
        answer "{{ .Name }} 60 IN A __IP__"
    }
    template IN AAAA $ZONES {
        rcode NOERROR
    }
    template IN HTTPS $ZONES {
        rcode NOERROR
    }
    forward . tls://1.1.1.1 tls://1.0.0.1 {
        tls_servername cloudflare-dns.com
        health_check 30s
    }
    cache 300
    errors
}

tls://.:853 {
    tls /etc/letsencrypt/live/__DOMAIN__/fullchain.pem /etc/letsencrypt/live/__DOMAIN__/privkey.pem
    import sites
}

https://.:8444 {
    bind 127.0.0.1
    tls /etc/letsencrypt/live/__DOMAIN__/fullchain.pem /etc/letsencrypt/live/__DOMAIN__/privkey.pem
    import sites
}
EOF

cat > "$DIR/compose.yml" <<'EOF'
# Сгенерировано install.sh.
services:
  nginx:
    image: nginx:alpine
    container_name: proxygpt-nginx
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./conf:/etc/nginx/proxygpt:ro
      - ./www:/srv/www:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    command: ["nginx", "-c", "/etc/nginx/proxygpt/nginx.conf", "-g", "daemon off;"]
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }

  dns:
    image: coredns/coredns:latest
    container_name: proxygpt-dns
    restart: unless-stopped
    network_mode: host
    user: "0:0"
    volumes:
      - ./conf:/etc/coredns:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    command: ["-conf", "/etc/coredns/Corefile"]
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
EOF

# ---------- файлы для устройств ----------

# iPhone, iPad, Mac: профиль DNS (DoH)
cat <<'EOF' | fill > "$DIR/www/apple.mobileconfig"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>DNSSettings</key>
            <dict>
                <key>DNSProtocol</key>
                <string>HTTPS</string>
                <key>ServerURL</key>
                <string>https://__DOMAIN__/dns-query</string>
                <key>ServerAddresses</key>
                <array>
                    <string>__IP__</string>
                </array>
            </dict>
            <key>PayloadDescription</key>
            <string>DNS __DOMAIN__: claude.ai, chatgpt.com and other listed sites go through your server</string>
            <key>PayloadDisplayName</key>
            <string>ProxyGPT DNS (__DOMAIN__)</string>
            <key>PayloadIdentifier</key>
            <string>com.apple.dnsSettings.managed.__UUID1__</string>
            <key>PayloadType</key>
            <string>com.apple.dnsSettings.managed</string>
            <key>PayloadUUID</key>
            <string>__UUID1__</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>ProxyGPT DNS (__DOMAIN__)</string>
    <key>PayloadIdentifier</key>
    <string>proxygpt.dns.__UUID2__</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>__UUID2__</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

# Windows 11: DNS через DoH для всех активных сетевых подключений (PowerShell от администратора)
cat <<'EOF' | fill > "$DIR/www/windows.ps1"
# ProxyGPT DNS for Windows 11. Run in PowerShell as Administrator:
#   irm https://__DOMAIN__/windows.ps1 | iex
# Undo:
#   Get-NetAdapter | % { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses }
$ip  = '__IP__'
$tpl = 'https://__DOMAIN__/dns-query'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run PowerShell as Administrator' -ForegroundColor Red; return
}
if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {
    Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $tpl -AllowFallbackToUdp $false -AutoUpgrade $true | Out-Null
} else {
    Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $tpl -AllowFallbackToUdp $false -AutoUpgrade $true | Out-Null
}
Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
    Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses $ip
    Write-Host ('DNS set: ' + $_.Name)
}
Clear-DnsClientCache
Write-Host ('Done. DNS = ' + $ip + ' over HTTPS (' + $tpl + ')') -ForegroundColor Green
EOF

# Страница с инструкцией
cat <<'EOF' | fill > "$DIR/www/index.html"
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>ProxyGPT DNS - __DOMAIN__</title>
<style>
  body { font: 16px/1.55 system-ui, -apple-system, sans-serif; max-width: 760px; margin: 0 auto; padding: 24px 18px 60px; color: #1b1b1f; background: #fafafa; }
  h1 { font-size: 26px; margin: 0 0 6px; } h2 { font-size: 20px; margin: 32px 0 8px; }
  .muted { color: #666; } code, pre { font: 14px ui-monospace, Menlo, Consolas, monospace; }
  pre { background: #fff; border: 1px solid #ddd; border-radius: 10px; padding: 12px; overflow-x: auto; white-space: pre-wrap; word-break: break-all; }
  .btn { display: inline-block; background: #1b1b1f; color: #fff; text-decoration: none; padding: 10px 16px; border-radius: 10px; margin: 6px 0; }
  li { margin: 4px 0; }
  @media (prefers-color-scheme: dark) { body { background: #151518; color: #ececf1; } pre { background: #1f1f24; border-color: #333; } .btn { background: #ececf1; color: #151518; } .muted { color: #9a9aa3; } }
</style>
</head>
<body>
<h1>DNS __DOMAIN__</h1>
<p class="muted">Настройте один раз: claude.ai, chatgpt.com и другие сайты из списка сервера будут открываться через сервер __IP__, всё остальное - как обычно. Это не VPN: приложение ставить не нужно.</p>

<h2>iPhone и iPad</h2>
<ol>
  <li>Откройте эту страницу в <b>Safari</b> и нажмите кнопку: <br><a class="btn" href="/apple.mobileconfig">Скачать профиль DNS</a></li>
  <li>«Разрешить» → Настройки → вверху «Профиль загружен» → Установить.</li>
  <li>Проверьте: Настройки → Основные → VPN и управление устройством → DNS → выбран «ProxyGPT DNS».</li>
</ol>

<h2>Mac</h2>
<pre>curl -fsSL https://__DOMAIN__/apple.mobileconfig -o ~/Downloads/proxygpt-dns.mobileconfig &amp;&amp; open ~/Downloads/proxygpt-dns.mobileconfig</pre>
<p>Затем Системные настройки → Основные → Управление устройством (или поиск «Профили») → «ProxyGPT DNS» → Установить.</p>

<h2>Android 9 и новее</h2>
<ol>
  <li>Настройки → Сеть и интернет → <b>Частный DNS</b> (на Samsung: Подключения → Другие настройки → Частный DNS).</li>
  <li>«Имя хоста поставщика частного DNS»: <pre>__DOMAIN__</pre></li>
</ol>

<h2>Windows 11</h2>
<p>PowerShell <b>от имени администратора</b>:</p>
<pre>irm https://__DOMAIN__/windows.ps1 | iex</pre>
<p class="muted">Вернуть как было: <code>Get-NetAdapter | % { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses }</code></p>

<h2>Linux (systemd-resolved)</h2>
<pre>sudo mkdir -p /etc/systemd/resolved.conf.d &amp;&amp; printf '[Resolve]\nDNS=__IP__#__DOMAIN__\nDNSOverTLS=yes\n' | sudo tee /etc/systemd/resolved.conf.d/proxygpt.conf &amp;&amp; sudo systemctl restart systemd-resolved</pre>

<h2>Если не работает</h2>
<ul>
  <li>iPhone и Mac: выключите «Частный узел iCloud» (Private Relay) - он обходит DNS в Safari.</li>
  <li>Chrome: Настройки → Конфиденциальность → «Безопасный DNS» - «Использовать текущего поставщика».</li>
  <li>Включённый VPN подменяет DNS: на время выключите его.</li>
  <li>После настройки закройте и откройте браузер или приложение заново.</li>
</ul>
</body>
</html>
EOF

# ---------- запуск ----------

say "Запускаю контейнеры"
(cd "$DIR" && compose pull -q && compose up -d --force-recreate --remove-orphans) >/dev/null
sleep 3
for c in proxygpt-nginx proxygpt-dns; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { docker logs --tail 20 "$c" 2>&1 >&2 || true; die "контейнер $c не запустился"; }
done

# ---------- проверка ----------

ok=1
if echo | timeout 10 openssl s_client -connect "127.0.0.1:853" -servername "$DOMAIN" >/dev/null 2>&1; then
  say "DoT (порт 853): отвечает"
else warn "DoT (порт 853) не отвечает"; ok=0; fi
res="$(curl -s -o /dev/null -w '%{http_code} %{remote_ip}' --max-time 20 --doh-url "https://$DOMAIN/dns-query" "https://${SITES[0]}/" || true)"
if [ "${res#* }" = "$IP" ]; then
  say "DoH и SNI-прокси: ${SITES[0]} -> $IP, ответ сайта ${res%% *} (403 у Cloudflare для curl - нормально, браузер пройдёт)"
else warn "DoH или SNI-прокси: неожиданный ответ '$res'"; ok=0; fi

cat <<EOF

$( [ $ok = 1 ] && printf '\033[1;32mГотово.\033[0m' || printf '\033[1;33mУстановлено, но проверка нашла ошибки (см. выше).\033[0m' )

Страница с настройкой устройств:  https://$DOMAIN/
  iPhone, iPad, Mac:  https://$DOMAIN/apple.mobileconfig  (профиль DNS)
  Android:            Частный DNS -> $DOMAIN
  Windows 11:         irm https://$DOMAIN/windows.ps1 | iex   (PowerShell от администратора)

Сайты: ${SITES[*]}
Правка списка: $DIR/sites.txt, затем запустить установку ещё раз.
Журнал прокси: docker logs -f proxygpt-nginx
EOF
