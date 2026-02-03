# Project Roadmap: Metal Tile-Based Drawing SDK

**Status**: ✅ REFINED (Audit V2 2026-01-30)

## 📅 Phase 1: Foundation (Core Metal & Memory)
- [ ] Настройка `MTLDevice`, `MTLCommandQueue` и базового `DrawEngine`.
- [ ] Реализация `CanvasGeometry`: хелпер для трансформации координат (World <-> Tile) с использованием **Double Precision**.
- [ ] Реализация **MTLHeap** для управления памятью тайлов (RGBA16Float).
- [ ] Реализация `TileSystem` (Actor):
    - [ ] Sparse Storage (`[LayerID: [TileCoord: Tile]]`).
    - [ ] Логика объединения в **Regions** (4x4 тайла).
    - [ ] **Region-Aware Binning**.
- [ ] Базовая структура `Tile` (`texture`, `solid`, `empty`).

## 📅 Phase 2: Display & Interaction
- [ ] Настройка `MTKView` и `TileRenderer`.
- [ ] **Input Abstraction Layer**: прослойка для обработки `UITouch` (iOS) и `NSEvent` (macOS).
- [ ] **Buffering Strategy**:
    - [ ] Triple-buffering для Uniforms и Instance Buffers.
    - [ ] Double-buffering для `LiveStrokeBuffer`.
- [ ] Реализация Metal Projection Matrix для связи зума/панорамирования с отрисовкой тайлов.
- [ ] Culling: отрисовка только видимых тайлов.

## 📅 Phase 3: Basic Drawing Pipeline
- [ ] `InputProcessor`: сбор Coalesced Touches и Pressure.
- [ ] `StrokePathGenerator`: интерполяция Catmull-Rom.
- [ ] `StampShader`: базовый шейдер для отрисовки отпечатков кисти.
- [ ] `LiveStrokeBuffer`: отображение мазка в реальном времени.

## 📅 Phase 4: Advanced Features
- [ ] **Snapshot Undo/Redo**: система LZ4-сжатых снимков тайлов в RAM.
- [ ] **Smudge Engine**: 
    - [ ] Временный атлас (Hybrid Atlas Strategy).
    - [ ] Compute Shader для логики размазывания.
- [ ] **Solid Fill**: оптимизированная заливка холста.

## 📅 Phase 5: Optimization & Refinement
- [ ] Premultiplied Alpha blending.
- [ ] Генерация Mipmaps для тайлов.
- [ ] Поддержка кастомных эффектов (Custom GPU Effects Hook).

## 📅 Phase 6: I/O & Finalization
- [ ] Экспорт холста в `UIImage` / `Data`.
- [ ] Импорт/Экспорт структуры проекта (сериализация тайлов).
- [ ] Финальное тестирование производительности (120 FPS check).
