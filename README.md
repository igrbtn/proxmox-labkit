# ProxMoxLabKit

Тулкит для headless-развёртывания **Windows-лаб на Proxmox VE** с рабочей станции
(macOS/Linux) - без консоли, без ручной установки, без агентов на клиенте кроме
`ssh`. Заточен под работу в паре с **Claude Code**: описываешь лабу словами
("домен, три ноды S2D, отдельный CA") - агент собирает её из building blocks.

```
Workstation --ssh--> Proxmox node --qm--> Windows guest
   (bash)             (building blocks)    (scheduled task + state-машина)
                                     ^
                                     +-- статус и команды через qemu-guest-agent
```

## Ключевые приёмы

- **Unattended-установка**: на каждую VM генерируется свой `autounattend.xml`;
  рядом на тот же ISO кладутся guest-скрипты, virtio-драйверы и
  `qemu-guest-agent`, вырезанные из `virtio-win.iso`. Один CD вместо трёх.
- **Self-driving гость**: `RunSynchronousCommand` из pass `specialize`
  регистрирует scheduled task; дальше state-машина (`C:\Lab\state.txt`) доводит
  сеть, роли, промо домена и join через ребуты.
- **Канал управления - guest agent, не WinRM**: гость пишет статус в
  `C:\Lab\status.txt`, хост читает его через `qm guest exec`. Работает без сети
  в госте и без доменных кред (аналог KVP в Hyper-V).
- **Секреты только в `.env`**: пароль лабы живёт в `LAB_PW`, в скриптах - токен
  `__LAB_PW__`, который подставляется при генерации. Литералов в репозитории нет.

## Быстрый старт

```bash
git clone <this-repo> && cd ProxMoxLabKit
cp .env.example .env && $EDITOR .env      # PVE_SSH, LAB_PW
./lib/prepare-media.sh                    # скачать Windows ISO + virtio-win на ноды

./labs/example-ad-s2d/build.sh            # собрать лабу
./bin/status.sh -w                        # ждать DONE-* по каждой VM
./labs/example-ad-s2d/form-cluster.sh     # собрать кластер S2D
```

## Что внутри

| Каталог | Назначение |
|---------|-----------|
| `lib/` | `common.sh` (.env, ssh-обёртки, подстановка токенов), `pve.sh` (обёртки `qm`), `unattend.sh` (генерация autounattend + сборка ISO), `prepare-media.sh` |
| `bin/` | `status.sh` (состояние VM + статус гостей), `exec.sh` (PowerShell в госте), `screenshot.sh` (консоль застрявшей VM), `cleanup.sh` |
| `guest/` | шаблоны bootstrap: первый DC, реплика DC (AD-сайт), member-join |
| `roles/` | ролевые state-машины поверх домена: AD CS, IIS, нода S2D, кластер S2D |
| `labs/` | по каталогу на лабу (топология + build-скрипт); `example-ad-s2d` - рабочий пример |
| `docs/` | `GOTCHAS.md` - грабли Windows на Proxmox. Читать при любой проблеме |
| `.claude/` | настройки и скиллы для Claude Code |

## Требования

- Proxmox VE 8/9, доступ по SSH с ключом, свободные VMID.
- ISO Windows Server 2022/2025 и `virtio-win.iso` на нодах (скачает
  `prepare-media.sh`).
- Рабочая станция: bash, ssh, python3 (для генерации), `genisoimage` **на ноде**.
- Для S2D: гости Datacenter edition, отдельные data-диски на VM, 3+ ноды.

## Безопасность

Это **лабораторный** тулкит: пароль администратора в открытом виде попадает в
`autounattend.xml` внутри unattend-ISO и в guest-скрипты внутри VM - неизбежная
плата за unattended-установку. `cleanup.sh --unattend` удаляет ISO после
раскатки. Не переносить паттерн на продуктивные системы.

## Версия

0.1.0 - building blocks, AD (лес/реплика/join), S2D-кластер, роли AD CS/IIS.
