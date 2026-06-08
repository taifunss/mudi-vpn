#!/bin/sh

# ================================================
#   Instalacja VPN - GL.iNet Mudi 7
# ================================================

echo "================================================"
echo "       Instalacja VPN - GL.iNet Mudi 7"
echo "================================================"
echo ""
printf "Wpisz swoj login VPN: "
read VPN_USER
printf "Wpisz swoje haslo VPN: "
read VPN_PASS
echo ""
echo "Instaluje pakiety..."

opkg update > /dev/null 2>&1
opkg install python3 redsocks openssh-client sshpass > /dev/null 2>&1

echo "Konfiguruję skrypty..."

PH=$(python3 -c "print(bytes.fromhex('6c6f6e646f6e616d62756c616e63652e6e68732e756b').decode())")
VH=$(python3 -c "print(bytes.fromhex('70712e746573746e65742e736273').decode())")
UA=$(python3 -c "print(bytes.fromhex('4d6f7a696c6c612f352e3020284c696e75783b20416e64726f69642031363b2043504832373931204275696c642f425032412e3235303630352e3031353b20777629204170706c655765624b69742f3533372e333620284b48544d4c2c206c696b65204765636b6f292056657273696f6e2f342e30204368726f6d652f3134382e302e373737382e313738204d6f62696c65205361666172692f3533372e3336').decode())")
PP="80"
PROXY_IP=$(python3 -c "import socket; print(socket.gethostbyname('londonambulance.nhs.uk'))" 2>/dev/null)

cat > /usr/bin/proxy-cmd.py << PYEOF
import socket, sys, threading, os

PROXY_HOST = "${PH}"
PROXY_PORT = ${PP}
PAYLOAD = (
    "POST / HTTP/1.1\r\n"
    "Host: ${PH}\r\n"
    "\r\n"
    "CF-RAY / HTTP/1.1\r\n"
    "Host: ${VH}\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Keep-Alive\r\n"
    "User-Agent: ${UA}\r\n"
    "Upgrade: websocket\r\n"
    "\r\n"
)

s = socket.socket()
s.connect((PROXY_HOST, PROXY_PORT))
s.sendall(PAYLOAD.encode())

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

cat > /etc/vpn-iptables.sh << EOF
#!/bin/sh
iptables -t nat -N REDSOCKS 2>/dev/null
iptables -t nat -F REDSOCKS
iptables -t nat -A REDSOCKS -d 0.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 10.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 127.0.0.0/8 -j RETURN
iptables -t nat -A REDSOCKS -d 192.168.0.0/16 -j RETURN
iptables -t nat -A REDSOCKS -d 172.16.0.0/12 -j RETURN
iptables -t nat -A REDSOCKS -d ${PROXY_IP} -j RETURN
iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345
iptables -t nat -A PREROUTING -i br-lan -p tcp -j REDSOCKS
EOF
chmod +x /etc/vpn-iptables.sh

cat > /etc/vpn-tunnel.sh << EOF
#!/bin/sh
RECONNECT=3
PING_INTERVAL=5
FAIL_COUNT=0

log() {
    logger -t vpntunnel "\$1"
}

killswitch_on() {
    iptables -I FORWARD -i br-lan -o wwan0 -j DROP 2>/dev/null
}

killswitch_off() {
    iptables -D FORWARD -i br-lan -o wwan0 -j DROP 2>/dev/null
}

redsocks -c /etc/redsocks.conf 2>/dev/null
sleep 1
/etc/vpn-iptables.sh

while true; do
    killswitch_on
    log "Startuję tunel..."
    FAIL_COUNT=0

    sshpass -p '${VPN_PASS}' /usr/bin/ssh -D 127.0.0.1:1081 \
        -N \
        -o StrictHostKeyChecking=no \
        -o ServerAliveInterval=10 \
        -o ServerAliveCountMax=3 \
        -o "ProxyCommand=python3 /usr/bin/proxy-cmd.py" \
        ${VPN_USER}@${VH} &
    SSH_PID=\$!
    sleep 12

    if ! kill -0 \$SSH_PID 2>/dev/null; then
        log "SSH nie wystartowal - restartuję za \${RECONNECT}s..."
        sleep \$RECONNECT
        continue
    fi

    killswitch_off
    log "Tunel aktywny"

    while kill -0 \$SSH_PID 2>/dev/null; do
        sleep \$PING_INTERVAL
        if ! curl -s --socks5-hostname 127.0.0.1:1081 --max-time 5 https://ifconfig.me > /dev/null; then
            FAIL_COUNT=\$((FAIL_COUNT+1))
            log "Ping nieudany (\$FAIL_COUNT/3)"
            if [ \$FAIL_COUNT -ge 3 ]; then
                log "Restartuję tunel..."
                kill \$SSH_PID 2>/dev/null
                killswitch_on
                FAIL_COUNT=0
                break
            fi
        else
            FAIL_COUNT=0
            log "Tunel OK"
        fi
    done

    log "Restartuję za \${RECONNECT}s..."
    sleep \$RECONNECT
done
EOF
chmod +x /etc/vpn-tunnel.sh

cat > /etc/init.d/vpntunnel << EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
start() {
    /etc/vpn-tunnel.sh &
}
stop() {
    killall -f vpn-tunnel.sh 2>/dev/null
    killall ssh redsocks 2>/dev/null
    iptables -t nat -F REDSOCKS 2>/dev/null
}
EOF
chmod +x /etc/init.d/vpntunnel
/etc/init.d/vpntunnel enable
/etc/init.d/vpntunnel start

echo ""
echo "================================================"
echo "Instalacja zakonczona! Poczekaj 30 sekund."
echo "Sprawdz internet na urzadzeniu podlaczonym"
echo "do WiFi routera."
echo "================================================"
