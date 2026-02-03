# Drawing Session Specification

> `DrawingSession` — центральный объект управления сессией рисования, обеспечивающий координацию между вводом пользователя, математической обработкой мазка и системой хранения тайлов.

**Status**: ✅ REFINED (Audit V3 2026-01-30)

---

## 1️⃣ Архитектурная декомпозиция (Actor Isolation)

Система разделена на 4 независимых домена изоляции (Swift 6 Ready):

### 1.1 DrawingSession (@MainActor)
*   **Роль**: Оркестратор и владелец состояния.
*   **Ответственность**: Владение `CanvasEnvironment` и `LayerManager`, координация UI, `UndoManager`.
*   **Синхронизация**: Формирует `LayerStackSnapshot` перед каждым кадром и передает его в `Compositor`.

### 1.2 LayerManager (@MainActor)
*   **Роль**: Менеджер структуры документа.
*   **Ответственность**: Управление стеком слоев, их метаданными (Blending, Opacity) и иерархией. Подробнее в `layer_system_specification.md`.

### 1.3 StrokeProcessor (Actor)
*   **Роль**: Фоновый вычислитель геометрии.
*   **Ответственность**: Интерполяция сплайнов (**Centripetal Catmull-Rom** в `Double`), 2-Tier Region Binning, генерация **Zero-Copy** буферов.

### 1.3 TileSystem (Actor)
*   **Роль**: **Residency Manager** и менеджер ресурсов GPU.
*   **Ответственность**: Управление `MTLSparseTexture`, маппинг страниц, контроль лимита VRAM (512MB).

### 1.4 DataActor (Actor)
*   **Роль**: Асинхронный I/O и компрессия.
*   **Ответственность**: LZ4-сжатие, атомарная запись на диск, обработка Memory Pressure.

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

## 4️⃣ Жизненный цикл мазка (Stroke Transaction)

1.  **Begin**: Захват текущих состояний тайлов. Создание Shadow-копий для `LiveBuffer`.
2.  **Process**: Асинхронная интерполяция и биннинг в `StrokeProcessor`.
3.  **Residency Update**: `TileSystem` подготавливает необходимые страницы Sparse-текстур.
4.  **Update**: Рендеринг в `LiveStrokeBuffer`.
5.  **Commit**: 
    *   **Delta Transfer**: Измененные данные уходят в `DataActor`.
    *   **Persistence**: LZ4-сжатие и запись в фоне (Low Priority).
6.  **Rollback**: Очистка временных буферов без слияния с основным холстом.

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
