# Brush Pipeline Specification for Metal Tile-Based SDK

> Документ описывает архитектуру, алгоритмы и GPU-конвейер отрисовки кистей.

**Status**: ✅ REFINED (Audit V4 2026-01-31 - Multi-pass & Smudge Hardened)

---

## 1️⃣ Overview

Цель: высокопроизводительный brush pipeline, поддерживающий:
* Stamp-based кисти (текстурные отпечатки).
* **Centripetal Catmull-Rom** ($\alpha = 0.5$) для устранения петель.
* **RGBA16Float HDR** конвейер (яркость > 1.0).
* **Multi-pass GPU effects** (Splat -> Process -> Composite).
* **Tonemapping-Safe Smudge** (размазывание без "взрывов" яркости).
* **Double Precision WorldSpace**: Поддержка холстов до **100,000 px** без дрожания (jitter).

---

## 2️⃣ Precision & Data Flow

### 2.1 WorldSpace vs. NDC Space
Для поддержки профессиональных холстов используется гибридная точность:
1.  **WorldSpace (CPU/Logic)**: Все расчеты координат, интерполяция Catmull-Rom и `StrokeProcessor` оперируют типом **`Double`**. 
2.  **Conversion (Vertex Shader)**: Переход `Double` -> `Float` происходит максимально поздно — при подготовке данных для GPU.
3.  **Relative Positioning (GPU)**: Чтобы избежать потери точности внутри шейдера, координаты передаются не как абсолютные значения WorldSpace, а как **Offset** относительно центра текущего Tile или Viewport.
    *   `float2 ndc_pos = (float2(world_pos - tile_origin) / tile_size) * 2.0 - 1.0`.

### 2.2 Zero-Copy Pipeline & Undo Integration
Для минимизации задержек (120 FPS):
*   **MTLBuffer Storage**: Геометрия мазка хранится в `MTLBuffer` с `MTLStorageMode.shared`.
*   **No memcpy**: `StrokeProcessor` пишет данные напрямую в указатель `buffer.contents()`. 
*   **Undo Integration**: `StrokeProcessor` вычисляет `damagedRect` (bounding box сегмента + padding кисти) и инициирует `UndoCoordinator.captureBefore`.
*   **Synchronization**: GPU начинает чтение буфера сразу после вызова `commit()`. Использование `MTLFence` гарантирует, что снапшоты для Undo захватывают верное состояние до мутации.

---

## 3️⃣ Алгоритмы и точность

### 3.1 Centripetal Catmull-Rom ($\alpha = 0.5$)
В отличие от Uniform сплайнов, Centripetal вариант гарантирует отсутствие самопересечений и петель (cusps).
- **Параметризация**: $t_{i+1} = t_i + \|P_{i+1}-P_i\|^{0.5}$.
- **Boundary Extrapolation**: 
  $P_{-1} = P_0 + (P_0 - P_1)$
  $P_{n+1} = P_n + (P_n - P_{n-1})$
- **Adaptive Step Sizing**: Количество сегментов зависит от кривизны: $N = \max(k, \text{dist} \times \text{Density} \times (1 + \text{CurvatureFactor}))$.

### 3.2 Alpha Accumulation
*   **Max-Alpha Blending**: Для сохранения текстурных деталей кисти при многократном перекрытии используется:
    *   `Alpha_final = max(Alpha_existing, Alpha_new_stamp)`.
*   **RGBA16Float**: Позволяет выполнять аддитивное смешивание без потери точности в тенях и HDR-светах.

---

## 4️⃣ GPU Rendering Pipeline

### 4.1 Multi-pass Brush System (Splat-Process-Composite)
Для реализации сложных эффектов (Smudge, Blur, Dual-Brush) используется трехстадийный конвейер, оптимизированный для **SRAM (Imageblocks)**:

1.  **Pass 1: Splatting (Mask/Stamp Generation)**:
    *   Отрисовка формы кисти в промежуточный `AccumulationBuffer` (R16Float).
    *   Использование `Memoryless` текстур для экономии Bandwidth.
2.  **Pass 2: Processing (Smudge/Blur/Texture)**:
    *   **Compute Kernel / Tile Shader**: Обработка накопленной маски или чтение из `BackBuffer` для Smudge.
    *   **Imageblock Usage**: Для тайлов 256x256 выполнение происходит частями 32x32 (Hardware Tiles), чтобы данные оставались в SRAM.
    *   **Smudge**: Чтение цвета "под кистью" из предыдущего состояния и смешивание в `threadgroup` памяти.
3.  **Pass 3: Final Compositing**:
    *   Смешивание результата с целевым слоем (`MTLSparseTexture`).
    *   Применение динамического цвета, шума и наложения текстур.

### 4.2 Deferred Mipmapping & TLDT
Генерация мип-мапов выполняется асинхронно, используя данные от системы Undo/Redo:
*   **Tile-Level Dirty Tracking (TLDT)**: Используется общая с `UndoCoordinator` маска грязных тайлов.
*   **Trigger Strategy**:
    1.  **Stroke End**: Немедленная генерация для измененных тайлов (по TLDT маске) после поднятия стилуса.
    2.  **Idle Loop**: Генерация в моменты покоя (FPS > 110).
    3.  **Export Pre-flight**: Принудительная генерация перед сохранением или экспортом.
*   **Optimization**: Используется `MTLBlitCommandEncoder.generateMipmaps`. Для Sparse текстур мип-мапы генерируются только для физически выделенных страниц.

---

## 5️⃣ Smudge Module & Optimization

### 5.1 Register Pressure & SRAM (120 FPS Target)
Smudge-ядро — критическая точка производительности. Для поддержания 120 FPS на Apple Silicon:
*   **Limit**: Максимум **32 регистра** на поток для обеспечения 100% occupancy.
*   **Threadgroup Memory**: Использование 8KB - 16KB `threadgroup` памяти для кэширования области холста под кистью. Это исключает повторные VRAM-запросы при расчете smudge-эффекта.
*   **Optimization**: 
    - Избегание `switch/case` в ядре.
    - Использование `half` вместо `float` для всех вычислений.

### 5.2 Smudge Logic (Hardened)
1.  **Capture Phase**: Загрузка 32x32 блока в `threadgroup` память.
2.  **Energy Preservation**: 
    - `half3 mixedColor = mix(canvasColor, smudgeSample, strength * pressure)`.
    - Ограничение Delta Brightness для HDR.

---

## 6️⃣ Synchronization (Pipeline Hardening)

### 6.1 MTLFence & MTLEvent
Для межкадровой синхронизации и предотвращения Race Conditions:
*   **MTLFence**: Используется для синхронизации между Render и Compute энкодерами в рамках одного `MTLCommandBuffer`.
*   **MTLEvent**: Обеспечивает Triple Buffering. CPU не начинает запись в `MTLBuffer` кадра `N+3`, пока GPU не сигнализирует о завершении кадра `N`.
*   **Triple Buffering**: Применяется к:
    - `Geometry Buffers` (координаты мазков).
    - `ResidencySet` (список активных ресурсов).
    - `Argument Buffers` (дескрипторы тайлов).

---

## 7️⃣ Pseudocode: Multi-pass Encoding

```swift
func encodeBrushStroke(commandBuffer: MTLCommandBuffer) {
    // 1. Pass 1: Stamp Splatting
    let stampEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: stampPassDesc)
    stampEncoder.setRenderPipelineState(stampPSO)
    stampEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
    stampEncoder.endEncoding()

    // 2. Pass 2: Smudge/Blur Compute
    if brush.hasEffects {
        let computeEncoder = commandBuffer.makeComputeCommandEncoder()
        computeEncoder.setComputePipelineState(effectPSO)
        computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        computeEncoder.endEncoding()
    }

    // 3. Pass 3: Final Composite
    let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: finalPassDesc)
    compositeEncoder.setRenderPipelineState(compositePSO)
    compositeEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    compositeEncoder.endEncoding()
}
```

---

## 8️⃣ Public Contracts (Public API)

```swift
public protocol StrokeProcessing: Actor {
    /// Формирует иммутабельный снимок геометрии для текущего кадра.
    func makeGeometrySnapshot() async -> GeometrySnapshot

    /// Добавляет новые точки ввода.
    /// Возвращает `damagedRect` (область изменений в World Space).
    func addPoints(_ points: [StrokePoint], in layerID: UUID) async -> CGRect
    
    /// Завершает текущий мазок и возвращает финальный `damagedRect`.
    func finishStroke() async -> CGRect
    
    /// Предиктивный расчет тайлов, которые скоро потребуются (100ms lookahead).
    func predictAffectedTiles(pos: CGPoint, velocity: CGPoint, radius: CGFloat) async -> [TileCoord]
    
    /// Связь с Undo: инициирует захват состояния через координатор.
    func requestCapture(token: TransactionToken, dirtyRect: CGRect) async throws
}
```

---

## 9️⃣ Key Principles

1.  **Double for World, Float for Offset**: Идеальная точность на любых размерах.
2.  **Zero-Copy**: Минимальный CPU overhead.
3.  **Bandwidth Optimization**: Экономия энергии и 120 FPS.
4.  **Residency Management**: Поддержка 32k+ холстов в 512MB VRAM.
