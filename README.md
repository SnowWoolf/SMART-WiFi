# SMART-WiFi

### Поддерживаемые чипсеты
```
RTL8811CU (Gembird WNP-UA-008)
RTL8192EU (Mercusys MW300UH)
MT7601 (Gembird WNP-UA-011)
```
### Установка
```
curl -fsSL https://raw.githubusercontent.com/SnowWoolf/SMART-WiFi/main/install.sh | bash
```
#### Скрипт автоматически:

- скачает конфиг wifi.conf
- установит драйверы Wi-Fi
- обновит зависимости модулей
- включит питание USB
- попытается загрузить драйверы
- создаст и включит сервис smart-wifi.service

### После установки
Проверка:

```
systemctl status smart-wifi.service --no-pager
ip a
iw dev
```

Логи:
```
journalctl -u smart-wifi.service -n 100 --no-pager
```

# Настройка

Основной конфиг лежит тут:
`/etc/smart-wifi/wifi.conf`

Перезапуск сервиса:
`systemctl restart smart-wifi.service`

---

### 1. Только установка драйверов

```
curl -fsSL https://raw.githubusercontent.com/SnowWoolf/SMART-WiFi/main/install-drivers.sh | bash
```

### 2. Только настройка адаптера

Подключить адаптер к USB и выполнить:
```
curl -fsSL https://raw.githubusercontent.com/SnowWoolf/SMART-WiFi/main/setup-wifi.sh | bash
```

---