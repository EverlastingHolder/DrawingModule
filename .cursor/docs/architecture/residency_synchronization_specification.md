# Residency Synchronization Specification: Zero-Latency Sync

**Status**: ✅ PROPOSED (Hardening Phase: Zero-Latency Sync)
**Version**: 1.0 (2026-02-04)

## 1. Концепция Zero-Latency Sync

Основная проблема высокопроизводительных систем на Swift 6 — задержки при переключении контекста (Actor Hopping). Чтобы рендерер мог работать на частоте 120 FPS без блокировок, он должен иметь доступ ко всем необходимым ресурсам GPU (текстурам, буферам) без использования `await`.

Этот документ описывает механизм **Handshake**, который позволяет `@MainActor` и фоновым акторам подготавливать данные для кадра заранее.

---

## 2. ResidencySnapshot

`ResidencySnapshot` — это иммутабельный `Sendable` объект, который является «картой ресурсов» для конкретного кадра.

### 2.1 Структура данных

```swift
public struct ResidencySnapshot: Sendable {
    /// Уникальный идентификатор кадра (Frame ID)
    public let frameIndex: UInt64
    
    /// Маппинг активных тайлов для текущего вьюпорта.
    /// TileKey = (LayerID, TileCoord)
    /// StorageID = Индекс в Argument Buffer или физический дескриптор.
    public let tileMapping: [TileKey: StorageID]
    
    /// Ссылка на набор ресурсов, которые ДОЛЖНЫ быть резидентны в VRAM.
    /// Используется тройная буферизация (Triple Buffering) для исключения Race Conditions с GPU.
    public let residencySet: MTLResidencySet
    
    /// Снимок состояния слоев, связанный с этим кадром.
    public let layerStack: LayerStackSnapshot
    
    /// Снимок геометрии активных мазков для рендеринга без await.
    public let geometry: GeometrySnapshot
    
    /// Глобальная битовая маска заполненности (Occupancy) для быстрого отсечения.
    public let occupancyMap: GlobalOccupancyMap
    
    /// Ресурсы, необходимые для кастомных эффектов в текущем кадре.
    public let customEffectResources: [MTLResource]
    
    /// Дескрипторы Argument Buffers для передачи в инкодер.
    public let effectArgumentBuffers: [UUID: MTLBuffer]
}

/// Иммутабельный снимок геометрии от StrokeProcessor.
public struct GeometrySnapshot: Sendable {
    /// Активные буферы мазков (MTLBuffer).
    /// Metal ресурсы потокобезопасны для использования в командах.
    public let strokeBuffers: [UUID: MTLBuffer]
    public let damagedRects: [UUID: CGRect]
}

public struct TileKey: Hashable, Sendable {
    public let layerID: UUID
    public let x: Int32
    public let y: Int32
}

public typealias StorageID = UInt16
```

### 2.2 Immutable Guarantee
`ResidencySnapshot` не содержит живых ссылок на акторы. Все данные в нем — примитивы или потокобезопасные объекты Metal (`MTLResidencySet`). Это позволяет рендереру читать его напрямую из любого потока.

---

## 3. Механизм Handshake (Рукопожатие)

Процесс синхронизации разделен на 3 фазы, выполняемые в рамках одного цикла `DisplayLink`.

### Фаза 1: Запрос (Main Thread / @MainActor)
1. `DrawingSession` получает сигнал начала кадра.
2. Он собирает `LayerStackSnapshot` (порядок и свойства слоев).
3. Формирует `ViewContext` (текущий Viewport, Scale).
4. Вызывает асинхронный запрос к `TileSystem`: `prepareResidency(for: viewContext, layers: layerStack)`.

### Фаза 2: Подготовка (TileSystem Actor)
1. `TileSystem` определяет список необходимых тайлов на основе `ViewContext` и `LayerStackSnapshot`.
2. Выполняет `unmap` старых страниц и `map` новых (Sparse Texture Management).
3. Добавляет новые ресурсы в `MTLResidencySet`.
4. Генерирует новый `ResidencySnapshot`.
5. Возвращает его `@MainActor`.

### Фаза 3: Рендеринг (Render Thread)
1. `@MainActor` передает `LayerStackSnapshot` и `ResidencySnapshot` в `Compositor` (Renderer).
2. Рендерер:
    - **НЕ использует await**.
    - Читает `tileMapping` для получения `StorageID`.
    - Использует `residencySet` для гарантии наличия ресурсов в памяти.
    - Кодирует команды отрисовки.

---

## 4. Безопасность GPU-памяти и Синхронизация

### 4.1 Triple Buffering для ResidencySet
Для исключения Race Conditions, когда `TileSystem` модифицирует набор ресурсов, который еще используется GPU для предыдущего кадра:
1. **Pool**: `TileSystem` владеет пулом из 3-х `MTLResidencySet`.
2. **Rotation**: 
    - **Frame N**: GPU читает из `Set_A`.
    - **Frame N+1**: `TileSystem` готовит `Set_B`.
    - **Frame N+2**: `Set_C` находится в очереди на очистку (Retirement).
3. **Handshake**: `ResidencySnapshot` всегда несет в себе ссылку на "замороженный" (committed) набор для конкретного кадра.

### 4.2 Deferred Eviction (Retirement Queue)
Физическое освобождение памяти (`unmap`) и переиспользование `StorageID` происходит по принципу **GPU Flight Safety**:
*   Когда тайл выгружается из VRAM или `StorageID` освобождается, он не удаляется мгновенно.
*   Он помещается в **Retirement Queue** со счетчиком кадров (обычно 3 кадра).
*   Только после того, как счетчик обнулится (подтверждая, что GPU завершил все операции с этим ресурсом), ID возвращается в пул, а страница размапливается.

### 4.3 MTLFence & Sync
Использование `MTLFence` внутри командного буфера гарантирует, что `Snapshotter` (в рамках Undo) захватит данные только ПОСЛЕ того, как `Compositor` завершит отрисовку мазка в этом кадре. Это предотвращает "разрывы" конвейера (Pipeline Bubbles).

---

## 5. Связь с MTLResidencySet (Usage)

- **Latency**: Подготовка `ResidencySnapshot` в `TileSystem` занимает < 2ms (в основном работа с Bitsets и Sparse Mapping).
- **Zero-Hopping**: После получения снимка, рендерер имеет все данные "на руках".
- **Memory**: Лимит 512MB контролируется внутри `TileSystem` через LRU. Если тайл не попал в `ResidencySnapshot`, он не будет отрисован, что защищает от GPU Faults при попытке доступа к нерезидентной памяти Sparse-текстуры.

---