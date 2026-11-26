#!/usr/bin/env python3
"""ProxyGPT: добавить в профили VPN для Happ цепочку «сайт -> VPN -> приёмник на вашем сервере -> сайт».

Берёт JSON-подписку VPN-сервиса в формате Happ (массив конфигов Xray) и в каждый конфиг добавляет:
  - выход `proxygpt` (VLESS через WebSocket до приёмника, его включает `install.sh --relay`);
  - `loopback`, чтобы подключение к приёмнику шло через собственный автовыбор (балансировщик) VPN -
    тот же, что работает в этой сети, в том числе на мобильном с белыми списками;
  - правила: сайты из списка -> `proxygpt`, их QUIC (UDP) закрыт.
Всё остальное в конфигах VPN не меняется.

Пример:
  python3 tools/happ-add-relay.py --sub "https://подписка-вашего-vpn" \\
      --relay "vless://...из /opt/proxygpt/relay.txt" -o happ-profiles.json
Потом: открыть файл на телефоне, скопировать весь текст, Happ -> «+» -> «Импорт из буфера».
В файле ключи вашего VPN и приёмника: никому его не пересылайте.
"""
import argparse
import http.cookiejar
import json
import sys
import urllib.parse
import urllib.request

DEFAULT_SITES = ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com",
                 "chatgpt.com", "openai.com", "oaistatic.com", "oaiusercontent.com"]


def fetch_subscription(url: str) -> list:
    # Некоторые сервисы отвечают переадресацией с cookie защиты от ботов - нужна банка cookie.
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    req = urllib.request.Request(url, headers={"User-Agent": "Happ/3.0"})
    with opener.open(req, timeout=30) as r:
        body = r.read().decode("utf-8", errors="replace").strip()
    try:
        data = json.loads(body)
    except json.JSONDecodeError:
        sys.exit("Подписка отдала не JSON. Скрипт работает только с JSON-подписками в формате Happ.")
    return data if isinstance(data, list) else [data]


def parse_relay(link: str) -> dict:
    u = urllib.parse.urlsplit(link.strip())
    if u.scheme != "vless" or not u.username or not u.hostname:
        sys.exit("--relay: нужна ссылка vless://... из /opt/proxygpt/relay.txt")
    q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
    if q.get("type") != "ws" or q.get("security") != "tls":
        sys.exit("--relay: ожидается ссылка приёмника ProxyGPT (type=ws, security=tls)")
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
        {"tag": "proxygpt-loop", "protocol": "loopback", "settings": {"inboundTag": "proxygpt-in"}},
    ]
    dom = ["domain:" + d for d in domains]
    new = [{"type": "field", "inboundTag": ["proxygpt-in"], **main}]
    if block:
        new.append({"type": "field", "domain": dom, "network": "udp", "outboundTag": block})
    new.append({"type": "field", "domain": dom, "outboundTag": "proxygpt"})
    cfg["routing"]["rules"] = new + rules
    cfg["remarks"] = cfg.get("remarks", "") + " · через мой сервер"
    return "через балансировщик VPN" if bal else "через сервер VPN"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--sub", help="ссылка JSON-подписки VPN (формат Happ)")
    src.add_argument("--in", dest="infile", help="или уже скачанный JSON-файл подписки")
    ap.add_argument("--relay", required=True, help="vless://... из /opt/proxygpt/relay.txt на сервере")
    ap.add_argument("--sites", default=" ".join(DEFAULT_SITES), help="сайты через ваш сервер (через пробел)")
    ap.add_argument("-o", "--out", required=True, help="куда записать профили для Happ")
    a = ap.parse_args()

    cfgs = fetch_subscription(a.sub) if a.sub else json.load(open(a.infile, encoding="utf-8"))
    relay = parse_relay(a.relay)
    domains = a.sites.split()
    for c in cfgs:
        how = add_relay(c, relay, domains)
        print(f"  {c.get('remarks', '?')[:60]:60} {how}")
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(cfgs, f, ensure_ascii=False, separators=(",", ":"))
    print(f"Готово: {len(cfgs)} профилей -> {a.out}. В файле ключи VPN и приёмника - не пересылайте его.")


if __name__ == "__main__":
    main()
