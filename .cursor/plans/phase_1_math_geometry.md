# План реализации Фазы 1: Geometry & Math Core

**Версия:** 1.2 (2026-01-31)
**Статус:** ✅ Одобрено (PLAN_REFINED)
**Цель фазы:** Создание математического ядра для интерполяции мазков с субпиксельной точностью и адаптивной плотностью точек через `StrokeProcessor` (Actor).

---

## L1: Architectural Overview (Архитектурный обзор)
*Разработано lead_architect*

### 1. Границы ответственности
- **CanvasEnvironment**: Структура (Value Semantics), Sendable. Хранит размеры холста, PPI и параметры сетки.
- **StrokeProcessor (Actor)**: Изолирует тяжелые математические расчеты Catmull-Rom ($\alpha=0.5$).
- **Math Core (Pure Logic)**: Набор статических SIMD-оптимизированных функций для расчетов сплайнов.

### 2. Потоки данных
- **Input**: `@MainActor DrawingSession` собирает точки и батчует их. Каждая точка содержит `ContinuousClock.Instant`.
- **Processing**: Передача `[ControlPoint]` и `CanvasEnvironment` в `StrokeProcessor`.
- **Output**: Генерация геометрии в `MTLBuffer` (Zero-copy) для последующей отрисовки.

---

## L2: Technical Deep-Dive (Технические детали)
*Разработано systems_engineer & metal_specialist*

### 1. Алгоритм: Centripetal Catmull-Rom (alpha = 0.5)
- **Стабильность**: Использование центростремительного параметра гарантирует отсутствие петель при резких изменениях скорости.
- **Интерполяция**: Реализация через каскадную пирамиду (Barry-Goldman) для повышения точности на SIMD-блоках.
- **Экстраполяция краев**: Для расчета первого и последнего сегментов используются виртуальные точки:
  - $P_{-1} = P_0 + (P_0 - P_1)$
  - $P_{n+1} = P_n + (P_n - P_{n-1})$
- **Адаптивный шаг (Curvature-dependent)**:
  - Расчет кривизны $\kappa$ через векторное произведение.
  - $N_{segments} = \text{clamp}(\frac{dist}{step} \times (1 + \kappa \times sensitivity), min, max)$.

### 2. Точность и GPU Bridge
- **CPU (Double Precision)**: Все расчеты координат сплайнов ведутся в `Double`.
- **GPU (Tile-Relative Float)**: Перевод в `Float` происходит только относительно `Tile Origin` для нивелирования погрешностей при экстремальном зуме.
- **SharedStructures.h**: Общий мост. `PointAttributes` с 16-байтным выравниванием.

---

## L3: Atomic Task List (Список задач)

### 1. Математическое ядро (Math Solver)
- [ ] **Task 1.1**: SIMD Extensions для `double2` и реализация `Barry-Goldman` интерполяции.
- [ ] **Task 1.2**: Реализация экстраполяции точек $P_{-1}$ и $P_{n+1}$.
- [ ] **Task 1.3**: Unit-тесты на точность (1,000,000x zoom) и вырожденные случаи (нулевое расстояние).

### 2. Логика меша (Tessellation Logic)
- [ ] **Task 1.4**: Реализация `AdaptiveStepEngine` на основе кривизны.
- [ ] **Task 1.5**: Генератор вершин (Vertex Generator) для развертки сплайна в ленту (Triangle Strip).
- [ ] **Task 1.6**: Реализация `TileRelativeConverter` для безопасного перевода Double -> Float.

### 3. Процессор мазков (StrokeProcessor)
- [ ] **Task 1.7**: Скелет `StrokeProcessor` (Actor) и интеграция с `FrameContext`.
- [ ] **Task 1.8**: Реализация `GeometryDescriptor` для передачи ссылок на буферы.

---

## Verification Matrix (Критерии успеха)
*Проверено system_validator*

1. **Производительность**: Расчет Catmull-Rom для 1000 точек < 1.0ms.
2. **Точность**: Отсутствие джиттера при экстремальном масштабировании.
3. **Надежность**: Мазок начинается точно в точке касания за счет экстраполяции.

---

## Вердикт Валидатора
**PLAN_STABLE** ✅
План декомпозирован согласно рекомендациям аудита. Разделение на Math Solver и Tessellation Logic обеспечено.
