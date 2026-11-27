#!/usr/bin/env bash
# ProxyGPT: настоящий claude.ai и chatgpt.com через ваш сервер - SNI-прокси + свой DNS (DoH и DoT).
#
# Установка и обновление одной командой (Debian или Ubuntu, от root):
#   curl -fsSL https://raw.githubusercontent.com/itnos/ProxyGPT/main/install.sh | bash -s -- --domain dns.example.com --agree-tos --relay
# Без curl:
#   wget -qO- https://raw.githubusercontent.com/itnos/ProxyGPT/main/install.sh | bash -s -- --domain dns.example.com --agree-tos --relay
# Проверка:
#   ... | bash -s -- --check
#
# Подробно - README.md: https://github.com/itnos/ProxyGPT
set -Eeuo pipefail

DIR=/opt/proxygpt
RAW="${PROXYGPT_RAW:-https://raw.githubusercontent.com/itnos/ProxyGPT/main}"
DOMAIN="" IP="" EMAIL="" SITES_ARG="" AGREE=0 UNINSTALL=0 CHECK=0 RELAY="" STOP="" START="" STATUS=0 PROXY=""
# Список по умолчанию (так он и ложится в sites.txt): Claude, ChatGPT и сторонние адреса их страниц,
# которые иначе видели бы настоящий IP (найдены по коду и CSP claude.ai и chatgpt.com 27.11.2026)
DEFAULT_SITES='# Claude и ChatGPT
claude.ai claude.com anthropic.com claudeusercontent.com
chatgpt.com openai.com oaistatic.com oaiusercontent.com
# другие домены Anthropic и OpenAI: приложения MCP, опубликованные страницы, настройки ChatGPT
claudemcpcontent.com claude.site chatgpt.site oaistatsig.com
# проверки «вы не робот» при входе (они же стоят на многих других сайтах)
hcaptcha.com challenges.cloudflare.com
# телеметрия страниц: ошибки, статистика, флаги функций
browser-intake-datadoghq.com browser-intake-us5-datadoghq.com sentry.io statsigapi.net featuregates.org growthbook.io
# чат поддержки Claude и оплата (Stripe - на всех сайтах, где через него платят)
intercom.io intercomcdn.com stripe.com stripe.network stripecdn.com'

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
  --sites "a.com b.com"      какие сайты пускать (по умолчанию Claude, ChatGPT и их сторонние адреса); иначе правьте /opt/proxygpt/sites.txt
  --dir /opt/proxygpt        куда ставить
  --relay                    включить приёмник для цепочки «другой VPN -> этот сервер -> сайт» (см. README)
  --no-relay                 выключить приёмник
  --check                    только проверить, что DNS и прокси работают
  --status                   что запущено, что остановлено
  --stop  [all|dns|proxy|relay]   остановить: всё (по умолчанию), DNS, прокси сайтов или приёмник
  --start [all|dns|proxy|relay]   запустить то же обратно
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
    --check)     CHECK=1; shift ;;
    --status)    STATUS=1; shift ;;
    --stop|--start)
      act="${1#--}" what=all
      case "${2:-}" in all|dns|proxy|relay) what="$2"; shift ;; esac
      shift
      if [ "$act" = stop ]; then STOP="$what"; else START="$what"; fi ;;
    --relay)     RELAY=1; shift ;;
    --no-relay)  RELAY=0; shift ;;
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
RELAY="${RELAY:-${PG_RELAY:-0}}"
PROXY="${PROXY:-${PG_PROXY:-1}}"   # 1 - сайты из списка идут через сервер, 0 - прокси выключен (--stop proxy)
DOMAIN="$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z')"

read_sites() {
  mapfile -t SITES < <(sed 's/#.*//' "$DIR/sites.txt" | tr 'A-Z' 'a-z' | tr -s ' \t' '\n' | grep -v '^$' | sort -u)
  CHECK_SITE="${SITES[0]:-}"
  for d in chatgpt.com claude.ai; do printf '%s\n' "${SITES[@]}" | grep -qx "$d" && CHECK_SITE="$d"; done
}

# Проверка приёмника: временный клиент Xray (socks 127.0.0.1:10099) -> wss://DOMAIN/путь -> сайт из списка.
check_relay() {
  local cfg=/tmp/proxygpt-relay-test.json res ip
  [ "$(docker inspect -f '{{.State.Running}}' proxygpt-relay 2>/dev/null)" = true ] && pass "контейнер proxygpt-relay работает" || { fail "контейнер proxygpt-relay не работает: docker logs proxygpt-relay"; return; }
  cat > "$cfg" <<EOF
{"log":{"loglevel":"error"},
 "inbounds":[{"listen":"127.0.0.1","port":10099,"protocol":"socks","settings":{"udp":false}}],
 "outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"$IP","port":443,"users":[{"id":"$PG_RELAY_UUID","encryption":"none"}]}]},
   "streamSettings":{"network":"ws","security":"tls","tlsSettings":{"serverName":"$DOMAIN","alpn":["http/1.1"]},"wsSettings":{"path":"$PG_RELAY_PATH","host":"$DOMAIN"}}}]}
EOF
  chmod 644 "$cfg"
  docker rm -f proxygpt-relay-test >/dev/null 2>&1 || true
  docker run -d --rm --name proxygpt-relay-test --network host -v "$cfg:/c.json:ro" ghcr.io/xtls/xray-core:latest run -c /c.json >/dev/null 2>&1
  sleep 2
  res="$(curl -s --max-time 15 --socks5-hostname 127.0.0.1:10099 "https://$CHECK_SITE/cdn-cgi/trace" || true)"
  ip="$(printf '%s\n' "$res" | sed -n 's/^ip=//p')"
  [ "$ip" = "$IP" ] && pass "приёмник: $CHECK_SITE через wss://$DOMAIN выходит с адреса сервера" || fail "приёмник: $CHECK_SITE не открылся через wss://$DOMAIN (ip='${ip:-нет ответа}')"
  res="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --socks5-hostname 127.0.0.1:10099 https://example.com/ || true)"
  [ "$res" = 000 ] && pass "приёмник: сайты не из списка не пропускает" || fail "приёмник пропустил example.com (код $res)"
  docker rm -f proxygpt-relay-test >/dev/null 2>&1 || true
  rm -f "$cfg"
  res="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/happ/$PG_SUB_TOKEN/" || true)"
  [ "$res" = 200 ] && pass "страница подписки Happ отвечает (адрес - в links.txt)" || fail "страница подписки Happ: код $res (docker logs proxygpt-sub)"
  res="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/happ/0000000000000000/" || true)"
  [ "$res" = 404 ] && pass "без секретного адреса страница подписки закрыта" || fail "страница подписки открылась без секрета (код $res)"
}

# Проверка: контейнеры, DoT, DoH, маршрут сайтов из списка и обычных сайтов, срок сертификата.
run_checks() {
  local ok=1 res ip loc days d
  pass() { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
  fail() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; ok=0; }
  say "Проверка ($DOMAIN, сервер $IP)"
  for c in proxygpt-nginx proxygpt-dns; do
    [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] && pass "контейнер $c работает" || fail "контейнер $c не работает: docker logs $c"
  done
  if echo | timeout 10 openssl s_client -connect "127.0.0.1:853" -servername "$DOMAIN" -verify_hostname "$DOMAIN" -verify_return_error >/dev/null 2>&1; then
    pass "DoT (порт 853, Android): отвечает, сертификат действителен"
  else fail "DoT (порт 853) не отвечает или сертификат не подходит"; fi
  # Ответ DNS по каждому сайту: curl спрашивает адрес у нашего DoH и пишет его в подробный вывод (IPv4: ...);
  # порт 853 открыт на сервере всегда, поэтому ответ виден, даже если у сайта нет корневого имени (oaiusercontent.com).
  for d in "${SITES[@]}"; do
    res="$(curl -sv -o /dev/null --connect-timeout 5 --max-time 10 --doh-url "https://$DOMAIN/dns-query" "https://$d:853/" 2>&1 \
      | sed -nE 's/^\* +IPv4: ([0-9.]+).*/\1/p; s/^\* +Trying ([0-9.]+):.*/\1/p' | head -1 || true)"
    if [ "$PROXY" = 1 ]; then
      [ "$res" = "$IP" ] && pass "DNS: $d -> $IP (через сервер)" || fail "DNS: $d -> '${res:-нет ответа}', ожидался $IP"
    else
      if [ "$res" = "$IP" ]; then fail "DNS: $d -> $IP, а прокси выключен (ждали настоящий адрес)"
      elif [ -n "$res" ]; then pass "DNS: $d -> $res (прокси выключен, напрямую)"
      else pass "DNS: $d - у корневого имени нет адреса, это нормально (прокси выключен)"; fi
    fi
  done
  res="$(curl -s -o /dev/null -w '%{remote_ip}' --max-time 15 --doh-url "https://$DOMAIN/dns-query" https://example.com/ || true)"
  [ -n "$res" ] && [ "$res" != "$IP" ] && pass "DNS: example.com -> $res (напрямую, как и должно)" || fail "DNS: example.com -> '${res:-нет ответа}'"
  if [ "$PROXY" = 1 ]; then
    res="$(curl -s --max-time 15 --doh-url "https://$DOMAIN/dns-query" "https://$CHECK_SITE/cdn-cgi/trace" || true)"
    ip="$(printf '%s\n' "$res" | sed -n 's/^ip=//p')"; loc="$(printf '%s\n' "$res" | sed -n 's/^loc=//p')"
    [ "$ip" = "$IP" ] && pass "$CHECK_SITE видит адрес сервера: ip=$ip loc=$loc" || fail "$CHECK_SITE видит ip='${ip:-?}' (нужно $IP)"
  else
    printf '  - прокси сайтов выключен (--stop proxy), включить: --start proxy\n'
  fi
  res="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/$PG_PAGE_TOKEN/" || true)"
  [ "$res" = 200 ] && pass "страница устройств открывается по секретному адресу (адрес - в links.txt)" || fail "страница устройств: код $res"
  res="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" || true)"
  [ "$res" = 404 ] && pass "без секрета страница закрыта (https://$DOMAIN/ - 404)" || fail "https://$DOMAIN/ отвечает $res, а должен 404"
  if [ "${RELAY:-0}" = 1 ]; then check_relay; fi
  days="$(( ( $(date -d "$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))"
  [ "$days" -gt 7 ] && pass "сертификат действует ещё $days дн. (продлевается сам)" || fail "сертификат истекает через $days дн.: certbot renew"
  [ "$ok" = 1 ] && say "Всё работает." || warn "Есть ошибки (см. выше)."
  [ "$ok" = 1 ]
}

# ---------- Docker и Compose ----------

compose() { $COMPOSE -p proxygpt -f "$DIR/compose.yml" "$@"; }

find_compose() {
  if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then COMPOSE="docker-compose"
  else return 1; fi
}

show_status() {
  local item n d st
  say "ProxyGPT: $DOMAIN ($IP)"
  for item in "proxygpt-nginx|прокси сайтов, страницы, DoH на 443" "proxygpt-dns|DNS: DoT 853 и DoH" \
              "proxygpt-relay|приёмник (работа через другой VPN)" "proxygpt-sub|страница и подписка Happ"; do
    n="${item%%|*}" d="${item#*|}"
    st="$(docker inspect -f '{{.State.Status}}' "$n" 2>/dev/null || echo 'не установлен')"
    case "$st" in running) st="✓ работает " ;; exited|created) st="■ ОСТАНОВЛЕН" ;; "не установлен") st="- нет      " ;; esac
    printf '  %s  %-15s %s\n' "$st" "$n" "$d"
  done
  if [ "$PROXY" = 1 ]; then echo "  прокси сайтов:  включён - сайты из sites.txt идут через сервер"
  else echo "  прокси сайтов:  выключен - DNS отдаёт настоящие адреса, сайты идут напрямую (включить: --start proxy)"; fi
}
dns_warning() {
  warn "Android и Windows с вашим DNS потеряют интернет, пока DNS не запустят снова (--start)."
  warn "iPhone и Mac перейдут на DNS сети: Claude/ChatGPT пойдут напрямую. После --start их надо переподключить"
  warn "к сети (авиарежим или Wi-Fi выкл/вкл), иначе они ещё какое-то время останутся на DNS сети."
  warn "Только Claude/ChatGPT убрать, не трогая DNS, - это --stop proxy."
}

if [ "$STATUS" = 1 ]; then
  [ -f "$DIR/settings.env" ] || die "ProxyGPT в $DIR не установлен"
  show_status
  exit 0
fi

if [ -n "$STOP$START" ]; then
  [ -f "$DIR/compose.yml" ] || die "ProxyGPT в $DIR не установлен"
  find_compose || die "нет Docker Compose"
  if [ -n "$STOP" ]; then act=stop what="$STOP"; else act=start what="$START"; fi
  case "$what" in
    proxy)
      # прокси - это режим, а не контейнер: пересобираем настройки (ниже, обычной установкой) и перезапускаем
      if [ "$act" = stop ]; then PROXY=0; say "Выключаю прокси: DNS будет отдавать настоящие адреса сайтов, сервер перестанет их пересылать"
      else PROXY=1; say "Включаю прокси: сайты из sites.txt снова пойдут через сервер"; fi ;;
    all)
      if [ "$act" = stop ]; then dns_warning; say "Останавливаю всё"; compose stop
      else say "Запускаю всё"; compose up -d
        say "iPhone и Mac: переподключите к сети (авиарежим или Wi-Fi выкл/вкл), чтобы они вернулись на этот DNS"; fi
      show_status; exit 0 ;;
    dns)
      [ "$act" = stop ] && dns_warning
      say "$([ "$act" = stop ] && echo Останавливаю || echo Запускаю) DNS"; docker "$act" proxygpt-dns >/dev/null
      [ "$act" = start ] && say "iPhone и Mac: переподключите к сети (авиарежим или Wi-Fi выкл/вкл), чтобы они вернулись на этот DNS"
      show_status; exit 0 ;;
    relay)
      [ "$RELAY" = 1 ] || die "приёмник не установлен: запустите установку с --relay"
      say "$([ "$act" = stop ] && echo Останавливаю || echo Запускаю) приёмник и подписку Happ"; docker "$act" proxygpt-relay proxygpt-sub >/dev/null
      show_status; exit 0 ;;
  esac
fi

if [ "$CHECK" = 1 ]; then
  [ -f "$DIR/settings.env" ] && [ -f "$DIR/sites.txt" ] || die "ProxyGPT в $DIR не установлен"
  read_sites
  run_checks
  exit $?
fi

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
    echo "# Сайты, которые идут через этот сервер: домены через пробел или по одному в строке, поддомены входят сами."
    echo "# После правки запустите установку ещё раз (ту же команду, можно без параметров)."
    if [ -n "$SITES_ARG" ]; then for d in $SITES_ARG; do echo "$d"; done
    else printf '%s\n' "$DEFAULT_SITES"; fi
  } > "$DIR/sites.txt"
fi
read_sites
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

LOC="$(curl -s --max-time 10 https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^loc=//p' || true)"
PG_UUID1="${PG_UUID1:-$(cat /proc/sys/kernel/random/uuid)}"
PG_UUID2="${PG_UUID2:-$(cat /proc/sys/kernel/random/uuid)}"
PG_PAGE_TOKEN="${PG_PAGE_TOKEN:-$(openssl rand -hex 12)}"   # страница устройств - только по секретному адресу
if [ "$RELAY" = 1 ]; then
  PG_RELAY_UUID="${PG_RELAY_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
  PG_RELAY_PATH="${PG_RELAY_PATH:-/$(openssl rand -hex 12)}"
  PG_SUB_TOKEN="${PG_SUB_TOKEN:-$(openssl rand -hex 16)}"
fi
cat > "$DIR/settings.env" <<EOF
# ProxyGPT: настройки установки (их читает install.sh при повторном запуске)
PG_DOMAIN=$DOMAIN
PG_IP=$IP
PG_EMAIL=$EMAIL
PG_UUID1=$PG_UUID1
PG_UUID2=$PG_UUID2
PG_RELAY=$RELAY
PG_RELAY_UUID=${PG_RELAY_UUID:-}
PG_RELAY_PATH=${PG_RELAY_PATH:-}
PG_SUB_TOKEN=${PG_SUB_TOKEN:-}
PG_PAGE_TOKEN=$PG_PAGE_TOKEN
PG_PROXY=$PROXY
EOF
chmod 600 "$DIR/settings.env"

# пункты проверки для страницы: Claude и ChatGPT, если они в списке
CHECK_ITEMS="" CHECK_CLI=""
for d in claude.ai chatgpt.com; do
  printf '%s\n' "${SITES[@]}" | grep -qx "$d" || continue
  CHECK_ITEMS="$CHECK_ITEMS  <li><a href=\"https://$d/cdn-cgi/trace\">$d/cdn-cgi/trace</a> - должно быть <code>ip=__IP__</code> и <code>loc=__LOC__</code>: $d идёт через сервер.</li>"
  [ "$d" = "$CHECK_SITE" ] || CHECK_CLI="${CHECK_CLI:+$CHECK_CLI }Для $d - то же самое с адресом $d."
done
[ -n "$CHECK_ITEMS" ] || CHECK_ITEMS="  <li><a href=\"https://__SITE__/cdn-cgi/trace\">__SITE__/cdn-cgi/trace</a> - должно быть <code>ip=__IP__</code>: сайт идёт через сервер.</li>"

# DNS stamp для dnscrypt-proxy на Windows 10: DoH на IP сервера, имя для TLS, путь; без привязки к сертификату
stamp_lp() { printf "\\$(printf '%03o' "${#1}")%s" "$1"; }
STAMP="sdns://$( { printf '\002\006\000\000\000\000\000\000\000'; stamp_lp "$IP"; printf '\000'; stamp_lp "$DOMAIN"; stamp_lp /dns-query; } | base64 | tr '+/' '-_' | tr -d '=\n')"

fill() { sed -e "s|__PAGE__|$PG_PAGE_TOKEN|g" -e "s|__STAMP__|$STAMP|g" -e "s|__CHECK_ITEMS__|$CHECK_ITEMS|g" -e "s|__CHECK_CLI__|$CHECK_CLI|g" -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__IP__|$IP|g" -e "s|__LOC__|${LOC:-??}|g" -e "s|__SITE__|$CHECK_SITE|g" -e "s|__UUID1__|$PG_UUID1|g" -e "s|__UUID2__|$PG_UUID2|g" -e "s|__RELAY_UUID__|${PG_RELAY_UUID:-}|g" -e "s|__RELAY_PATH__|${PG_RELAY_PATH:-}|g"; }

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
  if [ "$PROXY" = 1 ]; then
    for d in "${SITES[@]}"; do
      printf '        %-46s %s\n' "~^([a-z0-9-]+\\.)*$(printf '%s' "$d" | sed 's/\./\\./g')\$" '$ssl_preread_server_name:443;'
    done
  else
    echo "        # прокси выключен (--stop proxy): сайты не пересылаются"
  fi
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
        location = /dns-query {
            proxy_pass https://127.0.0.1:8444;
            proxy_http_version 1.1;
            proxy_ssl_server_name on;
            proxy_ssl_name __DOMAIN__;
            proxy_set_header Host __DOMAIN__;
            proxy_buffering off;
        }
        # Страница настройки устройств - только по секретному адресу /<секрет>/, корень закрыт.
        location = /__PAGE__ { return 301 /__PAGE__/; }
        location ^~ /__PAGE__/ {
            alias /srv/www/;
            index index.html;
            types { text/html html; application/x-apple-aspen-config mobileconfig; text/plain ps1; }
            default_type application/octet-stream;
        }
        include /etc/nginx/proxygpt/relay-location*.conf;   # приёмник (--relay), если включён
        location / { return 404; }
    }
}
EOF
} | fill > "$DIR/conf/nginx.conf"

# CoreDNS: сайты из списка -> IP сервера, у них же пустые AAAA и HTTPS (иначе устройство уйдёт напрямую),
# остальное - обычный ответ через Cloudflare DNS по TLS.
ZONES="${SITES[*]}"
if [ "$PROXY" = 1 ]; then
  TEMPLATES="    template IN A $ZONES {
        answer \"{{ .Name }} 60 IN A __IP__\"
    }
    template IN AAAA $ZONES {
        rcode NOERROR
    }
    template IN HTTPS $ZONES {
        rcode NOERROR
    }"
else
  TEMPLATES="    # прокси выключен (--stop proxy): все адреса - настоящие"
fi
cat <<EOF | fill > "$DIR/conf/Corefile"
# Сгенерировано install.sh. Правки - в sites.txt, затем запустить установку ещё раз.
(sites) {
$TEMPLATES
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

# Приёмник (--relay): VLESS через WebSocket за nginx на пути __RELAY_PATH__ того же имени DNS-сервера.
# Для промежуточного VPN это обычное HTTPS к имени DNS-сервера. Выпускает только сайты из sites.txt.
if [ "$RELAY" = 1 ]; then
  cat <<'EOF' | fill > "$DIR/conf/relay-location.conf"
location = __RELAY_PATH__ {
    if ($http_upgrade != "websocket") { return 404; }
    proxy_pass http://127.0.0.1:10086;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_buffering off;
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;
}

# Страница и подписка Happ (сервис proxygpt-sub): /happ/<секрет>/
location ^~ /happ/ {
    proxy_pass http://127.0.0.1:8446;
    proxy_set_header Host $host;
    proxy_read_timeout 60s;
}
EOF
  RELAY_DOMAINS="$(printf '"domain:%s",' "${SITES[@]}")"; RELAY_DOMAINS="[${RELAY_DOMAINS%,}]"
  cat <<EOF | fill > "$DIR/conf/xray.json"
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1", "port": 10086, "protocol": "vless",
    "settings": {"clients": [{"id": "__RELAY_UUID__"}], "decryption": "none"},
    "streamSettings": {"network": "ws", "wsSettings": {"path": "__RELAY_PATH__"}},
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}
  }],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
    {"tag": "block", "protocol": "blackhole"}
  ],
  "routing": {"domainStrategy": "AsIs", "rules": [
    {"type": "field", "domain": $RELAY_DOMAINS, "outboundTag": "direct"},
    {"type": "field", "network": "tcp,udp", "outboundTag": "block"}
  ]}
}
EOF
  chmod 644 "$DIR/conf/xray.json"
  RELAY_LINK="vless://${PG_RELAY_UUID}@${IP}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&alpn=http%2F1.1&type=ws&host=${DOMAIN}&path=$(printf '%s' "$PG_RELAY_PATH" | sed 's|/|%2F|g')#ProxyGPT-${DOMAIN}"
  # сервис страницы и подписки Happ
  mkdir -p "$DIR/app"
  curl -fsSL "$RAW/tools/happ_relay.py" -o "$DIR/app/happ_relay.py.new" && mv "$DIR/app/happ_relay.py.new" "$DIR/app/happ_relay.py" \
    || { [ -f "$DIR/app/happ_relay.py" ] && warn "не удалось обновить happ_relay.py, оставляю прежний" || die "не удалось скачать $RAW/tools/happ_relay.py"; }
  chmod 644 "$DIR/app/happ_relay.py"
  printf 'RELAY_LINK=%s\nSUB_TOKEN=%s\nSITES=%s\n' "$RELAY_LINK" "$PG_SUB_TOKEN" "${SITES[*]}" > "$DIR/sub.env"
  chmod 600 "$DIR/sub.env"
else
  rm -f "$DIR/conf/relay-location.conf" "$DIR/conf/xray.json" "$DIR/sub.env"
fi

# Все секретные ссылки - в одном файле (только root).
{
  echo "# ProxyGPT: секретные ссылки. С ними можно пользоваться вашим сервером - никому не пересылайте."
  echo
  echo "# Страница настройки устройств: профиль DNS для iPhone и Mac, Android, Windows, проверка"
  echo "https://${DOMAIN}/${PG_PAGE_TOKEN}/"
  if [ "$RELAY" = 1 ]; then
    echo
    echo "# Страница подписки Happ (работа через другой VPN): вставить ссылку подписки VPN -> «Добавить в Happ»"
    echo "https://${DOMAIN}/happ/${PG_SUB_TOKEN}/"
    echo
    echo "# Ссылка приёмника для клиентов Xray (Happ, v2RayTun, Streisand) и для tools/happ_relay.py"
    echo "$RELAY_LINK"
    echo
    echo "# Выход Xray для цепочки через другой VPN: dialerProxy - тег сервера этого VPN в его профиле."
    printf '{"tag":"proxygpt","protocol":"vless","settings":{"vnext":[{"address":"%s","port":443,"users":[{"id":"%s","encryption":"none"}]}]},"streamSettings":{"network":"ws","security":"tls","tlsSettings":{"serverName":"%s","fingerprint":"chrome","alpn":["http/1.1"]},"wsSettings":{"path":"%s","host":"%s"},"sockopt":{"dialerProxy":"<тег сервера VPN>"}}}\n' "$IP" "$PG_RELAY_UUID" "$DOMAIN" "$PG_RELAY_PATH" "$DOMAIN"
  fi
} > "$DIR/links.txt"
chmod 600 "$DIR/links.txt"
rm -f "$DIR/relay.txt"   # прежнее место ссылок приёмника

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
if [ "$RELAY" = 1 ]; then
  cat >> "$DIR/compose.yml" <<'EOF'

  relay:
    image: ghcr.io/xtls/xray-core:latest
    container_name: proxygpt-relay
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./conf:/etc/proxygpt:ro
    command: ["run", "-c", "/etc/proxygpt/xray.json"]
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }

  sub:
    image: python:3-alpine
    container_name: proxygpt-sub
    restart: unless-stopped
    network_mode: host
    user: "65534:65534"
    env_file: sub.env
    volumes:
      - ./app:/app:ro
    command: ["python3", "-I", "/app/happ_relay.py", "--serve", "127.0.0.1:8446"]
    logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
EOF
fi

# ---------- файлы для устройств ----------

# iPhone, iPad, Mac: профиль DNS (DoH). PayloadScope=System обязателен для macOS 26: без него
# установка падает с ошибкой «Не удалось создать службу VPN».
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
                <!-- не уходить на DNS сети, если этот сервер недоступен: Claude не пойдёт напрямую (iOS/macOS 26+) -->
                <key>AllowFailover</key>
                <false/>
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
    <key>PayloadScope</key>
    <string>System</string>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>__UUID2__</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOF

# Windows 10 и 11 (PowerShell от администратора). В Windows 11 есть свой DoH; в Windows 10 его нет -
# ставится служба dnscrypt-proxy (DoH-клиент) на 127.0.0.1:53. Результат проверяется, при ошибке всё возвращается.
cat <<'EOF' | fill > "$DIR/www/windows.ps1"
# ProxyGPT DNS for Windows 10 and 11. Run in PowerShell as Administrator:
#   irm https://__DOMAIN__/__PAGE__/windows.ps1 | iex
# Windows 11: built-in DNS over HTTPS (DoH) to __IP__.
# Windows 10 has no built-in DoH: installs the open-source dnscrypt-proxy service
#   (github.com/DNSCrypt/dnscrypt-proxy) into "C:\Program Files\ProxyGPT" and sets DNS to 127.0.0.1.
# The result is checked; if the check fails, everything is put back.
# Undo (works without internet), PowerShell as Administrator:
#   Get-NetAdapter | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses }
#   $e = "$env:ProgramFiles\ProxyGPT\dnscrypt-proxy.exe"; if (Test-Path $e) { & $e -service stop; & $e -service uninstall; Start-Sleep 2; Remove-Item -Recurse -Force (Split-Path $e) }
#   Clear-DnsClientCache
& {
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ip    = '__IP__'
$doh   = 'https://__DOMAIN__/dns-query'
$stamp = '__STAMP__'
$site  = '__SITE__'
$dir   = Join-Path $env:ProgramFiles 'ProxyGPT'
$exe   = Join-Path $dir 'dnscrypt-proxy.exe'
$conf  = Join-Path $dir 'dnscrypt-proxy.toml'
$log   = Join-Path $dir 'dnscrypt-proxy.log'

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }

# DNS on every network adapter, also on the ones not connected now
function Set-Dns([string[]]$servers) {
    foreach ($a in Get-NetAdapter) {
        try { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers; Say ('DNS set: ' + $a.Name) }
        catch {
            $v4 = @($servers | Where-Object { $_ -notlike '*:*' })
            if ($v4.Count -lt $servers.Count) {
                try { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $v4; Say ('DNS set (IPv4): ' + $a.Name) } catch {}
            }
        }
    }
    Clear-DnsClientCache
}
function Reset-Dns {
    foreach ($a in Get-NetAdapter) { try { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses } catch {} }
    Clear-DnsClientCache
}
# __SITE__ must resolve to the server, an ordinary site must resolve too
function Test-Dns([string]$server) {
    $p = @{ Type = 'A'; DnsOnly = $true; QuickTimeout = $true }
    if ($server) { $p.Server = $server }
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $a = @(Resolve-DnsName $site @p | Where-Object Type -eq 'A' | ForEach-Object IPAddress)
            $b = @(Resolve-DnsName 'example.com' @p | Where-Object Type -eq 'A')
            if (($a -contains $ip) -and $b.Count) { return $true }
        } catch {}
        Start-Sleep 2
        Clear-DnsClientCache
    }
    return $false
}
function Remove-Svc {
    Stop-Service dnscrypt-proxy -Force -ErrorAction SilentlyContinue
    if (Get-Service dnscrypt-proxy -ErrorAction SilentlyContinue) { sc.exe delete dnscrypt-proxy | Out-Null }
    Start-Sleep 2
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Say 'Run PowerShell as Administrator: right click Start -> Windows PowerShell (Admin) or Terminal (Admin).' Red; return }

$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber

# ---- Windows 11: built-in DoH ----
if (($build -ge 20348) -and (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) {
    Say "Windows build ${build}: built-in DNS over HTTPS"
    if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {
        Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $doh -AllowFallbackToUdp $false -AutoUpgrade $true | Out-Null
    } else {
        Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $doh -AllowFallbackToUdp $false -AutoUpgrade $true | Out-Null
    }
    Set-Dns @($ip)
    if (-not (Test-Dns)) {
        Reset-Dns
        Say 'Check failed: DNS is back to automatic, nothing changed. Turn off VPN and try again, or use the browser setting from the page.' Red
        return
    }
    Say "Done. DNS = $ip over HTTPS ($doh)" Green
    return
}

# ---- Windows 10: dnscrypt-proxy service ----
Say "Windows build ${build}: no built-in DNS over HTTPS, installing the dnscrypt-proxy service"
$svc = Get-CimInstance Win32_Service -Filter "Name='dnscrypt-proxy'"
if ($svc -and ($svc.PathName -notlike "*$dir*")) {
    Say ('Another dnscrypt-proxy service is already installed: ' + $svc.PathName) Red
    Say 'Nothing changed. Remove it first, or use the browser setting from the page.' Red
    return
}
$tmp = Join-Path $env:TEMP ('proxygpt-' + [guid]::NewGuid().ToString('N'))
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $arch = 'win32'
    if ([Environment]::Is64BitOperatingSystem -and $env:PROCESSOR_ARCHITECTURE -ne 'ARM64' -and $env:PROCESSOR_ARCHITEW6432 -ne 'ARM64') { $arch = 'win64' }
    $rel = Invoke-RestMethod 'https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest' -UserAgent 'ProxyGPT' -UseBasicParsing
    $asset = $rel.assets | Where-Object { $_.name -match "^dnscrypt-proxy-$arch-[0-9.]+\.zip$" } | Select-Object -First 1
    if (-not $asset) { throw "no $arch build in release $($rel.tag_name)" }
    New-Item -ItemType Directory $tmp | Out-Null
    $zip = Join-Path $tmp $asset.name
    Say ('Downloading ' + $asset.browser_download_url)
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    if (("$($asset.digest)" -match '^sha256:([0-9a-f]{64})$') -and ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $Matches[1])) { throw 'checksum mismatch' }
    Expand-Archive $zip -DestinationPath $tmp -Force
    $new = Get-ChildItem $tmp -Recurse -Filter 'dnscrypt-proxy.exe' | Select-Object -First 1
    if (-not $new) { throw 'dnscrypt-proxy.exe is not in the archive' }
} catch {
    Say ('Download failed, nothing changed: ' + $_.Exception.Message) Red
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    return
}

$switched = $false
try {
    if ($svc) { Remove-Svc }
    New-Item -ItemType Directory -Force $dir | Out-Null
    Copy-Item $new.FullName $exe -Force
    Get-ChildItem $tmp -Recurse -Filter 'LICENSE' | Select-Object -First 1 | Copy-Item -Destination (Join-Path $dir 'LICENSE') -Force
    $toml = @"
# ProxyGPT: DNS over HTTPS to __DOMAIN__ (__IP__), made by windows.ps1
listen_addresses = ['127.0.0.1:53', '[::1]:53']
server_names = ['proxygpt']
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = true
doh_servers = true
require_dnssec = false
require_nolog = false
require_nofilter = false
ignore_system_dns = true
netprobe_address = '__IP__:443'
netprobe_timeout = 60
timeout = 5000
keepalive = 30
cache = true
cache_min_ttl = 60
cache_max_ttl = 600
cache_neg_min_ttl = 10
cache_neg_max_ttl = 60
log_level = 2
log_file = '$log'
log_files_max_size = 2

[static]
  [static.'proxygpt']
  stamp = '$stamp'
"@
    [IO.File]::WriteAllText($conf, $toml, (New-Object Text.ASCIIEncoding))
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    & $exe -config $conf -service install 2>&1 | Out-Null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $eap
    if ($code) { throw "service install failed (code $code)" }
    sc.exe failure dnscrypt-proxy reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Start-Service dnscrypt-proxy
    if (-not (Test-Dns '127.0.0.1')) { throw 'dnscrypt-proxy does not answer on 127.0.0.1' }
    $switched = $true
    Set-Dns @('127.0.0.1', '::1')
    if (-not (Test-Dns)) { throw 'Windows does not use the new DNS (is a VPN on?)' }
} catch {
    Say ('Check failed: ' + $_.Exception.Message) Red
    if (Test-Path $log) { Get-Content $log -Tail 5 | ForEach-Object { Say ('  ' + $_) } }
    if ($switched -or $svc) { Reset-Dns; Say 'DNS is back to automatic.' Yellow }
    Remove-Svc
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    Say 'dnscrypt-proxy removed. Turn off VPN and try again, or use the browser setting from the page.' Yellow
    return
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Say "Done. DNS = 127.0.0.1 (dnscrypt-proxy service) -> $doh" Green
}
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
  <li>Откройте эту страницу в <b>Safari</b> и нажмите кнопку: <br><a class="btn" href="apple.mobileconfig">Скачать профиль DNS</a></li>
  <li>«Разрешить» → Настройки → вверху «Профиль загружен» → Установить.</li>
  <li>Проверьте: Настройки → Основные → VPN и управление устройством → DNS → выбран «ProxyGPT DNS».</li>
</ol>

<h2>Mac</h2>
<pre>curl -fsSL https://__DOMAIN__/__PAGE__/apple.mobileconfig -o ~/Downloads/proxygpt-dns.mobileconfig &amp;&amp; open ~/Downloads/proxygpt-dns.mobileconfig</pre>
<p>Затем Системные настройки → Основные → Управление устройством (или поиск «Профили») → «ProxyGPT DNS» → Установить.</p>

<h2>Android 9 и новее</h2>
<ol>
  <li>Настройки → Сеть и интернет → <b>Частный DNS</b> (на Samsung: Подключения → Другие настройки → Частный DNS).</li>
  <li>«Имя хоста поставщика частного DNS»: <pre>__DOMAIN__</pre></li>
</ol>

<h2>Windows 10 и 11</h2>
<ol>
  <li>Нажмите <b>правой кнопкой на «Пуск»</b> → «Windows PowerShell (администратор)» (в Windows 11 - «Терминал (администратор)») → «Да».</li>
  <li>Вставьте команду (правой кнопкой мыши в окне) и нажмите Enter: <pre>irm https://__DOMAIN__/__PAGE__/windows.ps1 | iex</pre></li>
  <li>Дождитесь зелёной надписи <b>Done</b>. Красная <b>Check failed</b> - не получилось, и скрипт уже вернул всё как было.</li>
</ol>
<p class="muted">Windows 11 умеет шифровать DNS сама, скрипт только включает это. В Windows 10 такого нет, поэтому скрипт ставит небольшую открытую программу <a href="https://github.com/DNSCrypt/dnscrypt-proxy">dnscrypt-proxy</a> (служба в C:\Program Files\ProxyGPT, скачивается с GitHub, контрольная сумма проверяется), и Windows ходит за DNS через неё.</p>

<h3>Вернуть как было</h3>
<p>Работает и без интернета. Откройте PowerShell от имени администратора (как в шаге 1), вставьте <b>все три строки сразу</b> и нажмите Enter:</p>
<pre>Get-NetAdapter | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses }
$e = "$env:ProgramFiles\ProxyGPT\dnscrypt-proxy.exe"; if (Test-Path $e) { &amp; $e -service stop; &amp; $e -service uninstall; Start-Sleep 2; Remove-Item -Recurse -Force (Split-Path $e) }
Clear-DnsClientCache</pre>
<p class="muted">DNS снова станет автоматическим (от роутера или провайдера), служба dnscrypt-proxy удалится, если она была.</p>

<h3>Только браузер, без изменений в Windows</h3>
<p>Если ставить ничего не хочется: работает в браузере, но не в приложениях Claude и ChatGPT. В настройках браузера найдите «Безопасный DNS» (в Firefox - «DNS через HTTPS», режим «Максимальная защита»), выберите своего (другого) поставщика и вставьте адрес:</p>
<pre>https://__DOMAIN__/dns-query</pre>
<p class="muted">Chrome: Настройки → Конфиденциальность и безопасность → Безопасность. Edge: Настройки → Конфиденциальность, поиск и службы → Безопасность. Firefox: Настройки → Приватность и защита.</p>

<h2>Linux (systemd-resolved)</h2>
<pre>sudo mkdir -p /etc/systemd/resolved.conf.d &amp;&amp; printf '[Resolve]\nDNS=__IP__#__DOMAIN__\nDNSOverTLS=yes\n' | sudo tee /etc/systemd/resolved.conf.d/proxygpt.conf &amp;&amp; sudo systemctl restart systemd-resolved</pre>

<h2>Проверка</h2>
<p>Выключите VPN, если он включён, и откройте на настроенном устройстве три адреса:</p>
<ol>
__CHECK_ITEMS__
  <li><a href="https://www.cloudflare.com/cdn-cgi/trace">cloudflare.com/cdn-cgi/trace</a> - здесь должен быть ваш обычный IP: остальные сайты идут напрямую.</li>
  <li><a href="https://__DOMAIN__/__PAGE__/">эта страница</a> открывается - сервер доступен.</li>
</ol>
<p>В проверке Claude или ChatGPT ваш обычный IP - DNS на устройстве не применился (см. ниже). Везде <code>__IP__</code> - включён VPN через этот же сервер.</p>
<p>Из командной строки:</p>
<pre>Mac, Linux:  curl -s https://__SITE__/cdn-cgi/trace | grep -E '^(ip|loc)='
Windows:     Resolve-DnsName __SITE__ -Type A        (IPAddress должен быть __IP__)
Android:     открыть в браузере __SITE__/cdn-cgi/trace
__CHECK_CLI__</pre>

<h2>Если не работает</h2>
<ul>
  <li>iPhone и Mac: выключите «Частный узел iCloud» (Private Relay) - он обходит DNS в Safari.</li>
  <li>Chrome, Edge: «Безопасный DNS» - «Использовать текущего поставщика» или адрес https://__DOMAIN__/dns-query (см. «Только браузер»).</li>
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
run_checks || ok=0

cat <<EOF

$( [ $ok = 1 ] && printf '\033[1;32mГотово.\033[0m' || printf '\033[1;33mУстановлено, но проверка нашла ошибки (см. выше).\033[0m' )

Страница настройки устройств (секретная, откройте на телефоне):

  https://$DOMAIN/$PG_PAGE_TOKEN/

  iPhone, iPad, Mac:  https://$DOMAIN/$PG_PAGE_TOKEN/apple.mobileconfig  (профиль DNS)
  Android:            Частный DNS -> $DOMAIN
  Windows 10, 11:     irm https://$DOMAIN/$PG_PAGE_TOKEN/windows.ps1 | iex   (PowerShell от администратора)

Сайты: ${SITES[*]}$( [ "$PROXY" = 1 ] || printf '  (прокси ВЫКЛЮЧЕН - идут напрямую; включить: --start proxy)' )
Правка списка: $DIR/sites.txt, затем запустить установку ещё раз.
Журнал прокси: docker logs -f proxygpt-nginx
Проверка на устройстве: раздел «Проверка» на странице настройки
Проверка на сервере: та же команда установки с параметром --check
Остановка и запуск: --status, --stop [all|dns|proxy|relay], --start [...] (подробно - README)
EOF

if [ "$RELAY" = 1 ]; then
  cat <<EOF

Работа через другой VPN (приёмник включён). Страница подписки Happ - откройте на телефоне,
вставьте ссылку подписки своего VPN и нажмите «Добавить в Happ»:

  https://$DOMAIN/happ/$PG_SUB_TOKEN/

Ссылка секретная: по ней можно ходить через ваш сервер. Она не меняется при повторных запусках установки.
Все секретные ссылки ещё раз:  cat $DIR/links.txt
EOF
fi
