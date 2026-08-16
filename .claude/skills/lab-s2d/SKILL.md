---
name: lab-s2d
description: Build a Storage Spaces Direct cluster on Proxmox-hosted Windows guests - data disks with serials, fault domains, witness, pool and volumes. Use for S2D, failover cluster or storage lab requests on Proxmox.
---

# lab-s2d: кластер S2D на гостях Proxmox

Рецепт поверх `lab-build`. Читать целиком - половина пунктов это грабли,
которые молча дают "здоровый кластер с пустым пулом".

## Требования к нодам

- Гости - **Datacenter edition** (S2D есть только там), Core экономит RAM.
- 3 ноды - классический минимум (three-way mirror); 2 ноды тоже работают
  (two-way mirror), 4+ дают больше вариантов живучести.
- Data-диски: минимум 2 на ноду, отдавать через `virtio-scsi` с `ssd=1`.
- **Каждому диску обязателен `serial=`, уникальный в пределах кластера.**
  Без него `Get-PhysicalDisk` диск не покажет, а `Enable-ClusterS2D` при этом
  отрапортует успех - пул останется пустым. `new_lab_vm` проставляет
  `serial=<VMNAME>d<N>` автоматически.
- Nested virt нужен, только если ноды сами будут крутить VM (hyper-converged).

## Порядок

1. DC -> `DONE-forest`, ноды -> `DONE-node` (bootstrap уже ставит фичи
   кластеризации и поднимает диски из offline).
2. `./labs/<name>/form-cluster.sh` - он делает: `Test-Cluster`, `New-Cluster
   -StaticAddress -NoStorage`, witness-шару на DC (права CNO выдаются **после**
   создания кластера - до этого объекта в AD нет), проверку числа видимых
   дисков, `Enable-ClusterStorageSpacesDirect`, том.
3. Ждать `CLUSTER|DONE-cluster`.

Fault domains (rack/site) создавать между `New-Cluster` и `Enable-ClusterS2D`:
```powershell
New-ClusterFaultDomain -Name Rack-A -Type Rack
Set-ClusterFaultDomain -Name S2D1 -Parent Rack-A
```

## Если пул пустой

Симптом: `Get-ClusterS2D` = Enabled, ноды Up, `Get-StoragePool` показывает
только Primordial. Проверяй по порядку:
```powershell
Get-Disk | Where-Object { $_.Number -ne $null } | Format-Table Number,SerialNumber,OperationalStatus
(Get-StorageSubSystem -FriendlyName "Clustered*" | Get-PhysicalDisk).Count
```
- Пустой `SerialNumber` -> остановить VM, задать `serial=` дискам, запустить.
- `Offline` -> `Set-Disk -Number N -IsOffline $false` (SAN policy).
- Диски появились уже после `Enable-ClusterS2D` -> `Disable-ClusterS2D
  -Confirm:$false`, подождать, включить снова: пул создаётся в момент включения.

## Тома

```powershell
New-Volume -StoragePoolFriendlyName S2DPool -FriendlyName Vol01 -FileSystem CSVFS_ReFS -Size 40GB
```
Для трёх нод резервирование выбирается само (Mirror, 3 копии). Проверка:
`Get-VirtualDisk | Format-Table FriendlyName,ResiliencySettingName,NumberOfDataCopies,HealthStatus`.

## Смоук отказоустойчивости

Выключить одну ноду (`qm stop`) - CSV обязан остаться `Online`, том уйдёт в
`Degraded` (это норма, потеряна одна копия). Вернуть ноду - состояние
восстановится само. Чекпоинты Proxmox на нодах с дисками в пуле не делать.
