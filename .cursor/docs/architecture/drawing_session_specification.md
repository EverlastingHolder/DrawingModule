# Drawing Session Specification

> `DrawingSession` — центральный объект управления сессией рисования, обеспечивающий координацию между вводом пользователя, математической обработкой мазка и системой хранения тайлов.

**Status**: ✅ REFINED (Audit V3 2026-01-30)

---

## 1️⃣ Архитектурная декомпозиция (Actor Isolation)

Система разделена на 5 независимых доменов изоляции (Swift 6 Ready):

### 1.1 DrawingSession (@MainActor)
*   **Роль**: Оркестратор и владелец состояния.
*   **Ответственность**: Владение `CanvasEnvironment`, `LayerManager` и `UndoCoordinator`, координация UI.
*   **Синхронизация**: Формирует `LayerStackSnapshot` перед каждым кадром и передает его в `Compositor`.

### 1.2 UndoCoordinator (Actor)
*   **Роль**: Координатор транзакций и истории.
*   **Ответственность**: Управление жизненным циклом транзакций (begin/commit), Stroke Coalescing, обеспечение FIFO через Serial Commit Pipeline.

### 1.3 LayerManager (@MainActor)
*   **Роль**: Менеджер структуры документа.
*   **Ответственность**: Управление стеком слоев, их метаданными (Blending, Opacity) и иерархией. Предоставляет снимки состояния для `UndoCoordinator`.

### 1.4 StrokeProcessor (Actor)
*   **Роль**: Фоновый вычислитель геометрии и драйвер Undo-событий.
*   **Ответственность**: Интерполяция сплайнов, 2-Tier Region Binning, расчет `damagedRect` для `captureBefore`.

### 1.5 TileSystem (Actor)
*   **Роль**: Residency Manager и менеджер ресурсов GPU.
*   **Ответственность**: Управление `MTLSparseTexture`, маппинг страниц, Tile-Level Dirty Tracking (TLDT) для оптимизации снапшотов.

### 1.6 DataActor (Actor)
*   **Роль**: Асинхронный I/O и компрессия.
*   **Ответственность**: LZ4-сжатие, атомарная запись WAL и манифеста, обработка HistoryStore.

---

## 2️⃣ Окружение холста (CanvasEnvironment)

```swift
public struct CanvasEnvironment: Sendable, Equatable {
    public let size: MTLSize
    public let scaleFactor: CGFloat
    public let pixelFormat: MTLPixelFormat = .rgba16Float
    
    public let useSparseTextures: Bool = true
    public let maxResidentMemoryMB: Int = 512
    
    public let tileSize: Int = 256
    public let regionSize: Int = 4 
}
```

---

## 3️⃣ Жизненный цикл кадра и синхронизация (Frame Lifecycle)

Для исключения **Actor Hopping** и обеспечения 120 FPS, поток рендеринга никогда не запрашивает данные у `@MainActor` во время отрисовки.

### 3.1 Подготовка кадра (Main Thread)
1.  Обработка пользовательского ввода.
2.  Обновление `LayerManager` (изменение видимости, прозрачности).
3.  Генерация `LayerStackSnapshot`.

### 3.2 Рендеринг (GPU/Render Thread)
1.  **Input**: Получение `LayerStackSnapshot` и текущих геометрических данных от `StrokeProcessor`.
2.  **Resource Check**: Запрос у `TileSystem` подтверждения готовности (Residency) тайлов для всех `storageID` из снимка.
3.  **Command Encoding**:
    *   Кодирование команд композитинга на основе данных из снимка.
    *   Использование `LayerState.opacity` и `LayerState.blendMode` как констант в Argument Buffers.
4.  **Submission**: Отправка команд в `MTLCommandQueue`.

## 4️⃣ Жизненный цикл мазка (Transactional Stroke)

1.  **Begin**: `DrawingSession` инициирует транзакцию в `UndoCoordinator.begin()`.
2.  **Process & Capture**: 
    *   `StrokeProcessor` вычисляет `damagedRect`.
    *   `UndoCoordinator.captureBefore(token, dirtyRect)` делает снапшот измененных тайлов.
    *   `TileSystem` использует TLDT для минимизации копирования.
3.  **Update**: Рендеринг мазка в `LiveStrokeBuffer`.
4.  **Commit**: 
    *   `captureAfter` захватывает финальное состояние.
    *   `UndoCoordinator.commit()` ставит задачу в Serial Commit Pipeline.
    *   `DataActor` сжимает данные и пишет в WAL.
5.  **Rollback**: `UndoCoordinator.abort()` или `undo()` восстанавливает состояние из тайловых снапшотов.

---

## 4️⃣ Управление системными событиями

### 4.1 App Lifecycle
*   **Background**: `DataActor` выполняет Emergency Flush. `TileSystem` очищает RAM-кэш (Soft LRU).
*   **Termination**: Блокирующий Commit текущего состояния.

### 4.2 Metal Device Loss Recovery
1.  **Stall**: Остановка всех Metal-задач.
2.  **Re-allocation**: Пересоздание `MTLHeap` и запросов нового устройства.
3.  **Re-hydration**: Ленивое восстановление данных из `DataActor`.

---

## 5️⃣ Сохранение и История (DataActor)

### 5.1 Приоритезация
*   **High Priority**: Undo/Redo и подгрузка тайлов для вьюпорта (< 8ms).
*   **Low Priority**: Автосохранение и фоновое сжатие.

### 5.2 Atomic Save Protocol
1.  **Staging**: Запись во временный `.tmp` файл.
2.  **Validation**: `fsync()` и проверка контрольной суммы (CRC32).
3.  **Atomic Swap**: Использование `replaceItemAt` для безопасной замены файла.
