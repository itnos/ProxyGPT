#!/usr/bin/env python3
"""ProxyGPT: профили Happ «сайт -> VPN -> приёмник на вашем сервере -> сайт».

Берёт JSON-подписку VPN-сервиса в формате Happ (массив конфигов Xray) и в каждый конфиг добавляет:
  - выход `proxygpt` (VLESS через WebSocket до приёмника, его включает `install.sh --relay`);
  - `loopback`, чтобы подключение к приёмнику шло через собственный автовыбор (балансировщик) VPN -
    тот же, что работает в этой сети, в том числе на мобильном с белыми списками;
  - правила: сайты из списка -> `proxygpt`, их QUIC (UDP) закрыт.
Всё остальное в конфигах VPN не меняется.

Два режима:
  1) На компьютере - собрать файл профилей:
       python3 tools/happ_relay.py --sub "https://подписка-вашего-vpn" --relay "vless://...из links.txt" -o happ.json
  2) На сервере (его запускает install.sh --relay) - страница и своя подписка для Happ, которая при каждом
     обновлении берёт свежие профили VPN:
       RELAY_LINK=vless://... SUB_TOKEN=секрет python3 happ_relay.py --serve 127.0.0.1:8446
     Страница: https://<имя DNS-сервера>/happ/<SUB_TOKEN>/
"""
import argparse
import base64
import hmac
import html
import http.cookiejar
import ipaddress
import json
import os
import socket
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# как в install.sh: Claude, ChatGPT и сторонние адреса их страниц
DEFAULT_SITES = ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com",
                 "chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com",
                 "claudemcpcontent.com", "claude.site", "chatgpt.site", "oaistatsig.com",
                 "hcaptcha.com", "challenges.cloudflare.com",
                 "browser-intake-datadoghq.com", "browser-intake-us5-datadoghq.com", "sentry.io",
                 "statsigapi.net", "featuregates.org", "growthbook.io",
                 "intercom.io", "intercomcdn.com", "stripe.com", "stripe.network", "stripecdn.com"]
PASS_HEADERS = ("subscription-userinfo", "support-url", "profile-web-page-url")


class FetchError(Exception):
    pass


def check_public_https(url: str) -> None:
    """Пускаем только https на публичные адреса: сервис не должен ходить во внутренние сети."""
    u = urllib.parse.urlsplit(url)
    if u.scheme != "https" or not u.hostname:
        raise FetchError("нужна ссылка https://")
    try:
        infos = socket.getaddrinfo(u.hostname, u.port or 443, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        raise FetchError("имя сервера подписки не найдено")
    for info in infos:
        if not ipaddress.ip_address(info[4][0]).is_global:
            raise FetchError("адрес подписки ведёт во внутреннюю сеть")


def fetch_subscription(url: str, user_agent: str = "Happ/3.0"):
    """JSON-подписка VPN. Некоторые сервисы ставят cookie защиты от ботов через переадресацию."""
    check_public_https(url)
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    req = urllib.request.Request(url, headers={"User-Agent": user_agent})
    try:
        with opener.open(req, timeout=20) as r:
            body = r.read(5_000_000).decode("utf-8", errors="replace").strip()
            headers = {k.lower(): v for k, v in r.headers.items()}
    except Exception as e:  # noqa: BLE001 - любую ошибку сети отдаём одним сообщением
        raise FetchError(f"подписка VPN не открылась: {e}")
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        raise FetchError("подписка отдала не JSON: нужна JSON-подписка в формате Happ")
    return (data if isinstance(data, list) else [data]), headers


def parse_relay(link: str) -> dict:
    u = urllib.parse.urlsplit(link.strip())
    if u.scheme != "vless" or not u.username or not u.hostname:
        sys.exit("нужна ссылка приёмника vless://... из /opt/proxygpt/links.txt")
    q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
    if q.get("type") != "ws" or q.get("security") != "tls":
        sys.exit("ожидается ссылка приёмника ProxyGPT (type=ws, security=tls)")
    return {"uuid": urllib.parse.unquote(u.username), "address": u.hostname, "port": u.port or 443,
            "sni": q.get("sni") or q.get("host"), "host": q.get("host") or q.get("sni"),
            "path": urllib.parse.unquote(q.get("path", "/"))}


def add_relay(cfg: dict, relay: dict, domains: list) -> str:
    outs = cfg.setdefault("outbounds", [])
    rules = cfg.setdefault("routing", {}).setdefault("rules", [])
    proxies = [o for o in outs if o.get("protocol") not in ("freedom", "blackhole", "dns", "loopback")]
    if not proxies or any(o.get("tag") == "proxygpt" for o in outs):
        return "пропущен"
    bal = next((r["balancerTag"] for r in rules if r.get("balancerTag")), None)
    main = {"balancerTag": bal} if bal else {"outboundTag": proxies[0]["tag"]}
    block = next((o["tag"] for o in outs if o.get("protocol") == "blackhole"), None)
    outs += [
        {"tag": "proxygpt", "protocol": "vless",
         "settings": {"vnext": [{"address": relay["address"], "port": relay["port"],
                                 "users": [{"id": relay["uuid"], "encryption": "none"}]}]},
         "streamSettings": {"network": "ws", "security": "tls",
                            "tlsSettings": {"serverName": relay["sni"], "fingerprint": "chrome", "alpn": ["http/1.1"]},
                            "wsSettings": {"path": relay["path"], "host": relay["host"]},
                            "sockopt": {"dialerProxy": "proxygpt-loop"}}},
        # подключение к приёмнику заворачивается обратно в маршрутизацию и идёт через автовыбор VPN
        {"tag": "proxygpt-loop", "protocol": "loopback", "settings": {"inboundTag": "proxygpt-in"}},
    ]
    dom = ["domain:" + d for d in domains]
    new = [{"type": "field", "inboundTag": ["proxygpt-in"], **main}]
    if block:
        new.append({"type": "field", "domain": dom, "network": "udp", "outboundTag": block})
    new.append({"type": "field", "domain": dom, "outboundTag": "proxygpt"})
    cfg["routing"]["rules"] = new + rules
    cfg["remarks"] = cfg.get("remarks", "") + " · мой сервер"
    return "через балансировщик VPN" if bal else "через сервер VPN"


# ---------- сервер: страница и подписка ----------

PAGE = """<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex"><title>Подписка Happ: VPN + мой сервер</title>
<style>
 body{font:16px/1.55 system-ui,-apple-system,sans-serif;max-width:720px;margin:0 auto;padding:24px 18px 60px;color:#1b1b1f;background:#fafafa}
 h1{font-size:24px;margin:0 0 6px} .muted{color:#666} input{width:100%;box-sizing:border-box;font:inherit;padding:12px;border:1px solid #ccc;border-radius:10px}
 .btn{display:inline-block;background:#1b1b1f;color:#fff;text-decoration:none;padding:12px 18px;border-radius:10px;margin:8px 8px 0 0;border:0;font:inherit;cursor:pointer}
 .btn[aria-disabled=true]{opacity:.35;pointer-events:none} code{font:14px ui-monospace,Menlo,monospace;word-break:break-all}
 li{margin:4px 0} @media(prefers-color-scheme:dark){body{background:#151518;color:#ececf1}.btn{background:#ececf1;color:#151518}.muted{color:#9a9aa3}input{background:#1f1f24;color:#ececf1;border-color:#333}}
</style></head><body>
<h1>Подписка Happ: VPN + мой сервер</h1>
<p class="muted">Вставьте ссылку подписки вашего VPN (ту, что открывается в Happ). Получится своя подписка: всё идёт через ваш VPN как обычно, а __SITES__ - через VPN и дальше через сервер __SERVER__. Профили VPN берутся свежие при каждом обновлении подписки в Happ.</p>
<p><input id="src" type="url" placeholder="https://ссылка-подписки-вашего-vpn" autocomplete="off" autocapitalize="off" spellcheck="false"></p>
<p><a id="add" class="btn" aria-disabled="true" href="#">Добавить в Happ</a><button id="copy" class="btn" aria-disabled="true" type="button">Скопировать ссылку</button></p>
<p id="out" class="muted"></p>
<ol class="muted">
 <li>«Добавить в Happ» откроет приложение. Если не открыло - «Скопировать ссылку», затем в Happ «+» → «Вставить из буфера».</li>
 <li>Подключитесь к любому профилю с пометкой «· мой сервер». Родное приложение VPN выключите.</li>
 <li>Проверка: <a href="https://claude.ai/cdn-cgi/trace">claude.ai/cdn-cgi/trace</a> и <a href="https://chatgpt.com/cdn-cgi/trace">chatgpt.com/cdn-cgi/trace</a> показывают <code>ip=__SERVER__</code>, а <a href="https://www.cloudflare.com/cdn-cgi/trace">cloudflare.com/cdn-cgi/trace</a> - адрес сервера VPN.</li>
</ol>
<p class="muted">Эта страница и ссылка подписки - секретные: по ним можно ходить через ваш сервер. Ссылку VPN сервер не хранит, она живёт только внутри ссылки подписки.</p>
<script>
const src = document.getElementById('src'), add = document.getElementById('add'), copy = document.getElementById('copy'), out = document.getElementById('out');
let link = '';
src.addEventListener('input', () => {
  const v = src.value.trim(), ok = /^https:\\/\\/\\S+$/.test(v);
  link = ok ? location.origin + location.pathname.replace(/\\/?$/, '/') + 'sub?url=' + encodeURIComponent(v) : '';
  add.href = ok ? 'happ://add/' + link : '#';
  add.setAttribute('aria-disabled', !ok); copy.setAttribute('aria-disabled', !ok);
  out.textContent = ok ? 'Ссылка готова.' : (v ? 'Нужна ссылка вида https://...' : '');
});
copy.addEventListener('click', async () => {
  try { await navigator.clipboard.writeText(link); out.textContent = 'Скопировано. В Happ: «+» → «Вставить из буфера».'; }
  catch (e) { out.textContent = link; }
});
</script></body></html>"""


def make_handler(relay: dict, token: str, sites: list):
    base = f"/happ/{token}/"
    shown = ", ".join(s for s in sites if s in ("claude.ai", "chatgpt.com")) or ", ".join(sites)
    page = PAGE.replace("__SITES__", html.escape(shown)).replace("__SERVER__", html.escape(relay["address"])).encode()

    class Handler(BaseHTTPRequestHandler):
        server_version = "ProxyGPT"
        sys_version = ""

        def log_message(self, fmt, *args):  # в журнал - без ссылок: в них секреты
            sys.stderr.write(f"{self.log_date_time_string()} {self.command} {self.path.split('?')[0][:6]}… {args[1] if len(args) > 1 else ''}\n")

        def send(self, code, body, ctype="text/plain; charset=utf-8", extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Robots-Tag", "noindex, nofollow")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path, _, query = self.path.partition("?")
            if not (path.startswith("/happ/") and hmac.compare_digest(path[:len(base)], base)):
                return self.send(404, b"not found")
            rest = path[len(base):]
            if rest == "":
                return self.send(200, page, "text/html; charset=utf-8")
            if rest != "sub":
                return self.send(404, b"not found")
            src = urllib.parse.parse_qs(query).get("url", [""])[0]
            ua = self.headers.get("User-Agent", "")
            try:
                cfgs, hdrs = fetch_subscription(src, ua if "happ" in ua.lower() else "Happ/3.0")
            except FetchError as e:
                return self.send(502, str(e).encode())
            for c in cfgs:
                add_relay(c, relay, sites)
            extra = {k: hdrs[k] for k in PASS_HEADERS if k in hdrs}
            title = hdrs.get("profile-title", "")
            title = title if title and not title.startswith("base64:") and len(title) <= 12 else "VPN"
            # кириллицу в заголовке HTTP передать нельзя - название в base64 (Happ понимает приставку base64:)
            extra["profile-title"] = "base64:" + base64.b64encode(f"{title} · мой сервер"[:25].encode()).decode()
            extra["profile-update-interval"] = "6"
            body = json.dumps(cfgs, ensure_ascii=False, separators=(",", ":")).encode()
            return self.send(200, body, "application/json; charset=utf-8", extra)

    return Handler


def serve(listen: str) -> None:
    relay = parse_relay(os.environ.get("RELAY_LINK", ""))
    token = os.environ.get("SUB_TOKEN", "")
    if len(token) < 16:
        sys.exit("SUB_TOKEN не задан или слишком короткий")
    sites = os.environ.get("SITES", " ".join(DEFAULT_SITES)).split()
    host, _, port = listen.rpartition(":")
    srv = ThreadingHTTPServer((host or "127.0.0.1", int(port)), make_handler(relay, token, sites))
    print(f"ProxyGPT: подписка Happ на {listen}, сайтов: {len(sites)}", flush=True)
    srv.serve_forever()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serve", metavar="HOST:PORT", help="режим сервера (страница и подписка Happ)")
    ap.add_argument("--sub", help="ссылка JSON-подписки VPN (формат Happ)")
    ap.add_argument("--in", dest="infile", help="или уже скачанный JSON-файл подписки")
    ap.add_argument("--relay", help="vless://... из /opt/proxygpt/links.txt на сервере")
    ap.add_argument("--sites", default=" ".join(DEFAULT_SITES), help="сайты через ваш сервер (через пробел)")
    ap.add_argument("-o", "--out", help="куда записать профили для Happ")
    a = ap.parse_args()
    if a.serve:
        return serve(a.serve)
    if not (a.sub or a.infile) or not a.relay or not a.out:
        ap.error("для файла профилей нужны --sub (или --in), --relay и -o")
    try:
        cfgs = fetch_subscription(a.sub)[0] if a.sub else json.load(open(a.infile, encoding="utf-8"))
    except FetchError as e:
        sys.exit(str(e))
    relay = parse_relay(a.relay)
    for c in cfgs:
        print(f"  {c.get('remarks', '?')[:60]:60} {add_relay(c, relay, a.sites.split())}")
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(cfgs, f, ensure_ascii=False, separators=(",", ":"))
    print(f"Готово: {len(cfgs)} профилей -> {a.out}. В файле ключи VPN и приёмника - не пересылайте его.")


if __name__ == "__main__":
    main()
