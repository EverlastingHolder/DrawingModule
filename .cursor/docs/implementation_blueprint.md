# Technical Implementation Blueprint: DrawEngine

**Версия:** 1.1 (2026-01-31)
**Статус:** ✅ REFINED (Audit V3 2026-01-31 - Systems Architecture Hardened)
**Роль документа:** Детальное техническое руководство для разработки DrawEngine.

---

## 1. Архитектурная оркестрация (Actor Hierarchy)

Система строится на базе Swift 6 Strict Concurrency с четким разделением доменов ответственности.

| Актор | Изоляция | Ответственность |
| :--- | :--- | :--- |
| **`LayerManager`** | `@MainActor` | Владелец структуры документа (Z-index, Tree), метаданных слоев и генератор иммутабельных `LayerStackSnapshot`. |
| **`DrawingSession`** | `@MainActor` | Оркестрация транзакций мазка, работа с UI, UndoManager, интеграция снимков слоев в кадр. |
| **`StrokeProcessor`** | `actor` (Background) | Математические расчеты: Centripetal Catmull-Rom ($\alpha=0.5$), World-to-Tile трансформация. |
| **`TileSystem`** | `actor` (Background) | Менеджер резидентности GPU: управление `MTLSparseTexture` (через `LayerID`), `MTLHeap`, LRU и Unified Page Table Mapping. |
| **`DataActor`** | `actor` (Background) | Асинхронный I/O: LZ4-компрессия, атомарная запись, обработка **Export-Streaming Mode**. |

### 1.1 DataActor & Background I/O
- **Background Tasks**: Использование `UIApplication.shared.beginBackgroundTask` (через `UIBackgroundTaskIdentifier`) для завершения записи регионов даже после сворачивания приложения (до 30 секунд).
- **Export-Streaming Mode**:
    - **Trigger**: Активируется при экспорте больших холстов (32k+).
    - **Logic**: `TileSystem` отключает LRU-вытеснение для экспортируемых регионов и использует выделенный поток чтения.
    - **Memory Backpressure**: Очередь чтения приостанавливается, если количество несжатых тайлов в RAM превышает **128MB**. Это предотвращает "Thrashing" (постоянную перезагрузку кэша).

### Базовые контракты (Protocols & Snapshots)

```swift
/// Иммутабельный снимок для рендеринга без Actor Hopping (Swift 6)
public struct LayerStackSnapshot: Sendable {
    public let layers: [LayerState]
    public let timestamp: ContinuousClock.Instant
}

@MainActor
public protocol DrawingSessionProtocol: AnyObject {
    var environment: CanvasEnvironment { get }
    func render(snapshot: LayerStackSnapshot)
    func beginStroke(at: CGPoint, pressure: Float) async
    func updateStroke(at: CGPoint, pressure: Float) async
    func endStroke() async
}

public protocol StrokeProcessorProtocol: Actor {
    func processPoints(_ points: [ControlPoint]) async throws -> MTLBuffer
}

public protocol TileSystemProtocol: Actor {
    func makeResident(coords: Set<TileCoord>) async throws
    func evictNonVisiblePages() async
}
```

---

## 2. Математическое ядро (Geometry & Interpolation)

### 2.1 Точность WorldSpace
- **CPU Logic**: Все расчеты координат и сплайнов — **`Double`**.
- **GPU Interface**: Координаты передаются как **`Float` смещения (Offsets)** относительно `TileOrigin`.
- **NDC Mapping**: `gpu_pos = ((worldPos - tileOrigin) / tileSize) * 2.0 - 1.0`.

### 2.2 Centripetal Catmull-Rom ($\alpha = 0.5$)
- **Преимущества**: Предотвращает самопересечения (cusps) в узлах.
- **Параметризация**: $t_{i+1} = t_i + \|P_{i+1}-P_i\|^{0.5}$.
- **Extrapolation Logic**:
  ```swift
  func extrapolate(p0: SIMD2<Double>, p1: SIMD2<Double>) -> SIMD2<Double> {
      return p0 + (p0 - p1)
  }
  ```
- **SIMD Optimization**: Расчет 4-х точек интерполяции одновременно через SIMD-инструкции.

---

## 3. GPU Rendering Pipeline (Metal)

### 1. Argument Buffers
Использование Metal Argument Buffers для минимизации CPU overhead:
- **`BrushResources`**:
  - `texture2d brushTexture`
  - `sampler brushSampler`
  - `struct BrushProperties { float size, softness, flow, spacing; }`
- **`SmudgeResources`**: Read-write текстура тайла, текстура-источник, параметры смешивания.
- **Layout**: Все структуры определяются в `SharedStructures.h` с выравниванием 16 байт.

### 2. Пайплайны (PSOs)
- **Pixel Format**: `RGBA16Float` (HDR, 8 байт на пиксель).
- **Blending**: Programmable Blending (`[[color(0)]]`) на Apple Silicon.
- **Compositing**: Single-pass TBDR смешивание всех слоев в SRAM тайла (Imageblocks).
  - **Optimization**: Использование **Argument Buffers** для передачи массива текстур слоев по `storageID`.
  - **Bandwidth**: Исключение Roundtrip (VRAM -> GPU -> VRAM) для каждого слоя.
- **Multi-pass Brush**: Разделение на **Mask Pass** (Memoryless), **Effect Kernel** (Compute) и **Final Blend**.

### 3. Сглаживание и тесселяция
- **Адаптивный шаг**: $step = \max(1.0, radius \times 0.5 \times scale)$.
- **SIMD Math**: Использование SIMD для Catmull-Rom и RDP упрощения.

---

## 4. Система тайлов и память (Tile System)

### 4.1 Параметры
- **Размер тайла**: 256x256 пикселей.
- **Регион**: 4x4 тайла (1024x1024 пикселя). Базовая единица I/O.
- **VRAM Limit**: 512MB (~1024 тайла).

### 4.2 LRU Eviction & Memory Optimization
- **Unified Heap Mapping**: Использование единого `MTLHeap` для всех тайлов всех слоев для снижения фрагментации.
- **Sparse Page Table**: 
  - **Lazy Mapping**: Аллокация таблиц страниц только при первой записи в слой.
  - **Eviction Policy**: Приоритетное размапливание (unmap) PTE для невидимых или перекрытых слоев.
- **Layer Priority**:
  1. **Active Layer**: Текущий слой (иммунитет).
  2. **Visible Layers**: Видимые слои во вьюпорте (LRU).
  3. **Background Layers**: Слои вне фокуса (LRU).
  4. **Invisible Layers**: Скрытые слои (LRU).

**Global Occupancy Map**: Использование битовой маски для пропуска пустых тайлов при композитинге.

---

## 5. Персистентность и I/O (Data Management)

### 5.1 Формат .drawregion (4x4 tiles)
- **Header**: Magic `DRGN`, Version.
- **Index**: 16 слотов `(offset, compressedLength)`. Защищен CRC32.
- **Payload**: Независимые LZ4-блоки.
- **Compaction Algorithm**:
  1. Создается `.tmp` файл.
  2. Валидные блоки из оригинального файла копируются последовательно.
  3. Индекс пересчитывается.
  4. Атомарный `rename()`.

---

## 6. Стратегия надежности (Reliability)

- **Device Loss**: При потере Metal-устройства `DrawingSession` восстанавливает состояние (Re-hydration) только для видимых тайлов из `DataActor`.
- **120 FPS Lock**:
    - Двойная буферизация геометрии.
    - Zero-Copy через `MTLStorageMode.shared`.
    - Предиктивное разворачивание Solid-тайлов в текстуры за 100ms до касания.

---

## 7. План реализации (Implementation Sequence)

1.  **Phase 1**: Базовая структура `CanvasEnvironment` и математика `StrokeProcessor` (Catmull-Rom).
2.  **Phase 2**: `LayerManager` и `TileSystem` (Sparse Textures) с менеджером резидентности.
3.  **Phase 3**: Metal Render Pipeline (Argument Buffers, HDR Shaders, Compositor).
4.  **Phase 4**: `DrawingSession` и Stroke Transaction (связка всех акторов).
5.  **Phase 5**: `DataActor` и LZ4 персистентность.
6.  **Phase 6**: UI Layer (`MetalDrawView`) и оптимизация.
