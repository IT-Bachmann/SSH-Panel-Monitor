# SSH-Panel-Monitor
Panel für SSH Verbindungen 

# Remote Panel

Ein selbst gehostetes Webpanel zur zentralen Verwaltung von SSH-Servern mit Benutzerverwaltung, 2FA, SSL-Manager und Monitoring.

## Funktionen im Überblick

### SSH Terminal
- Vollwertiges Terminal im Browser (xterm.js)
- Mehrere parallele SSH Verbindungen in Tabs
- Tabs sind einzeln schließbar
- Copy & Paste Unterstützung
- Session-Trennung möglich

### Serververwaltung
- Hinzufügen, Bearbeiten und Löschen von Servern
- IPv4 und IPv6 getrennt konfigurierbar
- Fallback: Wenn IPv6 nicht erreichbar, automatisch zu IPv4
- Ping-Überwachung mit Latenzanzeige
- Online-Status Erkennung (Online, Nur Ping, Offline)

### SSH Key Verwaltung
- Speichern von SSH Private Keys
- PPK (PuTTY Private Key) Support - automatische Konvertierung
- Keys können Servern zugewiesen werden
- Keys sind editierbar und löschbar

### Benutzerverwaltung
- Mehrere Benutzer mit Rollen (Admin/User)
- Nur Admins können Benutzer erstellen/löschen
- Anzeige ob 2FA aktiviert ist

### Zwei-Faktor-Authentifizierung (2FA)
- TOTP Standard (kompatibel mit Google Authenticator, Authy, etc.)
- QR Code zum einfachen Setup
- Aktivierung/Deaktivierung pro Benutzer
- Erzwingt zweite Authentifizierungsebene

### Monitoring
- Live CPU Auslastung
- Live RAM Auslastung
- Live Festplattenbelegung
- Uptime Anzeige
- Automatische Aktualisierung alle 5 Sekunden

### SSL Manager
- Automatisches Let's Encrypt Zertifikat beziehen
- Cloudflare DNS API Integration
- Automatische Nginx Konfiguration
- Zertifikatserneuerung
- Übersicht aller vorhandenen Zertifikate

### System-Updates
- Zeigt verfügbare System-Updates an
- Benachrichtigung im Panel-Header

### Mobilfreundlich
- Responsive Design
- Automatische Sidebar auf Smartphones
- Menü-Button unten rechts auf kleinen Bildschirmen

## Installation

bash
# SH-Datei herunterladen und ausführbar machen


chmod +x install-remote-ssh-panel.sh

# Als root ausführen
sudo ./install-remote-ssh-panel.sh
