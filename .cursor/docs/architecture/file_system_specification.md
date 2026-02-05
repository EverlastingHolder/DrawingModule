# File System Specification: DrawingModule

**Status**: ✅ REFINED (After System Validator Audit V4)
**Role**: Описание структуры исходного кода и организации файлов DrawEngine в соответствии с 6-Actor Model и Swift 6 Strict Concurrency.

---

## 📂 Общая структура проекта

Проект организован по функциональным зонам ответственности. Все данные, передаваемые между акторами, изолированы в моделях (Snapshots) или типах Handshake-протокола.

```text
Sources/DrawingModule/
├── Core/                       # Фундамент: общие типы, протоколы и математика
│   ├── Math/                   # Double-precision вычисления, Splines
│   │   ├── SplineProcessor.swift (Catmull-Rom α=0.5)
│   │   ├── GeometryUtils.swift
│   │   ├── GlobalOccupancyMap.swift # [NEW] Иерархическая битовая маска
│   │   └── CoordinateSpaces.swift (World to View conversion)
│   ├── Handshake/              # [NEW] Типы синхронизации кадра (Zero-Latency)
│   │   ├── FrameContext.swift      # Контейнер данных кадра
│   │   ├── ResidencySnapshot.swift # Маппинг ресурсов
│   │   └── GeometrySnapshot.swift  # Снапшот активных мазков
│   ├── Protocols/              # Общие интерфейсы
│   └── Constants.swift         # Лимиты (TileSize=256, VRAM limit=512MB)
│
├── Models/                     # Immutable Snapshots & Sendable Data
│   ├── Layer/                  # Состояние слоев
│   │   ├── LayerState.swift    # Снимок состояния (Sendable)
│   │   └── LayerStackSnapshot.swift
│   ├── Stroke/                 # Геометрия мазков
│   │   └── StrokePoint.swift
│   └── Tile/                   # Управление тайлами
│       └── TileCoord.swift     # (x, y, layerID)
│
├── Actors/                     # 6-Actor Model (Ядро логики)
│   ├── DrawingSession/         # Root Orchestrator (MainActor)
│   │   ├── DrawingSession.swift
│   │   └── InputProcessor.swift (UITouch/NSEvent)
│   ├── LayerManager/           # Logic Hierarchy
│   │   ├── LayerManager.swift
│   │   └── LayerEntity.swift   # [RENAME] Логический объект (@MainActor)
│   ├── TileSystem/             # Residency & Memory Manager
│   │   ├── TileSystem.swift
│   │   ├── SparsePageTable.swift # [NEW] Управление MTLHeap и Sparse Mapping
│   │   ├── SnapshotPool.swift    # CoW логика
│   │   ├── ResidencyManager.swift # MTLResidencySet & Retirement Queue
│   │   └── DirtyTileTracker.swift # [MOVED] Bitset маски изменений (TLDT)
│   ├── StrokeProcessor/        # Math Engine
│   │   └── StrokeProcessor.swift
│   ├── UndoManager/            # Transaction Manager
│   │   ├── UndoManager.swift
│   │   └── SerialCommitPipeline.swift
│   └── DataActor/              # I/O Engine (WAL & LZ4)
│       └── DataActor.swift     # Координатор фонового I/O
│
├── Rendering/                  # Metal Implementation
│   ├── Shaders/                # .metal файлы
│   │   ├── Compositing.metal   # Single-pass Imageblocks shader
│   │   ├── BrushSplat.metal    # Splat-Process-Composite pipeline
│   │   └── SharedTypes.h       # Общие структуры между Swift и Metal
│   ├── Pipelines/              # Настройка состояний Metal
│   │   ├── RenderPipelineDescriptor.swift
│   │   └── ComputePipelineDescriptor.swift
│   └── View/                   # UI Components
│       └── MetalDrawView.swift # 120Hz Display Link
│
├── Storage/                    # Persistence & File Format
│   ├── ProjectPackage/         # .drawproj handling
│   │   ├── ProjectManifest.swift
│   │   └── PackageLoader.swift
│   ├── WAL/                    # [FIX] Единое место для логики журнала
│   │   └── WALProcessor.swift  # CRC32c, LZ4 Block Deltas (64x64)
│   └── Compression/            # Общие утилиты сжатия
│       └── LZ4Service.swift
│
└── Extensions/                 # Metal & Foundation Helpers
    ├── Metal+Extensions.swift  # Удобные обертки для MTLDevice/Buffer
    └── SIMD+Extensions.swift
```

---

## 🏛 Принципы организации (Updated V4)

### 1. Zero-Latency Handshake (`Core/Handshake/`)
Все типы, участвующие в фазах 1-3 протокола синхронизации, выделены в отдельную папку. Это подчеркивает их критическую роль и гарантирует, что они являются `Sendable`. 

### 2. Изоляция TileSystem
Из-за высокой сложности управления `MTLSparseTexture` и `MTLHeap`, логика разделена:
- `SparsePageTable.swift`: Низкоуровневый маппинг страниц.
- `ResidencyManager.swift`: Управление `MTLResidencySet` и `Retirement Queue` (задержка в 3 кадра для GPU safety).
- `DirtyTileTracker.swift`: Отслеживание изменений на уровне битсетов (TLDT) перенесено сюда для прямой связи с `TileSystem`.

### 3. Разделение Layer Logic
`LayerEntity.swift` (@MainActor) — это ссылочный объект для UI. 
`LayerState.swift` (Sendable) — это его иммутабельное отражение для рендерера и фоновых задач. Физическое разделение предотвращает случайное использование ссылочных типов в акторах.

### 4. Устранение дублирования WAL
Вся низкоуровневая логика работы с бинарным журналом, CRC32c и LZ4-дельтами блоков (64x64) сосредоточена в `Storage/WAL/`. `DataActor` является лишь высокоуровневым координатором.

### 5. Оптимизация композитинга
`GlobalOccupancyMap.swift` (GOM) добавлен в `Core/Math/` как ключевой компонент для пропуска пустых областей холста, что критично для поддержания 120 FPS.
