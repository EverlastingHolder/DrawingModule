# План реализации Фазы 4: DrawingSession & Stroke Transaction

**Версия:** 1.2 (2026-01-31)
**Статус:** ✅ Одобрено (PLAN_REFINED)
**Цель фазы:** Оркестрация транзакции мазка через `@MainActor DrawingSession` и реализация попиксельного Undo/Redo через SnapshotPool с использованием иммутабельных снимков.

---

## L1: Architectural Overview (Архитектурный обзор)
*Разработано lead_architect*

### 1. Модель "Reactive-Pull" & Actors
- **DrawingSession (@MainActor)**: Главный оркестратор. Владеет состоянием текущего мазка, взаимодействует с UI и управляет жизненным циклом транзакции.
- **StrokeProcessor (Actor)**: Параллельная обработка точек (Catmull-Rom) и генерация геометрии.
- **TileSystem (Actor)**: Подготовка резидентности тайлов для области рисования.
- **LayerStackSnapshot**: Иммутабельный снимок слоев, передаваемый для рендеринга, исключающий Actor Hopping.

### 2. Оркестрация мазка (Stroke Handshake)
- `DrawingSession` получает ввод, батчует его и отправляет в `StrokeProcessor`.
- `StrokeProcessor` возвращает геометрию.
- `DrawingSession` запрашивает у `TileSystem` резидентность необходимых тайлов.
- По завершении подготовки, `DrawingSession` инициирует отрисовку кадра с актуальным `LayerStackSnapshot`.

---

## L2: Technical Deep-Dive (Технические детали)
*Разработано systems_engineer & lead_architect*

### 1. SnapshotPool для CoW (Copy-on-Write)
- **Хранилище**: Использование `MTLBuffer` (RGBA16Float) для снимков Undo. Это снижает VRAM overhead и упрощает LZ4-сжатие в `DataActor`.
- **Copy-on-Write**: Перед первой модификацией тайла в транзакции выполняется `kernel copy_texture_to_buffer` во временный буфер из пула.
- **ContinuousClock**: Использование `ContinuousClock.Instant` для точной временной метки снимков и синхронизации событий.

### 2. Undo/Redo Инфраструктура
- **Snapshot-per-Tile**: Сохранение дельт только измененных тайлов.
- **Иерархия кэша**:
  - L1 (VRAM): Активные буферы снимков в `SnapshotPool`.
  - L2 (RAM LZ4): Сжатые дельты последних мазков (DataActor).
  - L3 (Disk): Архивы `.drawundo`.

---

## L3: Implementation Steps (Список задач)

### 1. DrawingSession & Transaction logic
- [ ] **Task 4.1**: Реализовать `DrawingSessionProtocol` с методами `beginStroke`, `updateStroke`, `endStroke` (async).
- [ ] **Task 4.2**: Реализовать логику биннинга (Bounding Box -> Tile IDs) для определения области влияния мазка.
- [ ] **Task 4.3**: Интеграция `ContinuousClock` для меток времени в `LayerStackSnapshot`.

### 2. SnapshotPool & CoW
- [ ] **Task 4.4**: Реализовать `SnapshotPool` (менеджер переиспользования `MTLBuffer`) и CoW-механизм на основе `TileSystem`.
- [ ] **Task 4.5**: Реализовать кернелы копирования между текстурами тайлов и буферами снимков.

### 3. Undo/Redo System
- [ ] **Task 4.6**: Реализовать `UndoAction` (набор ID измененных тайлов и их снимков).
- [ ] **Task 4.7**: Асинхронная передача снимков в `DataActor` для LZ4-сжатия и хранения в RAM-кэше.
- [ ] **Task 4.8**: Unit-тесты на цепочку Stroke -> Undo -> Redo с проверкой консистентности `LayerStackSnapshot`.

---

## Verification Matrix (Критерии успеха)
*Проверено system_validator*

1. **Performance**: Оркестрация между `MainActor` и фоновыми акторами не вносит задержек > 2мс.
2. **Actor Safety**: Полное отсутствие Data Races при передаче `LayerStackSnapshot`.
3. **Correctness**: Попиксельное совпадение состояния холста после Undo/Redo.

---

## Вердикт Валидатора
**PLAN_STABLE** ✅
План обновлен в соответствии с Blueprint 1.1: введена работа с `LayerStackSnapshot` и использование `ContinuousClock`. Оркестрация акторов соответствует новой иерархии.
