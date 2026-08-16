---
name: lab-troubleshoot
description: Diagnose a Windows lab guest on Proxmox that is stuck, silent or unreachable - no guest agent, no network, install not starting, domain join failing. Use when a lab VM does not reach its expected DONE state.
---

# lab-troubleshoot: гость молчит или застрял

Диагностика идёт от дешёвого к дорогому. Не гадай - каждый шаг даёт факт.

## 1. Экран решает половину вопросов

```bash
./bin/screenshot.sh <VM>
```
- `Press any key to boot from CD` / `BdsDxe: No bootable option` -> UEFI-промпт
  не был отвечен, установка не начиналась. Перезапусти VM с `start_lab_vm`
  (он шлёт `sendkey ret` первые 12 секунд).
- `Installing Windows Server NN%` -> просто жди.
- Экран логона -> установка прошла, проблема дальше (агент/сеть/bootstrap).
- Мастер установки с выбором языка -> `autounattend.xml` не подхватился:
  проверь, что unattend-ISO подключён как `ide0` и содержит файл в корне.

## 2. Есть ли сеть

```bash
ping <IP гостя>
```
Отвечает - bootstrap дошёл минимум до настройки сети. Не отвечает при работающей
установке - почти всегда драйвер: сетевая должна быть `e1000`, потому что WinPE
инжектит только boot-critical драйверы и `netkvm` в систему не попадает.

## 3. Есть ли канал агента

```bash
ssh <PVE_SSH> "ssh -n <node> 'qm agent <vmid> ping'"
```
`QEMU guest agent is not running`, хотя служба в госте Running -> нет драйвера
`vioserial`. Он лежит в `vioserial/<osver>/amd64` на virtio-win, а НЕ в
`amd64/<osver>` (там только storage). Поставить в госте:
`pnputil /add-driver <путь>\vioser.inf /install`, затем `Restart-Service QEMU-GA`.

## 4. Что делал сам гость

Если сеть есть, WinRM обычно доступен (Windows Server включает его сам).
Лог bootstrap лежит в `C:\Lab\bootstrap.log`, состояние - в `C:\Lab\state.txt`.
Через агента:
```bash
./bin/exec.sh <VM> "Get-Content C:\Lab\bootstrap.log -Tail 20"
```
Типичные записи:
- `no NIC in Up state` -> см. пункт 2.
- `join ERROR: ... domain either does not exist or could not be contacted` ->
  нода стартовала раньше, чем DC поднял AD. Задача с повторяющимся триггером
  переиграет сама через 5 минут; если триггера нет - `Start-ScheduledTask
  -TaskName Lab-Bootstrap`.
- Лог обрывается на `promoting` -> промо идёт, это 10+ минут, жди.

## 5. Гость мёртв целиком

Смонтируй его диск на ноде и прочитай логи с выключенной VM:
```sh
qm stop <vmid>
lvchange -ay /dev/pve/vm-<vmid>-disk-1
kpartx -av /dev/pve/vm-<vmid>-disk-1
mount -t ntfs-3g -o ro /dev/mapper/pve-vm--<vmid>--disk--1p3 /mnt/x
cat /mnt/x/Lab/bootstrap.log; ls /mnt/x/Windows/System32/Tasks/
umount /mnt/x; kpartx -d /dev/pve/vm-<vmid>-disk-1
```
Так проверяются: скопировались ли guest-скрипты, зарегистрирована ли задача,
встали ли драйверы (`Windows/System32/DriverStore/FileRepository/`).

## 6. Не помогло

Пересобрать одну VM дешевле, чем чинить: `./labs/<name>/build.sh <VM>` удаляет
и создаёт её заново (~20 минут). Перед этим перечитай `docs/GOTCHAS.md` -
там записаны все грабли, уже стоившие времени.
