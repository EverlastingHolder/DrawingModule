# Drawing Session Specification

> `DrawingSession` — центральный объект управления сессией рисования, обеспечивающий координацию между вводом пользователя, математической обработкой мазка и системой хранения тайлов.

**Status**: ✅ REFINED (Audit V3 2026-01-30)

---

## 1️⃣ Архитектурная декомпозиция (Actor Isolation)

Система разделена на 6 независимых доменов изоляции (Swift 6 Ready):

### 1.1 DrawingSession (@MainActor)
*   **Роль**: Root Orchestrator.
*   **Ответственность**: Владение `CanvasEnvironment`, обработка UI-ввода, координация жизненного цикла кадра (Frame Lifecycle) и связь между акторами.

### 1.2 LayerManager (actor)
*   **Роль**: Logical Hierarchy Manager.
*   **Ответственность**: Управление структурой слоев (Z-index, группы), их метаданными (Blending, Opacity) и иерархией. Формирует `LayerStackSnapshot` для рендерера и Undo-системы. Автоматически управляет дегидратацией скрытых слоев.

### 1.3 UndoManager (actor)
*   **Роль**: Transaction Manager.
*   **Ответственность**: Управление FIFO-очередью транзакций через Serial Commit Pipeline, Stroke Coalescing (500ms), обеспечение консистентности истории.

### 1.4 StrokeProcessor (Actor)
*   **Роль**: Math Engine.
*   **Ответственность**: Интерполяция сплайнов (Catmull-Rom), World-to-Tile биннинг, расчет `damagedRect` для TLDT и предиктивное разворачивание (Predictive Unfolding).

### 1.5 TileSystem (Actor)
*   **Роль**: Resource & Residency Manager.
*   **Ответственность**: Владение `MTLSparseTexture`, управление `MTLHeap` и `MTLResidencySet`, генерация `ResidencySnapshot`, реализация CoW (Copy-on-Write) на уровне тайлов.

### 1.6 DataActor (Actor)
*   **Роль**: I/O Engine.
*   **Ответственность**: LZ4-сжатие, атомарная запись WAL (Write-Ahead Log) и манифеста, фоновая персистентность.

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
2.  Параллельное получение данных (`async let`):
    *   `layerStack = layerManager.getSnapshot()`
    *   `geometry = strokeProcessor.getSnapshot()`
3.  Генерация `ResidencySnapshot` через `tileSystem.prepareResidency(layerStack, geometry)`.

### 3.2 Рендеринг (GPU/Render Thread)
1.  **Input**: Использование синхронного `ResidencySnapshot`, подготовленного заранее.
2.  **Resource Safety**: `ResidencySnapshot` гарантирует резидентность всех необходимых текстур в VRAM.
3.  **Command Encoding**:
    *   Кодирование команд композитинга на основе данных из снимка.
    *   Использование `LayerState.opacity` и `LayerState.blendMode` как констант в Argument Buffers.
4.  **Submission & Cleanup**: 
    *   Отправка команд в `MTLCommandQueue`.
    *   `ResidencySnapshot.onComplete`: Автономное освобождение семафора и возврат ресурсов в пул после завершения GPU-задач.

## 4️⃣ Жизненный цикл мазка (Transactional Stroke)

1.  **Begin**: `DrawingSession` инициирует транзакцию в `UndoManager.begin()`.
2.  **Process & Capture**: 
    *   `StrokeProcessor` вычисляет `damagedRect`.
    *   `UndoManager.captureBefore(token, dirtyRect)` делает снапшот измененных тайлов.
    *   `TileSystem` использует TLDT для минимизации копирования.
3.  **Update**: Рендеринг мазка в `LiveStrokeBuffer`.
4.  **Commit**: 
    *   `captureAfter` захватывает финальное состояние.
    *   `UndoManager.commit()` ставит задачу в Serial Commit Pipeline.
    *   `DataActor` сжимает данные и пишет в WAL.
5.  **Rollback**: `UndoManager.abort()` или `undo()` восстанавливает состояние из тайловых снапшотов.

---

## 4️⃣ Управление системными событиями

### 4.1 App Lifecycle
*   **Background**: `DataActor` выполняет Emergency Flush. `TileSystem` очищает RAM-кэш (Soft LRU).
*   **Termination**: Блокирующий Commit текущего состояния.

### 4.2 Metal Device Loss Recovery
1.  **Stall**: Остановка всех Metal-задач.
2.  **Re-allocation**: Пересоздание `MTLHeap` и запросов нового устройства.
3.  **Re-hydration**: Ленивое восстановление данных из `DataActor`.
4.  **Active Stroke Replay**: `StrokeProcessor` заново генерирует геометрию для незавершенного мазка на основе сохраненных в CPU-памяти точек. Подробнее в `reliability_persistence_specification.md`.

---

## 5️⃣ Сохранение и История (DataActor)

### 5.1 Приоритезация
*   **High Priority**: Undo/Redo (через `UndoManager`) и подгрузка тайлов для вьюпорта (< 8ms).
*   **Low Priority**: Автосохранение и фоновое сжатие.

### 5.2 Atomic Save Protocol
1.  **Staging**: Запись во временный `.tmp` файл.
2.  **Validation**: `fsync()` и проверка контрольной суммы (CRC32c).
3.  **Atomic Swap**: Использование `replaceItemAt` (DataActor) для безопасной замены файла без создания бэкапов.
