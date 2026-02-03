# План реализации Фазы 2: Tile Storage & Virtualization

**Версия:** 1.3 (2026-01-31)
**Статус:** ✅ Одобрено (PLAN_REFINED)
**Цель фазы:** Управление виртуальной памятью GPU (Sparse Textures) и физической памятью (Unified Heap) для работы с бесконечным холстом через `TileSystem` (Actor).

---

## L1: Architectural Overview (Архитектурный обзор)
*Разработано lead_architect*

### 1. Границы ответственности
- **LayerManager (@MainActor)**: Владелец структуры слоев, формирует декларативный `VisibilityManifest` и метаданные.
- **TileSystem (Actor)**: Единый оркестратор виртуализации и резидентности. Владеет `MTLSparseTexture`, `MTLHeap` и управляет таблицей страниц.
- **Global Occupancy Map (GOM)**: Битовая маска занятости тайлов для оптимизации композитинга.

### 2. Связи
- `TileSystem` получает манифест видимости от `LayerManager`.
- **Async Mapping**: Маппинг страниц Sparse Textures выполняется через `MTLResourceStateCommandEncoder`.
- **Synchronization**: Использование `MTLEvent` для гарантии того, что маппинг завершен до начала использования тайла в `DrawingSession`.

---

## L2: Technical Deep-Dive (Технические детали)
*Разработано systems_engineer & metal_specialist*

### 1. Решение проблемы 1px щелей (Integer-Based Geometry)
- Все расчеты границ тайлов и биннинга выполняются в целых числах (`Int`).
- Шейдеры получают `uint2 tileID` и `float2 localPos` [0..1].
- Мировые координаты восстанавливаются как `(tileID * size) + (localPos * size)`, что гарантирует идентичность границ соседних тайлов.

### 2. GPU Virtualization & Memory Management
- **MTLSparseTexture Tier 2**: 256x256 пикселей (512KB), страницы по 64KB. Поддержка разреженных текстур уровня Tier 2 для эффективного управления памятью.
- **Unified Heap Mapping**: Использование единого `MTLHeap` для всех слоев. Это минимизирует фрагментацию VRAM и упрощает управление жизненным циклом тайлов.
- **Unified Page Table**: Глобальный `MTLBuffer` с метаданными всех тайлов всех слоев.
- **Residency Checking**: В шейдерах используется функция `check_residency` (MSL) для безопасного обращения к страницам Sparse-текстур.

### 3. Алгоритмы и Приоритеты
- **Layer Priority (4 уровня)**:
  1. **Active Layer**: Текущий редактируемый слой (иммунитет к вытеснению).
  2. **Visible Layers**: Видимые слои во вьюпорте (Weighted LRU).
  3. **Background Layers**: Видимые слои вне вьюпорта или перекрытые слои (LRU).
  4. **Invisible Layers**: Скрытые пользователем слои (LRU). Первый кандидат на выгрузку.
- **Weighted LRU**: Приоритет $P = (Visibility \times 1000) + (LayerPriority \times 500) + (BrushProximity \times 200) + \frac{1}{\Delta T + 1}$.
- **Mapping Batching**: Накопление запросов на маппинг (до 16 тайлов) для отправки одной транзакцией через `MTLResourceStateCommandEncoder`.
---

## L3: Implementation Steps (Список задач)

### 1. Базовые структуры и GOM
- [ ] **Task 2.1**: Реализовать `TileCoord` (упаковка layerID + x + y) и `CanvasGeometry`.
- [ ] **Task 2.2**: Реализовать `GlobalOccupancyMap` (иерархическая битовая маска).
- [ ] **Task 2.3**: Реализовать `TileDescriptorPool` для передачи метаданных в Metal.

### 2. Менеджеры памяти и LRU
- [ ] **Task 2.4**: Реализовать `ResidencyManager` (Actor) и `LRUPriorityQueue`.
- [ ] **Task 2.5**: Реализовать State Machine для состояний тайла (`Empty -> Allocating -> Ready`).
- [ ] **Task 2.6**: Механизм Hard Limit Enforcement (блокировка записи при переполнении VRAM).

### 3. Metal Sparse & Batching
- [ ] **Task 2.7**: Настройка `MTLHeap` и `MTLSparseTexture` (Tier 2).
- [ ] **Task 2.8**: Реализация `MappingBatcher` для групповых операций `updateTextureMappings`.
- [ ] **Task 2.9**: Реализация `SparseResidency.metal` (функции `check_residency`).

---

## Verification Matrix (Критерии успеха)
*Проверено system_validator*

1. **Memory Budget**: Лимит 512МБ VRAM позволяет держать 1024 активных тайла.
2. **Gapless Rendering**: Отсутствие щелей на стыках тайлов подтверждено тестами на Integer Math.
3. **Batching Efficiency**: Маппинг 16 тайлов занимает < 0.5мс на GPU.

---

## Вердикт Валидатора
**PLAN_STABLE** ✅
Рекомендация: использовать `MTLEvent` для синхронизации маппинга с началом рендеринга мазка.
