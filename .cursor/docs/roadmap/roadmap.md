# Project Roadmap: DrawEngine (Professional Metal Drawing SDK)

**Status**: 🏗 IN PROGRESS (Updated 2026-02-04)
**Vision**: Создание самого производительного iOS/macOS SDK для рисования, способного работать с холстами 100k+ px при стабильных 120 FPS, используя инновационную 3-уровневую систему кэширования и Swift 6 Actor Model.

---

## 🏛 Core Pillars
*   **Performance**: Стабильные 120 FPS даже на сложных кистях с размазыванием.
*   **Scale**: Поддержка холстов до 100,000 пикселей (Sparse Textures).
*   **Memory Efficiency**: Жесткий лимит 512MB VRAM через интеллектуальный Residency Manager.
*   **Safety**: Полная изоляция данных через 5-Actor Model (Swift 6 Strict Concurrency).

---

## 🎯 Milestone 1: The Infinite Canvas (Core Infrastructure)
*Фокус: Математика, Управление памятью, Архитектура слоев.*

- [ ] **CanvasGeometry (Double Precision)**: 
    - [ ] Реализация World <-> Tile трансформаций на `Double`.
    - [ ] 2-Tier Region Binning (Region/Tile passes).
- [ ] **TileSystem & MTLHeap (Physical Memory)**:
    - [ ] Настройка `MTLSparseTexture` и `MTLHeap` (Placement Heap).
    - [ ] Tile-Level Dirty Tracking (TLDT) bitsets.
- [ ] **Residency Manager (VRAM Guard)**:
    - [ ] Реализация `MTLResidencySet`.
    - [ ] Логика вытеснения (LRU) на основе Layer Priority (Active > Visible > Background).
- [ ] **Global Occupancy Map (GOM)**:
    - [ ] Иерархическая маска (L1/L2) для быстрого пропуска пустых областей при композитинге.
- [ ] **LayerManager & State**:
    - [ ] Swift 6 Actor isolation.
    - [ ] Система `LayerStackSnapshot` для исключения Actor Hopping при рендеринге.

**⚡️ Performance Checkpoint**: Тестирование лимита 512MB VRAM на холсте 32k x 32k с 10 слоями.

---

## 🎯 Milestone 2: Fluid Experience (View & Interaction)
*Фокус: Минимизация задержки, Рендеринг, Жизненный цикл кадра.*

- [ ] **MetalDrawView & Input Abstraction**:
    - [ ] Обработка `UITouch` / `NSEvent` с поддержкой `predictedTouches`.
    - [ ] Координатный маппинг (Screen -> World).
- [ ] **FrameContext & Synchronization**:
    - [ ] Механизм Handshake между акторами для подготовки кадра.
    - [ ] Triple Buffering & `MTLFence` для синхронизации GPU.
- [ ] **Tile-based SRAM Compositor**:
    - [ ] Смешивание слоев в один проход внутри Imageblocks (on-chip memory).
    - [ ] Viewport-Aware Culling.
- [ ] **LiveStrokeBuffer**:
    - [ ] Real-time отображение текущего мазка до фиксации в тайлах.

**⚡️ Performance Checkpoint**: 120 FPS при панорамировании и зуме на тяжелых проектах.

---

## 🎯 Milestone 3: Professional Tools (Brush Engine)
*Фокус: Математика мазка, GPU Эффекты, Обработка текстур.*

- [ ] **StrokeProcessor (The Brain)**:
    - [ ] Адаптивная интерполяция Centripetal Catmull-Rom ($\alpha=0.5$).
    - [ ] Zero-Copy Geometry (shared MTLBuffers).
- [ ] **Multi-pass Brush Pipeline**:
    - [ ] **Pass 1: Splatting** (генерация маски отпечатков).
    - [ ] **Pass 2: Processing** (Compute-ядра для Smudge/Blur).
    - [ ] **Pass 3: Composite** (финальное наложение на слой).
- [ ] **Smudge Engine (Occupancy Optimized)**:
    - [ ] Оптимизация ядер (< 32 регистра на поток).
    - [ ] HDR-Safe смешивание (RGBA16Float).
- [ ] **Deferred Mipmapping**:
    - [ ] Асинхронная генерация мипов на основе TLDT масок после завершения мазка.

**⚡️ Performance Checkpoint**: Замер Register Pressure и Occupancy на Apple Silicon для Smudge-ядра.

---

## 🎯 Milestone 4: Production Grade (Data & Undo)
*Фокус: Надежность, История правок, Формат файла.*

- [ ] **Tile-centric Undo/Redo**:
    - [ ] Захват снапшотов на уровне тайлов/блоков (64x64).
    - [ ] LZ4 Snapshot Pipeline (фоновое сжатие в RAM).
- [ ] **Serial Commit Pipeline**:
    - [ ] FIFO гарантированный порядок транзакций через `AsyncStream`.
- [ ] **.drawproj Package & Persistence**:
    - [ ] Write-Ahead Log (WAL) для атомарности сохранений.
    - [ ] Global Transaction Index для быстрого восстановления истории.
- [ ] **Pro Export**:
    - [ ] HDR to SDR (ACES/Reinhard Tonemapping).
    - [ ] Export-Streaming Mode для 32k+ холстов.

**⚡️ Final Checkpoint**: Полный цикл Undo/Redo на 100+ шагов и сохранение/загрузка проекта 1GB+.
