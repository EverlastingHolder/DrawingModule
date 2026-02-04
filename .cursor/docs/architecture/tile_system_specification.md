# Tile System Specification for Metal Drawing SDK

> Этот документ описывает архитектуру, управление памятью и логику работы тайловой системы холста.

**Status**: ✅ REFINED (Audit V4 2026-01-31 - Systems Architecture Hardened)

---

## 1️⃣ Базовые параметры

*   **Размер тайла**: 256x256 пикселей.
*   **Формат пикселя**: **RGBA16Float** (8 байт на пиксель) для Pro-level рендеринга.
*   **Регион**: Группа 4x4 тайла (1024x1024 пикселя). Базовая единица пространственного индекса.
*   **Tile-centric Snapshot**: Снапшоты Undo/Redo оперируют на уровне отдельных тайлов (256x256).
*   **Block Delta**: Внутри тайла отслеживаются изменения на уровне блоков 64x64 (16 блоков на тайл) для минимизации Write Amplification.
*   **Поддержка Sparse Textures**: Использование `MTLSparseTexture` для холстов до **32k x 32k** (и выше). Физическая память (64KB страницы) выделяется только под активные области.
*   **Layers**: Физическое хранение данных слоев. Адресация: `[LayerID: MTLSparseTexture]`. Управление логикой (порядок, прозрачность) вынесено в `LayerManager`. Подробнее в `layer_system_specification.md`.

---

## 2️⃣ Архитектурные уровни

### 2.1 CanvasGeometry (Math)
*   **2-Tier Region Binning**: 
    1. **Region Pass**: Точки распределяются по 1024px регионам (битовые сдвиги `>> 10`).
    2. **Tile Pass**: Внутри активных регионов — биннинг по тайлам (`>> 8`).
*   **Prediction Box**: Рассчитывается как `AABB(CurrentSegment)` + вектор предсказания $\vec{V}_{pred} = \vec{Velocity} \times 100ms$.

### 2.2 TileSystem (Actor) — Residency Manager
*   **MTLHeap Slot Management**: Текстуры аллоцируются из **Placement Heap**. Фиксированный размер тайлов исключает фрагментацию.
*   **Tile-Level Dirty Tracking (TLDT)**: 
    - Использование Bitset масок (один бит на тайл). 
    - Шейдеры отрисовки помечают затронутые тайлы. 
    - `UndoCoordinator` использует эту маску для выборочного копирования (sparse copy) в VRAM.
*   **3-Level Caching Strategy**:
    1.  **L1: VRAM (Resident)**: Лимит **512MB**. `MTLSparseTexture` страницы + VRAM-снапшоты текущих транзакций.
    2.  **L2: LZ4 RAM (Warm)**: Системная RAM. Тайлы и Block Deltas (64x64) хранятся в сжатом LZ4 виде.
    3.  **L3: Disk (Cold)**: Файловая система. WAL (Write-Ahead Log) записей и снапшоты регионов.
*   **Layer Priority Eviction**:
    При достижении лимита VRAM (512MB) вытеснение происходит в следующем порядке:
    1.  **Invisible Layers**: Скрытые слои вытесняются первыми (LRU внутри группы).
    2.  **Background Layers**: Слои, находящиеся далеко от активного (Active +/- 5 слоев).
    3.  **Visible Layers**: Видимые слои во вьюпорте (LRU).
    4.  **Active Layer**: Текущий слой для рисования (иммунитет до критического дефицита).
*   **Residency Logic**:
    1. **LruCache**: Ведется LRU-список резидентных страниц (64KB).
    2. **Hard Limit**: Общий объем резидентной памяти ограничен **512MB** (или 2.5x от площади Viewport).
    3. **Eviction**: При достижении лимита вызывается `unmap` для старейших страниц через `MTLResourceStateCommandEncoder`.
*   **Viewport-Aware LRU**: Тайлы, видимые во вьюпорте, имеют иммунитет к выгрузке (`refCount > 0`).

### 2.3 DataActor (Background I/O & History)
*   **WAL & History Store**: Каждое изменение (мазок, операция со слоем) записывается в WAL-журнал с CRC32c валидацией.
*   **LZ4 Snapshot Pipeline**: Фоновое сжатие снапшотов Undo/Redo в RAM.
*   **Memory Pressure Relay**: При системном `Memory Warning` происходит немедленный сброс (flush) всех LZ4-снапшотов из RAM на диск в `HistoryStore`.
*   **Atomic Saves**: Использование временных файлов, `fsync()` и `rename()` для безопасности манифеста.

### 2.4 Tile (Data Container)
Три состояния контента:
1.  **Empty**: Тайл не содержит данных, память не выделена.
2.  **Solid**: Тайл залит одним цветом (RGBA16F). Текстура не выделена.
3.  **Texture**: Полноценная `MTLTexture` (или отображенная страница Sparse), размещенная в `MTLHeap`.

### 2.5 Global Occupancy Map (GOM)
Для оптимизации композитинга и пропуска пустых областей используется иерархическая битовая маска:

*   **Structure**:
    - **L1 (Region Mask)**: 1 бит на регион (1024x1024). Позволяет быстро отсекать целые области.
    - **L2 (Tile Mask)**: 1 бит на тайл (256x256). Хранится как `uint64_t` для каждого активного региона.
*   **Usage**:
    - `Compositor`: Рендерит только те тайлы, где хотя бы один слой имеет бит `1` в GOM.
    - `StrokeProcessor`: Проверяет GOM для определения `affectedTiles`.
*   **Atomic Operations**: Обновление маски происходит атомарно при переходе тайла из `Empty` в `Solid/Texture`.

---

## 3️⃣ Предиктивное разворачивание (Predictive Unfolding)

Для минимизации задержек при переходе от `Solid` к `Texture` используется **Lookahead 100ms**:

1.  **Trigger**: При получении нового сегмента мазка (`StrokeProcessor`).
2.  **Allocation**: Если тайл в `Solid` состоянии попадает в `PredictionBox`, система:
    - Резервирует страницу в `MTLHeap`.
    - Вызывает `ClearKernel` для заполнения текстуры цветом из `Solid` состояния.
    - Переводит статус в `Texture`.
3.  **Lookahead**: $\vec{V}_{pred} = \vec{Velocity} \times 0.1s$.

```swift
func predictUnfolding(currentPos: CGPoint, velocity: CGPoint, brushRadius: CGFloat) -> [TileCoord] {
    let futurePos = currentPos + velocity * 0.1 // 100ms предикция
    let predictionBox = AABB(currentPos, futurePos).insetBy(brushRadius)
    return CanvasGeometry.affectedTiles(predictionBox).filter { $0.isNotTexture }
}
```

---

## 4️⃣ Формат хранения (Persistence)

*   **Unit**: Регион 4x4 (16 тайлов).
*   **WAL Journaling**: Каждое изменение метаданных региона сначала записывается в журнал транзакций.
*   **LZ4 Compression**: Сжатие Raw RGBA16Float данных перед записью. Снижает I/O на 60-80%.

---

## 5️⃣ Математическое ядро (Engine Math)

### 5.1 Centripetal Catmull-Rom Spline
Для интерполяции точек мазка используется Centripetal Catmull-Rom ($\alpha = 0.5$), так как она гарантирует отсутствие самопересечений и "петель" при резких поворотах.

**Формула:**
Для четырех контрольных точек $P_0, P_1, P_2, P_3$:
1. Вычисляются узлы времени $t_i$:
   $t_{i+1} = t_i + \|P_{i+1} - P_i\|^\alpha$, где $t_0 = 0, \alpha = 0.5$.
2. Интерполяция в интервале $[t_1, t_2]$ для параметра $t \in [t_1, t_2]$:
   $A_1 = \frac{t_1-t}{t_1-t_0}P_0 + \frac{t-t_0}{t_1-t_0}P_1$
   $A_2 = \frac{t_2-t}{t_2-t_1}P_1 + \frac{t-t_1}{t_2-t_1}P_2$
   $A_3 = \frac{t_3-t}{t_3-t_2}P_2 + \frac{t-t_2}{t_3-t_2}P_3$
   $B_1 = \frac{t_2-t}{t_2-t_0}A_1 + \frac{t-t_0}{t_2-t_0}A_2$
   $B_2 = \frac{t_3-t}{t_3-t_1}A_2 + \frac{t-t_1}{t_3-t_1}A_3$
   $C = \frac{t_2-t}{t_2-t_1}B_1 + \frac{t-t_1}{t_2-t_1}B_2$

Где $C$ — результирующая точка на кривой.
