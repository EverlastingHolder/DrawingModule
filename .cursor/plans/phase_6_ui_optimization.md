# План реализации Фазы 6: UI Layer & Optimization

**Версия:** 1.2 (2026-01-31)
**Статус:** ✅ Одобрено (PLAN_REFINED)
**Цель фазы:** Минимизация задержки ввода через предиктивный рендеринг и интеграция `MetalDrawView` с системой снимков слоев.

---

## L1: Architectural Overview (Архитектурный обзор)
*Разработано lead_architect*

### 1. Цикл рендеринга и Снимки
- **MetalDrawView**: Подписывается на обновления от `DrawingSession`.
- **LayerStackSnapshot**: Вью получает иммутабельный снимок состояния слоев для каждого кадра. Это позволяет рендерить текущее состояние без блокировки акторов.
- **Sync**: `DispatchSemaphore(value: 3)` для Triple Buffering, предотвращающий переполнение очереди GPU.

---

## L2: Technical Deep-Dive (Технические детали)
*Разработано systems_engineer & metal_specialist*

### 1. Predicted Touches (Ephemeral Overlay)
- **Ephemeral Overlay**: Предиктивные точки отрисовываются в отдельном "эфемеровом" слое поверх основного мазка.
- **Data Flow**: `UIEvent.predictedTouches` передаются напрямую в `MetalDrawView`. Они не попадают в `DrawingSession` или `UndoManager`.
- **Rendering**: Предиктивный мазок отрисовывается в `Mask Pass` (Memoryless) и сбрасывается в каждом кадре.

### 2. Viewport & Gesture Optimization
- **Double Precision**: Все трансформации (Zoom, Pan) хранятся в `Double`.
- **Relative-to-Center**: При передаче в GPU координаты приводятся к `Float` относительно центра вьюпорта для сохранения точности.
- **Memory Pressure Priority**:
  1. `DataActor`: Сброс RAM-кэша (LZ4 блоки).
  2. `TileSystem`: Unmap невидимых тайлов и освобождение `MTLHeap`.
  3. Деградация качества (Downsampled Preview для фоновых слоев).

---

## L3: Implementation Steps (Список задач)

### 1. View & Viewport
- [ ] **Task 6.1**: Реализовать `MetalDrawView` (MTKViewDelegate), интегрированный с `DrawingSessionProtocol`.
- [ ] **Task 6.2**: Реализовать отрисовку кадра на основе `LayerStackSnapshot`.
- [ ] **Task 6.3**: Настройка `CADisplayLink` для 120Hz (ProMotion) с адаптивным интервалом.

### 2. Жесты и Ввод
- [ ] **Task 6.4**: Реализовать `GestureManager` (Anchor Point Zoom, Inertial Pan) с использованием `Double`.
- [ ] **Task 6.5**: Реализовать `Ephemeral Overlay` для отрисовки `UIEvent.predictedTouches`.
- [ ] **Task 6.6**: Реализация `DispatchSemaphore(3)` для управления нагрузкой на GPU.

### 3. Оптимизация и Память
- [ ] **Task 6.7**: Реализация системного обработчика Memory Pressure с каскадной очисткой (DataActor -> TileSystem).
- [ ] **Task 6.8**: Бенчмаркинг Input-to-Display задержки (цель < 15мс на iPad Pro).

---

## Verification Matrix (Критерии успеха)
*Проверено system_validator*

1. **Latency**: Эффект "мокрого следа" за счет корректной реализации Ephemeral Overlay.
2. **Smoothness**: Стабильные 120 FPS без микро-фризов на MainActor при активном сжатии в фоне.
3. **Actor Integrity**: Вью использует только Sendable снимки (`LayerStackSnapshot`).

---

## Вердикт Валидатора
**PLAN_STABLE** ✅
План синхронизирован с Blueprint 1.1. Внедрена поддержка `LayerStackSnapshot` и уточнены детали работы с предиктивным вводом.
