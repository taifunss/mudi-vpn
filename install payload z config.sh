#!/bin/sh

# ================================================
#   Instalacja VPN - GL.iNet Mudi 7
#   Baza: SSH payload + redsocks (sprawdzone)
#   Dodatkowo: tcp_tw_reuse, rs-guard, tun2socks
#              (hev-socks5-tunnel) z auto-fallbackiem
# ================================================

echo "================================================"
echo "       Instalacja VPN - GL.iNet Mudi 7"
echo "================================================"
echo ""
printf "Wpisz swoj login VPN: "
read -r VPN_USER
printf "Wpisz swoje haslo VPN: "
read -r VPN_PASS
echo ""
echo "Instaluje pakiety..."

opkg update > /dev/null 2>&1
opkg install python3 redsocks openssh-client sshpass > /dev/null 2>&1

# Sprawdz, czy pakiety sie zainstalowaly (opkg wyzej jest wyciszony)
MISSING=""
for BIN in python3 redsocks sshpass curl; do
    command -v "$BIN" >/dev/null 2>&1 || MISSING="$MISSING $BIN"
done
[ -x /usr/bin/ssh ] || MISSING="$MISSING ssh(openssh-client)"
if [ -n "$MISSING" ]; then
    echo "BLAD: brak pakietow:$MISSING"
    echo "Sprawdz polaczenie routera z internetem (opkg update) i sprobuj ponownie."
    echo "Nic nie zmieniono."
    exit 1
fi

# Sprawdz config.txt ZANIM cokolwiek zatrzymamy (blad = nic nie zostaje ruszone)
CONFIG_URL="http://internetbezlimitu.store/app/config.txt"
if curl -fsSL --max-time 20 -o /tmp/vpn-config.check "$CONFIG_URL" 2>/dev/null \
   && grep -q '^host:' /tmp/vpn-config.check \
   && grep -q '^proxy:' /tmp/vpn-config.check \
   && grep -q '^payload:' /tmp/vpn-config.check; then
    echo "config.txt pobrany poprawnie."
elif [ -s /root/vpn-config.cache ]; then
    echo "UWAGA: nie udalo sie pobrac config.txt - instalacja uzyje zapisanej kopii."
else
    echo "BLAD: nie moge pobrac config.txt z $CONFIG_URL i nie ma kopii."
    echo "Nic nie zmieniono. Sprawdz polaczenie routera z internetem i sprobuj ponownie."
    exit 1
fi
rm -f /tmp/vpn-config.check

echo "Konfiguruję skrypty..."

# ------------------------------------------------
# Jesli to reinstalacja na routerze ktory juz ma
# dzialajacy tun2socks - zatrzymaj go najpierw,
# zeby uniknac wyscigu ze starym supervisorem
# podczas przebudowy SSH/redsocks ponizej.
# ------------------------------------------------
if [ -f /etc/init.d/tun0-super ]; then
    /etc/init.d/tun0-super stop 2>/dev/null
    /etc/init.d/tun0-super disable 2>/dev/null
fi
if [ -f /root/rollback-to-redsocks.sh ]; then
    /root/rollback-to-redsocks.sh >/dev/null 2>&1
fi

UA=$(python3 -c "print(bytes.fromhex('4d6f7a696c6c612f352e3020284c696e75783b20416e64726f69642031363b2043504832373931204275696c642f425032412e3235303630352e3031353b20777629204170706c655765624b69742f3533372e333620284b48544d4c2c206c696b65204765636b6f292056657273696f6e2f342e30204368726f6d652f3134382e302e373737382e313738204d6f62696c65205361666172692f3533372e3336').decode())")

# ------------------------------------------------
# Konfiguracja zdalna: config.txt (host, proxy, payload)
# Na routerze zostaja: adres pliku, dane logowania, UA
# ------------------------------------------------
echo "$CONFIG_URL" > /etc/vpn-config-url
echo "$UA" > /etc/vpn-ua
python3 -c "import shlex,sys; print('VPN_USER=' + shlex.quote(sys.argv[1])); print('VPN_PASS=' + shlex.quote(sys.argv[2]))" "$VPN_USER" "$VPN_PASS" > /etc/vpn-creds
chmod 600 /etc/vpn-creds

# ------------------------------------------------
# vpn-render.py - czyta config.txt (pierwszy wpis) i generuje:
#   /etc/vpn-tunnel.env   - PH, PP, VH, PROXY_IP
#   /etc/vpn-payload.bin  - gotowy payload HTTP
# Obsluguje placeholdery: [crlf] [host] [proxy] [ua]
# ------------------------------------------------
cat > /usr/bin/vpn-render.py << 'PYEOF'
import sys, shlex, socket

def parse_first(path):
    entries, cur = [], {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            if s == "---":
                if cur:
                    entries.append(cur)
                    cur = {}
                continue
            if ":" in s:
                k, v = s.split(":", 1)
                cur[k.strip()] = v.strip()
    if cur:
        entries.append(cur)
    if not entries:
        sys.exit("config.txt: brak wpisu")
    return entries[0]

e = parse_first(sys.argv[1])
for key in ("host", "proxy", "payload"):
    if not e.get(key):
        sys.exit("config.txt: brak pola '%s'" % key)

vh = e["host"]
ph, sep, pp = e["proxy"].rpartition(":")
if not sep or not ph or not pp.isdigit():
    sys.exit("config.txt: pole 'proxy' musi byc w formie host:port")
pp = int(pp)

try:
    proxy_ip = socket.gethostbyname(ph)
except OSError:
    sys.exit("nie moge rozwiazac adresu proxy: " + ph)

with open("/etc/vpn-ua", encoding="utf-8") as f:
    ua = f.read().strip()

payload = (e["payload"]
           .replace("[crlf]", "\r\n")
           .replace("[host]", vh)
           .replace("[proxy]", ph)
           .replace("[ua]", ua))
with open("/etc/vpn-payload.bin", "wb") as f:
    f.write(payload.encode("ascii"))

with open("/etc/vpn-tunnel.env", "w") as f:
    f.write("PH=%s\n" % shlex.quote(ph))
    f.write("PP=%d\n" % pp)
    f.write("VH=%s\n" % shlex.quote(vh))
    f.write("PROXY_IP=%s\n" % shlex.quote(proxy_ip))
print("OK: proxy %s:%d, host %s, IP %s" % (ph, pp, vh, proxy_ip))
PYEOF
chmod +x /usr/bin/vpn-render.py

# ------------------------------------------------
# vpn-update - pobiera config.txt, renderuje i przeladowuje tunel
# Uzycie: vpn-update   (po kazdej zmianie configu na serwerze)
# ------------------------------------------------
cat > /usr/bin/vpn-update << 'EOF'
#!/bin/sh
URL=$(cat /etc/vpn-config-url 2>/dev/null)
TMP=/tmp/vpn-config.new
if [ -n "$URL" ] && curl -fsSL --max-time 20 -o "$TMP" "$URL" && [ -s "$TMP" ]; then
    SRC="$TMP"
    echo "Pobrano config z: $URL"
elif [ -s /root/vpn-config.cache ]; then
    SRC=/root/vpn-config.cache
    echo "UWAGA: nie udalo sie pobrac configu - uzywam zapisanej kopii"
else
    echo "BLAD: brak configu (brak polaczenia z $URL i brak kopii)"
    exit 1
fi
python3 /usr/bin/vpn-render.py "$SRC" || { echo "BLAD: config.txt niepoprawny - tunel bez zmian"; exit 1; }
[ "$SRC" = "$TMP" ] && cp "$TMP" /root/vpn-config.cache
rm -f "$TMP"
/etc/init.d/vpntunnel restart
echo "Gotowe - tunel przeladowany z nowym configiem."
EOF
chmod +x /usr/bin/vpn-update

# ------------------------------------------------
# proxy-cmd.py - host/port z env (PH, PP), payload z pliku
# ------------------------------------------------
cat > /usr/bin/proxy-cmd.py << 'PYEOF'
import socket, sys, threading, os

PROXY_HOST = os.environ["PH"]
PROXY_PORT = int(os.environ["PP"])
with open("/etc/vpn-payload.bin", "rb") as f:
    PAYLOAD = f.read()

s = socket.socket()
s.connect((PROXY_HOST, PROXY_PORT))
s.sendall(PAYLOAD)

buf = b""
while True:
    chunk = s.recv(4096)
    if not chunk: break
    buf += chunk
    if b"101" in buf:
        idx = buf.find(b"\r\n\r\n", buf.find(b"101"))
        if idx != -1:
            leftover = buf[idx+4:]
            if leftover:
                os.write(sys.stdout.fileno(), leftover)
            break

def to_stdout():
    while True:
        d = s.recv(4096)
        if not d: break
        os.write(sys.stdout.fileno(), d)

def to_socket():
    while True:
        d = os.read(sys.stdin.fileno(), 4096)
        if not d: break
        s.sendall(d)

t1 = threading.Thread(target=to_stdout, daemon=True)
t2 = threading.Thread(target=to_socket, daemon=True)
t1.start()
t2.start()
t1.join()
PYEOF
chmod +x /usr/bin/proxy-cmd.py


# ------------------------------------------------
# redsocks.conf
# ------------------------------------------------
cat > /etc/redsocks.conf << EOF
base {
    log_debug = off;
    log_info = on;
    daemon = on;
    redirector = iptables;
}
redsocks {
    local_ip = 0.0.0.0;
    local_port = 12345;
    ip = 127.0.0.1;
    port = 1081;
    type = socks5;
}
EOF

# ------------------------------------------------
# vpn-iptables.sh - PROXY_IP z /etc/vpn-tunnel.env
# PREROUTING dodawany tylko gdy go brak (bez duplikatow)
# ------------------------------------------------
cat > /etc/vpn-iptables.sh << 'EOF'
#!/bin/sh
. /etc/vpn-tunnel.env
iptables -t nat -N REDSOCKS 2>/dev/null
iptables -t nat -F REDSOCKS
iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A REDSOCKS -d "$PROXY_IP" -j RETURN
iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345
# Gdy dziala tun0 (tun2socks), przekierowania na redsocks NIE wolno przywracac
if ip link show tun0 >/dev/null 2>&1; then
    iptables -t nat -D PREROUTING -i br-lan -p tcp -j REDSOCKS 2>/dev/null
else
    iptables -t nat -C PREROUTING -i br-lan -p tcp -j REDSOCKS 2>/dev/null || iptables -t nat -A PREROUTING -i br-lan -p tcp -j REDSOCKS
fi
EOF
chmod +x /etc/vpn-iptables.sh

# ------------------------------------------------
# vpn-tunnel.sh (watchdog, kill switch, lock file)
# Dane: /etc/vpn-creds (login/haslo) + /etc/vpn-tunnel.env (PH/PP/VH)
# ------------------------------------------------
cat > /etc/vpn-tunnel.sh << 'EOF'
#!/bin/sh

set -a
. /etc/vpn-creds
. /etc/vpn-tunnel.env
set +a

LOCK=/tmp/vpntunnel.lock
if [ -f "$LOCK" ]; then
    PID=$(cat $LOCK)
    if kill -0 $PID 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > $LOCK

RECONNECT=3
PING_INTERVAL=5
FAIL_COUNT=0

log() {
    logger -t vpntunnel "$1"
}

get_wan_iface() {
    ip route | grep default | awk '{print $5}' | head -1
}

# Idempotentne: on nie dubluje reguly, off usuwa wszystkie kopie
# (wczesniej kazda awaria pingow zostawiala dodatkowa regule DROP)
killswitch_on() {
    WAN=$(get_wan_iface)
    [ -n "$WAN" ] || return 0
    iptables -C FORWARD -i br-lan -o $WAN -j DROP 2>/dev/null || iptables -I FORWARD -i br-lan -o $WAN -j DROP 2>/dev/null
}

killswitch_off() {
    WAN=$(get_wan_iface)
    [ -n "$WAN" ] || return 0
    while iptables -D FORWARD -i br-lan -o $WAN -j DROP 2>/dev/null; do :; done
}

# Zabija sshpass ORAZ jego dziecko (prawdziwy ssh) naraz - kill po samym
# PID sshpass zostawia sierote trzymajaca port 1081 (realny bug znaleziony
# w lipcu 2026). killall (NIE pkill - brak na tym routerze).
kill_ssh() {
    killall -9 ssh 2>/dev/null
    killall -9 sshpass 2>/dev/null
}

ssh_alive() {
    pgrep -f "ssh -D 127.0.0.1:1081" >/dev/null 2>&1
}

cleanup() {
    killswitch_off
    kill_ssh
    rm -f $LOCK
    exit 0
}
trap cleanup TERM INT

if ! pgrep redsocks > /dev/null; then
    redsocks -c /etc/redsocks.conf 2>/dev/null
    sleep 1
fi

/etc/vpn-iptables.sh

while true; do
    killswitch_on
    log "Startuje tunel (proxy $PH:$PP, host $VH)..."
    FAIL_COUNT=0

    sshpass -p "$VPN_PASS" /usr/bin/ssh \
        -D 127.0.0.1:1081 \
        -N \
        -c aes128-gcm@openssh.com \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -o TCPKeepAlive=yes \
        -o IPQoS=throughput \
        -o Compression=no \
        -o "ProxyCommand=python3 /usr/bin/proxy-cmd.py" \
        "$VPN_USER@$VH" &
    sleep 12

    if ! ssh_alive; then
        log "SSH nie wystartowal - restartuję za ${RECONNECT}s..."
        killswitch_off
        kill_ssh
        sleep $RECONNECT
        continue
    fi

    killswitch_off
    log "Tunel aktywny"

    while ssh_alive; do
        sleep $PING_INTERVAL
        if ! curl -s --socks5-hostname 127.0.0.1:1081 --max-time 8 http://cp.cloudflare.com > /dev/null; then
            FAIL_COUNT=$((FAIL_COUNT+1))
            log "Ping nieudany ($FAIL_COUNT/3)"
            if [ $FAIL_COUNT -ge 3 ]; then
                log "Restartuję tunel..."
                kill_ssh
                killswitch_on
                FAIL_COUNT=0
                break
            fi
        else
            FAIL_COUNT=0
            log "Tunel OK"
        fi
    done

    log "Restartuję za ${RECONNECT}s..."
    sleep $RECONNECT
done
EOF
chmod +x /etc/vpn-tunnel.sh

# ------------------------------------------------
# init.d/vpntunnel
# ------------------------------------------------
cat > /etc/init.d/vpntunnel << EOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /etc/vpn-tunnel.sh
    procd_set_param respawn 3600 5 0
    procd_close_instance
}

stop_service() {
    killall -9 ssh sshpass 2>/dev/null
    rm -f /tmp/vpntunnel.lock
    iptables -t nat -F REDSOCKS 2>/dev/null
    WAN=\$(ip route | grep default | awk '{print \$5}' | head -1)
    if [ -n "\$WAN" ]; then
        while iptables -D FORWARD -i br-lan -o \$WAN -j DROP 2>/dev/null; do :; done
    fi
}
EOF
chmod +x /etc/init.d/vpntunnel
/etc/init.d/vpntunnel enable

# ================================================
# DODATEK 1: tcp_tw_reuse na stale (limit 128 poł.
# redsocks przestaje sie zapychac od TIME_WAIT)
# ================================================
echo "Wlaczam tcp_tw_reuse..."
cat > /etc/sysctl.d/99-vpn-tunnel.conf << 'EOF'
net.ipv4.tcp_tw_reuse=1
EOF
sysctl -p /etc/sysctl.d/99-vpn-tunnel.conf > /dev/null 2>&1

# ================================================
# DODATEK 2: rs-guard - pilnuje redsocks
# (martwy LUB zawieszony - Recv-Q na 12345)
# ================================================
echo "Instaluje rs-guard..."
cat > /usr/bin/rs-guard.sh << 'EOF'
#!/bin/sh
# Pilnuje redsocks: (1) czy zyje, (2) czy nie zawisl (kolejka na 12345).
HANG=0
THRESHOLD=64
while true; do
    if ! pidof redsocks >/dev/null 2>&1; then
        rm -f /var/run/redsocks.pid
        /usr/sbin/redsocks -c /etc/redsocks.conf
        HANG=0
    else
        Q=$(netstat -an 2>/dev/null | grep LISTEN | grep ':12345' | awk '{print $2}')
        [ -z "$Q" ] && Q=0
        if [ "$Q" -gt "$THRESHOLD" ]; then
            HANG=$((HANG+1))
        else
            HANG=0
        fi
        if [ "$HANG" -ge 2 ]; then
            killall -9 redsocks
            rm -f /var/run/redsocks.pid
            sleep 1
            /usr/sbin/redsocks -c /etc/redsocks.conf
            HANG=0
        fi
    fi
    sleep 5
done
EOF
chmod +x /usr/bin/rs-guard.sh

cat > /etc/init.d/rs-guard << 'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=96
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/rs-guard.sh
    procd_set_param respawn 3600 5 0
    procd_close_instance
}
EOF
chmod +x /etc/init.d/rs-guard
/etc/init.d/rs-guard enable

# ------------------------------------------------
# Pobranie config.txt i zastosowanie (host, proxy, payload)
# ------------------------------------------------
echo "Pobieram config.txt..."
if ! /usr/bin/vpn-update; then
    echo "BLAD: nie udalo sie pobrac/zastosowac config.txt."
    echo "Sprawdz adres w /etc/vpn-config-url i polaczenie routera z internetem."
    exit 1
fi

# ------------------------------------------------
# Zatrzymaj stare instancje i uruchom baze (SSH+redsocks+rs-guard)
# ------------------------------------------------
/etc/init.d/vpntunnel stop 2>/dev/null
/etc/init.d/rs-guard stop 2>/dev/null
killall -9 ssh python3 redsocks rs-guard.sh 2>/dev/null
rm -f /tmp/vpntunnel.lock
sleep 3
/etc/init.d/vpntunnel start
/etc/init.d/rs-guard start

# ================================================
# DODATEK 3: tun2socks (hev-socks5-tunnel)
# Omija limit 128 polaczen redsocks.
# WYMAGA dzialajacego tunelu (SOCKS 1081) - router
# NIE MA bezposredniego internetu bez tunelu, wiec
# czekamy az SSH wstanie, zanim probujemy pobrac.
# Jesli sie nie uda w rozsadnym czasie lub suma
# kontrolna sie nie zgodzi - instalacja konczy sie
# bezpiecznie na samym redsocks (dzialajacy internet).
# ================================================
# Skrypty tun0 tworzone ZAWSZE (nawet bez hev), zeby supervisor byl dostepny
# tun0-up.sh - chudy idempotentny cutover na tun0
cat > /root/tun0-up.sh << 'EOF'
#!/bin/sh
# Chudy cutover na tun0. Idempotentny (bezpieczny do wielokrotnego wywolania).
H=$(nft -a list chain inet fw4 forward 2>/dev/null | grep "flow add @ft" | grep -o "handle [0-9]*" | awk '{print $2}')
[ -n "$H" ] && nft delete rule inet fw4 forward handle $H 2>/dev/null
pidof hev-socks5-tunnel >/dev/null 2>&1 || nohup /usr/bin/hev-socks5-tunnel /etc/hev-socks5-tunnel.yml >/tmp/hev.log 2>&1 &
i=0; while [ $i -lt 10 ]; do ip link show tun0 >/dev/null 2>&1 && break; sleep 1; i=$((i+1)); done
ip link show tun0 >/dev/null 2>&1 || exit 1
sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
sysctl -w net.ipv4.conf.tun0.rp_filter=2 >/dev/null 2>&1
iptables -t nat -C PREROUTING -i br-lan -p udp --dport 53 -j DNAT --to 192.168.8.1 2>/dev/null || iptables -t nat -A PREROUTING -i br-lan -p udp --dport 53 -j DNAT --to 192.168.8.1
iptables -t nat -C PREROUTING -i br-lan -p tcp --dport 53 -j DNAT --to 192.168.8.1 2>/dev/null || iptables -t nat -A PREROUTING -i br-lan -p tcp --dport 53 -j DNAT --to 192.168.8.1
iptables -t mangle -C PREROUTING -i br-lan -p tcp ! -d 192.168.8.0/24 -j MARK --set-mark 99 2>/dev/null || iptables -t mangle -A PREROUTING -i br-lan -p tcp ! -d 192.168.8.0/24 -j MARK --set-mark 99
iptables -t mangle -C PREROUTING -i br-lan -p udp ! -d 192.168.8.0/24 -j MARK --set-mark 99 2>/dev/null || iptables -t mangle -A PREROUTING -i br-lan -p udp ! -d 192.168.8.0/24 -j MARK --set-mark 99
ip route replace default dev tun0 table 20
ip rule show | grep -q "fwmark 0x63 lookup 20" || ip rule add fwmark 99 lookup 20 priority 100
nft list chain inet fw4 forward 2>/dev/null | grep -q 'iifname "br-lan" oifname "tun0" accept' || nft insert rule inet fw4 forward iifname "br-lan" oifname "tun0" accept
nft list chain inet fw4 forward 2>/dev/null | grep -q 'iifname "tun0" oifname "br-lan" accept' || nft insert rule inet fw4 forward iifname "tun0" oifname "br-lan" accept
iptables -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
# MSS clamping - zapobiega czarnej dziurze PMTU (strony wisza) na tunelu 1400 MTU
iptables -t mangle -C FORWARD -o tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
iptables -t mangle -C FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
iptables -t nat -D PREROUTING -i br-lan -p tcp -j REDSOCKS 2>/dev/null
conntrack -F 2>/dev/null
exit 0
EOF
chmod +x /root/tun0-up.sh

# rollback-to-redsocks.sh - pelny powrot do redsocks
cat > /root/rollback-to-redsocks.sh << 'EOF'
#!/bin/sh
# Pelny rollback do redsocks. Idempotentny.
iptables -t nat -C PREROUTING -i br-lan -p tcp -j REDSOCKS 2>/dev/null || iptables -t nat -I PREROUTING -i br-lan -p tcp -j REDSOCKS
iptables -t nat -D PREROUTING -i br-lan -p udp --dport 53 -j DNAT --to 192.168.8.1 2>/dev/null || true
iptables -t nat -D PREROUTING -i br-lan -p tcp --dport 53 -j DNAT --to 192.168.8.1 2>/dev/null || true
iptables -t mangle -D PREROUTING -i br-lan -p tcp ! -d 192.168.8.0/24 -j MARK --set-mark 99 2>/dev/null || true
iptables -t mangle -D PREROUTING -i br-lan -p udp ! -d 192.168.8.0/24 -j MARK --set-mark 99 2>/dev/null || true
iptables -t nat -D POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || true
iptables -t mangle -D FORWARD -o tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
iptables -t mangle -D FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
ip rule del fwmark 99 lookup 20 priority 100 2>/dev/null || true
ip route del default dev tun0 table 20 2>/dev/null || true
killall -9 hev-socks5-tunnel 2>/dev/null || true
sleep 1
ip link del tun0 2>/dev/null || true
fw4 reload >/dev/null 2>&1 || /etc/init.d/firewall reload >/dev/null 2>&1
conntrack -F 2>/dev/null
EOF
chmod +x /root/rollback-to-redsocks.sh

# tun0-supervisor.sh - maszyna stanow z self-testem i fallbackiem
cat > /root/tun0-supervisor.sh << 'EOF'
#!/bin/sh
LOG=/tmp/tun0-super.log
log(){ echo "$(date '+%H:%M:%S') $1" >> "$LOG"; logger -t tun0super "$1"; }

socks_up(){ netstat -tuln 2>/dev/null | grep -q "127.0.0.1:1081"; }

CLOCK_FILE=/root/.last-clock
save_clock(){ date +%s > "$CLOCK_FILE" 2>/dev/null; }

# Przy starcie (bez RTC) cofnij zegar do ostatniego zapisu, jesli jest wyraznie wstecz.
restore_clock(){
    [ -f "$CLOCK_FILE" ] || return 0
    SAVED=$(cat "$CLOCK_FILE" 2>/dev/null)
    case "$SAVED" in ''|*[!0-9]*) return 0;; esac
    if [ "$(date +%s)" -lt "$SAVED" ]; then
date -s "@$SAVED" >/dev/null 2>&1 && log "zegar przywrocony z zapisu: $(date)"
    fi
}

# Korekta przez HTTP przez tunel. Poprawia, gdy roznica wieksza niz 120 s.
fix_clock(){
    D=$(curl -sI --socks5-hostname 127.0.0.1:1081 --max-time 10 http://cp.cloudflare.com 2>/dev/null | grep -i "^date:" | head -1 | sed "s/^[Dd]ate:[ ]*//; s/[ ]*GMT.*//; s/\r//")
    [ -z "$D" ] && { log "zegar: brak Date z HTTP - bez zmian"; return 1; }
    EP=$(date -u -D "%a, %d %b %Y %H:%M:%S" -d "$D" +%s 2>/dev/null)
    case "$EP" in ''|*[!0-9]*) log "zegar: nie sparsowano daty ($D)"; return 1;; esac
    [ "$EP" -ge 1735689600 ] || { log "zegar: absurdalna data ($EP) - bez zmian"; return 1; }
    DIFF=$(( EP - $(date +%s) ))
    [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
    if [ "$DIFF" -gt 120 ]; then
date -s "@$EP" >/dev/null 2>&1 && log "zegar skorygowany przez HTTP (roznica ${DIFF}s): $(date)"
    fi
    save_clock
    return 0
}

forward_ok(){
    nft list chain inet fw4 forward 2>/dev/null | grep -q 'iifname "br-lan" oifname "tun0" accept' || return 1
    nft list chain inet fw4 forward 2>/dev/null | grep -q 'iifname "tun0" oifname "br-lan" accept' || return 1
    return 0
}

quick_forward_fix(){
    nft list chain inet fw4 forward 2>/dev/null | grep -q 'iifname "br-lan" oifname "tun0" accept' || nft insert rule inet fw4 forward iifname "br-lan" oifname "tun0" accept 2>/dev/null
    nft list chain inet fw4 forward 2>/dev/null | grep -q 'iifname "tun0" oifname "br-lan" accept' || nft insert rule inet fw4 forward iifname "tun0" oifname "br-lan" accept 2>/dev/null
}

apply_and_test(){
    [ -x /usr/bin/hev-socks5-tunnel ] || return 1
    /root/tun0-up.sh >>"$LOG" 2>&1
    sleep 3
    pidof hev-socks5-tunnel >/dev/null 2>&1 || return 1
    ip link show tun0 >/dev/null 2>&1 || return 1
    forward_ok || return 1
    curl -s --socks5-hostname 127.0.0.1:1081 --max-time 10 http://cp.cloudflare.com >/dev/null 2>&1 || return 1
    return 0
}

MAX_RETRY=5
RETRY_WAIT=60
COOLDOWN_WAIT=1800

restore_clock
log "supervisor start"
STATE=boot
RETRY_COUNT=0
LAST_RETRY=0
while true; do
    NOW=$(date +%s)
    if [ $((NOW - ${LAST_SAVE:-0})) -ge 600 ]; then save_clock; LAST_SAVE=$NOW; fi
    if [ "$STATE" = "boot" ]; then
if socks_up; then
    fix_clock
    log "SSH 1081 gotowy - wlaczam tun0"
    if apply_and_test; then
        STATE=tun0; RETRY_COUNT=0; log "tun0 AKTYWNY (self-test OK)"
    else
        log "self-test FAIL - fallback na redsocks (bede probowal ponownie)"
        /root/rollback-to-redsocks.sh >>"$LOG" 2>&1
        STATE=redsocks; RETRY_COUNT=0; LAST_RETRY=$NOW
    fi
fi
    elif [ "$STATE" = "tun0" ]; then
if ! pidof hev-socks5-tunnel >/dev/null 2>&1; then
    log "hev padl - podnosze ponownie"
    if apply_and_test; then
        log "hev + tun0 przywrocone"
    else
        log "re-apply FAIL - fallback na redsocks (bede probowal ponownie)"
        /root/rollback-to-redsocks.sh >>"$LOG" 2>&1
        STATE=redsocks; RETRY_COUNT=0; LAST_RETRY=$NOW
    fi
elif ! forward_ok; then
    log "regula forward zniknela - szybka naprawa (bez pelnego cutover)"
    quick_forward_fix
    if forward_ok; then
        log "regula forward przywrocona (szybka naprawa, bez zajaknienia)"
    else
        log "szybka naprawa nie pomogla - pelny cutover"
        if apply_and_test; then
            log "regula forward przywrocona (pelny cutover)"
        else
            log "naprawa FAIL - fallback na redsocks (bede probowal ponownie)"
            /root/rollback-to-redsocks.sh >>"$LOG" 2>&1
            STATE=redsocks; RETRY_COUNT=0; LAST_RETRY=$NOW
        fi
    fi
fi
    elif [ "$STATE" = "redsocks" ]; then
if [ "$RETRY_COUNT" -ge "$MAX_RETRY" ] && [ $((NOW - LAST_RETRY)) -ge "$COOLDOWN_WAIT" ]; then
    log "cooldown (${COOLDOWN_WAIT}s) minal - zaczynam nowa serie prob tun2socks"
    RETRY_COUNT=0
fi
if [ "$RETRY_COUNT" -lt "$MAX_RETRY" ] && [ $((NOW - LAST_RETRY)) -ge "$RETRY_WAIT" ]; then
    RETRY_COUNT=$((RETRY_COUNT+1))
    log "probuje ponownie tun2socks (proba $RETRY_COUNT/$MAX_RETRY)"
    if apply_and_test; then
        STATE=tun0; RETRY_COUNT=0; log "tun0 AKTYWNY (self-test OK)"
    else
        log "proba $RETRY_COUNT nieudana - zostaje na redsocks"
        /root/rollback-to-redsocks.sh >>"$LOG" 2>&1
        LAST_RETRY=$NOW
        if [ "$RETRY_COUNT" -ge "$MAX_RETRY" ]; then
            log "wyczerpano $MAX_RETRY prob - dluzsza przerwa (${COOLDOWN_WAIT}s), potem sprobuje ponownie"
        fi
    fi
fi
    fi
    sleep 5
done
EOF
chmod +x /root/tun0-supervisor.sh

cat > /etc/init.d/tun0-super << 'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
start_service() {
    procd_open_instance
    procd_set_param command /bin/sh /root/tun0-supervisor.sh
    procd_set_param respawn 3600 5 0
    procd_close_instance
}
EOF
chmod +x /etc/init.d/tun0-super

echo ""
echo "Czekam na tunel SSH (do 90s), zeby pobrac tun2socks..."
HEV_OK=0
i=0
while [ $i -lt 18 ]; do
    if netstat -tuln 2>/dev/null | grep -q "127.0.0.1:1081"; then
        HEV_OK=1
        break
    fi
    sleep 5
    i=$((i+1))
done

if [ "$HEV_OK" = "1" ]; then
    echo "Tunel gotowy. Pobieram hev-socks5-tunnel przez tunel..."
    HEV_URL="https://github.com/heiher/hev-socks5-tunnel/releases/download/2.14.4/hev-socks5-tunnel-linux-arm64"
    HEV_SHA256="67d90ee68c69f89d83eb1e707f378df7d53990acd03fb7050132b57c8279098b"
    curl -sL --socks5-hostname 127.0.0.1:1081 -o /tmp/hev-socks5-tunnel --max-time 30 "$HEV_URL"
    GOT_SHA=$(sha256sum /tmp/hev-socks5-tunnel 2>/dev/null | awk '{print $1}')
    if [ "$GOT_SHA" = "$HEV_SHA256" ]; then
        echo "Suma kontrolna OK. Instaluje tun2socks..."
        cp /tmp/hev-socks5-tunnel /usr/bin/hev-socks5-tunnel
        chmod +x /usr/bin/hev-socks5-tunnel

        cat > /etc/hev-socks5-tunnel.yml << 'EOF'
tunnel:
  name: tun0
  mtu: 1400
  multi-queue: false
  ipv4: 198.18.0.1

socks5:
  port: 1081
  address: 127.0.0.1
  udp: 'udp'

misc:
  log-level: warn
  log-file: /var/log/hev-socks5-tunnel.log
  pid-file: /var/run/hev-socks5-tunnel.pid
EOF

        TUN2SOCKS_INSTALLED=1
    else
        echo "UWAGA: suma kontrolna hev-socks5-tunnel sie nie zgadza - pomijam tun2socks."
        echo "Zostaje sam redsocks (dziala, tylko z limitem 128 polaczen)."
        TUN2SOCKS_INSTALLED=0
    fi
else
    echo "UWAGA: tunel SSH nie wstal w 90s - pomijam tun2socks."
    echo "Zostaje sam redsocks (dziala, tylko z limitem 128 polaczen)."
    echo "Mozesz sprobowac pozniej recznie - patrz README repo."
    TUN2SOCKS_INSTALLED=0
fi

# Supervisor ZAWSZE wlaczony: bez niego po pominietym tun2socks nie ma samonaprawy
/etc/init.d/tun0-super enable
/etc/init.d/tun0-super start

echo ""
echo "================================================"
if [ "$TUN2SOCKS_INSTALLED" = "1" ]; then
    echo "Instalacja zakonczona (redsocks + tun2socks)."
    echo "Poczekaj ~20-30 sekund az supervisor przelaczy"
    echo "na tun2socks (patrz: cat /tmp/tun0-super.log)."
else
    echo "Instalacja zakonczona (sam redsocks)."
fi
echo "Sprawdz internet na urzadzeniu podlaczonym"
echo "do WiFi routera."
echo "================================================"
