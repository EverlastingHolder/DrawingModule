# План реализации Фазы 5: DataActor & Persistence (LZ4)

**Версия:** 1.3 (2026-01-31)
**Статус:** ✅ Одобрено (PLAN_REFINED)
**Цель фазы:** Реализация надежного асинхронного хранилища с LZ4-компрессией, защитой от сбоев и поддержкой Export-Streaming режима.

---

## L1: Architectural Overview (Архитектурный обзор)
*Разработано lead_architect*

### 1. Роль DataActor
- Изолированный домен для I/O. Реализует **Write-Behind Caching**.
- **Backpressure**: Ограничение очереди записи (256MB) и чтения (128MB) для защиты стабильности системы.
- **Priority**: Использование `UIBackgroundTaskIdentifier` для гарантированного завершения записи при уходе в фон.

### 2. Export-Streaming Mode
- **Trigger**: Активируется при экспорте сверхбольших холстов (32k+).
- **Logic**: `TileSystem` отключает LRU-вытеснение для экспортируемых регионов, а `DataActor` переходит в режим последовательного стриминга тайлов с диска в RAM с контролем Backpressure (128MB limit).

---

## L2: Technical Deep-Dive (Технические детали)
*Разработано systems_engineer*

### 1. Спецификация формата .drawregion
- **Magic Number**: `DRGN` (4 bytes).
- **Header**: Version, RegionCoord.
- **Index Table**: 16 слотов `(offset, compressedLength)`. Защищен CRC32.
- **Payload**: Независимые LZ4-блоки данных тайлов.

### 2. Режимы работы и Backpressure
- **Export-Streaming Mode**:
  - Активируется при экспорте больших холстов (32k+).
  - `TileSystem` отключает LRU-вытеснение для экспортируемых регионов.
  - Используется выделенный поток чтения для минимизации влияния на UI.
- **Memory Backpressure**:
  - Пауза очереди чтения, если объем несжатых данных в RAM превышает **128MB**.
  - Предотвращает переполнение памяти (Thrashing) при интенсивном I/O.

### 3. Атомарность и Compaction
- **Atomic Save**: Запись в `.tmp` -> `fsync()` (файл + родительская директория) -> `rename()`.
- **Compaction (Дефрагментация)**: 
  - Триггер: > 40% устаревших данных или файл > 50MB.
  - **Inhibition**: Запрет запуска Compaction во время активного сеанса рисования (`DrawingSession.isActive`).

---

## L3: Implementation Steps (Список задач)

### 1. Инфраструктура сжатия и CRC
- [ ] **Task 5.1**: Интеграция `liblz4` и создание Swift-обертки `LZ4Wrapper`.
- [ ] **Task 5.2**: Реализация `CRC32` утилиты через `Accelerate.framework`.
- [ ] **Task 5.3**: Определение бинарных моделей заголовка и индекса (Magic `DRGN`).

### 2. DataActor и I/O
- [ ] **Task 5.4**: Реализация `DataActor` с очередями приоритетов и логикой `Memory Backpressure` (128MB limit).
- [ ] **Task 5.5**: Реализация `Export-Streaming Mode` (отключение LRU, dedicated stream).
- [ ] **Task 5.6**: Реализация `SafeFileWriter` (tmp + fsync + rename).
- [ ] **Task 5.7**: Реализация `UIBackgroundTaskIdentifier` интеграции.

### 3. Compaction Manager
- [ ] **Task 5.8**: Анализатор фрагментации региональных файлов.
- [ ] **Task 5.9**: Реализация логики Compaction с проверкой состояния `DrawingSession`.

---

## Verification Matrix (Критерии успеха)
*Проверено system_validator*

1. **Integrity**: Нулевая потеря данных при внезапном выключении (подтверждено Magic `DRGN` и fsync/rename).
2. **Backpressure**: Система сохраняет стабильность при чтении > 1GB данных благодаря лимиту 128MB.
3. **Speed**: Декомпрессия тайла < 0.3мс.
4. **Efficiency**: LZ4-сжатие снижает объем на 60-80%.

---

## Вердикт Валидатора
**PLAN_STABLE** ✅
План доработан: изменен Magic Number на `DRGN`, добавлена логика Backpressure и Export-Streaming согласно Blueprint 1.1.
