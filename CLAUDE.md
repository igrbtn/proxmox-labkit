# CLAUDE.md - ProxMoxLabKit

## Overview

Headless-сборка Windows-лаб на Proxmox VE с рабочей станции (macOS/Linux).
Цепочка: `Workstation --ssh--> Proxmox node --qm--> Windows guest`, канал внутрь
гостя - **qemu-guest-agent** (не WinRM). Установка unattended, дальше гость
доводит себя сам (scheduled task + state-машина, переживает ребуты).
Пользователь просит лабу словами - ты собираешь её из building blocks.
Скиллы: `lab-build`, `lab-ad-multisite`, `lab-s2d`, `lab-roles`.

## Quick Start (из корня репо)

```bash
cp .env.example .env      # PVE_SSH, LAB_PW - или через scripts/creds_editor.py
./lib/prepare-media.sh    # Windows ISO + virtio-win на все ноды кластера

./bin/status.sh                       # состояние VM + статус гостей
./bin/exec.sh S2D1 "Get-ClusterNode"  # PowerShell в госте через guest agent
./bin/screenshot.sh DC01              # консоль застрявшей VM (PNG на ноде)
```

## Architecture

- **lib/** - `common.sh` (.env, `ssh -n`-обёртки, подстановка `__LAB_PW__`),
  `pve.sh` (обёртки `qm`: create/destroy/start + ответ на UEFI-промпт),
  `unattend.sh` (генерация `autounattend.xml`, вырезание драйверов из
  `virtio-win.iso`, сборка unattend-ISO), `prepare-media.sh`.
- **guest/** - шаблоны bootstrap (первый DC, реплика DC, member-join) с
  плейсхолдерами; копируются в `labs/<lab>/guest/`, там заполняется CONFIG.
- **roles/** - ролевые state-машины поверх домена (AD CS, IIS, нода S2D,
  сборка кластера). Деплой только через `Install-LabGuestTask`.
- **labs/** - каталог на лабу: топология + `build.sh` + post-скрипты.

## Workflow сборки лабы

1. Спроектируй топологию (VM, нода Proxmox, IP, RAM, диски), покажи пользователю.
2. `labs/<name>/`: скопируй шаблоны guest, заполни CONFIG (IP, домен, сайт).
3. `build.sh`: `qm create` + unattend-ISO на каждую VM, старт с ответом на
   UEFI-промпт.
4. Жди `<VM>|DONE-*` через `bin/status.sh` (интервал 60-120 c).
5. Роли и кластер - после того, как все зависимости отрапортовали DONE.

## Жёсткие правила

- **Сеть гостя - `e1000`, не virtio.** WinPE инжектит из unattend-ISO только
  boot-critical драйверы, поэтому `netkvm` в систему не попадает и гость
  поднимается без сети вообще.
- **На unattend-ISO обязателен драйвер `vioserial`** (каталог
  `vioserial/<osver>/amd64`, НЕ `amd64/<osver>` - там только storage). Без него
  guest agent запускается, но канал до хоста мёртв и управление теряется.
- **После `qm start` ответь на UEFI-промпт**: `sendkey ret` через `qm monitor`
  ~12 секунд. Позже слать нельзя - установка начнётся заново.
- **`ssh -n` в любом цикле по VM**, иначе ssh съест stdin и отработает только
  первая машина.
- Задача в госте - с повторяющимся триггером (каждые 5 минут): нода, не
  дождавшаяся DC, должна получить второй шанс без ребута.
- Долгие операции - только scheduled task в госте + опрос статуса. Синхронно
  ждать в `qm guest exec` нельзя.
- Кластерные команды требуют доменных прав, а агент работает от SYSTEM -
  скрипт кластера перерегистрирует себя задачей от `DOMAIN\Administrator`.
- Скрипты - ASCII-only, комментарии на английском. Кириллица только в `.md`.
- Секреты: только токен `__LAB_PW__`; не печатай `$LAB_PW`, не проси пароль в чат.
- При любой странности - `docs/GOTCHAS.md`, потом `bin/screenshot.sh`.

## Configuration

`.env` в корне: `PVE_SSH` (точка входа в кластер), `LAB_PW`, опционально
`WIN_ISO`/`VIRTIO_ISO`. Отсутствие ключа - жёсткая ошибка с подсказкой.

## Testing

Смоук = поднявшаяся лаба: `bin/status.sh` до терминальных `DONE-*`, затем
проверки через `bin/exec.sh` (`Get-ADDomain`, `Get-ClusterS2D`, `Get-VirtualDisk`).

## Versioning

Semver здесь и в README. Текущая: **0.1.0**.
