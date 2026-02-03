# План реализации Фазы 3: Metal Render Pipeline

**Версия:** 1.2 (2026-01-31)
**Статус:** ✅ Одобрено (PLAN_REFINED)
**Цель фазы:** Создание высокопроизводительного HDR-конвейера отрисовки с использованием `LayerStackSnapshot` и оптимизацией TBDR.

---

## L1: Architectural Overview (Архитектурный обзор)
*Разработано lead_architect*

### 1. Потоковая модель
- **Preparation Zone (Async Actors)**: `StrokeProcessor` (геометрия) и `TileSystem` (резидентность) подготавливают ресурсы в фоне.
- **Snapshot Zone (Sync Bridge)**: `DrawingSession` формирует иммутабельный `LayerStackSnapshot`.
- **Execution Zone (RenderActor)**: Выделенный серийный актор для кодирования команд Metal. Выполняет `semaphore.wait()` для Triple Buffering, не блокируя MainActor.

### 2. Безопасность ресурсов (ResourcePurgeManager)
- Система отложенного удаления (Deferred Deletion). Ресурсы физически удаляются только через 3 кадра после пометки, гарантируя завершение всех GPU-операций.

---

## L2: Technical Deep-Dive (Технические детали)
*Разработано metal_specialist & systems_engineer*

### 1. Triple Buffering & Frame Pacing
- **Синхронизация**: `DispatchSemaphore(value: 3)`.
- **Unified Memory**: `MTLStorageMode.shared` для Zero-copy передачи данных. Выравнивание 256 байт для всех смещений буферов.

### 2. Single-pass TBDR (Imageblocks)
- **Programmable Blending**: Использование `[[color(0)]]` в SRAM (Tile Memory / Imageblocks) Apple Silicon для композитинга всех слоев без промежуточных записей в VRAM.
- **HDR Pipeline**: Формат `RGBA16Float` (8 байт на пиксель).
- **Argument Buffers (Tier 2)**: Группировка всех ресурсов кисти и передача массива текстур всех слоев для доступа по `storageID` в одном вызове отрисовки.
- **GOM Optimization**: Фрагментный шейдер композитора проверяет бит в Global Occupancy Map перед вызовом `sample`.

---

## L3: Implementation Steps (Список задач)

### 1. Инфраструктура и Буферы
- [ ] **Task 3.1**: Реализовать `ConstantBufferPool` (кольцевой буфер с выравниванием 256 байт).
- [ ] **Task 3.2**: Реализовать `FrameOrchestrator` и `RenderActor`, интегрированные с `LayerStackSnapshot`.
- [ ] **Task 3.3**: Реализовать `ResourcePurgeManager` (Deferred Deletion).

### 2. Шейдеры и Пайплайны
- [ ] **Task 3.4**: Реализовать `fragment_brush_accumulate` с Programmable Blending.
- [ ] **Task 3.5**: Реализовать `fragment_composite_layers` с поддержкой Tier 2 AB и GOM-фильтрации.
- [ ] **Task 3.6**: Настройка PSOs для Brush Pass (Memoryless) и Composite Pass.

### 3. Мониторинг
- [ ] **Task 3.7**: Внедрение `os_signpost` для замера CPU Wait и GPU Frame Time.
- [ ] **Task 3.8**: Валидация в Metal Debugger на отсутствие Store Actions для промежуточных текстур.

---

## Verification Matrix (Критерии успеха)
*Проверено system_validator*

1. **Bandwidth Efficiency**: Минимальное использование шины памяти за счет SRAM-композитинга.
2. **Actor Safety**: Рендеринг полностью изолирован от мутируемого состояния через снимки.
3. **Scalability**: Поддержка 50+ слоев без деградации FPS через Tier 2 Argument Buffers.

---

## Вердикт Валидатора
**PLAN_STABLE** ✅
План обновлен для работы с `LayerStackSnapshot`. Внедрена поддержка Tier 2 Argument Buffers и оптимизация GOM.
