---
name: lab-build
description: Build a Windows lab on Proxmox from a natural-language request - domain controllers, member servers, clusters. Use whenever the user describes a lab topology to create on Proxmox.
---

# lab-build: сборка Windows-лабы на Proxmox

## 1. Проектирование

Разбери запрос в таблицу и ПОКАЖИ пользователю до сборки:

| VM | VMID | Нода Proxmox | IP | RAM | vCPU | Диски | Роль |
|----|------|--------------|-----|-----|------|-------|------|

Проверь ресурсы перед обещаниями:
```bash
ssh <PVE_SSH> "pvesh get /nodes --output-format json" | python3 -m json.tool | grep -E 'node|maxmem|mem'
ssh <PVE_SSH> "pvesm status -content images"
ssh <PVE_SSH> "pvesh get /cluster/nextid"
```
Правила: первый DC всегда первый; RAM считай по свободной, а не общей; ISO лежит
локально на каждой ноде (`lib/prepare-media.sh` разносит); Datacenter edition -
только если нужен S2D.

## 2. Каркас лабы

```
labs/<name>/
  lab.conf         # топология (таблица VMS), домен, сеть, кластер
  build.sh         # копия примера, обычно менять не нужно
  form-cluster.sh  # если в лабе есть кластер
```
Копируй `labs/example-ad-s2d/` целиком и правь `lab.conf`. Guest-шаблоны
(`guest/bootstrap_*.ps1`) параметризуются из `lab.conf` - не редактируй их
под конкретную лабу.

## 3. Выполнение

```bash
./lib/prepare-media.sh                       # разово: ISO на ноды
./labs/<name>/build.sh                       # создать и запустить VM
LAB=labs/<name>/lab.conf ./bin/status.sh -w  # ждать DONE-*
./labs/<name>/form-cluster.sh                # когда все ноды DONE-node
```
Установка Windows 15-25 мин на VM (идут параллельно), промо DC ~10 мин,
join ~5 мин, кластер ~10 мин. Поллинг 60-120 c, не чаще.

## 4. Жёсткие правила

- Не выполняй долгие операции синхронно через `qm guest exec` - таймаут агента
  оборвёт вызов. Всё длинное - задача в госте + опрос статуса.
- Не редактируй чужие VM на кластере. VMID бери из `pvesh get /cluster/nextid`
  и выше, проверив занятость.
- Не печатай `$LAB_PW` и не вставляй пароль в команды - только токен.
- Гость молчит? Сначала `./bin/screenshot.sh <VM>` - экран сразу скажет,
  идёт установка, висит UEFI-промпт или это уже логон. Потом `docs/GOTCHAS.md`.

## 5. Верификация

После терминальных статусов проверь лабу по смыслу:
```bash
./bin/exec.sh DC01 "Get-ADDomain | fl DNSRoot,DomainMode"
./bin/exec.sh S2D1 "Get-ClusterNode; Get-ClusterS2D; Get-VirtualDisk"
```
Затем предложи снапшоты: `qm snapshot <vmid> baseline`.
