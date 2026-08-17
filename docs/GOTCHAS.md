# GOTCHAS - грабли Windows-лаб на Proxmox

Проверено на живом стенде (Proxmox 9.2, Windows Server 2025). Каждый пункт стоил
времени, поэтому читай раньше, чем начнёшь чинить наугад.

## Установка Windows

- **UEFI ждёт нажатия клавиши.** Под OVMF установочный ISO Windows показывает
  `Press any key to boot from CD or DVD`, и без нажатия прошивка уходит на пустой
  диск: `BdsDxe: No bootable option or device was found`. VM выглядит запущенной,
  но установка не начинается вообще. **Фикс:** после `qm start` слать
  `sendkey ret` через `qm monitor` в течение ~12 секунд.
  ```sh
  qm start $VMID
  for i in $(seq 1 12); do echo "sendkey ret" | qm monitor $VMID >/dev/null; sleep 1; done
  ```
  Позже слать **нельзя**: на ребуте в середине установки нажатие запустит
  установку заново с нуля.

- **WinPE инжектит только boot-critical драйверы.** Если положить virtio-драйверы
  на unattend-ISO и прописать `DriverPaths` в pass `windowsPE`, в установленную
  систему попадёт `vioscsi` (нужен для загрузки/дисков), но **не** `netkvm` -
  и гость поднимется вообще без сети. **Фикс:** сетевая карта `e1000`
  (in-box драйвер Windows) либо доустановка `netkvm` через `pnputil` уже в
  системе. Для лабы `e1000` проще и не зависит от версии virtio-win.

- **Порядок дисков.** OS-диск на `sata0` ставится без единого стороннего
  драйвера. Data-диски под S2D - на `virtio-scsi` (`scsihw virtio-scsi-single`,
  `ssd=1`): `vioscsi` приезжает через `DriverPaths` и работает.

- **Имя образа в `autounattend.xml`** сверяй с реальным ISO, индексы плавают.
  Для WS2025 eval: 1 = `Windows Server 2025 SERVERSTANDARDCORE`,
  2 = `SERVERSTANDARD`, 3 = `SERVERDATACENTERCORE`, 4 = `SERVERDATACENTER`.
  Вытащить список без wimlib можно из хвоста `install.wim` (метаданные в
  UTF-16LE) - см. `lib/wiminfo.sh`.

- **`qemu-guest-agent` ставится из `virtio-win.iso`** (`guest-agent\qemu-ga-x86_64.msi`).
  Без него нет канала внутрь гостя: ни `qm guest exec`, ни статуса. Ставить в
  первом же шаге bootstrap, до всего остального.

## Управление гостями

- **Канал управления - guest agent, а не WinRM.** `qm guest exec` работает без
  сети в госте и без доменных кред. Аналог KVP из Hyper-V: гость пишет статус в
  `C:\Lab\status.txt`, хост читает его через агента.
- **Долгие операции - только scheduled task в госте.** Промо DC, join, установка
  ролей переживают ребуты через state-файл; хост лишь опрашивает статус.
  Синхронно ждать в `qm guest exec` нельзя - таймаут агента убьёт вызов.
- **Кластерные команды требуют доменных прав**, а guest agent работает от SYSTEM.
  Скрипт кластера перерегистрирует себя задачей от `DOMAIN\Administrator`.

## Ожидания и повторы

- **Ответа DNS недостаточно, чтобы считать домен готовым.** Контроллер поднимает
  DNS задолго до того, как AD пригодна для join или промо реплики: нода видит
  ответ, идёт присоединяться и падает с "domain either does not exist or could
  not be contacted". Ждать нужно SRV-записи netlogon
  (`_ldap._tcp.dc._msdcs.<domain>`) **и** порт 389.
- **`-RepetitionDuration` рядом с `-Once` ломает повтор.** С ограниченной
  длительностью следующий запуск задачи планируется на сутки вперёд, а не через
  пять минут - "второй шанс" не наступает никогда. Ставить
  `[TimeSpan]::MaxValue`.
- **Windows-путь не переживает цепочку `bash -> ssh -> qm -> powershell`.**
  `qm guest exec ... -File C:\Lab\x.ps1` молча ничего не делает: файл в госте
  есть, задачи и лога нет. Запускать через `-EncodedCommand` (base64 UTF-16LE).

## Сеть и настройка гостя

- **Настройка сети - жёсткий гейт.** Если `Get-NetAdapter | ? Status -eq 'Up'`
  пуст, дальше идти нельзя: промо леса без сети даёт сломанный домен, который
  проще снести, чем чинить. Ждать адаптер циклом и выходить со статусом
  `no-nic`, а не продолжать.
- **DNS домена не должен совпадать с зоной локального резолвера лабы** - иначе
  гости уходят к нему вместо DC. Бери отдельную зону под лабу.

## S2D на Proxmox

- **Диску обязателен `serial=`.** Без него Windows показывает пустой
  `SerialNumber`, и Storage Spaces вообще не отдаёт диск как `PhysicalDisk`:
  `Get-Disk` его видит, а `Get-PhysicalDisk` - нет, пул создаётся пустым.
  Симптом обманчивый: `Get-ClusterS2D` рапортует `Enabled`, кластер здоров,
  дисков в пуле ноль. Задавать при создании и делать **уникальным в пределах
  всего кластера**:
  ```sh
  qm set $VMID --scsi1 local-lvm:32,ssd=1,serial=S2D1d1
  ```
  Меняется только на выключенной VM.
- **SAN policy оставляет новые диски offline.** На Windows Server политика по
  умолчанию (`OfflineShared`) не подключает добавленные диски, и S2D их не
  заклеймит. Лечится в bootstrap до сборки кластера:
  ```powershell
  Get-Disk | Where-Object { $_.Number -ne $null -and $_.Number -gt 0 } |
      ForEach-Object { Set-Disk -Number $_.Number -IsOffline $false; Set-Disk -Number $_.Number -IsReadOnly $false }
  ```
- Диски видятся как `MediaType Unspecified` даже с `ssd=1`, поэтому
  `Enable-ClusterStorageSpacesDirect -SkipEligibilityChecks -CacheState Disabled`.
- Гости - **Datacenter edition**: S2D есть только в нём. Core экономит RAM и диск.
- Fault domains создавать ПОСЛЕ `New-Cluster` и ДО `Enable-ClusterStorageSpacesDirect`.
- Права на witness-шару кластерному аккаунту (`CLUSTERNAME$`) выдавать **после**
  `New-Cluster`: до этого объекта в AD нет.
- Витрина: чекпоинты Proxmox на нодах с дисками в пуле - способ потерять пул.

## Скрипты хоста

- **`ssh` съедает stdin цикла.** `while read ... done` по списку VM отработает
  ровно одну итерацию, если внутри вызывается `ssh` - он читает тот же stdin.
  Лечится `ssh -n`, а не переписыванием цикла. Симптом обманчивый: скрипт
  завершается с кодом 0, просто «половина машин не создалась».
- **`qm clone` асинхронный**: возвращает UPID, и настройка сразу после него
  падает по правам на ещё не существующий VMID. Ждать завершения задачи.
- ISO лежит на локальном хранилище каждой ноды - при раскладке VM по разным
  нодам образ нужно разнести заранее (`scp` внутри кластера, не качать трижды).
