# Layer System Specification for DrawEngine

> Этот документ описывает архитектуру слоев, управление их состоянием и логику композитинга в DrawEngine.

**Status**: ✅ REFINED (Audit V4 2026-01-31 - Production Ready)

---

## 1️⃣ Архитектурный гибрид

Система слоев разделена на два уровня ответственности для обеспечения производительности и чистоты кода.

### 1.1 Logical Level (`LayerManager` / `@MainActor`)
*   **Роль**: Владелец структуры документа и метаданных.
*   **Ответственность**:
    *   Порядок слоев (Z-Index).
    *   Группировка слоев (Tree structure).
    *   Метаданные: `Opacity`, `Visibility`, `BlendMode`, `IsLocked`.
    *   Специфические свойства: `Clipping Mask`, `Adjustment Layer` данные.
*   **Связь**: Каждому логическому слою соответствует уникальный `LayerID` (UUID или Int).

### 1.2 Physical Level (`TileSystem` / `actor`)
*   **Роль**: Поставщик ресурсов и менеджер памяти GPU.
*   **Ответственность**:
    *   Владение `MTLSparseTexture` для каждого `LayerID`.
    *   Менеджмент `MTLHeap` (Shared Pool для всех слоев).
    *   Глобальное вытеснение (LRU) — страницы вытесняются из любых слоев на основе общей активности.
*   **Связь**: Оперирует данными через `LayerID`. Не знает о "порядке" слоев или их прозрачности.

---

## 2️⃣ Модель данных и Concurrency

### 2.1 Layer State (Snapshot)
Для соблюдения требований Swift 6 и исключения "Actor Hopping", состояние слоя разделено на изменяемый объект управления и неизменяемый снимок состояния.

```swift
public enum BlendMode: String, Sendable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn
}

/// Неизменяемый снимок состояния слоя для потока рендеринга.
public struct LayerState: Sendable, Identifiable {
    public let id: UUID
    public let storageID: UInt16
    public let name: String
    public let isVisible: Bool
    public let opacity: Float
    public let blendMode: BlendMode
    
    // Иерархия и маски
    public let parentID: UUID?
    public let isClippingMask: Bool
    
    // Данные для корректирующих слоев (Adjustment Layers)
    public let adjustmentData: [String: Sendable]? 
    
    public init(
        id: UUID,
        storageID: UInt16,
        name: String,
        isVisible: Bool,
        opacity: Float,
        blendMode: BlendMode,
        parentID: UUID? = nil,
        isClippingMask: Bool = false,
        adjustmentData: [String: Sendable]? = nil
    ) {
        self.id = id
        self.storageID = storageID
        self.name = name
        self.isVisible = isVisible
        self.opacity = opacity
        self.blendMode = blendMode
        self.parentID = parentID
        self.isClippingMask = isClippingMask
        self.adjustmentData = adjustmentData
    }
}

/// Коллекция состояний всех слоев в правильном Z-порядке.
public struct LayerStackSnapshot: Sendable {
    /// Слои, отсортированные снизу вверх (Bottom-to-Top).
    public let layers: [LayerState]
    public let timestamp: ContinuousClock.Instant
    
    public init(layers: [LayerState]) {
        self.layers = layers
        self.timestamp = .now
    }
}
```

### 2.2 Layer Object (@MainActor)
Логический объект слоя, используемый в UI и для управления.

```swift
@MainActor
public final class Layer: Identifiable {
    public let id: UUID
    public var name: String
    public var isVisible: Bool
    public var opacity: Float
    public var blendMode: BlendMode
    
    public internal(set) var parentID: UUID?
    public var isClippingMask: Bool
    
    public var adjustmentData: [String: Sendable]?
    
    internal let storageID: UInt16
    
    public init(id: UUID = UUID(), storageID: UInt16, name: String) {
        self.id = id
        self.storageID = storageID
        self.name = name
        self.isVisible = true
        self.opacity = 1.0
        self.blendMode = .normal
        self.isClippingMask = false
        self.adjustmentData = nil
    }
    
    /// Создает иммутабельный снимок текущего состояния.
    public func makeSnapshot() -> LayerState {
        LayerState(
            id: id,
            storageID: storageID,
            name: name,
            isVisible: isVisible,
            opacity: opacity,
            blendMode: blendMode,
            parentID: parentID,
            isClippingMask: isClippingMask,
            adjustmentData: adjustmentData
        )
    }
}
```


---

## 3️⃣ Операции со слоями

### 3.1 Создание и Удаление
1.  **Create**: `LayerManager` создает объект `Layer` -> запрашивает у `TileSystem` аллокацию новой `MTLSparseTexture`.
2.  **Delete**: `LayerManager` удаляет объект -> `TileSystem` помечает все страницы этого `LayerID` как свободные и удаляет текстуру из словаря.

### 3.2 Изменение порядка (Reordering)
*   Выполняется мгновенно на `@MainActor` в `LayerManager`.
*   Не требует никаких изменений в `TileSystem` или GPU-памяти (меняется только порядок итерации при композитинге).

---

## 4️⃣ Композитинг (Rendering)

### 4.1 Процесс отрисовки холста (Tile-based Shading)
Для достижения стабильных **120 FPS** на Apple Silicon используется архитектура **TBDR (Tile-Based Deferred Rendering)** с применением **Imageblocks** и **Programmable Blending**.

1.  **Snapshot Creation**: `@MainActor LayerManager` формирует `LayerStackSnapshot`.
2.  **Dispatch**: Снимок передается в поток рендеринга.
3.  **Single-Pass Compositing**: Вместо последовательного блендинга через несколько Render Passes, все видимые слои смешиваются внутри одного прохода внутри **on-chip tile memory (SRAM)**.
    *   **Imageblock Layout**: В фрагментном шейдере определяется структура `Imageblock`, содержащая аккумуляторы цвета. Это исключает дорогостоящий Memory Bandwidth Roundtrip (VRAM -> GPU -> VRAM) для каждого слоя.
    *   **Argument Buffers**: Используются для передачи массива текстур (на основе `storageID`).
4.  **Residency Prep**: `TileSystem` подготавливает резидентность (Mapping) только для активных тайлов.

### 4.2 Преимущества для 120 FPS
1.  **Bandwidth Efficiency**: Экономия до 80% пропускной способности памяти при 10+ слоях. Смешивание в SRAM происходит с наносекундными задержками.
2.  **Low Latency**: Снижение нагрузки на контроллер памяти позволяет GPU поддерживать стабильный фреймрейт без троттлинга.
3.  **Tile-based Execution**: Цикл по слоям выполняется эффективно внутри локальной памяти тайла: `current_color = blend(current_color, layer_tex.sample(...))`.

### 4.3 Оптимизация Sparse Page Table
При наличии 100+ слоев накладные расходы на таблицы страниц (`Page Tables`) для каждой `MTLSparseTexture` могут достигать десятков мегабайт.
*   **Unified Heap Mapping**: Использование единого `MTLHeap` для всех тайлов всех слоев.
*   **Eviction Policy**: Приоритетное размапливание (unmap) невидимых или перекрытых слоев для освобождения Page Table Entries (PTE).
*   **Lazy Mapping**: Таблицы страниц для новых слоев выделяются только при первой попытке рисования.

### 4.4 Режимы смешивания (Blend Modes)
Поддерживаются стандартные режимы (через кастомные шейдеры внутри Imageblock):
*   `Normal`, `Multiply`, `Screen`, `Overlay`, `Darken`, `Lighten`, `Color Dodge`, `Color Burn`.
*   Все вычисления производятся в **RGBA16Float** для HDR точности.

---

## 3️⃣ SnapshotPool & CoW (Copy-on-Write)

Для управления памятью VRAM и обеспечения атомарности Undo/Redo внедряется `SnapshotPool`.

```swift
/// Менеджер версионности тайлов в VRAM.
public actor SnapshotPool {
    private var registry: [StorageID: TileVersion]
    private var lruCache: LRUBuffer
    
    /// Реализует Copy-on-Write для тайла.
    /// Если тайл модифицируется впервые в рамках транзакции, создается его копия.
    public func checkoutForWrite(tileID: TileCoord, layerID: UUID) -> StorageID {
        // Логика выделения новой страницы из MTLHeap
    }
    
    /// Освобождает ресурсы старых поколений, если на них нет ссылок в Global Transaction Index.
    public func collectGarbage(activeGenerations: Set<UInt64>) {
        // Deferred Deletion ресурсов
    }
}
```

---

## 4️⃣ Package-First Architecture (.drawproj)

Проект DrawEngine — это папка-пакет со следующей структурой:

```text
Project.drawproj/
├── manifest.json          <-- Global Transaction Index (The "Source of Truth")
├── project.json           <-- Структура слоев, настройки холста, метаданные
├── layers/                <-- Бинарные данные тайлов (.drawregion)
│   ├── L1_G1.drawregion   <-- Layer 1, Generation 1
│   └── L1_G2.drawregion   <-- Измененные тайлы Layer 1 в Generation 2
└── brushes/               <-- Кастомные текстуры кистей
```

---

## 5️⃣ Global Transaction Index (Manifest)

Для обеспечения консистентности при сбоях (Crash Consistency) используется манифест поколений.

```swift
public struct ProjectManifest: Codable, Sendable {
    public let lastSuccessfulGeneration: UInt64
    public let transactions: [TransactionRecord]
    
    public struct TransactionRecord: Codable, Sendable {
        public let genID: UInt64
        public let timestamp: Date
        public let modifiedFiles: [String] // Список путей к .drawregion
        public let checksum: String        // CRC32 манифеста для валидации
    }
}
```

### Алгоритм "Safe Save":
1. **Write**: Новые тайлы записываются в новые файлы `_G(N+1).drawregion`.
2. **Sync**: Вызов `fsync()` для всех новых данных.
3. **Commit**: Обновление `manifest.json` (атомарная замена файла через `replaceItemAt`).
4. **Recovery**: При открытии движок читает только те файлы, которые указаны в `lastSuccessfulGeneration`. Недописанные файлы игнорируются.

---

## 6️⃣ Rendering Pipeline: Snapshot Integration

1. `DrawingSession` запрашивает `LayerStackSnapshot`.
2. `SnapshotPool` подтверждает, что все `storageID` в снимке заблокированы в VRAM.
3. `FrameContext` собирает все данные в единый immutable пакет.
4. **Zero-Hopping Render**: Рендерер выполняет цикл по слоям без единого `await`.

---

## 7️⃣ Ограничения и лимиты

*   **Количество слоев**: Теоретический лимит — 65535 (ограничение `UInt16` для `LayerID`). Практический лимит ограничен RAM/VRAM и производительностью композитинга.
*   **Глобальный бюджет VRAM (512MB)**: Распределяется динамически. Если в документе 100 слоев, каждый слой в среднем может иметь меньше резидентных тайлов, чем при 1 слое.
*   **Sparse Texture Size**: Все слои имеют одинаковый физический размер, соответствующий размеру холста.

---

## 6️⃣ План интеграции

1.  **Phase 1**: Реализация `LayerID` и маппинга текстур в `TileSystem`.
2.  **Phase 2**: Создание `LayerManager` и базового стека слоев.
3.  **Phase 3**: Разработка шейдера композитинга с поддержкой `BlendMode`.
4.  **Phase 4**: Поддержка масок и корректирующих слоев.
