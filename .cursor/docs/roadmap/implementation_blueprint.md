# Technical Implementation Blueprint: DrawEngine

**Версия:** 4.0 (2026-02-05)
**Статус:** ✅ APPROVED (Architecture Hardened V4)
**Роль документа:** Стратегическое техническое руководство по реализации критических узлов DrawEngine в соответствии с архитектурой 'Hardened V4'.

---

## 1. Архитектурная оркестрация и Zero-Latency Sync

Система строится на базе Swift 6 Strict Concurrency. Для обеспечения 120 FPS без блокировок используется механизм **Handshake** между 6 акторами.

### 1.1 6-Actor Model
| Актор | Изоляция | Ответственность |
| :--- | :--- | :--- |
| **`DrawingSession`** | `@MainActor` | **Root Orchestrator**: Координация кадра, обработка ввода (`UITouch`/`NSEvent`). |
| **`LayerManager`** | `actor` | **Logical Hierarchy**: Владелец структуры слоев и их метаданных. |
| **`UndoManager`** | `actor` | **Transaction Manager**: **Serial Commit Pipeline**, управление очередью транзакций. |
| **`StrokeProcessor`** | `actor` | **Math Engine**: Расчет сплайнов (Double), биннинг, **Active Stroke Replay** (CPU recovery). |
| **`TileSystem`** | `actor` | **Residency Manager**: Управление Sparse Texture, `MTLHeap`, CoW, **Retirement Queue**. |
| **`DataActor`** | `actor` | **I/O Engine**: **WAL** (Write-Ahead Log), LZ4, Crash Recovery, SLRU Cache. |

### 1.2 Handshake Protocol (Zero-Latency Sync)
Синхронизация выполняется в рамках одного цикла `DisplayLink`:
1.  **Фаза 1 (Request)**: `DrawingSession` собирает данные у `LayerManager` и `StrokeProcessor`. Вызывает `prepareResidency` у `TileSystem`.
2.  **Фаза 2 (Prepare)**: `TileSystem` выполняет Sparse Mapping, обновляет `MTLResidencySet` (Triple Buffering) и генерирует **`ResidencySnapshot`**.
3.  **Фаза 3 (Render)**: Рендерер получает `ResidencySnapshot` и **`GeometrySnapshot`**. Рендеринг идет **без использования `await`**, так как все ресурсы гарантированно резидентны и иммутабельны.

### 1.3 Snapshot Модель
- **`ResidencySnapshot`**: Содержит `tileMapping` (StorageID), `residencySet` и `occupancyMap`.
- **`GeometrySnapshot`**: Содержит `strokeBuffers` (MTLBuffer) и `damagedRects`. Все объекты — `Sendable` и потокобезопасны.

---

## 2. Metal Hardening & GPU Safety

### 2.1 Sub-Tiling & Imageblocks (32x32)
Для минимизации **Write Amplification** и нагрузки на шину памяти:
- Логический тайл (256x256) разбивается на **Hardware Sub-Tiles (32x32)**.
- Весь композитинг и эффекты (Smudge, Lighting) выполняются внутри **on-chip SRAM** (Imageblocks).

### 2.2 Многоканальные слои (Material Layers)
Для поддержки эффектов (глиттер, блеск):
- Один логический слой может использовать **две физические текстуры** (Color + Attribute Map).
- `ResidencySnapshot` поддерживает маппинг нескольких `StorageID` на один `TileKey`.
- Использование **RG8Unorm** для карт атрибутов для экономии VRAM.

### 2.3 Tile-Level Dirty Tracking (TLDT) & Block Delta
- **TLDT**: Система отслеживает измененные области на уровне битсетов.
- **Block Delta (64x64)**: Внутри тайла 256x256 изменения фиксируются блоками 64x64. Это позволяет сохранять только измененные части тайла, радикально снижая объем I/O.

### 2.4 GPU Flight Safety & Extensibility
- **Retirement Queue**: Ресурсы (StorageID, страницы памяти) помещаются в очередь с задержкой в **3 кадра**. Это исключает Race Conditions между CPU and GPU.
- **Custom GPU Hooks**: Система расширяема через протокол `BrushEffect` и стадию `CustomProcess` (Splat -> **Custom** -> Composite).

---

## 3. Reliability & Crash Recovery

### 3.1 WAL (DrawEngine Write-Ahead Log)
Бинарный протокол для обеспечения атомарности и целостности:
- **Format**: `[Size(4B)][CRC32c(4B)][Payload]`.
- **CRC32c**: Защита каждой записи (полином `0x82F63B78`).
- **Payload**: Сжатые **LZ4** дельты блоков (**Block Delta 64x64**).

### 3.2 Recovery Mechanisms
- **Crash Recovery**: При старте Replay WAL-записей с проверкой контрольных сумм.
- **Active Stroke Replay**: В случае **Metal Device Loss** `StrokeProcessor` (CPU) переподает точки активного мазка, восстанавливая визуальное состояние.

### 3.3 Backpressure & Adaptive Pressure Control
`DataActor` передает уровень нагрузки на I/O обратно в систему:
- **Pressure > 0.4**: Увеличение Stroke Coalescing до 1000мс.
- **Pressure > 0.8**: Активация `ThrottleInput` (блокировка нового ввода до разгрузки очереди).
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
    - [ ] **Active Stroke Replay** (CPU-side state).
    - [ ] CanvasGeometry: 2-Tier Region Binning.
2.  **Phase 2: Tile System & Residency**
    - [ ] `TileSystem`: `MTLSparseTexture`, `MTLHeap`.
    - [ ] **Retirement Queue** (3-frame delay).
    - [ ] **Handshake Protocol**: Фазы 1-3.
3.  **Phase 3: Metal Pipeline & Hardening**
    - [ ] **Sub-Tiling (32x32)** & **Imageblocks** композитор.
    - [ ] Smudge Engine с Threadgroup Memory (< 32 регистра).
4.  **Phase 4: Undo & Reliability**
    - [ ] `UndoManager`: Serial Commit Pipeline.
    - [ ] **WAL**: CRC32c + LZ4 (**Block Delta 64x64**).
    - [ ] **Crash Recovery**: WAL Replay.
5.  **Phase 5: Persistence & UX**
    - [ ] **Adaptive Pressure Control** (Backpressure).
    - [ ] `MetalDrawView`: 120Hz Display Link & Predictive Input.
    - [ ] Pro Export: Streaming mode (HDR/SDR).
