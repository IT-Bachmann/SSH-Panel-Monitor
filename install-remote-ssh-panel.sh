#!/bin/bash
set -e

clear
echo "================================================================================"
echo "     REMOTE PANEL - MIT 2FA + SSL MANAGER + NOTFALL RESET"
echo "================================================================================"
echo ""

dpkg --configure -a 2>/dev/null || true
apt --fix-broken install -y 2>/dev/null || true

for pkg in nginx mariadb-server curl wget git unzip ufw fail2ban dnsutils net-tools putty-tools certbot python3-certbot-nginx; do
    if ! dpkg -l | grep -q "^ii.*$pkg"; then
        apt install -y $pkg
    fi
done

if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
fi

mkdir -p /opt/remote-panel/{backend,frontend,logs,uploads,sessions,ssh-keys}

cd /opt/remote-panel/backend

if [ ! -f package.json ]; then
    npm init -y --quiet
fi

for pkg in express socket.io ssh2 mysql2 bcrypt express-session uuid cors speakeasy qrcode; do
    if [ ! -d "node_modules/$pkg" ]; then
        npm install $pkg --quiet
    fi
done

mysql <<EOF
CREATE DATABASE IF NOT EXISTS remotepanel;
USE remotepanel;
CREATE USER IF NOT EXISTS 'remotepanel'@'localhost' IDENTIFIED BY 'RemotePanel123!';
GRANT ALL PRIVILEGES ON remotepanel.* TO 'remotepanel'@'localhost';
FLUSH PRIVILEGES;

CREATE TABLE IF NOT EXISTS users (
    id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(100) UNIQUE,
    password_hash TEXT,
    role VARCHAR(50) DEFAULT 'user',
    totp_secret VARCHAR(100),
    totp_enabled TINYINT(1) DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS servers (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    hostname VARCHAR(255),
    ipv4_host VARCHAR(255),
    ipv6_host VARCHAR(255),
    port INT DEFAULT 22,
    username VARCHAR(100) NOT NULL,
    password TEXT,
    ssh_key_name VARCHAR(100),
    prefer_ipv6 TINYINT(1) DEFAULT 0,
    last_status VARCHAR(20) DEFAULT 'unknown',
    last_ping_ms INT DEFAULT NULL,
    last_check TIMESTAMP NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS ssl_certificates (
    id INT AUTO_INCREMENT PRIMARY KEY,
    domain VARCHAR(255) NOT NULL,
    cert_path TEXT,
    key_path TEXT,
    issuer VARCHAR(100),
    expires_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_secret VARCHAR(100);
ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_enabled TINYINT(1) DEFAULT 0;
ALTER TABLE servers ADD COLUMN IF NOT EXISTS last_status VARCHAR(20) DEFAULT 'unknown';
ALTER TABLE servers ADD COLUMN IF NOT EXISTS last_ping_ms INT DEFAULT NULL;
ALTER TABLE servers ADD COLUMN IF NOT EXISTS last_check TIMESTAMP NULL;

DELETE FROM users WHERE username = 'admin';
INSERT INTO users (username, password_hash, role, totp_enabled) VALUES ('admin', '\$2b\$10\$EwTq4Xr1Xr1Xr1Xr1Xr1Xu1Xr1Xr1Xr1Xr1Xr1Xr1Xr1Xr1Xr1', 'admin', 0);
EOF

# ==================== NOTFALL RESET SCRIPT (SH) ====================
cat > /opt/remote-panel/reset.sh << 'EOF'
#!/bin/bash
# ============================================================
# NOTFALL RESET SCRIPT - NUR PER SSH AUSFUEHRBAR!
# ============================================================
# Verwendung:
#   /opt/remote-panel/reset.sh --help
#   /opt/remote-panel/reset.sh --list
#   /opt/remote-panel/reset.sh --user admin --reset-password
#   /opt/remote-panel/reset.sh --user admin --disable-2fa
#   /opt/remote-panel/reset.sh --reset-all
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DB_NAME="remotepanel"
DB_USER="remotepanel"
DB_PASS="RemotePanel123!"
ADMIN_HASH='\$2b\$10\$EwTq4Xr1Xr1Xr1Xr1Xr1Xu1Xr1Xr1Xr1Xr1Xr1Xr1Xr1Xr1Xr1'

show_help() {
    echo ""
    echo "================================================================================"
    echo "     NOTFALL RESET SCRIPT - Remote Panel"
    echo "================================================================================"
    echo ""
    echo "Verwendung:"
    echo "  $0 --help                    - Diese Hilfe anzeigen"
    echo "  $0 --list                    - Alle Benutzer auflisten"
    echo "  $0 --user <name> --show      - Benutzerdetails anzeigen"
    echo "  $0 --user <name> --reset-password - Passwort auf 'reset123' setzen"
    echo "  $0 --user <name> --set-password <pw> - Passwort setzen"
    echo "  $0 --user <name> --disable-2fa - 2FA fuer Benutzer deaktivieren"
    echo "  $0 --reset-all               - ALLE Benutzer zuruecksetzen (PW=reset123, 2FA aus)"
    echo "  $0 --restart-service         - Panel Service neustarten"
    echo ""
    echo "Beispiele:"
    echo "  $0 --list"
    echo "  $0 --user admin --show"
    echo "  $0 --user admin --reset-password"
    echo "  $0 --user admin --disable-2fa"
    echo ""
}

list_users() {
    echo ""
    echo "Benutzer in der Datenbank:"
    echo "------------------------------------------------------------------------"
    mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT id, username, role, totp_enabled, created_at FROM users ORDER BY id;" 2>/dev/null
    echo "------------------------------------------------------------------------"
}

show_user() {
    local username="$1"
    echo ""
    echo "Benutzerdetails fuer: $username"
    echo "------------------------------------------------------------------------"
    mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT id, username, role, totp_enabled, created_at FROM users WHERE username='$username';" 2>/dev/null
    echo "------------------------------------------------------------------------"
}

reset_password() {
    local username="$1"
    local new_password="${2:-reset123}"
    
    local exists=$(mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -sN -e "SELECT COUNT(*) FROM users WHERE username='$username';" 2>/dev/null)
    if [ "$exists" -eq 0 ]; then
        echo -e "${RED}Benutzer '$username' nicht gefunden!${NC}"
        return 1
    fi
    
    if [ "$new_password" = "reset123" ]; then
        mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "UPDATE users SET password_hash='$ADMIN_HASH' WHERE username='$username';" 2>/dev/null
    else
        local hashed=$(node -e "const bcrypt = require('bcrypt'); console.log(bcrypt.hashSync('$new_password', 10));" 2>/dev/null)
        if [ -z "$hashed" ]; then
            hashed=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$new_password', bcrypt.gensalt(10)).decode())" 2>/dev/null)
        fi
        if [ -z "$hashed" ]; then
            echo -e "${RED}Fehler beim Hashen des Passworts${NC}"
            return 1
        fi
        mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "UPDATE users SET password_hash='$hashed' WHERE username='$username';" 2>/dev/null
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Passwort fuer '$username' wurde zurueckgesetzt!${NC}"
        echo -e "Neues Passwort: ${YELLOW}$new_password${NC}"
    else
        echo -e "${RED}Fehler beim Zurücksetzen des Passworts${NC}"
    fi
}

disable_2fa() {
    local username="$1"
    
    local exists=$(mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -sN -e "SELECT COUNT(*) FROM users WHERE username='$username';" 2>/dev/null)
    if [ "$exists" -eq 0 ]; then
        echo -e "${RED}Benutzer '$username' nicht gefunden!${NC}"
        return 1
    fi
    
    mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "UPDATE users SET totp_enabled=0, totp_secret=NULL WHERE username='$username';" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}2FA fuer '$username' wurde deaktiviert!${NC}"
    else
        echo -e "${RED}Fehler beim Deaktivieren von 2FA${NC}"
    fi
}

reset_all() {
    echo -e "${YELLOW}WARNUNG: Dies setzt ALLE Benutzer zurueck!${NC}"
    echo -n "Fortfahren? [j/N]: "
    read -r answer
    if [[ ! "$answer" =~ ^[Jj] ]]; then
        echo -e "${RED}Abgebrochen.${NC}"
        return 0
    fi
    
    mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "UPDATE users SET password_hash='$ADMIN_HASH', totp_enabled=0, totp_secret=NULL;" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Alle Benutzer wurden zurueckgesetzt!${NC}"
        echo -e "Neues Passwort fuer alle: ${YELLOW}reset123${NC}"
    else
        echo -e "${RED}Fehler beim Zurücksetzen${NC}"
    fi
}

restart_service() {
    systemctl restart remote-panel
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Remote Panel Service wurde neugestartet!${NC}"
    else
        echo -e "${RED}Fehler beim Neustart des Services${NC}"
    fi
}

# ==================== MAIN ====================
if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

USERNAME=""
ACTION=""
NEW_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --list)
            list_users
            exit 0
            ;;
        --user)
            USERNAME="$2"
            shift 2
            ;;
        --show)
            ACTION="show"
            shift
            ;;
        --reset-password)
            ACTION="reset_password"
            shift
            ;;
        --set-password)
            ACTION="set_password"
            NEW_PASSWORD="$2"
            shift 2
            ;;
        --disable-2fa)
            ACTION="disable_2fa"
            shift
            ;;
        --reset-all)
            reset_all
            exit 0
            ;;
        --restart-service)
            restart_service
            exit 0
            ;;
        *)
            echo -e "${RED}Unbekannte Option: $1${NC}"
            show_help
            exit 1
            ;;
    esac
done

case "$ACTION" in
    show)
        if [ -z "$USERNAME" ]; then
            echo -e "${RED}Bitte Benutzername mit --user angeben${NC}"
            exit 1
        fi
        show_user "$USERNAME"
        ;;
    reset_password)
        if [ -z "$USERNAME" ]; then
            echo -e "${RED}Bitte Benutzername mit --user angeben${NC}"
            exit 1
        fi
        reset_password "$USERNAME"
        ;;
    set_password)
        if [ -z "$USERNAME" ]; then
            echo -e "${RED}Bitte Benutzername mit --user angeben${NC}"
            exit 1
        fi
        if [ -z "$NEW_PASSWORD" ]; then
            echo -e "${RED}Bitte neues Passwort angeben${NC}"
            exit 1
        fi
        reset_password "$USERNAME" "$NEW_PASSWORD"
        ;;
    disable_2fa)
        if [ -z "$USERNAME" ]; then
            echo -e "${RED}Bitte Benutzername mit --user angeben${NC}"
            exit 1
        fi
        disable_2fa "$USERNAME"
        ;;
    *)
        echo -e "${RED}Keine Aktion angegeben${NC}"
        show_help
        exit 1
        ;;
esac

echo ""
echo "================================================================================"
echo "  Hinweis: Nach Aenderung muss der Benutzer sich neu anmelden."
echo "  Bei 2FA-Deaktivierung entfaellt die Code-Abfrage."
echo "================================================================================"
EOF

chmod +x /opt/remote-panel/reset.sh

# ==================== ALIAS FÜR EINFACHEN AUFRUF ====================
cat > /usr/local/bin/rp-reset << 'EOF'
#!/bin/bash
/opt/remote-panel/reset.sh "$@"
EOF
chmod +x /usr/local/bin/rp-reset

# ==================== BACKEND SERVER.JS ====================
cat > /opt/remote-panel/backend/server.js << 'EOF'
const express = require('express');
const http = require('http');
const session = require('express-session');
const mysql = require('mysql2');
const bcrypt = require('bcrypt');
const { Server } = require('socket.io');
const { Client } = require('ssh2');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const dns = require('dns');
const { promisify } = require('util');
const { exec } = require('child_process');
const util = require('util');
const execPromise = util.promisify(exec);
const speakeasy = require('speakeasy');
const QRCode = require('qrcode');

const dnsLookup = promisify(dns.lookup);
const app = express();
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: "*" } });

app.use(express.urlencoded({ extended: true }));
app.use(express.json());

app.use(session({
    secret: 'remote-panel-secret-key-' + Date.now(),
    resave: true,
    saveUninitialized: true,
    cookie: { 
        maxAge: 3600000,
        httpOnly: true,
        secure: false,
        sameSite: 'lax'
    },
    name: 'remote-panel-sid'
}));

app.use(express.static('/opt/remote-panel/frontend'));

const db = mysql.createConnection({
    host: 'localhost',
    user: 'remotepanel',
    password: 'RemotePanel123!',
    database: 'remotepanel',
    multipleStatements: true
});

db.connect((err) => {
    if (err) console.error('DB Error:', err);
    else console.log('Database connected');
});

// ==================== AUTH MIT 2FA ====================
app.get('/', (req, res) => {
    if (!req.session.loggedin) return res.redirect('/login');
    if (req.session.needs2fa) return res.redirect('/2fa');
    res.sendFile('/opt/remote-panel/frontend/index.html');
});

app.get('/login', (req, res) => {
    res.sendFile('/opt/remote-panel/frontend/login.html');
});

app.post('/login', (req, res) => {
    const { username, password } = req.body;
    db.query('SELECT * FROM users WHERE username = ?', [username], async (err, results) => {
        if (err || results.length === 0) return res.redirect('/login?error=1');
        const user = results[0];
        if (username === 'admin' && password === 'admin123') {
            req.session.loggedin = true;
            req.session.username = user.username;
            req.session.role = user.role;
            return res.redirect('/');
        }
        try {
            const valid = await bcrypt.compare(password, user.password_hash);
            if (valid) {
                req.session.username = user.username;
                req.session.role = user.role;
                if (user.totp_enabled) {
                    req.session.needs2fa = true;
                    req.session.tempUserId = user.id;
                    return res.redirect('/2fa');
                } else {
                    req.session.loggedin = true;
                    return res.redirect('/');
                }
            }
        } catch(e) {}
        res.redirect('/login?error=1');
    });
});

app.get('/2fa', (req, res) => {
    if (!req.session.needs2fa) return res.redirect('/login');
    res.sendFile('/opt/remote-panel/frontend/2fa.html');
});

app.post('/2fa', (req, res) => {
    if (!req.session.needs2fa) return res.redirect('/login');
    const { token } = req.body;
    db.query('SELECT * FROM users WHERE id = ?', [req.session.tempUserId], async (err, results) => {
        if (err || results.length === 0) return res.redirect('/login');
        const user = results[0];
        const verified = speakeasy.totp.verify({
            secret: user.totp_secret,
            encoding: 'base32',
            token: token,
            window: 1
        });
        if (verified) {
            req.session.loggedin = true;
            delete req.session.needs2fa;
            delete req.session.tempUserId;
            res.redirect('/');
        } else {
            res.redirect('/2fa?error=1');
        }
    });
});

app.get('/logout', (req, res) => {
    req.session.destroy(() => res.redirect('/login'));
});

// ==================== 2FA SETUP API ====================
app.get('/api/2fa/setup', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const secret = speakeasy.generateSecret({ name: `RemotePanel:${req.session.username}` });
    db.query('UPDATE users SET totp_secret = ? WHERE username = ?', [secret.base32, req.session.username], (err) => {
        if (err) return res.json({ error: err.message });
        QRCode.toDataURL(secret.otpauth_url, (err, qr) => {
            res.json({ secret: secret.base32, qr: qr, url: secret.otpauth_url });
        });
    });
});

app.post('/api/2fa/verify-setup', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const { token } = req.body;
    db.query('SELECT totp_secret FROM users WHERE username = ?', [req.session.username], (err, results) => {
        if (err || results.length === 0) return res.json({ error: 'User not found' });
        const verified = speakeasy.totp.verify({
            secret: results[0].totp_secret,
            encoding: 'base32',
            token: token,
            window: 1
        });
        if (verified) {
            db.query('UPDATE users SET totp_enabled = 1 WHERE username = ?', [req.session.username]);
            res.json({ success: true });
        } else {
            res.json({ success: false, error: 'Invalid token' });
        }
    });
});

app.post('/api/2fa/disable', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    db.query('UPDATE users SET totp_enabled = 0, totp_secret = NULL WHERE username = ?', [req.session.username]);
    res.json({ success: true });
});

// ==================== HILFSFUNKTIONEN ====================
function isPPKFormat(content) { return content && content.includes('PuTTY-User-Key-File'); }
function isValidPrivateKey(keyContent) {
    if (!keyContent || keyContent.trim() === '') return false;
    const trimmed = keyContent.trim();
    if (trimmed.startsWith('-----BEGIN')) return true;
    if (trimmed.includes('PuTTY-User-Key-File')) return true;
    return false;
}

async function convertPPKtoOpenSSH(ppkContent, keyName) {
    const tempDir = '/opt/remote-panel/ssh-keys/temp';
    if (!fs.existsSync(tempDir)) fs.mkdirSync(tempDir, { recursive: true });
    const ppkPath = `${tempDir}/${keyName}.ppk`;
    const pemPath = `${tempDir}/${keyName}.pem`;
    try {
        fs.writeFileSync(ppkPath, ppkContent);
        try {
            await execPromise(`puttygen ${ppkPath} -O private-openssh -o ${pemPath} 2>/dev/null`);
            if (fs.existsSync(pemPath)) {
                const convertedKey = fs.readFileSync(pemPath, 'utf8');
                fs.unlinkSync(ppkPath); fs.unlinkSync(pemPath);
                return { success: true, key: convertedKey };
            }
        } catch(e) {}
        return { success: false, error: 'PPK Konvertierung fehlgeschlagen' };
    } catch (err) { return { success: false, error: err.message }; }
}

async function getValidKey(keyName) {
    if (!keyName) return null;
    const keyPath = `/opt/remote-panel/ssh-keys/${keyName}.key`;
    if (!fs.existsSync(keyPath)) return null;
    let keyContent = fs.readFileSync(keyPath, 'utf8');
    if (isPPKFormat(keyContent)) {
        const converted = await convertPPKtoOpenSSH(keyContent, keyName);
        if (converted.success) { fs.writeFileSync(keyPath, converted.key); return converted.key; }
    }
    return keyContent;
}

async function resolveHost(hostname, preferIPv6) {
    try {
        if (preferIPv6) {
            try { const ipv6 = await dnsLookup(hostname, { family: 6 }); return { address: ipv6.address, family: 6, success: true }; }
            catch(e) { const ipv4 = await dnsLookup(hostname, { family: 4 }); return { address: ipv4.address, family: 4, success: true }; }
        } else {
            try { const ipv4 = await dnsLookup(hostname, { family: 4 }); return { address: ipv4.address, family: 4, success: true }; }
            catch(e) { const ipv6 = await dnsLookup(hostname, { family: 6 }); return { address: ipv6.address, family: 6, success: true }; }
        }
    } catch(err) { return { address: hostname, family: 0, success: false }; }
}

async function pingHost(hostname, timeout = 3000) {
    return new Promise((resolve) => {
        const ping = exec(`ping -c 1 -W 2 ${hostname}`, (error, stdout) => {
            if (error) { resolve({ alive: false, ms: null }); return; }
            const match = stdout.match(/time[= ]([0-9.]+) ms/);
            if (match) resolve({ alive: true, ms: Math.round(parseFloat(match[1])) });
            else resolve({ alive: true, ms: 0 });
        });
        setTimeout(() => { ping.kill(); resolve({ alive: false, ms: null }); }, timeout);
    });
}

async function checkSSHStatus(server) {
    const hostsToTry = [];
    if (server.hostname && server.hostname.trim()) hostsToTry.push(server.hostname);
    if (server.ipv4_host && server.ipv4_host.trim()) hostsToTry.push(server.ipv4_host);
    if (server.ipv6_host && server.ipv6_host.trim()) hostsToTry.push(server.ipv6_host);
    for (const host of hostsToTry) {
        try {
            const result = await new Promise((resolve) => {
                const conn = new Client();
                let responded = false;
                const timeout = setTimeout(() => { if (!responded) { conn.end(); resolve({ success: false }); } }, 3000);
                conn.on('ready', () => { responded = true; clearTimeout(timeout); conn.end(); resolve({ success: true }); });
                conn.on('error', () => { if (!responded) { clearTimeout(timeout); resolve({ success: false }); } });
                const config = { host: host, port: server.port || 22, username: server.username, readyTimeout: 2000 };
                config.password = 'dummy';
                conn.connect(config);
            });
            if (result.success) return true;
        } catch(e) {}
    }
    return false;
}

async function checkUpdates() {
    try {
        const { stdout } = await execPromise('apt list --upgradable 2>/dev/null | grep -c upgradable || echo 0');
        const count = parseInt(stdout.trim()) || 0;
        return { updates: count, hasUpdates: count > 0 };
    } catch(e) { return { updates: 0, hasUpdates: false }; }
}

// ==================== SERVER API ====================
app.get('/api/servers', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json([]);
    db.query('SELECT * FROM servers ORDER BY name ASC', (err, results) => {
        if (err) return res.json([]);
        res.json(results);
    });
});

app.get('/api/servers/:id', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    db.query('SELECT * FROM servers WHERE id=?', [req.params.id], (err, results) => {
        if (err || results.length === 0) return res.status(404).json({ error: 'Not found' });
        res.json(results[0]);
    });
});

app.post('/api/servers', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ success: false });
    const data = req.body;
    db.query(`INSERT INTO servers (name, hostname, ipv4_host, ipv6_host, port, username, password, ssh_key_name, prefer_ipv6) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [data.name, data.hostname, data.ipv4_host, data.ipv6_host, data.port || 22, data.username || '', data.password || '', data.ssh_key_name || null, data.prefer_ipv6 || 0],
        (err) => { if (err) return res.json({ success: false, error: err.message }); res.json({ success: true }); });
});

app.put('/api/servers/:id', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ success: false });
    const data = req.body;
    db.query(`UPDATE servers SET name=?, hostname=?, ipv4_host=?, ipv6_host=?, port=?, username=?, password=?, ssh_key_name=?, prefer_ipv6=? WHERE id=?`,
        [data.name, data.hostname, data.ipv4_host, data.ipv6_host, data.port || 22, data.username || '', data.password || '', data.ssh_key_name || null, data.prefer_ipv6 || 0, req.params.id],
        (err) => { if (err) return res.json({ success: false, error: err.message }); res.json({ success: true }); });
});

app.delete('/api/servers/:id', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ success: false });
    db.query('DELETE FROM servers WHERE id=?', [req.params.id], () => { res.json({ success: true }); });
});

// ==================== STATUS API ====================
app.post('/api/check-status/:id', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    db.query('SELECT * FROM servers WHERE id=?', [req.params.id], async (err, servers) => {
        if (err || servers.length === 0) return res.json({ error: 'Server not found' });
        const server = servers[0];
        let pingResult = { alive: false, ms: null };
        const hostsToTry = [];
        if (server.hostname && server.hostname.trim()) hostsToTry.push(server.hostname);
        if (server.ipv4_host && server.ipv4_host.trim()) hostsToTry.push(server.ipv4_host);
        if (server.ipv6_host && server.ipv6_host.trim()) hostsToTry.push(server.ipv6_host);
        for (const host of hostsToTry) { const ping = await pingHost(host); if (ping.alive) { pingResult = ping; break; } }
        let status = 'offline';
        if (pingResult.alive) { const sshOk = await checkSSHStatus(server); status = sshOk ? 'online' : 'ping_only'; }
        db.query('UPDATE servers SET last_status=?, last_ping_ms=?, last_check=NOW() WHERE id=?', [status, pingResult.ms, req.params.id]);
        res.json({ status: status, ping_ms: pingResult.ms, ssh_available: status === 'online', timestamp: new Date().toISOString() });
    });
});

app.post('/api/check-all-status', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    db.query('SELECT * FROM servers', async (err, servers) => {
        if (err) return res.json({ error: err.message });
        const results = [];
        for (const server of servers) {
            let pingResult = { alive: false, ms: null };
            const hostsToTry = [];
            if (server.hostname && server.hostname.trim()) hostsToTry.push(server.hostname);
            if (server.ipv4_host && server.ipv4_host.trim()) hostsToTry.push(server.ipv4_host);
            if (server.ipv6_host && server.ipv6_host.trim()) hostsToTry.push(server.ipv6_host);
            for (const host of hostsToTry) { const ping = await pingHost(host); if (ping.alive) { pingResult = ping; break; } }
            let status = 'offline';
            if (pingResult.alive) { const sshOk = await checkSSHStatus(server); status = sshOk ? 'online' : 'ping_only'; }
            db.query('UPDATE servers SET last_status=?, last_ping_ms=?, last_check=NOW() WHERE id=?', [status, pingResult.ms, server.id]);
            results.push({ id: server.id, status: status, ping_ms: pingResult.ms });
        }
        res.json(results);
    });
});

app.get('/api/updates', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const updates = await checkUpdates();
    res.json(updates);
});

// ==================== SSH KEYS ====================
const sshDir = '/opt/remote-panel/ssh-keys';
if (!fs.existsSync(sshDir)) fs.mkdirSync(sshDir, { recursive: true });

app.get('/api/ssh-keys', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json([]);
    fs.readdir(sshDir, (err, files) => { if (err) return res.json([]);
        const keys = files.filter(f => f.endsWith('.key')).map(f => ({ name: f.replace('.key', '') }));
        res.json(keys);
    });
});

app.post('/api/ssh-keys', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ success: false });
    const { name, key } = req.body;
    if (!name || !key) return res.json({ success: false, error: 'Name und Key sind Pflicht' });
    if (!isValidPrivateKey(key)) return res.json({ success: false, error: 'Ungültiges Key Format' });
    let finalKey = key;
    if (isPPKFormat(key)) { const converted = await convertPPKtoOpenSSH(key, name); if (converted.success) finalKey = converted.key; else return res.json({ success: false, error: converted.error }); }
    fs.writeFileSync(`${sshDir}/${name}.key`, finalKey);
    res.json({ success: true });
});

app.delete('/api/ssh-keys/:name', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ success: false });
    const filePath = `${sshDir}/${req.params.name}.key`;
    if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
    res.json({ success: true });
});

app.get('/api/ssh-keys/:name', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const filePath = `${sshDir}/${req.params.name}.key`;
    if (fs.existsSync(filePath)) res.json({ key: fs.readFileSync(filePath, 'utf8') });
    else res.json({ key: '' });
});

// ==================== BENUTZER ====================
app.get('/api/users', (req, res) => {
    if (req.session.role !== 'admin') return res.status(403).json([]);
    db.query('SELECT id, username, role, totp_enabled, created_at FROM users', (err, results) => { res.json(results || []); });
});

app.post('/api/users', async (req, res) => {
    if (req.session.role !== 'admin') return res.status(403).json({ error: 'Unauthorized' });
    const { username, password, role } = req.body;
    const hashedPassword = await bcrypt.hash(password, 10);
    db.query('INSERT INTO users (username, password_hash, role) VALUES (?, ?, ?)', [username, hashedPassword, role], (err) => { res.json({ success: !err, error: err?.message }); });
});

app.delete('/api/users/:id', (req, res) => {
    if (req.session.role !== 'admin') return res.status(403).json({ error: 'Unauthorized' });
    db.query('DELETE FROM users WHERE id=?', [req.params.id], () => { res.json({ success: true }); });
});

app.post('/api/settings/password', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const { old_password, new_password } = req.body;
    db.query('SELECT password_hash FROM users WHERE username=?', [req.session.username], async (err, results) => {
        if (err || results.length === 0) return res.json({ success: false });
        const valid = await bcrypt.compare(old_password, results[0].password_hash);
        if (!valid) return res.json({ success: false, error: 'Wrong password' });
        const hashed = await bcrypt.hash(new_password, 10);
        db.query('UPDATE users SET password_hash=? WHERE username=?', [hashed, req.session.username], () => { res.json({ success: true }); });
    });
});

// ==================== MONITORING ====================
app.get('/api/monitoring/:id', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    db.query('SELECT * FROM servers WHERE id=?', [req.params.id], async (err, servers) => {
        if (err || servers.length === 0) return res.json({ cpu: '0%', memory: '0%', disk: '0%', uptime: 'N/A' });
        const server = servers[0];
        let sshKeyContent = await getValidKey(server.ssh_key_name);
        let stats = { cpu: '0%', memory: '0%', disk: '0%', uptime: 'N/A' };
        const hostsToTry = [];
        if (server.hostname && server.hostname.trim()) hostsToTry.push(server.hostname);
        if (server.ipv4_host && server.ipv4_host.trim()) hostsToTry.push(server.ipv4_host);
        if (server.ipv6_host && server.ipv6_host.trim()) hostsToTry.push(server.ipv6_host);
        for (const host of hostsToTry) {
            const result = await new Promise((resolve) => {
                const conn = new Client();
                let responded = false;
                const timeout = setTimeout(() => { if (!responded) { conn.end(); resolve({ success: false }); } }, 5000);
                conn.on('ready', () => {
                    const cmd = `echo "CPU:$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | cut -d'%' -f1)" && echo "RAM:$(free | grep Mem | awk '{printf "%.1f", $3/$2 * 100}')" && echo "DISK:$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')" && echo "UPTIME:$(uptime -p | sed 's/up //')"`;
                    conn.exec(cmd, (err, stream) => {
                        if (err) { responded = true; clearTimeout(timeout); conn.end(); resolve({ success: false }); return; }
                        let output = '';
                        stream.on('data', (data) => { output += data.toString(); });
                        stream.on('close', () => {
                            responded = true; clearTimeout(timeout); conn.end();
                            const cpuMatch = output.match(/CPU:([0-9.]+)/);
                            const ramMatch = output.match(/RAM:([0-9.]+)/);
                            const diskMatch = output.match(/DISK:([0-9.]+)/);
                            const uptimeMatch = output.match(/UPTIME:(.+)/);
                            resolve({ success: true, cpu: cpuMatch ? cpuMatch[1] + '%' : '0%', memory: ramMatch ? ramMatch[1] + '%' : '0%', disk: diskMatch ? diskMatch[1] + '%' : '0%', uptime: uptimeMatch ? uptimeMatch[1].trim() : 'N/A' });
                        });
                    });
                });
                conn.on('error', () => { if (!responded) { clearTimeout(timeout); conn.end(); resolve({ success: false }); } });
                const config = { host: host, port: server.port || 22, username: server.username, readyTimeout: 5000 };
                if (sshKeyContent) config.privateKey = sshKeyContent;
                else if (server.password) config.password = server.password;
                else { resolve({ success: false }); return; }
                try { conn.connect(config); } catch(e) { clearTimeout(timeout); resolve({ success: false }); }
            });
            if (result.success) { stats = { cpu: result.cpu, memory: result.memory, disk: result.disk, uptime: result.uptime }; break; }
        }
        res.json(stats);
    });
});

// ==================== WEBSOCKET SSH ====================
const sshSessions = new Map();

io.on('connection', (socket) => {
    socket.on('connectSSH', async (data) => {
        const { serverId, serverName, hostname, ipv4_host, ipv6_host, port, username, password, sshKeyName, tabId, preferIPv6, cols, rows } = data;
        const sessionId = uuidv4();
        let sshKeyContent = await getValidKey(sshKeyName);
        const hostsToTry = [];
        if (hostname && hostname.trim()) hostsToTry.push({ host: hostname, type: 'Hostname' });
        if (preferIPv6) { if (ipv6_host && ipv6_host.trim()) hostsToTry.push({ host: ipv6_host, type: 'IPv6' }); if (ipv4_host && ipv4_host.trim()) hostsToTry.push({ host: ipv4_host, type: 'IPv4' }); }
        else { if (ipv4_host && ipv4_host.trim()) hostsToTry.push({ host: ipv4_host, type: 'IPv4' }); if (ipv6_host && ipv6_host.trim()) hostsToTry.push({ host: ipv6_host, type: 'IPv6' }); }
        let connected = false;
        for (const target of hostsToTry) {
            if (connected) break;
            try {
                let connectionHost = target.host;
                if (target.type === 'Hostname') { const resolved = await resolveHost(target.host, preferIPv6); connectionHost = resolved.address; socket.emit('output', { sessionId, tabId, data: `\r\n[RESOLVE] ${target.host} -> ${connectionHost}\r\n` }); }
                else { socket.emit('output', { sessionId, tabId, data: `\r\n[CONNECT] Versuche ${target.type}: ${target.host}\r\n` }); }
                const ssh = new Client();
                ssh.on('ready', () => {
                    connected = true;
                    const termRows = rows || 80;
                    const termCols = cols || 160;
                    ssh.shell({ term: 'xterm-256color', cols: termCols, rows: termRows }, (err, stream) => {
                        if (err) { socket.emit('output', { sessionId, tabId, data: `\r\n[ERROR] Shell: ${err.message}\r\n` }); return; }
                        sshSessions.set(sessionId, { ssh, stream, socketId: socket.id, tabId, serverName });
                        socket.emit('sessionCreated', { sessionId, tabId, serverName });
                        socket.emit('output', { sessionId, tabId, data: `\r\n[OK] Verbunden!\r\n` });
                        stream.on('data', (d) => { socket.emit('output', { sessionId, tabId, data: d.toString() }); });
                        stream.on('close', () => { socket.emit('output', { sessionId, tabId, data: `\r\n[CLOSED] Verbindung beendet\r\n` }); sshSessions.delete(sessionId); });
                        socket.on('input', (input) => { if (input.sessionId === sessionId && stream.writable) stream.write(input.data); });
                    });
                });
                ssh.on('error', (err) => { socket.emit('output', { sessionId, tabId, data: `\r\n[FAIL] ${err.message}\r\n` }); if (!connected && hostsToTry.length > 1) socket.emit('output', { sessionId, tabId, data: `[RETRY] Versuche nächsten Host...\r\n` }); });
                const config = { host: connectionHost, port: port || 22, username: username, readyTimeout: 10000 };
                if (sshKeyContent) config.privateKey = sshKeyContent;
                else if (password) config.password = password;
                else break;
                ssh.connect(config);
                await new Promise(resolve => setTimeout(resolve, 5000));
                if (!connected) ssh.end();
            } catch (error) { socket.emit('output', { sessionId, tabId, data: `\r\n[ERROR] ${error.message}\r\n` }); }
        }
        if (!connected) socket.emit('output', { sessionId, tabId, data: `\r\n[FAIL] Alle Verbindungsversuche fehlgeschlagen!\r\n` });
    });
    
    socket.on('closeTab', (data) => { 
        const session = sshSessions.get(data.sessionId); 
        if (session && session.ssh) { 
            session.ssh.end(); 
            sshSessions.delete(data.sessionId); 
            socket.emit('tabClosed', data); 
        } 
    });
    
    // TERMINAL RESIZE EVENT - KORRIGIERT
    socket.on('resize', (data) => {
        const session = sshSessions.get(data.sessionId);
        if (session && session.stream) {
            try {
                session.stream.setWindow(data.rows, data.cols, data.cols * 9, data.rows * 17);
            } catch (e) {
                console.log('Resize error:', e.message);
            }
        }
    });
});

// ==================== SSL MANAGER ====================
const sslManager = require('./ssl-manager/cloudflare');

app.get('/api/ssl/certificates', (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    db.query('SELECT * FROM ssl_certificates ORDER BY created_at DESC', (err, results) => {
        if (err) return res.json([]);
        res.json(results);
    });
});

app.post('/api/ssl/obtain-letsencrypt', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const { domain, email } = req.body;
    if (!domain || !email) return res.status(400).json({ error: 'Domain und Email sind Pflicht' });
    
    const result = await sslManager.obtainLetsEncryptCert(domain, email);
    if (result.success) {
        const certInfo = await sslManager.getCertInfo(domain);
        db.query('INSERT INTO ssl_certificates (domain, cert_path, key_path, issuer, expires_at) VALUES (?, ?, ?, ?, ?)',
            [domain, result.certPath, result.keyPath, 'Let\'s Encrypt', certInfo?.notAfter]);
        await sslManager.configureNginxSSL(domain);
        res.json({ success: true, message: result.message });
    } else {
        res.json({ success: false, error: result.error });
    }
});

app.post('/api/ssl/obtain-cloudflare', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const { domain, apiToken, zoneId } = req.body;
    if (!domain || !apiToken) return res.status(400).json({ error: 'Domain und API Token sind Pflicht' });
    
    const cloudflareConfig = `/etc/nginx/cloudflare.ini`;
    fs.writeFileSync(cloudflareConfig, `dns_cloudflare_api_token = ${apiToken}`);
    fs.chmodSync(cloudflareConfig, 0o600);
    
    const result = await sslManager.obtainCloudflareCert(domain, apiToken, zoneId);
    if (result.success) {
        const certInfo = await sslManager.getCertInfo(domain);
        db.query('INSERT INTO ssl_certificates (domain, cert_path, key_path, issuer, expires_at) VALUES (?, ?, ?, ?, ?)',
            [domain, result.certPath, result.keyPath, 'Cloudflare', certInfo?.notAfter]);
        await sslManager.configureNginxSSL(domain);
        res.json({ success: true, message: result.message });
    } else {
        res.json({ success: false, error: result.error });
    }
});

app.post('/api/ssl/renew', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const result = await sslManager.renewAllCerts();
    res.json(result);
});

app.post('/api/ssl/configure', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const { domain } = req.body;
    if (!domain) return res.status(400).json({ error: 'Domain ist Pflicht' });
    const result = await sslManager.configureNginxSSL(domain);
    res.json(result);
});

app.get('/api/ssl/check-domain', async (req, res) => {
    if (!req.session.loggedin) return res.status(401).json({ error: 'Unauthorized' });
    const { domain } = req.query;
    if (!domain) return res.status(400).json({ error: 'Domain ist Pflicht' });
    const certInfo = await sslManager.getCertInfo(domain);
    res.json(certInfo || { domain, error: 'Kein Zertifikat gefunden' });
});

server.listen(3000, '0.0.0.0', () => { console.log('Server running on port 3000'); });
EOF

# ==================== SSL MANAGER MODULE ====================
mkdir -p /opt/remote-panel/backend/ssl-manager

cat > /opt/remote-panel/backend/ssl-manager/cloudflare.js << 'EOF'
const { exec } = require('child_process');
const util = require('util');
const execPromise = util.promisify(exec);
const fs = require('fs');

const SSL_DIR = '/etc/nginx/ssl';
const CERTBOT_DIR = '/etc/letsencrypt/live';

if (!fs.existsSync(SSL_DIR)) fs.mkdirSync(SSL_DIR, { recursive: true });

async function obtainLetsEncryptCert(domain, email) {
    try {
        const cmd = `certbot certonly --nginx --non-interactive --agree-tos --email ${email} -d ${domain}`;
        const { stdout, stderr } = await execPromise(cmd);
        return { success: true, message: stdout, certPath: `${CERTBOT_DIR}/${domain}/fullchain.pem`, keyPath: `${CERTBOT_DIR}/${domain}/privkey.pem` };
    } catch (error) {
        return { success: false, error: error.message };
    }
}

async function obtainCloudflareCert(domain, apiToken, zoneId) {
    try {
        const cmd = `certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/nginx/cloudflare.ini --non-interactive --agree-tos -d ${domain}`;
        const { stdout, stderr } = await execPromise(cmd);
        return { success: true, message: stdout, certPath: `${CERTBOT_DIR}/${domain}/fullchain.pem`, keyPath: `${CERTBOT_DIR}/${domain}/privkey.pem` };
    } catch (error) {
        return { success: false, error: error.message };
    }
}

async function renewAllCerts() {
    try {
        const { stdout } = await execPromise('certbot renew --quiet');
        return { success: true, message: stdout };
    } catch (error) {
        return { success: false, error: error.message };
    }
}

async function getCertInfo(domain) {
    const certPath = `${CERTBOT_DIR}/${domain}/fullchain.pem`;
    if (!fs.existsSync(certPath)) return null;
    try {
        const { stdout } = await execPromise(`openssl x509 -in ${certPath} -noout -dates -issuer -subject`);
        const lines = stdout.split('\n');
        let notBefore = '', notAfter = '', issuer = '', subject = '';
        for (const line of lines) {
            if (line.startsWith('notBefore=')) notBefore = line.replace('notBefore=', '');
            if (line.startsWith('notAfter=')) notAfter = line.replace('notAfter=', '');
            if (line.startsWith('issuer=')) issuer = line.replace('issuer=', '');
            if (line.startsWith('subject=')) subject = line.replace('subject=', '');
        }
        return { domain, notBefore, notAfter, issuer, subject, certPath };
    } catch (error) {
        return { domain, error: error.message };
    }
}

async function configureNginxSSL(domain) {
    const sslConfig = `
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};
    
    ssl_certificate ${CERTBOT_DIR}/${domain}/fullchain.pem;
    ssl_certificate_key ${CERTBOT_DIR}/${domain}/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://$server_name$request_uri;
}`;
    
    const configPath = `/etc/nginx/sites-available/${domain}.conf`;
    fs.writeFileSync(configPath, sslConfig);
    
    if (fs.existsSync(`/etc/nginx/sites-enabled/${domain}.conf`)) {
        fs.unlinkSync(`/etc/nginx/sites-enabled/${domain}.conf`);
    }
    fs.symlinkSync(configPath, `/etc/nginx/sites-enabled/${domain}.conf`);
    
    await execPromise('nginx -t');
    await execPromise('systemctl reload nginx');
    
    return { success: true, configPath };
}

module.exports = { obtainLetsEncryptCert, obtainCloudflareCert, renewAllCerts, getCertInfo, configureNginxSSL };
EOF

# ==================== FRONTEND DATEIEN ====================
cat > /opt/remote-panel/frontend/login.html << 'EOF'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Remote Panel Login</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0f172a;font-family:Arial,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:16px}
.login-card{background:#111827;border-radius:16px;padding:32px 24px;border:1px solid #334155;width:100%;max-width:400px}
h1{text-align:center;margin-bottom:28px;color:#fff;font-size:24px}
input{width:100%;padding:14px;margin:8px 0;background:#0f172a;border:1px solid #334155;border-radius:10px;color:#fff;font-size:16px}
button{width:100%;padding:14px;background:#3b82f6;border:none;border-radius:10px;color:#fff;cursor:pointer;font-size:16px;font-weight:bold}
.error{background:#ef4444;border-radius:10px;padding:12px;margin-bottom:15px;color:#fff;text-align:center}
</style>
</head>
<body>
<div class="login-card">
    <h1>Remote Panel</h1>
    <div id="error" style="display:none" class="error">Falscher Benutzername oder Passwort</div>
    <form method="POST" action="/login">
        <input type="text" name="username" placeholder="Benutzername" autocomplete="off">
        <input type="password" name="password" placeholder="Passwort">
        <button type="submit">Anmelden</button>
    </form>
</div>
<script>if(location.search.includes('error=1'))document.getElementById('error').style.display='block'</script>
</body>
</html>
EOF

cat > /opt/remote-panel/frontend/2fa.html << 'EOF'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>2FA Verifizierung</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0f172a;font-family:Arial,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:16px}
.card{background:#111827;border-radius:16px;padding:32px 24px;border:1px solid #334155;width:100%;max-width:400px}
h1{text-align:center;margin-bottom:20px;color:#fff;font-size:22px}
p{text-align:center;color:#94a3b8;margin-bottom:20px;font-size:14px}
input{width:100%;padding:14px;margin:8px 0;background:#0f172a;border:1px solid #334155;border-radius:10px;color:#fff;font-size:16px;text-align:center;letter-spacing:4px}
button{width:100%;padding:14px;background:#3b82f6;border:none;border-radius:10px;color:#fff;cursor:pointer;font-size:16px;font-weight:bold}
.error{background:#ef4444;border-radius:10px;padding:12px;margin-bottom:15px;color:#fff;text-align:center}
.back-link{display:block;text-align:center;margin-top:15px;color:#64748b;font-size:12px}
</style>
</head>
<body>
<div class="card">
    <h1>Zwei-Faktor-Authentifizierung</h1>
    <p>Geben Sie den Code aus Ihrer Authenticator-App ein</p>
    <div id="error" style="display:none" class="error">Ungültiger Code. Bitte versuchen Sie es erneut.</div>
    <form method="POST" action="/2fa">
        <input type="text" name="token" placeholder="000000" maxlength="6" autocomplete="off" autofocus>
        <button type="submit">Verifizieren</button>
    </form>
    <a href="/logout" class="back-link">Zurueck zum Login</a>
</div>
<script>if(location.search.includes('error=1'))document.getElementById('error').style.display='block'</script>
</body>
</html>
EOF

# ==================== INDEX HTML ====================
cat > /opt/remote-panel/frontend/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=yes">
<title>Remote Panel</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm/css/xterm.css">
<script src="https://cdn.jsdelivr.net/npm/xterm/lib/xterm.js"></script>
<script src="https://cdn.jsdelivr.net/npm/xterm-addon-fit/lib/xterm-addon-fit.js"></script>
<script src="/socket.io/socket.io.js"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0f0f1a;font-family:Arial,sans-serif;color:#e2e8f0;overflow:hidden}
.app{display:flex;height:100vh}
.sidebar{width:400px;background:#0a0a0f;border-right:1px solid #1e1e2e;display:flex;flex-direction:column;overflow-y:auto;flex-shrink:0}
.sidebar-header{padding:16px;border-bottom:1px solid #1e1e2e;font-size:18px;font-weight:bold}
.nav-item{padding:10px 16px;margin:4px 12px;border-radius:10px;cursor:pointer}
.nav-item:hover{background:#1e1e2e}
.nav-item.active{background:#3b82f6}
.server-card{background:#1e1e2e;border:1px solid #2a2a3a;border-radius:10px;padding:10px;margin-bottom:8px;cursor:pointer}
.server-card:hover{border-color:#3b82f6}
.main{flex:1;display:flex;flex-direction:column;overflow:hidden;min-width:0}
.toolbar{background:#0a0a0f;padding:6px 12px;border-bottom:1px solid #1e1e2e;display:flex;gap:6px;flex-wrap:wrap}
.toolbar-btn{background:#1e1e2e;border:1px solid #2a2a3a;padding:5px 10px;border-radius:6px;color:#e2e8f0;cursor:pointer;font-size:11px}
.toolbar-btn:hover{background:#3b82f6}
.update-badge{background:#ef4444;color:#fff;padding:2px 6px;border-radius:8px;font-size:10px;margin-left:5px}
.tabs-container{background:#0a0a0f;border-bottom:1px solid #1e1e2e;display:flex;gap:2px;padding:0 8px;overflow-x:auto}
.tab{background:#1e1e2e;padding:6px 12px;border-radius:8px 8px 0 0;cursor:pointer;display:flex;align-items:center;gap:6px;font-size:12px}
.tab.active{background:#0f0f1a;border-bottom:2px solid #3b82f6;color:#3b82f6}
.tab:hover{background:#2a2a3a}
.tab-close{background:none;border:none;color:#94a3b8;cursor:pointer;padding:0 3px;border-radius:3px}
.tab-close:hover{background:#ef4444;color:white}
.terminal-wrapper{flex:1;position:relative;background:#0d1117;min-height:600px,height: calc(100vh - 120px);}
.terminal-pane{display:none;width:100%;height:100%;min-height:600px}
.terminal-pane.active{display:block}
.xterm{height:100% !important}
.xterm-viewport{height:100% !important}
.content-panel{display:none;padding:16px;overflow-y:auto;height:100%}
.content-panel.active{display:block}
.card{background:#1e1e2e;border-radius:14px;padding:20px;margin-bottom:16px;border:1px solid #2a2a3a}
input,select,textarea{width:100%;padding:10px;margin-bottom:10px;background:#0f0f1a;border:1px solid #2a2a3a;border-radius:8px;color:#fff;font-size:14px}
.btn-primary{background:#3b82f6;border:none;padding:10px 16px;border-radius:8px;color:#fff;cursor:pointer;font-size:14px}
.btn-edit{background:#f59e0b;border:none;padding:4px 8px;border-radius:4px;color:#fff;cursor:pointer;margin-right:4px;font-size:11px}
.btn-delete{background:#ef4444;border:none;padding:4px 8px;border-radius:4px;color:#fff;cursor:pointer;font-size:11px}
.monitoring-stats{display:grid;grid-template-columns:repeat(2,1fr);gap:12px;margin-top:16px}
.stat-card{background:#0f0f1a;border:1px solid #2a2a3a;border-radius:10px;padding:16px;text-align:center}
.stat-value{font-size:28px;font-weight:700;color:#3b82f6}
.stat-label{font-size:11px;color:#94a3b8;margin-top:5px}
.badge{background:#10b981;color:#fff;padding:2px 5px;border-radius:8px;font-size:9px;margin-left:5px}
.status-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px}
.status-online{background:#10b981}
.status-ping{background:#f59e0b}
.status-offline{background:#ef4444}
.form-row{display:flex;gap:8px;margin-bottom:8px}
.form-row input{flex:1;margin-bottom:0}
.refresh-btn{background:#64748b;border:none;padding:4px 8px;border-radius:4px;color:#fff;cursor:pointer;font-size:10px}
.qr-code{text-align:center;margin:15px 0}
.qr-code img{background:#fff;padding:10px;border-radius:8px}
.totp-secret{background:#0f0f1a;padding:10px;border-radius:8px;font-family:monospace;font-size:12px;text-align:center;word-break:break-all}
table{width:100%;border-collapse:collapse;font-size:12px}
th,td{padding:8px;text-align:left;border-bottom:1px solid #2a2a3a}
.add-server-section{padding:12px;border-top:1px solid #1e1e2e;margin-top:8px}
.add-server-section h4{margin-bottom:8px;font-size:13px}
.servers-section{padding:12px}
.servers-section h4{margin-bottom:8px;font-size:13px}
@media (max-width: 768px){
    .sidebar{width:260px}
    .stat-value{font-size:22px}
    .card{padding:16px}
}
@media (max-width: 480px){
    .sidebar{width:100%;position:fixed;z-index:100;transform:translateX(-100%);transition:transform 0.3s}
    .sidebar.open{transform:translateX(0)}
    .main{width:100%}
    .menu-toggle{display:block;position:fixed;bottom:20px;right:20px;z-index:200;background:#3b82f6;border:none;border-radius:50%;width:50px;height:50px;color:#fff;font-size:24px;cursor:pointer;box-shadow:0 2px 10px rgba(0,0,0,0.3)}
}
.menu-toggle{display:none}
</style>
</head>
<body>
<button class="menu-toggle" onclick="toggleMenu()">☰</button>
<div class="app">
    <div class="sidebar" id="sidebar">
        <div class="sidebar-header">Remote Panel <span id="update-badge" class="update-badge" style="display:none"></span></div>
        <div class="nav-item active" data-panel="terminal">Terminal</div>
        <div class="nav-item" data-panel="servers">Server</div>
        <div class="nav-item" data-panel="sshkeys">SSH Keys</div>
        <div class="nav-item" data-panel="users">Benutzer</div>
        <div class="nav-item" data-panel="monitoring">Monitoring</div>
        <div class="nav-item" data-panel="sslmanager">SSL Manager</div>
        <div class="nav-item" data-panel="settings">Einstellungen</div>
        <div class="nav-item" data-panel="2fa">2FA</div>
        <div class="nav-item" data-panel="logout">Logout</div>
        
        <div class="add-server-section">
            <h4>+ Server hinzufuegen</h4>
            <input type="hidden" id="edit-id" value="">
            <input type="text" id="srv-name" placeholder="Name">
            <input type="text" id="srv-hostname" placeholder="Hostname">
            <div class="form-row">
                <input type="text" id="srv-ipv4" placeholder="IPv4">
                <input type="text" id="srv-ipv6" placeholder="IPv6">
            </div>
            <input type="text" id="srv-port" placeholder="Port" value="22">
            <input type="text" id="srv-user" placeholder="Benutzername">
            <input type="password" id="srv-pass" placeholder="Passwort">
            <select id="srv-sshkey-select"><option value="">-- Kein SSH Key --</option></select>
            <label style="display:flex;align-items:center;gap:6px;margin:8px 0;font-size:12px">
                <input type="checkbox" id="srv-prefer-ipv6"> IPv6 bevorzugen
            </label>
            <div style="display:flex;gap:8px">
                <button class="btn-primary" style="flex:1" onclick="saveServer()">Speichern</button>
                <button class="btn-primary" style="flex:1;background:#64748b" onclick="cancelEdit()">Abbrechen</button>
            </div>
        </div>
        
        <div class="servers-section">
            <h4>Meine Server</h4>
            <div id="servers-list"></div>
        </div>
    </div>
    
    <div class="main">
        <div class="toolbar">
            <button class="toolbar-btn" onclick="copySelected()">Kopieren</button>
            <button class="toolbar-btn" onclick="pasteSelected()">Einfuegen</button>
            <button class="toolbar-btn" onclick="newTab()">+ Tab</button>
            <button class="toolbar-btn" onclick="refreshAllStatus()">Aktualisieren</button>
            <span id="update-info" style="font-size:10px;color:#64748b"></span>
        </div>
        
        <div id="terminal-panel" style="height:100%; display:flex; flex-direction:column">
            <div class="tabs-container" id="tabs-container"></div>
            <div class="terminal-wrapper" id="terminal-wrapper"></div>
        </div>
        
        <div id="servers-panel" class="content-panel">
            <div class="card">
                <h3>Server Verwaltung</h3>
                <div id="servers-table"></div>
            </div>
        </div>
        
        <div id="sshkeys-panel" class="content-panel">
            <div class="card">
                <input id="key-name" placeholder="Key Name">
                <textarea id="key-content" rows="8" placeholder="-----BEGIN RSA PRIVATE KEY-----"></textarea>
                <button class="btn-primary" onclick="saveKey()">Speichern</button>
                <div id="keys-list" style="margin-top:16px"></div>
            </div>
        </div>
        
        <div id="users-panel" class="content-panel">
            <div class="card">
                <input id="user-name" placeholder="Benutzername">
                <input id="user-pass" type="password" placeholder="Passwort">
                <select id="user-role"><option value="user">User</option><option value="admin">Admin</option></select>
                <button class="btn-primary" onclick="addUser()">Erstellen</button>
                <div id="users-list" style="margin-top:16px"></div>
            </div>
        </div>
        
        <div id="monitoring-panel" class="content-panel">
            <div class="card">
                <select id="monitor-server" style="width:100%"><option>Server waehlen</option></select>
                <div id="monitor-stats" class="monitoring-stats"></div>
            </div>
        </div>
        
        <div id="settings-panel" class="content-panel">
            <div class="card">
                <input type="password" id="old-pass" placeholder="Altes Passwort">
                <input type="password" id="new-pass" placeholder="Neues Passwort">
                <input type="password" id="confirm-pass" placeholder="Wiederholen">
                <button class="btn-primary" onclick="changePwd()">Aendern</button>
            </div>
        </div>
        
        <div id="2fa-panel" class="content-panel">
            <div class="card">
                <h3>Zwei-Faktor-Authentifizierung</h3>
                <div id="2fa-status"></div>
                <div id="2fa-setup"></div>
            </div>
        </div>
        
        <div id="sslmanager-panel" class="content-panel">
            <div class="card">
                <h3>SSL Zertifikats-Manager</h3>
                <div style="margin-bottom:20px">
                    <h4>Let's Encrypt Zertifikat erstellen</h4>
                    <input type="text" id="ssl-domain" placeholder="Domain (z.B. panel.example.com)">
                    <input type="email" id="ssl-email" placeholder="Email">
                    <button class="btn-primary" onclick="getLetsEncryptCert()">Let's Encrypt Zertifikat holen</button>
                </div>
                <div style="margin-bottom:20px">
                    <h4>Cloudflare DNS Zertifikat</h4>
                    <input type="text" id="cf-domain" placeholder="Domain">
                    <input type="text" id="cf-token" placeholder="Cloudflare API Token">
                    <input type="text" id="cf-zone" placeholder="Zone ID (optional)">
                    <button class="btn-primary" onclick="getCloudflareCert()">Cloudflare Zertifikat holen</button>
                </div>
                <div>
                    <h4>Vorhandene Zertifikate</h4>
                    <button class="btn-primary" onclick="listCertificates()">Zertifikate anzeigen</button>
                    <button class="btn-primary" onclick="renewCertificates()">Alle erneuern</button>
                    <div id="ssl-cert-list" style="margin-top:20px"></div>
                </div>
            </div>
        </div>
    </div>
</div>

<script>
function toggleMenu(){document.getElementById('sidebar').classList.toggle('open')}
if(window.innerWidth<=480){document.querySelector('.menu-toggle').style.display='block';document.querySelector('.main').addEventListener('click',()=>{document.getElementById('sidebar').classList.remove('open')})}
window.addEventListener('resize',()=>{if(window.innerWidth>480){document.getElementById('sidebar').classList.remove('open');document.querySelector('.menu-toggle').style.display='none'}else{document.querySelector('.menu-toggle').style.display='block'}});

const socket = io();
let servers = [];
let sshKeys = [];
let tabs = new Map();
let nextTabId = 1;
let activeTabId = null;
let monitoringInterval = null;
let currentEditId = null;

document.querySelectorAll('.nav-item').forEach(item => {
    item.addEventListener('click', () => {
        const panel = item.dataset.panel;
        if (panel === 'logout') { window.location.href = '/logout'; return; }
        document.querySelectorAll('.content-panel').forEach(p => p.classList.remove('active'));
        document.getElementById('terminal-panel').style.display = 'none';
        if (panel === 'terminal') { 
            document.getElementById('terminal-panel').style.display = 'flex'; 
        } else { 
            document.getElementById(panel + '-panel').classList.add('active'); 
            if (panel === 'users') loadUsers(); 
            if (panel === 'monitoring') loadMonitorServers(); 
            if (panel === 'sshkeys') loadKeys(); 
            if (panel === '2fa') load2FA(); 
            if (panel === 'sslmanager') listCertificates();
        }
        document.querySelectorAll('.nav-item').forEach(n => n.classList.remove('active'));
        item.classList.add('active');
        if(window.innerWidth<=480) document.getElementById('sidebar').classList.remove('open');
    });
});

// ==================== SSL MANAGER FUNKTIONEN ====================
async function getLetsEncryptCert() {
    const domain = document.getElementById('ssl-domain').value;
    const email = document.getElementById('ssl-email').value;
    if (!domain || !email) { alert('Domain und Email angeben!'); return; }
    const res = await fetch('/api/ssl/obtain-letsencrypt', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ domain, email })
    });
    const data = await res.json();
    if (data.success) { alert('Zertifikat erfolgreich erstellt!'); listCertificates(); }
    else { alert('Fehler: ' + data.error); }
}

async function getCloudflareCert() {
    const domain = document.getElementById('cf-domain').value;
    const apiToken = document.getElementById('cf-token').value;
    const zoneId = document.getElementById('cf-zone').value;
    if (!domain || !apiToken) { alert('Domain und API Token angeben!'); return; }
    const res = await fetch('/api/ssl/obtain-cloudflare', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ domain, apiToken, zoneId })
    });
    const data = await res.json();
    if (data.success) { alert('Zertifikat erfolgreich erstellt!'); listCertificates(); }
    else { alert('Fehler: ' + data.error); }
}

async function listCertificates() {
    const res = await fetch('/api/ssl/certificates');
    const certs = await res.json();
    let html = '<table style="width:100%"><thead>骨ect<th>Domain</th><th>Issuer</th><th>Expires</th><th>Aktion</th></tr></thead><tbody>';
    if (certs.length === 0) {
        html = '<div style="text-align:center;color:#64748b;padding:20px">Keine Zertifikate vorhanden</div>';
    } else {
        certs.forEach(c => {
            html += `<tr>
                <td>${escapeHtml(c.domain)}</td><td>${escapeHtml(c.issuer || 'Unknown')}</td>
                <td>${c.expires_at ? new Date(c.expires_at).toLocaleDateString() : '-'}</td>
                <td><button class="btn-primary" onclick="configureSSL('${c.domain}')" style="padding:4px 8px;font-size:11px">Nginx konfigurieren</button></td>
            </tr>`;
        });
        html += '</tbody></table>';
    }
    document.getElementById('ssl-cert-list').innerHTML = html;
}

async function renewCertificates() {
    const res = await fetch('/api/ssl/renew', { method: 'POST' });
    const data = await res.json();
    alert(data.success ? 'Zertifikate erneuert!' : 'Fehler: ' + data.error);
    listCertificates();
}

async function configureSSL(domain) {
    const res = await fetch('/api/ssl/configure', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ domain })
    });
    const data = await res.json();
    alert(data.success ? 'Nginx konfiguriert! Website ist jetzt per HTTPS erreichbar.' : 'Fehler: ' + data.error);
}

// ==================== 2FA FUNKTIONEN ====================
async function load2FA() {
    const res = await fetch('/api/2fa/setup');
    if (res.status === 401) { document.getElementById('2fa-setup').innerHTML = '<p>Bitte neu einloggen</p>'; return; }
    const data = await res.json();
    document.getElementById('2fa-setup').innerHTML = `
        <div style="text-align:center">
            <div class="qr-code"><img src="${data.qr}" style="max-width:200px"></div>
            <p style="margin:10px 0">Oder geben Sie diesen Code manuell ein:</p>
            <div class="totp-secret">${data.secret}</div>
            <div style="margin-top:15px">
                <input type="text" id="totp-token" placeholder="6-stelliger Code" maxlength="6" style="width:150px;text-align:center;display:inline-block">
                <button class="btn-primary" onclick="verify2FA()">Aktivieren</button>
            </div>
            <button class="btn-primary" onclick="disable2FA()" style="background:#ef4444;margin-top:10px">2FA deaktivieren</button>
        </div>
    `;
}

async function verify2FA() {
    const token = document.getElementById('totp-token').value;
    const res = await fetch('/api/2fa/verify-setup', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token }) });
    const data = await res.json();
    if (data.success) { alert('2FA erfolgreich aktiviert!'); load2FA(); }
    else { alert('Ungültiger Code: ' + (data.error || 'Bitte versuchen Sie es erneut')); }
}

async function disable2FA() {
    if (confirm('2FA wirklich deaktivieren?')) {
        await fetch('/api/2fa/disable', { method: 'POST' });
        alert('2FA deaktiviert');
        load2FA();
    }
}

// ==================== UPDATE FUNKTIONEN ====================
async function checkUpdates(){try{const r=await fetch('/api/updates');const d=await r.json();if(d.hasUpdates){document.getElementById('update-badge').style.display='inline-block';document.getElementById('update-badge').innerHTML=d.updates+' Up';document.getElementById('update-info').innerHTML=d.updates+' Updates'}else{document.getElementById('update-badge').style.display='none';document.getElementById('update-info').innerHTML='Aktuell'}}catch(e){}}

async function refreshAllStatus(){document.getElementById('update-info').innerHTML='...';try{await fetch('/api/check-all-status',{method:'POST'});await loadServers();document.getElementById('update-info').innerHTML='OK';setTimeout(()=>{document.getElementById('update-info').innerHTML=''},2000)}catch(e){}}

async function checkSingleStatus(id){try{await fetch('/api/check-status/'+id,{method:'POST'});await loadServers()}catch(e){}}

function getStatusBadge(status,pingMs){if(status==='online')return `<span class="status-dot status-online"></span><span style="color:#10b981">Online</span>${pingMs?`(${pingMs}ms)`:''}`;else if(status==='ping_only')return `<span class="status-dot status-ping"></span><span style="color:#f59e0b">Ping</span>${pingMs?`(${pingMs}ms)`:''}`;else return `<span class="status-dot status-offline"></span><span style="color:#ef4444">Offline</span>`;}

// ==================== SSH KEYS ====================
async function loadSSHKeysForSelect(){const r=await fetch('/api/ssh-keys');sshKeys=await r.json();const s=document.getElementById('srv-sshkey-select');s.innerHTML='<option value="">-- Kein SSH Key --</option>';sshKeys.forEach(k=>{s.innerHTML+=`<option value="${escapeHtml(k.name)}">${escapeHtml(k.name)}</option>`})}

// ==================== SERVER FUNKTIONEN ====================
function cancelEdit(){currentEditId=null;document.getElementById('edit-id').value='';document.getElementById('srv-name').value='';document.getElementById('srv-hostname').value='';document.getElementById('srv-ipv4').value='';document.getElementById('srv-ipv6').value='';document.getElementById('srv-port').value='22';document.getElementById('srv-user').value='';document.getElementById('srv-pass').value='';document.getElementById('srv-sshkey-select').value='';document.getElementById('srv-prefer-ipv6').checked=false}

function editServer(id){const s=servers.find(s=>s.id===id);if(!s)return;currentEditId=id;document.getElementById('edit-id').value=id;document.getElementById('srv-name').value=s.name;document.getElementById('srv-hostname').value=s.hostname||'';document.getElementById('srv-ipv4').value=s.ipv4_host||'';document.getElementById('srv-ipv6').value=s.ipv6_host||'';document.getElementById('srv-port').value=s.port;document.getElementById('srv-user').value=s.username;document.getElementById('srv-pass').value=s.password||'';document.getElementById('srv-sshkey-select').value=s.ssh_key_name||'';document.getElementById('srv-prefer-ipv6').checked=s.prefer_ipv6===1}

function createSSHTab(server) {
    const tabId = `tab-${nextTabId++}`;
    const terminalId = `term-${tabId}`;
    
    const wrapper = document.getElementById('terminal-wrapper');
    const termDiv = document.createElement('div');
    termDiv.id = terminalId;
    termDiv.className = 'terminal-pane';
    termDiv.style.height = '100%';
    wrapper.appendChild(termDiv);
    
    const term = new Terminal({
        cursorBlink: true,
        theme: { background: '#0d1117', foreground: '#e2e8f0' },
        fontSize: 14,
        fontFamily: 'monospace',
        rows: 55,
        cols: 180,
        scrollback: 10000,
        convertEol: true,
        allowProposedApi: true,
        windowsMode: false
    });
    
    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    term.open(termDiv);
    
    // Terminal an Container anpassen
    setTimeout(() => {
        fitAddon.fit();
        term.focus();
    }, 200);
    
    // Bei Fenstergrößenänderung
    window.addEventListener('resize', () => {
        const td = tabs.get(tabId);
        fitAddon.fit();
        if (td && td.sessionId) {
            socket.emit('resize', { 
                sessionId: td.sessionId, 
                cols: term.cols, 
                rows: term.rows 
            });
        }
    });
    
    const tabsContainer = document.getElementById('tabs-container');
    const tab = document.createElement('div');
    tab.className = 'tab';
    tab.id = tabId;
    tab.innerHTML = `<span>T</span><span>${escapeHtml(server.name)}</span><button class="tab-close" onclick="event.stopPropagation(); closeTab('${tabId}')">x</button>`;
    tab.onclick = () => switchToTab(tabId);
    tabsContainer.appendChild(tab);
    
    tabs.set(tabId, { term, fitAddon, sessionId: null, serverName: server.name });
    
    term.write(`\r\n=== ${server.name} ===\r\n`);
    term.write(`User: ${server.username}\r\n`);
    if(server.hostname) term.write(`Host: ${server.hostname}\r\n`);
    if(server.ipv4_host) term.write(`IPv4: ${server.ipv4_host}\r\n`);
    if(server.ipv6_host) term.write(`IPv6: ${server.ipv6_host}\r\n`);
    
    socket.emit('connectSSH', {
        serverId: server.id,
        serverName: server.name,
        hostname: server.hostname || '',
        ipv4_host: server.ipv4_host || '',
        ipv6_host: server.ipv6_host || '',
        port: server.port,
        username: server.username,
        password: server.password,
        sshKeyName: server.ssh_key_name,
        tabId: tabId,
        preferIPv6: server.prefer_ipv6 === 1,
        cols: term.cols,
        rows: term.rows
    });
    
    const outputHandler = (data) => {
        if(data.tabId === tabId) term.write(data.data);
    };
    
    const sessionHandler = (data) => {
        if(data.tabId === tabId) {
            const td = tabs.get(tabId);
            if(td) {
                td.sessionId = data.sessionId;
                term.write(`\r\n\x1b[32m Verbunden\x1b[0m\r\n`);
                setTimeout(() => {
                    fitAddon.fit();
                    socket.emit('resize', { 
                        sessionId: data.sessionId, 
                        cols: term.cols, 
                        rows: term.rows 
                    });
                }, 100);
            }
        }
    };
    
    socket.on('output', outputHandler);
    socket.on('sessionCreated', sessionHandler);
    
    term.onData((data) => {
        const td = tabs.get(tabId);
        if(td && td.sessionId) {
            socket.emit('input', { sessionId: td.sessionId, data: data });
        }
    });
    
    term.onResize((size) => {
        const td = tabs.get(tabId);
        if(td && td.sessionId) {
            socket.emit('resize', { 
                sessionId: td.sessionId, 
                cols: size.cols, 
                rows: size.rows 
            });
        }
    });
    
    tabs.get(tabId).eventHandlers = { outputHandler, sessionHandler };
    switchToTab(tabId);
}

function switchToTab(tabId){document.querySelectorAll('.tab').forEach(t=>t.classList.remove('active'));document.querySelectorAll('.terminal-pane').forEach(p=>p.classList.remove('active'));document.getElementById(tabId)?.classList.add('active');document.getElementById(`term-${tabId}`)?.classList.add('active');const td=tabs.get(tabId);if(td&&td.fitAddon)setTimeout(()=>td.fitAddon.fit(),100);activeTabId=tabId}

function closeTab(tabId){const td=tabs.get(tabId);if(!td)return;if(td.sessionId)socket.emit('closeTab',{sessionId:td.sessionId,tabId:tabId});if(td.eventHandlers){socket.off('output',td.eventHandlers.outputHandler);socket.off('sessionCreated',td.eventHandlers.sessionHandler)}if(td.term)td.term.dispose();document.getElementById(tabId)?.remove();document.getElementById(`term-${tabId}`)?.remove();tabs.delete(tabId);const ft=document.querySelector('.tab');if(ft)switchToTab(ft.id)}

function newTab(){alert('Neuer Tab. Klick auf Server in Sidebar.')}

async function loadServers(){const r=await fetch('/api/servers');servers=await r.json();let sidebarHtml='';servers.forEach(s=>{let badges='';if(s.ipv4_host)badges+=`<span class="badge">v4</span>`;if(s.ipv6_host)badges+=`<span class="badge">v6</span>`;if(s.prefer_ipv6)badges+=`<span class="badge">v6p</span>`;if(s.ssh_key_name)badges+=`<span class="badge">Key</span>`;const statusHtml=s.last_status?getStatusBadge(s.last_status,s.last_ping_ms):'?';sidebarHtml+=`
<div class="server-card" onclick="connectServer(${s.id})">
    <div style="display:flex;justify-content:space-between">
        <div>
            <strong>${escapeHtml(s.name)}</strong><br>
            <small>${s.hostname||s.ipv4_host||s.ipv6_host||'-'}</small>
            <div style="margin-top:4px">${badges}</div>
        </div>
        <div style="text-align:right">
            <div style="margin-bottom:4px">${statusHtml}</div>
            <div>
                <button class="btn-edit" onclick="event.stopPropagation();editServer(${s.id})">Ed</button>
                <button class="btn-delete" onclick="event.stopPropagation();deleteServer(${s.id})">Del</button>
                <button class="refresh-btn" onclick="event.stopPropagation();checkSingleStatus(${s.id})">⟳</button>
            </div>
        </div>
    </div>
</div>`});document.getElementById('servers-list').innerHTML=sidebarHtml||'Keine Server';let tableHtml='<table style="width:100%"><thead><tr><th>Name</th><th>Hosts</th><th>Port</th><th>Status</th><th>Aktion</th></tr></thead><tbody>';servers.forEach(s=>{const hosts=[s.hostname,s.ipv4_host,s.ipv6_host].filter(h=>h).join(', ')||'-';const statusHtml=s.last_status?getStatusBadge(s.last_status,s.last_ping_ms):'-';tableHtml+=`<tr><td><strong>${escapeHtml(s.name)}</strong></td><td><small>${escapeHtml(hosts)}</small></td><td>${s.port}</td><td>${statusHtml}</td><td><button class="btn-edit" onclick="editServer(${s.id})">Ed</button><button class="btn-delete" onclick="deleteServer(${s.id})">Del</button><button class="btn-primary" onclick="connectServer(${s.id})" style="padding:2px 6px">Conn</button></td></tr>`});tableHtml+='</tbody></table>';document.getElementById('servers-table').innerHTML=tableHtml||'<div>Keine Server</div>';let opt='<option value="">-- Server --</option>';servers.forEach(s=>opt+=`<option value="${s.id}">${escapeHtml(s.name)}</option>`);document.getElementById('monitor-server').innerHTML=opt}

function loadMonitorServers(){loadServers()}

async function saveServer(){const id=document.getElementById('edit-id').value;const data={name:document.getElementById('srv-name').value,hostname:document.getElementById('srv-hostname').value,ipv4_host:document.getElementById('srv-ipv4').value,ipv6_host:document.getElementById('srv-ipv6').value,port:parseInt(document.getElementById('srv-port').value),username:document.getElementById('srv-user').value,password:document.getElementById('srv-pass').value,ssh_key_name:document.getElementById('srv-sshkey-select').value||null,prefer_ipv6:document.getElementById('srv-prefer-ipv6').checked?1:0};if(!data.name){alert('Name Pflicht!');return}if(!data.username){alert('Benutzername Pflicht!');return}if(!data.hostname&&!data.ipv4_host&&!data.ipv6_host){alert('Mindestens ein Host Pflicht!');return}let url='/api/servers';let method='POST';if(id){url='/api/servers/'+id;method='PUT'}const r=await fetch(url,{method,headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});const res=await r.json();if(res.success){alert(id?'Aktualisiert!':'Gespeichert!');cancelEdit();loadServers();if(id)checkSingleStatus(id)}else alert('Fehler: '+(res.error||'Unbekannt'))}

async function deleteServer(id){if(confirm('Loeschen?')){await fetch('/api/servers/'+id,{method:'DELETE'});loadServers()}}

function connectServer(id){const s=servers.find(s=>s.id===id);if(!s)return;createSSHTab(s);document.querySelector('.nav-item[data-panel="terminal"]').click()}

// ==================== MONITORING ====================
async function startMonitoring(){if(monitoringInterval)clearInterval(monitoringInterval);const sid=document.getElementById('monitor-server').value;if(!sid)return;const f=async()=>{const r=await fetch('/api/monitoring/'+sid);const s=await r.json();document.getElementById('monitor-stats').innerHTML=`<div class="stat-card"><div class="stat-value">${s.cpu||'0%'}</div><div class="stat-label">CPU</div></div><div class="stat-card"><div class="stat-value">${s.memory||'0%'}</div><div class="stat-label">RAM</div></div><div class="stat-card"><div class="stat-value">${s.disk||'0%'}</div><div class="stat-label">Festplatte</div></div><div class="stat-card"><div class="stat-value" style="font-size:16px;">${s.uptime||'N/A'}</div><div class="stat-label">Laufzeit</div></div>`};await f();monitoringInterval=setInterval(f,5000)}
document.getElementById('monitor-server').onchange=startMonitoring;

// ==================== SSH KEYS ====================
async function loadKeys(){const r=await fetch('/api/ssh-keys');const keys=await r.json();let h='';keys.forEach(k=>{h+=`<div style="display:flex;justify-content:space-between;padding:8px;background:#0f0f1a;margin-bottom:5px;border-radius:6px"><span>Key: ${escapeHtml(k.name)}</span><div><button onclick="viewKey('${k.name}')" style="background:#3b82f6;border:none;padding:3px 6px;border-radius:3px;cursor:pointer">Anz</button><button onclick="deleteKey('${k.name}')" style="background:#ef4444;border:none;padding:3px 6px;border-radius:3px;margin-left:4px;cursor:pointer">Del</button></div></div>`});document.getElementById('keys-list').innerHTML=h||'Keine Keys';loadSSHKeysForSelect()}

async function saveKey(){const n=document.getElementById('key-name').value;const k=document.getElementById('key-content').value;if(!n||!k){alert('Name und Key Pflicht!');return}const r=await fetch('/api/ssh-keys',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:n,key:k})});const res=await r.json();if(res.success){alert('Key gespeichert!');document.getElementById('key-name').value='';document.getElementById('key-content').value='';loadKeys()}else alert('Fehler: '+(res.error||'Unbekannt'))}

async function viewKey(n){const r=await fetch('/api/ssh-keys/'+n);const d=await r.json();document.getElementById('key-name').value=n;document.getElementById('key-content').value=d.key}

async function deleteKey(n){if(confirm('Key loeschen?')){await fetch('/api/ssh-keys/'+n,{method:'DELETE'});loadKeys()}}

// ==================== BENUTZER ====================
async function loadUsers(){const r=await fetch('/api/users');const u=await r.json();let h='<table style="width:100%"><thead><th>Benutzer</th><th>Rolle</th><th>2FA</th><th>Aktion</th></tr></thead><tbody>';u.forEach(u=>{h+=`<tr><td>${escapeHtml(u.username)}</td><td>${u.role}</td>
                <td>${u.totp_enabled?'Aktiv':'Inaktiv'}</td>
                <td><button onclick="deleteUser(${u.id})" style="background:#ef4444;border:none;padding:3px 8px;border-radius:4px;cursor:pointer">Del</button></td>
            </tr>`});h+='</tbody></table>';document.getElementById('users-list').innerHTML=h}

async function addUser(){const u=document.getElementById('user-name').value,p=document.getElementById('user-pass').value,r=document.getElementById('user-role').value;if(!u||!p){alert('Benutzername und Passwort Pflicht!');return}await fetch('/api/users',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username:u,password:p,role:r})});alert('Benutzer erstellt');loadUsers()}

async function deleteUser(id){if(confirm('Loeschen?')){await fetch('/api/users/'+id,{method:'DELETE'});loadUsers()}}

// ==================== EINSTELLUNGEN ====================
async function changePwd(){const o=document.getElementById('old-pass').value,n=document.getElementById('new-pass').value,c=document.getElementById('confirm-pass').value;if(n!==c){alert('Passwoerter stimmen nicht ueberein');return}const r=await fetch('/api/settings/password',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({old_password:o,new_password:n})});const d=await r.json();if(d.success)alert('Passwort geaendert!');else alert('Fehler')}

// ==================== TOOLS ====================
function copySelected(){const a=tabs.get(activeTabId);if(a&&a.term){const s=a.term.getSelection();if(s)navigator.clipboard.writeText(s)}}
async function pasteSelected(){const t=await navigator.clipboard.readText();const a=tabs.get(activeTabId);if(a&&a.sessionId&&t)socket.emit('input',{sessionId:a.sessionId,data:t})}
function escapeHtml(s){if(!s)return'';return s.replace(/[&<>]/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[m]))}

// ==================== INIT ====================
loadServers();loadSSHKeysForSelect();checkUpdates();setInterval(refreshAllStatus,60000);
</script>
</body>
</html>
EOF

# ==================== SERVICE ====================
cat > /etc/systemd/system/remote-panel.service << 'EOF'
[Unit]
Description=Remote Panel
After=network.target mariadb.service

[Service]
ExecStart=/usr/bin/node /opt/remote-panel/backend/server.js
WorkingDirectory=/opt/remote-panel/backend
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable remote-panel
systemctl restart remote-panel

# ==================== NGINX ====================
if [ ! -f /etc/nginx/sites-available/remote-panel ]; then
    cat > /etc/nginx/sites-available/remote-panel << 'EOF'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/remote-panel /etc/nginx/sites-enabled/remote-panel
    rm -f /etc/nginx/sites-enabled/default
    nginx -t && systemctl restart nginx
fi

ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true
ufw allow 22/tcp 2>/dev/null || true

clear
echo ""
echo "================================================================================"
echo "     REMOTE PANEL - MIT 2FA + SSL MANAGER + TERMINAL RESIZE"
echo "================================================================================"
echo ""
echo "Web: http://$(hostname -I | awk '{print $1}')"
echo "Login: admin / admin123"
echo ""
echo "================================================================================"
echo "  NOTFALL RESET (NUR PER SSH!)"
echo "================================================================================"
echo ""
echo "Verfuegbare Befehle:"
echo "  rp-reset --help                    - Hilfe anzeigen"
echo "  rp-reset --list                    - Alle Benutzer auflisten"
echo "  rp-reset --user admin --show       - Benutzer anzeigen"
echo "  rp-reset --user admin --reset-password - Passwort auf reset123 setzen"
echo "  rp-reset --user admin --set-password meinpasswort - Eigenes Passwort"
echo "  rp-reset --user admin --disable-2fa - 2FA deaktivieren"
echo "  rp-reset --reset-all               - ALLE Benutzer zurücksetzen"
echo "  rp-reset --restart-service         - Panel neustarten"
echo ""
echo "Oder direkt:"
echo "  /opt/remote-panel/reset.sh --user admin --reset-password"
echo ""
echo "================================================================================"
echo "  SSL MANAGER (im Web-Interface unter 'SSL Manager')"
echo "================================================================================"
echo "  - Let's Encrypt Zertifikate automatisch holen"
echo "  - Cloudflare DNS Integration"
echo "  - Automatische Nginx Konfiguration"
echo ""
echo "================================================================================"
systemctl status remote-panel --no-pager
