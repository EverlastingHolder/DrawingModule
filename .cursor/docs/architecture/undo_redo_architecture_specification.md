# Architecture Specification — Undo/Redo для DrawEngine

**Статус:** `APPROVED` (после архитектурной ремедиации 4 февраля 2026 г.)
**Версия:** 2.0

## Change Log (Remediation 2.0)

| Issue Ref | Before | After | Expert Solution | Side Effects |
| :--- | :--- | :--- | :--- | :--- |
| **Issue 1: WA & IO Collapse** | Region-centric snapshot (4x4 tiles) for every stroke. | Tile-centric + Block Delta (64x64) + Stroke Coalescing. | **Systems Engineer**: Снижение WA в десятки раз. | Улучшен FPS и IO, но один Undo может отменить серию мазков. |
| **Issue 2: GPU Bubbles** | Snapshot phase -> write phase sequential in Command Buffer. | Tile-Level Dirty Tracking (TLDT) + MTLFence. | **Metal Specialist**: Снижение объема VRAM копирования в 64 раза. | Стабильные 120 FPS за счет sparse copy. |
| **Issue 3: FIFO Races** | Reentrancy risks in Transaction Index at 1000Hz. | Serial Commit Pipeline (AsyncStream/TaskQueue). | **Architect**: Гарантированный FIFO порядок транзакций. | Устранение гонок, небольшое увеличение latency коммитов. |
| **God-object Risk** | UndoCoordinator calculated dirty regions and managed state. | Dirty logic moved to StrokeProcessor. | **Lead Architect**: Четкое разделение ответственности. | Чистая архитектура, облегчение тестирования. |

## Источники (база архитектуры)
- `project_knowledge_base.md`: 6-actor model, LZ4 snapshot pipeline, Global Transaction Index, `.drawproj`.
- `drawing_session_specification.md`: роли `DrawingSession`, `LayerManager`, `StrokeProcessor`, `TileSystem`, `DataActor`.
- `residency_synchronization_specification.md`: Handshake, ResidencySnapshot, Zero-Latency Sync.
- `layer_system_specification.md`: `LayerStackSnapshot`, разделение logical/physical.
- `tile_system_specification.md`: тайл 256x256, регион 4x4, 3-уровневый кэш, WAL.
- `brush_pipeline_specification.md`: multi-pass, live-stroke, 120 FPS.
- `view_lifecycle_specification.md`: 120 FPS, frame lifecycle.

## Цели и требования
1) Кастомные действия (расширяемый реестр).
2) Встроенная работа со слоями.
3) Встроенная работа с рисованием, всеми кистями и инструментами.
4) Сохранение истории undo/redo после export/import.

Дополнительно: 120 FPS, Swift 6 concurrency, отсутствие actor-hopping.

---

# Уровень 1 — Conceptual Design (APPROVED)

## Overview
Undo/Redo проектируется как транзакционный журнал с snapshot-redo по умолчанию и reapply только для детерминированных действий. История хранится в `.drawproj` вместе с манифестом и Global Transaction Index, что обеспечивает экспорт/импорт без потери undo/redo.

## Core Components
- **UndoCoordinator** (actor): оркестратор транзакций с гарантированным FIFO-порядком через Serial Commit Pipeline. Отвечает за жизненный цикл транзакций и Stroke Coalescing.
- **HistoryStore** (actor): сериализация истории и атомарные коммиты.
- **Snapshotter**: захват before/after снапшотов на уровне отдельных тайлов (256x256).
- **ActionRegistry**: реестр кастомных действий и декодеров.
- **BudgetController/Coalescer**: агрегация мелких мазков (Stroke Coalescing) для снижения IOPS и WA.
- **RecoveryManager**: восстановление по манифесту/WAL.

## Public Contracts
```swift
public protocol UndoCoordinating: Actor {
    /// Инициализирует транзакцию. Возвращает токен для идентификации.
    func begin(label: String) async -> TransactionToken
    
    /// Захват состояния ДО мутации. 
    /// dirtyRect: область, вычисленная StrokeProcessor или LayerManager.
    func captureBefore(_ token: TransactionToken, dirtyRect: CGRect, layerID: UUID) async throws
    
    /// Фиксация состояния ПОСЛЕ мутации. Использует область из captureBefore.
    func captureAfter(_ token: TransactionToken) async throws
    
    func commit(_ token: TransactionToken) async throws
    func abort(_ token: TransactionToken) async
    
    func undo() async throws
    func redo() async throws
}

public protocol UndoableAction: Sendable {
    var actionID: String { get }
    var registryVersion: Int { get }
    var isDeterministic: Bool { get }
    func encode() throws -> Data
    func reapply(in ctx: CanvasStateProvider) async throws
}
```

## Transaction Lifecycle
`open -> captureBefore(dirtyRect) -> captureAfter -> committing -> committed/aborted`

Снимки снимаются по тайлам (256x256), фиксируются версии блоков 64x64 внутри тайла.

## Persistence Strategy
- `.drawproj/History/tx_<id>/` + `manifest.json`.
- Atomic commit: temp -> fsync -> rename -> fsync.
- Снапшоты LZ4, индексы по тайлам.

## Integration Plan
- `DrawingSession` инициирует транзакции через `UndoCoordinator`.
- `LayerManager` отдаёт `LayerStackSnapshot`.
- `StrokeProcessor` — основной драйвер данных: вычисляет `damagedRect` и инициирует `captureBefore`.
- `TileSystem` обеспечивает COW/VRAM на уровне тайлов.
- `DataActor` — LZ4 + I/O.

## Limits & Backpressure
- Лимиты параллельности LZ4 и I/O.
- **Stroke Coalescing**: объединение мелких мазков в одну транзакцию (Temporal/Adaptive).
- Деградация при давлении памяти: агрессивный коалесинг.

### Статус уровня 1
- **Что спроектировано:** транзакции, контракты, persistence, интеграция, лимиты.
- **Риски:** атомарность манифеста, детерминизм reapply, perf/backpressure.
- **Устранение:** two-phase commit, snapshot-redo default, строгие лимиты, детерминизм-контракт.

---

# Уровень 2 — Interaction Design (APPROVED)

## Components & DI
- `UndoCoordinator` зависит только от протоколов (HistoryStore, Snapshotter, ActionRegistry, BudgetController).
- `CanvasStateActor` (read-only) предоставляет `LayerStackSnapshot` вне `@MainActor`.

## Actor Boundaries
- `@MainActor`: `DrawingSession`, `LayerManager`.
- `UndoCoordinator` actor: транзакции и FIFO-очередь (Serial Commit Pipeline).
- `HistoryStore` actor: журнал и persistence.
- `DataActor` actor: LZ4 + disk.
- GPU/TileSystem отделен, доступ через протоколы с использованием `MTLFence`.

## Data Flow Sequences
**Stroke (Оптимизировано)**
1. `DrawingSession` -> `UndoCoordinator.begin()`.
2. `StrokeProcessor` в реальном времени вычисляет `damagedRect` (bounding box сегмента + padding).
3. `StrokeProcessor` -> `UndoCoordinator.captureBefore(token, dirtyRect: damagedRect)`.
4. `UndoCoordinator` делегирует `Snapshotter` захват только **измененных тайлов** (Tile-Level Dirty Tracking).
5. По завершении мазка: `captureAfter` -> async GPU fence -> `commit`.

## Структура UndoCoordinator (Варианты)

### Вариант А: "Serial Pipeline Actor" (Рекомендуемый)
Использование внутреннего `AsyncStream` или серийной очереди задач для обработки событий транзакций.
- **Trade-offs:**
    - **(+) Гарантированный FIFO**: Полностью устраняет гонки в `Global Transaction Index`.
    - **(+) Встроенный Coalescing**: Легко реализовать накопление мелких `damagedRect` по таймеру.
    - **(–) Latency**: Все транзакции (даже не связанные) проходят через единое "горлышко".

### Вариант Б: "Distributed Transaction Registry"
Координатор хранит только реестр состояний (`[Token: State]`), а тяжелая работа (LZ4, Snapshot) происходит параллельно.
- **Trade-offs:**
    - **(+) Максимальный параллелизм**: Подготовка снапшотов не блокирует друг друга.
    - **(–) Риск инконсистентности**: Требует сложной логики "барьеров" при коммите.
    - **(–) Сложность коалесинга**: Логика размывается между процессорами.

**Layer ops**
1. `open` -> `captureBefore` -> apply -> `captureAfter` -> commit.
2. `reapply` допустим только при детерминизме.

**Custom action**
1. ActionRegistry decode/encode.
2. Snapshot-redo, если `!isDeterministic` или бюджет превышен.

## Failure Handling & Pending Policy
- Persist fail -> commit не происходит.
- Undo/Redo во время pending -> ставится в очередь или отменяет pending (политика).

### Статус уровня 2
- **Что спроектировано:** DI, actor-границы, data-flows, pending-policy.
- **Риски:** UI-stall, протечки абстракций, гонки.
- **Устранение:** async GPU fences, read-only CanvasStateActor, протокольные границы.

---

# Уровень 3 — Implementation Theory (APPROVED)

## Algorithms & Data Layout
- **Tile-centric snapshot**: `RootSnapshot -> TileRef -> BlockDelta`.
  - Вместо регионов 4x4 теперь оперируем атомарными тайлами 256x256. Это снижает объем копируемых данных при мелких мазках в 16 раз.
- **Block Delta**: Внутри тайла 256x256 WAL оперирует блоками 64x64 (16 блоков на тайл).
  - При сохранении на диск записываются только "грязные" (dirty) блоки, что минимизирует Write Amplification (WA).
- **Deterministic order**: tiles -> blocks (фиксированный порядок).

## WAL & Crash Recovery (детали)
**WAL record**: header + payload + footer CRC32c.  
**CRC покрывает header+payload**, заголовок валидируется до аллокаций.  
**Bounds**: `max_record`, `max_payload`, контроль overflow.  
**Durable ordering**: DATA fsync до COMMIT/TOMBSTONE.  
**Epoch fence**: `EpochFence(old->new, last_lsn)` + fsync -> активация новой эпохи.

## GC Semantics
`GC_MARK` идемпотентен -> не удаляет.  
`GC_COMMIT` удаляет только при наличии durable `GC_MARK`.  
Crash: `MARK` без `COMMIT` -> ничего не удаляем.

## Scheduling & FIFO Commit Pipeline
- **Serial Dispatcher**: `UndoCoordinator` использует внутренний `AsyncStream` или серийный `TaskQueue` для обработки коммитов. Это гарантирует FIFO-порядок и предотвращает гонки при реентерабельности акторов.
  - Любой `commit()` помещается в очередь и дожидается завершения предыдущего I/O в `HistoryStore`.
- **Adaptive Pressure Control**: 
  - При задержках I/O (Pressure > 0.4) увеличивается агрессивность Stroke Coalescing.
  - При критическом давлении (Pressure > 0.8) активируется режим `ThrottleInput`. Подробнее в `reliability_persistence_specification.md`.
- **Stroke Coalescing (Adaptive Semantic Buffer)**: 
  - Мазки объединяются, пока суммарный Bounding Box не превысит 512x512 или не наступит пауза (idle) > 200мс.
- **Backpressure**: При переполнении очереди коммитов включается режим агрессивного коалесинга.

## GPU Snapshot Strategy (Оптимизировано)
- **Tile-Level Dirty Tracking (TLDT)**: 
  - Использование Dirty Mask Buffer (Bitset), где каждый бит соответствует тайлу 256x256.
  - Шейдер помечает затронутые тайлы. `BlitEncoder` выполняет выборочное копирование (sparse copy) только измененных `MTLRegion`.
- **Pipeline Optimization**: 
  - Single Command Buffer Flow: отрисовка и Blit снапшота в одном буфере.
  - Использование `MTLFence` для обеспечения видимости ресурсов без разрыва конвейера (Bubble Mitigation).
- **Sequential Interleaved Blit**: основной режим для 120 FPS. За счет TLDT объем данных для Blit становится пренебрежимо малым.

## Device Loss
- CPU-state = source of truth.
- Новый epoch, replay до last committed.
- GPU caches пересоздаются из CPU.

### Статус уровня 3
- **Что спроектировано:** WAL протокол, determinism, GPU snapshot, recovery, backpressure.
- **Риски:** WAL truncation, fence overhead, epoch-гонки.
- **Устранение:** CRC+bounds, epoch-fence, batching регионов.

---

# Итоговые гарантии
- Undo/Redo устойчивы к crash и сохраняются в `.drawproj` (export/import).
- **Минимальный Write Amplification**: переход на Tile-centric snapshots и Block Delta снижает нагрузку на IO в десятки раз.
- **120 FPS защищены**: Tile-Level Dirty Tracking и оптимизация энкодеров устраняют GPU Pipeline Bubbles.
- **Гарантированный FIFO**: Serial Commit Pipeline исключает гонки при высокой частоте мазков (1000 Гц).
- **Stroke Coalescing**: Adaptive Semantic Buffer оптимизирует количество транзакций без потери удобства для пользователя.
- Snapshot-redo по умолчанию обеспечивает детерминизм для всех кистей/инструментов.
- Кастомные действия поддерживаются через `ActionRegistry` с versioning.

---

## Рекомендованные тесты
- Crash в середине WAL, truncated record, CRC mismatch.
- Undo/Redo во время pending commit.
- Device loss -> recovery + replay.
- Массовые мазки -> backpressure и FPS.
