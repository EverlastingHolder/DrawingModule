# Project Roadmap: DrawEngine (Professional Metal Drawing SDK)

**Status**: 🏗 IN PROGRESS (Updated 2026-02-05)
**Vision**: Создание самого производительного iOS/macOS SDK для рисования, способного работать с холстами 100k+ px при стабильных 120 FPS, используя инновационную 3-уровневую систему кэширования и Swift 6 Actor Model.

---

## 🏛 Core Pillars
*   **Performance**: Стабильные 120 FPS даже на сложных кистях с размазыванием (Smudge).
*   **Scale**: Поддержка холстов до 100,000 пикселей через `MTLSparseTexture`.
*   **Memory Efficiency**: Жесткий лимит 512MB VRAM через интеллектуальный Residency Manager.
*   **Safety**: Полная изоляция данных через **6-Actor Model** (Swift 6 Strict Concurrency): `DrawingSession`, `LayerManager`, `UndoManager`, `StrokeProcessor`, `TileSystem`, `DataActor`.
*   **Reliability**: Гарантия сохранности данных через **WAL** (DrawEngine Write-Ahead Log) с CRC32c.

---

## 🎯 Milestone 1: Math & Geometry (Phase 1)
*Фокус: Математика кривых, Биннинг и Геометрический конвейер.*

- [ ] **CanvasGeometry (Double Precision)**: 
    - [ ] Реализация World <-> Tile трансформаций на `Double`.
    - [ ] 2-Tier Region Binning (Region/Tile passes) для быстрого отсечения.
- [ ] **StrokeProcessor (actor)**:
    - [ ] Генерация сплайнов (Catmull-Rom) и формирование `GeometrySnapshot`.
    - [ ] **Active Stroke Replay**: CPU-side хранение точек для восстановления после Device Loss.
- [ ] **Global Occupancy Map (GOM)**:
    - [ ] Иерархическая маска (L1/L2) для быстрого пропуска пустых областей при композитинге.
- [ ] **Input Pipeline**:
    - [ ] Обработка `UITouch` / `NSEvent` с поддержкой `predictedTouches`.

**⚡️ Performance Checkpoint**: Точность позиционирования на ультра-зуме (1000x) без дрожания (jitter).

---

## 🎯 Milestone 2: The Infinite Canvas (Phase 2)
*Фокус: Управление памятью, Архитектура акторов и Residency.*

- [ ] **6-Actor Model Orchestration**:
    - [ ] `@MainActor DrawingSession`: UI Orchestrator & Input.
    - [ ] `actor LayerManager`: Logical Hierarchy & Metadata.
    - [ ] `actor TileSystem`: Resource Manager & MTLSparseTexture.
    - [ ] **Handshake Protocol**: Реализация Фаз 1-3 (Zero-Latency Sync) для 120 FPS.
- [ ] **TileSystem & MTLHeap**:
    - [ ] Настройка `MTLSparseTexture` и `MTLHeap` (Placement Heap).
    - [ ] **Tile-Level Dirty Tracking (TLDT)** bitsets для минимизации обновлений.
- [ ] **Residency Manager (VRAM Guard)**:
    - [ ] Реализация `MTLResidencySet` с Triple Buffering.
    - [ ] **Retirement Queue**: 3-frame delay для безопасного освобождения ресурсов GPU.

**⚡️ Performance Checkpoint**: Тестирование лимита 512MB VRAM на холсте 32k x 32k с 10 слоями.

---

## 🎯 Milestone 3: Professional Rendering (Phase 3)
*Фокус: Metal Hardening, Smudge Engine, Оптимизация SRAM.*

- [ ] **Sub-Tiling & Imageblocks**:
    - [ ] Разбиение тайлов 256x256 на **Hardware Tiles (32x32)**.
    - [ ] Смешивание слоев внутри **on-chip SRAM** (Imageblocks) для минимизации Write Amplification.
- [ ] **Multi-pass Brush Pipeline**:
    - [ ] **Pass 1: Splatting** (генерация маски отпечатков).
    - [ ] **Pass 2: Processing** (Smudge через Threadgroup Memory).
    - [ ] **Pass 3: Composite** (финальное наложение на слой).
- [ ] **Smudge Engine (Occupancy Optimized)**:
    - [ ] Оптимизация ядер (< 32 регистра на поток).
    - [ ] HDR-Safe смешивание (RGBA16Float).
- [ ] **Deferred Mipmapping**:
    - [ ] Асинхронная генерация мипов на основе TLDT масок после завершения мазка.

**⚡️ Performance Checkpoint**: Замер Register Pressure и Occupancy на Apple Silicon для Smudge-ядра.

---

## 🎯 Milestone 4: Data & Reliability (Phase 4)
*Фокус: Надежность, История правок, Восстановление.*

- [ ] **WAL (DrawEngine Write-Ahead Log)**:
    - [ ] Реализация бинарного лога: `[Size][CRC32c][Payload]`.
    - [ ] **LZ4** сжатие payload (**Block Delta 64x64**) для минимизации I/O.
- [ ] **Crash Recovery**:
    - [ ] Автоматический Replay WAL при старте после краша (проверка CRC32c).
- [ ] **Undo/Redo Architecture**:
    - [ ] `UndoManager`: Serial Commit Pipeline (FIFO order).
    - [ ] Tile-centric snapshots с использованием Block Deltas.
- [ ] **SLRU Cache Management**:
    - [ ] Двухсегментный кэш (Protected 20% / Probationary 80%) для LZ4 снапшотов.

**⚡️ Performance Checkpoint**: Полный цикл Undo/Redo на 100+ шагов и восстановление после симулированного сбоя.

---

## 🎯 Milestone 5: Fluid Interaction & UX (Phase 5)
*Фокус: Минимизация задержки, Адаптивность, Жизненный цикл.*

- [ ] **Backpressure & Adaptive Pressure Control**:
    - [ ] Динамическая настройка Stroke Coalescing на основе I/O pressure (DataActor feedback).
    - [ ] ThrottleInput при критической нагрузке (> 0.8 pressure).
- [ ] **MetalDrawView & FrameContext**:
    - [ ] Механизм **Handshake** между 6 акторами для подготовки кадра.
    - [ ] `MTLFence` для синхронизации GPU и Snapshotter.
- [ ] **LiveStrokeBuffer**:
    - [ ] Real-time отображение текущего мазка до фиксации в слое.
- [ ] **Pro Export**:
    - [ ] HDR to SDR (ACES/Reinhard Tonemapping).
    - [ ] Export-Streaming Mode для 32k+ холстов без переполнения RAM.

**⚡️ Final Checkpoint**: Стабильные 120 FPS при рисовании на тяжелых проектах 100k+ px.
