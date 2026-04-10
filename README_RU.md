<div align="center">

# 🦀 Rust Wipe Manager

### Готовый к продакшену набор автоматизации для Rust-серверов на LinuxGSM

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?style=flat&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![systemd](https://img.shields.io/badge/systemd-000000?style=flat&logo=linux&logoColor=white)](https://systemd.io/)
[![LinuxGSM](https://img.shields.io/badge/LinuxGSM-0066CC?style=flat&logo=linux&logoColor=white)](https://linuxgsm.com/)
[![Telegram](https://img.shields.io/badge/Telegram-26A5E4?style=flat&logo=telegram&logoColor=white)](https://telegram.org/)
[![Rust Game](https://img.shields.io/badge/Rust-CD412B?style=flat&logo=rust&logoColor=white)](https://rust.facepunch.com/)

**Ежедневные рестарты • Умный Full Wipe • Детектор обновлений • Telegram-алерты • Самовосстановление**

[🇬🇧 English](README.md) • [Возможности](#-возможности) • [Как работает](#-как-это-работает) • [Установка](#-установка) • [Конфигурация](#%EF%B8%8F-конфигурация) • [Решение проблем](#-решение-проблем)

</div>

---

## 📖 Обзор

**Rust Wipe Manager** — это полный набор автоматизации для серверов [Rust](https://rust.facepunch.com/), работающих на [LinuxGSM](https://linuxgsm.com/). Он берёт на себя всю рутину администрирования Rust-сервера: ежедневные рестарты, ежемесячные Full Wipe, синхронизированные с циклом обновлений Facepunch, восстановление после крашей, обновления ОС и подробные Telegram-уведомления на каждом шаге.

Тулкит написан и проверен в боевых условиях на реальном production-сервере (`bzod.ru`), работающем на **Ubuntu 24.04 LTS** + **Proxmox VM** + **LinuxGSM** + **uMod (Oxide)**.

## ✨ Возможности

### 🔄 Умные ежедневные рестарты
- Предупреждение игроков через RCON с обратным отсчётом (по умолчанию 30 минут)
- Корректное завершение работы с фолбэком на `systemctl stop` если процесс завис
- Автоматическое обновление Rust + Oxide во время рестарта
- Сам пропускает себя в день Full Wipe, чтобы избежать конфликта

### 🔥 Автоматический Full Wipe в первый четверг каждого месяца
- Синхронизируется с официальным расписанием патчей Facepunch (19:00 по Лондону)
- **Ждёт реального появления апдейта в Steam** перед вайпом (риск вайпа на старой версии исключён)
- Опрашивает Steam каждые 2 минуты, до 2 часов
- Прерывает вайп с критическим Telegram-алертом, если апдейт не вышел вовремя
- Бэкапит директорию Oxide `Managed/` перед обновлением

### 🛡️ Интеграция с systemd
- Автозапуск при загрузке машины
- Автоперезапуск при краше (через LGSM monitor)
- Логи доступны через `journalctl -u rustserver`
- Чистый интерфейс `start`/`stop`/`restart`

### 📱 Telegram-уведомления на каждом шаге
- Старт рестарта / RCON отправлен / сервер остановлен / обновления готовы / сервер поднят
- Три уровня логирования: `full` / `success_error` / `error_only`
- Критические алерты при сбоях (таймаут, ошибка обновления, сервер не запустился)

### 🔐 Безопасность
- Все секреты хранятся в отдельном файле `.secrets.env` с правами `chmod 600`
- Sudo ограничен только командами `systemctl` для конкретного сервиса
- Никаких credentials в основном скрипте — безопасно публиковать

## 🏗️ Архитектура

```mermaid
graph TB
    subgraph "🖥️ Хост Proxmox"
        subgraph "🐧 Виртуалка Ubuntu"
            CRON[⏰ cron]
            SYSTEMD[⚙️ systemd]
            MANAGER[📜 manager.sh]
            LGSM[🎮 LinuxGSM]
            RUST[🦀 RustDedicated]
            OXIDE[🔧 Oxide/uMod]
        end
    end

    TG[📱 Telegram Bot API]
    STEAM[☁️ Steam / Facepunch]
    PLAYERS[👥 Игроки]

    CRON -->|"04:30 ежедневно"| MANAGER
    CRON -->|"19:00 четверги"| MANAGER
    SYSTEMD -->|"при загрузке/краше"| LGSM
    MANAGER -->|"start/stop"| SYSTEMD
    MANAGER -->|"RCON команды"| RUST
    MANAGER -->|"check-update"| LGSM
    MANAGER -->|"алерты"| TG
    LGSM -->|"скачивание апдейтов"| STEAM
    LGSM -->|"управление"| RUST
    RUST -->|"хостит"| OXIDE
    PLAYERS -.->|"подключение"| RUST

    style MANAGER fill:#CD412B,color:#fff
    style RUST fill:#CD412B,color:#fff
    style TG fill:#26A5E4,color:#fff
    style SYSTEMD fill:#000,color:#fff
```

## 🎯 Как это работает

### Сценарий ежедневного рестарта

```mermaid
sequenceDiagram
    participant C as ⏰ cron (04:30 МСК)
    participant M as 📜 manager.sh
    participant R as 🦀 Rust сервер
    participant S as ⚙️ systemd
    participant T as 📱 Telegram

    C->>M: запуск режима "restart"
    M->>M: Сегодня первый четверг?
    alt Да (день Full Wipe)
        M->>T: "Пропускаю ежедневный рестарт"
        M-->>C: exit 0
    else Нет (обычный день)
        M->>T: "Начало ежедневного рестарта"
        M->>R: RCON "restart 1800 server_restart"
        Note over R: Игроки видят отсчёт<br/>30 минут
        R->>R: Игроки предупреждены, отсчёт
        M->>M: sleep 1800 сек
        R->>S: сервер остановлен
        M->>T: "Сервер остановлен"
        M->>M: ./rustserver update
        M->>M: ./rustserver mods-update
        M->>T: "Обновления готовы"
        M->>S: systemctl start rustserver
        S->>R: запуск сервера
        M->>M: проверка процесса RustDedicated
        M->>T: "✅ Рестарт завершён"
    end
```

### Сценарий Full Wipe

```mermaid
sequenceDiagram
    participant C as ⏰ cron (четв. 19:00)
    participant M as 📜 manager.sh
    participant FP as ☁️ Facepunch/Steam
    participant R as 🦀 Rust сервер
    participant T as 📱 Telegram

    C->>M: запуск режима "fullwipe"
    M->>M: Сегодня первый четверг?
    alt Нет
        M-->>C: exit 0
    else Да
        M->>M: Считаем 19:00 по Лондону<br/>(BST/GMT автоматически)
        M->>M: спим до момента T-30мин
        M->>T: "🔥 Подготовка к Full Wipe"
        M->>R: RCON "restart 600 FULL_WIPE_UPDATE"
        Note over R: Отсчёт 10 минут
        M->>M: sleep 600 сек
        R->>R: сервер остановлен

        loop Каждые 2 минуты (макс 2ч)
            M->>FP: check-update (сравнение builds)
            alt Апдейт доступен
                M->>T: "🎉 Апдейт обнаружен!"
            else Апдейта пока нет
                M->>M: sleep 120 сек
            end
        end

        alt Таймаут (нет апдейта 2 часа)
            M->>T: "🚨 ТАЙМАУТ! Нужно ручное вмешательство"
            M-->>C: exit 1
        else Апдейт найден
            M->>M: бэкап Oxide Managed/
            M->>FP: ./rustserver update
            M->>FP: ./rustserver mods-update
            M->>R: ./rustserver full-wipe
            Note over R: Карта + blueprints<br/>сброшены
            M->>R: systemctl start rustserver
            M->>T: "🎉 Новый вайп запущен!"
        end
    end
```

## 🛠️ Технологии

| Компонент | Назначение |
|---|---|
| ![Bash](https://img.shields.io/badge/-Bash-4EAA25?logo=gnubash&logoColor=white) | Основной язык скриптов |
| ![Ubuntu](https://img.shields.io/badge/-Ubuntu_24.04-E95420?logo=ubuntu&logoColor=white) | Хостовая ОС |
| ![systemd](https://img.shields.io/badge/-systemd-000000?logo=linux&logoColor=white) | Управление сервисами и автозапуск |
| ![LinuxGSM](https://img.shields.io/badge/-LinuxGSM-0066CC?logo=linux&logoColor=white) | Обёртка для игрового сервера |
| ![Rust](https://img.shields.io/badge/-Rust_Game-CD412B?logo=rust&logoColor=white) | Сама игра |
| ![Oxide](https://img.shields.io/badge/-uMod/Oxide-7B68EE) | Фреймворк плагинов |
| ![cron](https://img.shields.io/badge/-cron-008000) | Планировщик задач |
| ![rcon-cli](https://img.shields.io/badge/-rcon--cli-FF6B6B) | RCON-клиент |
| ![Telegram](https://img.shields.io/badge/-Telegram_Bot_API-26A5E4?logo=telegram&logoColor=white) | Уведомления |

## 📋 Требования

- **ОС**: Ubuntu 24.04 LTS (или любой современный Debian-based дистрибутив с systemd)
- **LinuxGSM** установлен и `rustserver` настроен в `~/rustserver`
- **Rust dedicated server** работает через LGSM
- **systemd** (есть во всех современных дистрибутивах)
- **rcon-cli** от gorcon: [github.com/gorcon/rcon-cli](https://github.com/gorcon/rcon-cli)
- **Telegram-бот** (опционально, но рекомендуется) — токен у [@BotFather](https://t.me/BotFather)
- **sudo** права для пользователя сервера (ограниченные `systemctl`)

## 🚀 Установка

### 1️⃣ Установить LinuxGSM и Rust-сервер

```bash
curl -Lo linuxgsm.sh https://linuxgsm.sh && chmod +x linuxgsm.sh && bash linuxgsm.sh rustserver
./rustserver auto-install
```

### 2️⃣ Установить rcon-cli

```bash
cd ~
wget https://github.com/gorcon/rcon-cli/releases/download/v0.10.3/rcon-0.10.3-amd64_linux.tar.gz
tar -xzf rcon-0.10.3-amd64_linux.tar.gz
rm rcon-0.10.3-amd64_linux.tar.gz
```

### 3️⃣ Настроить systemd-сервис

Создать `/etc/systemd/system/rustserver.service`:

```ini
[Unit]
Description=Rust Server (LinuxGSM)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=YOUR_USERNAME
Group=YOUR_USERNAME
WorkingDirectory=/home/YOUR_USERNAME
ExecStart=/home/YOUR_USERNAME/rustserver start
ExecStop=/home/YOUR_USERNAME/rustserver stop
TimeoutStartSec=600
TimeoutStopSec=300

[Install]
WantedBy=multi-user.target
```

Включить и запустить:
```bash
sudo systemctl daemon-reload
sudo systemctl enable rustserver
sudo systemctl start rustserver
```

> ⚠️ **Почему `Type=oneshot`, а не `Type=forking`?** LinuxGSM использует tmux внутри и отделяет процесс. С `Type=forking` systemd теряет связь с реальным процессом сервера. `Type=oneshot` + `RemainAfterExit=yes` — самое чистое решение, которое надёжно работает с LGSM.

### 4️⃣ Настроить sudoers (sudo без пароля)

```bash
echo 'YOUR_USERNAME ALL=(root) NOPASSWD: /usr/bin/systemctl start rustserver, /usr/bin/systemctl stop rustserver, /usr/bin/systemctl restart rustserver' | sudo tee /etc/sudoers.d/YOUR_USERNAME-rustserver
sudo chmod 440 /etc/sudoers.d/YOUR_USERNAME-rustserver
```

### 5️⃣ Скачать репозиторий

```bash
mkdir -p ~/rust_server
cd ~/rust_server
wget https://raw.githubusercontent.com/wobujidao/rust-wipe-manager/main/manager.sh
wget https://raw.githubusercontent.com/wobujidao/rust-wipe-manager/main/config.env.example -O config.env
wget https://raw.githubusercontent.com/wobujidao/rust-wipe-manager/main/secrets.env.example -O .secrets.env
chmod +x manager.sh
chmod 600 .secrets.env
```

### 6️⃣ Настроить секреты и конфиг

Отредактировать `.secrets.env` реальными значениями:
```bash
nano ~/rust_server/.secrets.env
```

```env
TELEGRAM_BOT_TOKEN="123456789:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
TELEGRAM_CHAT_ID="-1001234567890"
RCON_PASS="ваш_rcon_пароль"
```

Отредактировать `config.env` под свои пути и предпочтения:
```bash
nano ~/rust_server/config.env
```

### 7️⃣ Протестировать

```bash
~/rust_server/manager.sh test-telegram
~/rust_server/manager.sh check-update
```

Должно прийти сообщение в Telegram и вывестись информация о версиях из Steam.

### 8️⃣ Добавить задачи в cron

```bash
crontab -e
```

Добавить:
```cron
30 4 * * * /home/YOUR_USERNAME/rust_server/manager.sh restart
0 19 * * 4 /home/YOUR_USERNAME/rust_server/manager.sh fullwipe
```

> 💡 Задача Full Wipe запускается **каждый четверг** в 19:00, но скрипт сам проверяет, является ли сегодня первым четвергом месяца, и в обычные четверги сразу выходит.

## ⚙️ Конфигурация

Все настройки находятся в `config.env`. Самые важные:

| Параметр | По умолчанию | Описание |
|---|---|---|
| `DAILY_RESTART_COUNTDOWN` | `1800` | Отсчёт перед ежедневным рестартом (секунд) |
| `DAILY_RESTART_UPDATE_RUST` | `true` | Обновлять Rust при ежедневном рестарте |
| `DAILY_RESTART_UPDATE_OXIDE` | `true` | Обновлять Oxide при ежедневном рестарте |
| `FULLWIPE_COUNTDOWN` | `600` | Отсчёт перед остановкой при Full Wipe (секунд) |
| `FULLWIPE_LONDON_HOUR` | `19` | Час по Лондону, когда Facepunch выпускает апдейты |
| `FULLWIPE_PRE_WAIT_MINUTES` | `30` | За сколько минут до апдейта начать подготовку |
| `FULLWIPE_UPDATE_WAIT_MAX` | `7200` | Макс. время ожидания апдейта Steam (секунд) |
| `FULLWIPE_UPDATE_CHECK_INTERVAL` | `120` | Проверять Steam каждые N секунд |
| `SKIP_DAILY_RESTART_ON_FULLWIPE_DAY` | `true` | Пропускать ежедневный рестарт в день Full Wipe |
| `OXIDE_BACKUP_BEFORE_UPDATE` | `true` | Бэкапить `Managed/` перед обновлением Oxide |
| `SERVER_START_TIMEOUT` | `600` | Макс. время ожидания процесса RustDedicated |
| `ENABLE_TELEGRAM` | `true` | Включить Telegram-уведомления |
| `TELEGRAM_LOG_LEVEL` | `full` | `full` / `success_error` / `error_only` |

## 🎮 Команды

```bash
# Ежедневный рестарт (с авто-пропуском в день Full Wipe)
./manager.sh restart

# Full Wipe (запустится только если сегодня первый четверг)
./manager.sh fullwipe

# Ручной Full Wipe — пропускает проверку даты (ОСТОРОЖНО)
./manager.sh fullwipe-now

# Тест Telegram-уведомлений
./manager.sh test-telegram

# Проверить наличие апдейта Rust в Steam
./manager.sh check-update
```

## 📁 Структура проекта

```
rust_server/
├── manager.sh           # Главный скрипт
├── config.env           # Конфигурация (пути, тайминги, флаги)
├── .secrets.env         # Telegram токен, RCON пароль (chmod 600)
└── logs/
    └── manager-YYYYMMDD.log
```

## 🔧 Решение проблем

### Сервер не поднимается автоматически после ребута
Проверь systemd-юнит:
```bash
sudo systemctl status rustserver
sudo systemctl is-enabled rustserver
journalctl -u rustserver -n 50
```
Убедись, что он `enabled` и используется `Type=oneshot` (а не `forking`).

### `sudo: a password is required` из cron
Правило `sudoers.d/` не применилось корректно. Проверь:
```bash
sudo -n systemctl status rustserver
```
Должно показать статус без запроса пароля.

### Full Wipe запустился, но сервер на старой версии
Цикл `wait_for_rust_update` должен это предотвратить. Если всё-таки случилось:
1. Посмотри `~/rust_server/logs/manager-*.log` на этапе ожидания
2. Проверь вручную, что `check-update` корректно возвращает номера build
3. Увеличь `FULLWIPE_UPDATE_WAIT_MAX`, если Facepunch особо опаздывает

### Oxide не загружается после Full Wipe
Релизы Oxide иногда задерживаются на 30-90 минут после релизов Rust. Если `mods-update` отработал слишком рано — может быть скачана несовместимая версия. Решения:
- Подожди 30 минут и запусти `~/rustserver mods-update` вручную, потом перезапусти сервер
- Восстанови из автобэкапа: `~/serverfiles/RustDedicated_Data/Managed.backup-YYYY-MM-DD/`

### Сообщения Telegram не приходят
```bash
~/rust_server/manager.sh test-telegram
```
Если ничего не приходит, проверь:
- Корректный токен бота в `.secrets.env`
- Корректный chat ID (отрицательный для групп, положительный для личных чатов)
- Бот добавлен в группу/канал
- `curl https://api.telegram.org/botYOUR_TOKEN/getMe` возвращает `"ok":true`

## 🗺️ Планы развития

- [ ] Поддержка Discord webhook (вместе с Telegram)
- [ ] Веб-дашборд для просмотра логов
- [ ] Автоматическая ротация сидов карт
- [ ] Интеграция с `BattleMetrics` API для алертов по онлайну
- [ ] Уведомления об апдейтах популярных плагинов
- [ ] Поддержка нескольких серверов (один менеджер, много серверов)

## 🤝 Вклад в проект

PR и issue приветствуются. Этот проект сделан для реальной боевой эксплуатации, поэтому, пожалуйста, тестируй изменения на реальном LGSM Rust-сервере перед PR.

## 📜 Лицензия

MIT — делай с этим кодом что хочешь, только не вини меня, если твой сервер взорвётся.

## 🙏 Благодарности

- [LinuxGSM](https://linuxgsm.com/) — невоспетый герой хостинга игровых серверов
- [gorcon/rcon-cli](https://github.com/gorcon/rcon-cli) — чистый RCON-клиент
- [Facepunch Studios](https://facepunch.com/) — за создание Rust
- [uMod / Oxide](https://umod.org/) — за экосистему плагинов

---

<div align="center">

Если это сэкономило тебе время — поставь ⭐ репозиторию!

</div>
