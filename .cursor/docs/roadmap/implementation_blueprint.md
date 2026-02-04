# Technical Implementation Blueprint: DrawEngine

**Версия:** 3.0 (2026-02-04)
**Статус:** ✅ APPROVED (Architecture Hardened V4)
**Роль документа:** Стратегическое техническое руководство по реализации критических узлов DrawEngine.

---

## 1. Архитектурная оркестрация и Zero-Latency Sync

Система строится на базе Swift 6 Strict Concurrency. Для обеспечения 120 FPS без блокировок используется механизм **Handshake** между акторами.

### 1.1 Handshake Protocol (Фазы 1-3)
Синхронизация выполняется в рамках одного цикла `DisplayLink`:
1.  **Фаза 1 (Request)**: `@MainActor` (`DrawingSession`) собирает `LayerStackSnapshot` и `ViewContext`. Вызывает `prepareResidency` у `TileSystem`.
2.  **Фаза 2 (Prepare)**: `TileSystem` выполняет Sparse Mapping, обновляет `MTLResidencySet` и генерирует иммутабельный **`ResidencySnapshot`**.
3.  **Фаза 3 (Render)**: Рендерер получает `ResidencySnapshot` и **`GeometrySnapshot`** (от `StrokeProcessor`). Рендеринг идет **без использования `await`**, так как все ресурсы гарантированно резидентны и иммутабельны.

### 1.2 Snapshot Модель
- **`ResidencySnapshot`**: Содержит `tileMapping` (StorageID), `residencySet` и `occupancyMap`.
- **`GeometrySnapshot`**: Содержит `strokeBuffers` (MTLBuffer) и `damagedRects`. Все объекты — `Sendable` и потокобезопасны.

| Актор | Изоляция | Ответственность |
| :--- | :--- | :--- |
| **`DrawingSession`** | `@MainActor` | **Root Orchestrator**: Координация кадра, обработка ввода. |
| **`LayerManager`** | `@MainActor` | **Logical Hierarchy**: Владелец структуры слоев. |
| **`UndoCoordinator`** | `actor` | **Transaction Manager**: **Serial Commit Pipeline**, управление очередью коммитов. |
| **`StrokeProcessor`** | `actor` | **Math Engine**: Расчет сплайнов (Double), биннинг, генерация `GeometrySnapshot`. |
| **`TileSystem`** | `actor` | **Residency Manager**: Управление Sparse Texture, `MTLHeap`, CoW. |
| **`DataActor`** | `actor` | **I/O Engine**: WAL (DWAL), LZ4, Crash Recovery, SLRU Cache. |

### 1.1 Handshake Protocol & Advanced FX
...
2.  **Фаза 2 (Prepare)**: `TileSystem` выполняет Sparse Mapping, обновляет `MTLResidencySet` и генерирует иммутабельный **`ResidencySnapshot`**. В снимок включаются данные о векторе освещения (LightVector) и ресурсах для материальных эффектов.
...
---

## 2. Metal Hardening & Advanced FX

### 2.1 Sub-Tiling & Imageblocks (32x32)
...
- Весь композитинг, включая **PBR-lite освещение** и эффекты материалов, выполняется внутри **on-chip SRAM**.

### 2.2 Многоканальные слои (Material Layers)
Для поддержки эффектов (глиттер, блеск):
- Один логический слой может использовать **две физические текстуры** (Color + Attribute Map).
- `ResidencySnapshot` поддерживает маппинг нескольких `StorageID` на один `TileKey`.
- Использование **RG8Unorm** для карт атрибутов для экономии VRAM.
Для минимизации spilling (вытеснения) данных из SRAM в VRAM:
- Логический тайл (256x256) разбивается на **Hardware Tiles (32x32)**.
- Весь композитинг и эффекты выполняются внутри **on-chip SRAM** (Imageblocks), что снижает нагрузку на шину памяти.

### 2.2 Smudge Engine & Threadgroup Memory
- **Smudge**: Использует 8KB-16KB **Threadgroup Memory** для кэширования пикселей холста под кистью.
- **Occupancy**: Ограничение в **32 регистра** на поток для поддержания 100% загрузки ядер GPU на частоте 120 FPS.

### 2.3 GPU Flight Safety
- **Retirement Queue**: Ресурсы (StorageID, страницы памяти) не освобождаются мгновенно, а помещаются в очередь с задержкой в **3 кадра**. Это исключает Race Conditions между CPU и GPU.
- **Custom GPU Hooks**: Система расширяема через протокол `BrushEffect` и стадию `CustomProcess` (Splat -> **Custom** -> Composite).

---

## 3. Reliability & Crash Recovery

### 3.1 DWAL (DrawEngine Write-Ahead Log)
Бинарный формат WAL для атомарности:
- **Magic**: `0x4457414C`.
- **Защита**: Каждая запись защищена **CRC32c (Castagnoli)**.
- **Payload**: Сжатые LZ4 дельты блоков 64x64 (Tile-Level Dirty Tracking).

### 3.2 Crash Recovery & Device Loss
- **Recovery**: При старте система сканирует WAL, отбрасывает записи с `LSN <= lastCommittedLSN`, проверяет CRC и делает **Replay** валидных транзакций.
- **Active Stroke Replay**: При потере Metal Device (`Device Loss`) `StrokeProcessor` (CPU) переподает точки активного мазка в новый контекст, восстанавливая визуальное состояние.

### 3.3 Управление памятью и I/O
- **SLRU (Segmented LRU)**: L2 кэш (1.5ГБ) разделен на `Protected` (20%) и `Probationary` (80%) сегменты.
- **Adaptive Pressure Control**: 
    - Pressure > 0.4: Увеличение Stroke Coalescing до 1000мс.
    - Pressure > 0.8: Активация `ThrottleInput` (блокировка ввода до очистки очереди).
- **Disk Full**: При < 50MB свободного места система переходит в **Read-Only** режим.

---

## 4. Performance Tiers (Адаптивность)

Движок автоматически выбирает профиль производительности на основе модели GPU.

| Профиль | Устройства | Цель | Особенности |
| :--- | :--- | :--- | :--- |
| **Ultra (M1+)** | Apple Silicon | 120 FPS | Full HDR, Real-time Noise, Multi-tap Bloom. |
| **Pro (A13+)** | iPhone 11+ | 120/60 FPS | Compressed Material Maps, Simple Bloom. |
| **Legacy (A10-A12)**| iPad 2018 | 60 FPS | **Baked Noise** (текстура), No Bloom, RGBA8 Fallback. |

---

## 5. План реализации (Implementation Sequence)

1.  **Phase 1: Math & Geometry**
    - [ ] `StrokeProcessor`: Catmull-Rom (Double) & GeometrySnapshot.
    - [ ] `CanvasGeometry`: 2-Tier Region Binning.
2.  **Phase 2: Tile System & Residency**
    - [ ] `TileSystem`: MTLSparseTexture, ResidencySnapshot & Retirement Queue.
    - [ ] `Handshake`: Реализация Фаз 1-3 (Zero-Latency Sync).
3.  **Phase 3: Metal Pipeline & Hardening**
    - [ ] Sub-Tiling (32x32) & Imageblock композитор.
    - [ ] Smudge Engine с Threadgroup Memory.
    - [ ] Custom GPU Hooks API.
4.  **Phase 4: Undo & Reliability**
    - [ ] `UndoCoordinator`: Serial Commit Pipeline & TLDT.
    - [ ] `DataActor`: DWAL протокол с CRC32c и SLRU кэш.
    - [ ] Crash Recovery & Active Stroke Replay.
5.  **Phase 5: Persistence & UI**
    - [ ] Adaptive Pressure Control & Monitoring.
    - [ ] `MetalDrawView`: 120Hz Display Link & Predictive Input.
