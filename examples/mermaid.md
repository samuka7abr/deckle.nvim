# Mermaid no deckle

Showcase só de Mermaid: pelo menos um diagrama grande de cada um dos 14 tipos que o
renderer de texto cobre (`deckle_native.supported_types()`), usando a sintaxe quase toda.
Abra com `:Deckle open`. É também um teste: o `cargo test` renderiza cada bloco daqui, e o
job `native` abre este arquivo no preview e exige que nenhum bloco degrade, com a única
exceção do `pie` da última seção. Voltar ao [showcase geral](showcase.md).

Estilo e cor (`classDef`, `style`, `linkStyle`, `rect rgb(...)`, `box`) viram cor no preview
em flowchart, state e sequence quando `mermaid.colors = true` (o padrão). Em class o merman
não emite cor. Em nenhum caso o estilo pode quebrar ou degradar o desenho.

## Índice

- [flowchart](#flowchart): formas de nó, arestas, subgraphs aninhados, 50+ nós, `RL` e `BT`
- [sequence](#sequence), [class](#class), [state](#state), [er](#er)
- [gantt](#gantt), [gitgraph](#gitgraph), [journey](#journey), [kanban](#kanban)
- [mindmap](#mindmap), [packet](#packet), [timeline](#timeline), [treeView](#treeview),
  [xychart](#xychart)
- [README do ILZA](#readme-do-ilza): dois diagramas reais, um bug report
- [Degradação esperada](#degradação-esperada)

## flowchart

### Todas as formas de nó e todas as arestas

As quatorze formas clássicas, numa cadeia que usa os oito tipos de aresta (`-->`, `---`,
`-.->`, `==>`, `--o`, `--x`, `<-->`, `~~~`), com e sem rótulo, mais uma aresta de volta. Os
traços alternam ao longo da cadeia, mas nenhum se cruza: o layout de texto do merman não
desenha duas arestas de traços diferentes que se cruzam (ver `:help deckle-limitations`).

```mermaid
flowchart TB
    N1[Retângulo]
    N2(Arredondado)
    N3([Estádio])
    N4[[Sub-rotina]]
    N5[(Banco de dados)]
    N6((Círculo))
    N7>Assimétrico]
    N8{Decisão}
    N9{{Hexágono}}
    N10[/Paralelogramo/]
    N11[\Paralelogramo alt\]
    N12[/Trapézio\]
    N13[\Trapézio alt/]
    N14(((Círculo duplo)))

    N1 --> N2
    N2 --- N3
    N3 -.-> N4
    N4 ==> N5
    N5 --o N6
    N6 --x N7
    N7 <--> N8
    N8 ~~~ N9
    N9 -->|com rótulo| N10
    N10 -- rótulo longo --> N11
    N11 -. pontilhada .-> N12
    N12 == grossa ==> N13
    N13 --- N14
    N14 -.->|reinicia| N1
```

### Pipeline de CI/CD: subgraphs aninhados com direção, estilo e cliques

Subgraphs aninhados, `direction` diferente em cada um, `classDef`, `class`, `:::`, `style`,
`linkStyle` com cores e `click` (que o desenho ignora). Rótulos com emoji, acento, CJK e `\n`.

```mermaid
flowchart LR
    classDef ok fill:#d4edda,stroke:#28a745,stroke-width:2px,color:#155724
    classDef warn fill:#fff3cd,stroke:#ffc107,color:#856404
    classDef bad fill:#f8d7da,stroke:#dc3545,stroke-dasharray: 5 5
    classDef cjk fill:#e8eaf6,stroke:#3949ab

    DEV(["👩‍💻 Dev\nabre PR"]):::ok

    subgraph CI["⚙️ Integração contínua"]
        direction TB
        LINT["Lint\n(stylua · selene)"]:::ok
        subgraph TESTES["🧪 Testes"]
            direction LR
            UNIT["Unitários"]
            INTEG["Integração"]
            E2E["E2E\n(headless)"]:::warn
        end
        BUILD[["Build do .so"]]
        LINT --> UNIT
        UNIT --> INTEG --> E2E
        E2E --> BUILD
    end

    subgraph CD["🚀 Entrega"]
        direction TB
        subgraph MATRIZ["Matriz de plataformas"]
            direction LR
            LNX[(Linux)]
            MAC[(macOS)]
            WIN[(Windows)]
        end
        SUM{{"Checksums\nSHA-256"}}
        REL>"Release v0.3"]:::ok
        MATRIZ --> SUM --> REL
    end

    subgraph I18N["🌏 国際化"]
        direction LR
        JA["日本語"]:::cjk
        ZH["中文"]:::cjk
        PT["Português"]:::cjk
        JA --- ZH --- PT
    end

    DEV -->|push| LINT
    BUILD -->|artefato| MATRIZ
    REL -.->|docs| I18N

    style DEV stroke-width:4px
    style BUILD fill:#e1f5fe,stroke:#0288d1
    linkStyle 0 stroke:#28a745,stroke-width:3px,color:green
    linkStyle 1,2 stroke:#ff9800
    linkStyle default stroke:#666

    click LINT href "https://github.com/JohnnyMorganz/StyLua" "StyLua"
    click REL callback "tooltip da release"
```

### Plataforma com mais de 50 nós

Cinquenta e quatro nós em nove camadas, 72 arestas que se cruzam entre camadas, nove
`classDef`, uma forma de nó por camada. É o caso de estresse do layout: gasta cerca de 2
milhões das unidades de trabalho que o merman permite (o deckle sobe o teto para 4 milhões).
Sem subgraphs de propósito: aresta que pula uma camada de subgraph é a que o merman não roteia
(o diagrama do ILZA, mais abaixo, é o exemplo).

```mermaid
flowchart TB
    classDef cli fill:#e3f2fd,stroke:#1565c0
    classDef brd fill:#e8eaf6,stroke:#283593
    classDef gtw fill:#e0f7fa,stroke:#00838f
    classDef svc fill:#f3e5f5,stroke:#6a1b9a
    classDef sv2 fill:#ede7f6,stroke:#4527a0
    classDef fil fill:#fff3e0,stroke:#e65100
    classDef dad fill:#fce4ec,stroke:#c62828
    classDef ext fill:#fff8e1,stroke:#f57f17
    classDef obs fill:#e8f5e9,stroke:#2e7d32

    L0N0(["Web"]):::cli
    L0N1(["Mobile"]):::cli
    L0N2(["Parceiros"]):::cli
    L0N3(["Admin"]):::cli
    L0N4(["Bots"]):::cli
    L0N5(["CLI"]):::cli

    L1N0{{"CDN"}}:::brd
    L1N1{{"WAF"}}:::brd
    L1N2{{"Anti-DDoS"}}:::brd
    L1N3{{"Balanceador"}}:::brd
    L1N4{{"Rate limit"}}:::brd
    L1N5{{"TLS"}}:::brd

    L2N0["API Gateway"]:::gtw
    L2N1["BFF Web"]:::gtw
    L2N2["BFF Mobile"]:::gtw
    L2N3["GraphQL"]:::gtw
    L2N4["Webhooks"]:::gtw
    L2N5["API Admin"]:::gtw

    L3N0["Auth"]:::svc
    L3N1["Usuários"]:::svc
    L3N2["Catálogo"]:::svc
    L3N3["Carrinho"]:::svc
    L3N4["Pedidos"]:::svc
    L3N5["Pagamentos"]:::svc

    L4N0["Estoque"]:::sv2
    L4N1["Envio"]:::sv2
    L4N2["Busca"]:::sv2
    L4N3["Notificações"]:::sv2
    L4N4["Relatórios"]:::sv2
    L4N5["Cupons"]:::sv2

    L5N0>"Pedidos\ncriados"]:::fil
    L5N1>"Pagamentos"]:::fil
    L5N2>"Estoque\nbaixo"]:::fil
    L5N3>"E-mails"]:::fil
    L5N4>"Eventos"]:::fil
    L5N5>"Auditoria"]:::fil

    L6N0[("Postgres\nusuários")]:::dad
    L6N1[("Postgres\npedidos")]:::dad
    L6N2[("Redis\nsessões")]:::dad
    L6N3[("Elastic\nbusca")]:::dad
    L6N4[("S3\nmídia")]:::dad
    L6N5[("ClickHouse\neventos")]:::dad

    L7N0[["Stripe"]]:::ext
    L7N1[["Correios"]]:::ext
    L7N2[["SendGrid"]]:::ext
    L7N3[["Twilio"]]:::ext
    L7N4[["Zendesk"]]:::ext
    L7N5[["Slack"]]:::ext

    L8N0["Prometheus"]:::obs
    L8N1["Grafana"]:::obs
    L8N2["Loki"]:::obs
    L8N3["Tempo"]:::obs
    L8N4["Alertmanager"]:::obs
    L8N5["PagerDuty"]:::obs

    L0N0 --> L1N0
    L0N0 --> L1N1
    L0N1 --> L1N1
    L0N2 --> L1N2
    L0N2 --> L1N3
    L0N3 --> L1N3
    L0N4 --> L1N4
    L0N4 --> L1N5
    L0N5 --> L1N5

    L1N0 --> L2N0
    L1N0 --> L2N1
    L1N1 --> L2N1
    L1N2 --> L2N2
    L1N2 --> L2N3
    L1N3 --> L2N3
    L1N4 --> L2N4
    L1N4 --> L2N5
    L1N5 --> L2N5

    L2N0 --> L3N0
    L2N0 --> L3N1
    L2N1 --> L3N1
    L2N2 --> L3N2
    L2N2 --> L3N3
    L2N3 --> L3N3
    L2N4 --> L3N4
    L2N4 --> L3N5
    L2N5 --> L3N5

    L3N0 --> L4N0
    L3N0 --> L4N1
    L3N1 --> L4N1
    L3N2 --> L4N2
    L3N2 --> L4N3
    L3N3 --> L4N3
    L3N4 --> L4N4
    L3N4 --> L4N5
    L3N5 --> L4N5

    L4N0 --> L5N0
    L4N0 --> L5N1
    L4N1 --> L5N1
    L4N2 --> L5N2
    L4N2 --> L5N3
    L4N3 --> L5N3
    L4N4 --> L5N4
    L4N4 --> L5N5
    L4N5 --> L5N5

    L5N0 --> L6N0
    L5N0 --> L6N1
    L5N1 --> L6N1
    L5N2 --> L6N2
    L5N2 --> L6N3
    L5N3 --> L6N3
    L5N4 --> L6N4
    L5N4 --> L6N5
    L5N5 --> L6N5

    L6N0 --> L7N0
    L6N0 --> L7N1
    L6N1 --> L7N1
    L6N2 --> L7N2
    L6N2 --> L7N3
    L6N3 --> L7N3
    L6N4 --> L7N4
    L6N4 --> L7N5
    L6N5 --> L7N5

    L7N0 --> L8N0
    L7N0 --> L8N1
    L7N1 --> L8N1
    L7N2 --> L8N2
    L7N2 --> L8N3
    L7N3 --> L8N3
    L7N4 --> L8N4
    L7N4 --> L8N5
    L7N5 --> L8N5
```

### Direção `RL`

Da direita para a esquerda, com os rótulos de aresta em português e uma decisão.

```mermaid
flowchart RL
    A([Início]) --> B{Tem cache?}
    B -->|sim| C[Lê do cache]
    B -->|não| D[Chama o crate]
    D --> E{Deu certo?}
    E -->|sim| F[Guarda no cache]
    E -->|não| G[Cai para código cru]
    F --> H([Desenha])
    C --> H
    G --> I([Nota sob o bloco])
    H --> J[(Preview)]
    I --> J
```

### Direção `BT`

De baixo para cima: uma pilha de camadas, cada uma apoiada na anterior.

```mermaid
flowchart BT
    L0[Hardware]
    L1[Kernel]
    L2[Terminal]
    L3[Neovim]
    L4[deckle.nvim]
    L5[Preview]
    L0 --> L1 --> L2 --> L3 --> L4 --> L5
    L3 -->|API Lua| L4
    L4 -->|mlua| R[deckle_native.so]
    R -->|merman| M[Mermaid em texto]
    M --> L5
```

### Sintaxe nova de forma: `@{ shape: ... }`

```mermaid
flowchart LR
    A@{ shape: rect, label: "Retângulo" }
    B@{ shape: rounded, label: "Arredondado" }
    C@{ shape: stadium, label: "Estádio" }
    D@{ shape: cyl, label: "Banco" }
    E@{ shape: diamond, label: "Decisão" }
    F@{ shape: hex, label: "Hexágono" }
    G@{ shape: circle, label: "Círculo" }
    H@{ shape: doc, label: "Documento" }
    A --> B --> C --> D
    D --> E
    E --> F
    E --> G
    F --> H
    G --> H
```

## sequence

Todos os tipos de seta, `autonumber`, `box`, `create`/`destroy`, ativação com `+`/`-`,
`loop`/`alt`/`else`/`opt`/`par`/`and`/`critical`/`option`/`break`, `rect` e as três
posições de nota.

```mermaid
sequenceDiagram
    autonumber
    actor U as 👤 Usuário
    box rgb(230, 240, 255) Cliente
        participant N as Neovim
        participant L as deckle (Lua)
    end
    box Aqua Nativo
        participant R as deckle_native
        participant M as merman
    end
    participant FS as Sistema de arquivos

    U->>N: :Deckle open
    activate N
    N->>L: preview.open()
    activate L
    L->>FS: lê o buffer
    FS-->>L: linhas
    L->>L: parse (treesitter)

    rect rgb(230, 255, 230)
        Note over L,R: Cada bloco mermaid
        loop Para cada bloco
            L->>+R: render(src, opts)
            R->>+M: parse + layout
            M-->>-R: linhas
            alt render deu certo
                R-->>L: linhas
            else erro de sintaxe
                R--)L: erro legível
                Note right of L: vira código com nota
            else tipo não coberto
                R-x L: unsupported
            end
            deactivate R
        end
    end

    rect rgb(245, 230, 255)
        par desenha o preview
            L->>N: escreve o buffer
        and guarda o cache
            L->>L: SHA-256 do bloco
        and move o cursor
            L-)N: sync de cursor
        end
    end

    opt o usuário edita
        U->>N: digita
        N-)L: TextChanged
        Note left of N: debounce de 150 ms
    end

    critical lê a configuração
        L->>FS: lê o arquivo de config
        FS-->>L: ok
    option arquivo ausente
        L->>L: usa os valores de fábrica
    end

    break o módulo nativo não carregou
        L->>N: camada 0
    end

    create participant C as Cache
    L->>C: guarda as linhas
    L->>C: consulta
    C-->>L: acerto
    destroy C
    L-xC: descarta

    Note over U,N: Fim do ciclo
    L-->>N: pronto
    deactivate L
    N-->>U: preview na tela
    deactivate N
```

## class

Genéricos, visibilidade (`+ - # ~`), métodos abstratos (`*`) e estáticos (`$`), anotações,
todos os tipos de relação com cardinalidade e rótulo, `namespace`, notas e estilo.

```mermaid
classDiagram
    direction TB

    class Preview {
        <<service>>
        -int bufnr
        -int winid
        #Config config
        +open() void
        +close() void
        +refresh(force: bool) void
        ~on_resize() void
        +state(src: int)$ State
    }

    class Renderer {
        <<interface>>
        +render(block, ctx)* Lines
    }

    class MermaidRenderer {
        +render(block, ctx) Lines
        -draw(block, ctx) Lines
        -degrade(block, ctx) Lines
    }

    class CodeRenderer {
        +render(block, ctx) Lines
    }

    class Cache~K, V~ {
        -int limit
        -Map~K, V~ entries
        +get(key: K) V
        +put(key: K, value: V) void
        +stats() Stats
    }

    class Stats {
        +int hits
        +int misses
        +int size
    }

    class Native {
        <<singleton>>
        +get() Module
        +status() Status
        +reset()$ void
    }

    class Block {
        <<abstract>>
        +kind string
        +src_start int
        +src_end int
    }

    class CodeBlock {
        +lang string
        +lines string[]
    }

    class Config {
        <<enumeration>>
        UNICODE
        ASCII
        AUTO
    }

    namespace Render {
        class Table
        class Heading
    }

    Renderer <|.. MermaidRenderer : implementa
    Renderer <|.. CodeRenderer : implementa
    Block <|-- CodeBlock : herda
    Preview "1" *-- "many" Block : contém
    Preview "1" o-- "1" Cache : usa
    Cache "1" --> "1" Stats : produz
    MermaidRenderer ..> Native : depende
    MermaidRenderer --> Cache : consulta
    MermaidRenderer ..> CodeRenderer : degrada para
    Preview --> Renderer
    Preview -- Config
    Table ..|> Renderer
    Heading ..|> Renderer
    CodeBlock "0..*" -- "1" Preview : aparece em

    note "Todo render devolve linhas e marcas"
    note for MermaidRenderer "Cai para código cru com uma nota"

    classDef core fill:#e3f2fd,stroke:#1565c0
    cssClass "Preview,Renderer" core
    style Native fill:#fff3e0,stroke:#e65100
```

## state

`[*]`, `<<choice>>`, `<<fork>>`, `<<join>>`, notas e `classDef`, numa máquina de 14 estados.
O segundo diagrama é um estado composto. O layout de texto do merman só desenha o composto
na forma mais simples (entra por um estado, tem `[*]` no começo e no fim, sai para `[*]`):
composto com aresta de volta, composto dentro de composto e concorrência com `--` ficam de
fora (ver `:help deckle-limitations`).

```mermaid
stateDiagram-v2
    classDef ruim fill:#f8d7da,stroke:#dc3545
    classDef bom fill:#d4edda,stroke:#28a745
    classDef neutro fill:#e3f2fd,stroke:#1565c0

    [*] --> Fechado
    Fechado --> Abrindo : :Deckle open
    Abrindo --> Parse : buffer lido
    Parse --> Escolha
    state Escolha <<choice>>
    Escolha --> Mermaid : bloco mermaid
    Escolha --> Texto : outro bloco

    state fork_in <<fork>>
    state join_out <<join>>
    Mermaid --> fork_in
    fork_in --> Cache : consulta
    fork_in --> Nativo : chama o crate
    Cache --> join_out : acerto
    Nativo --> join_out : linhas
    join_out --> Pronto
    Texto --> Pronto

    Nativo --> Erro : falha
    Erro --> Degradado : nota sob o bloco
    Degradado --> Pronto

    Pronto --> Aberto : escreve o buffer
    Aberto --> Fechando : :Deckle close

    Fechando --> [*]

    note right of Fechado
        Estado inicial e final
    end note
    note left of Erro : degrada só o bloco
    note right of Cache : LRU de 64 entradas

    class Erro ruim
    class Degradado ruim
    class Pronto bom
    class Aberto bom
    class Cache neutro
```

```mermaid
stateDiagram-v2
    [*] --> Fechado
    Fechado --> Aberto : :Deckle open
    state Aberto {
        [*] --> Ocioso
        Ocioso --> Renderizando : TextChanged
        Renderizando --> Sincronizando : pronto
        Sincronizando --> Atualizado : CursorMoved
        Atualizado --> [*]
    }
    Aberto --> [*]
```

## er

Dez entidades, todas as cardinalidades, atributos com `PK`, `FK`, `UK` e comentários.

```mermaid
erDiagram
    CLIENTE ||--o{ PEDIDO : faz
    CLIENTE }o--o{ ENDERECO : mora
    CLIENTE ||--|| PERFIL : tem
    PEDIDO ||--|{ ITEM : contém
    PEDIDO |o--o| CUPOM : aplica
    PEDIDO ||--o| PAGAMENTO : paga
    PRODUTO ||--o{ ITEM : aparece
    PRODUTO }|--|{ CATEGORIA : classifica
    FORNECEDOR }o--o{ PRODUTO : fornece
    PAGAMENTO }o..o{ ESTORNO : gera

    CLIENTE {
        int id PK
        string email UK "login do cliente"
        string nome
        date nascimento
    }
    ENDERECO {
        int id PK
        string rua
        string cep
        string cidade
    }
    PERFIL {
        int cliente_id PK, FK
        string avatar
        string bio "texto livre"
    }
    PEDIDO {
        int id PK
        int cliente_id FK
        int cupom_id FK
        datetime criado_em
        string status "aberto, pago ou cancelado"
    }
    ITEM {
        int pedido_id PK, FK
        int produto_id PK, FK
        int quantidade
        decimal preco
    }
    PRODUTO {
        int id PK
        string sku UK
        string nome
        decimal preco
    }
    CATEGORIA {
        int id PK
        string nome UK
    }
    FORNECEDOR {
        int id PK
        string cnpj UK
        string razao_social
    }
    CUPOM {
        int id PK
        string codigo UK
        decimal desconto
    }
    PAGAMENTO {
        int id PK
        int pedido_id FK
        string metodo
        decimal valor
    }
    ESTORNO {
        int id PK
        int pagamento_id FK
        decimal valor
    }
```

## gantt

```mermaid
gantt
    title Plano das fases do deckle.nvim
    dateFormat YYYY-MM-DD
    axisFormat %d/%m
    tickInterval 1week
    weekday monday
    excludes weekends
    todayMarker off

    section Fundação
    Parser com treesitter          :done, f1, 2026-08-03, 5d
    Render de texto                :done, f2, after f1, 4d
    Tabelas e código               :done, f3, after f2, 6d
    Cursor sincronizado            :done, f4, after f3, 4d
    Imagens por Unicode            :done, f5, after f3, 5d

    section Mermaid
    Crate deckle-native            :done, m1, after f4, 5d
    Mermaid no preview             :done, m2, after m1, 4d
    Cache por hash                 :done, m3, after m2, 2d
    Perfil compacto                :done, m4, after m2, 3d
    Distribuição em 6 alvos        :done, m5, after m3, 6d
    Instalador com checksum        :done, m6, after m5, 3d

    section Qualidade
    Fuzz do parser                 :done, q1, after f2, 7d
    Benchmark do flowchart         :done, q2, after m1, 2d
    Gate de CI                     :done, q3, after m6, 2d
    Validação em terminal de verdade :active, q4, after q3, 4d

    section Entrega
    Documentação                   :active, d1, after m6, 3d
    Correção dos subgraphs         :crit, active, d2, after d1, 2d
    Showcase do Mermaid            :crit, d3, after d2, 2d
    Revisão                        :d4, after d3, 2d
    Release v0.3                   :milestone, crit, rel, after d4, 0d
    Pós-release                    :d5, after rel, 5d
```

## gitgraph

Branches, merges, `cherry-pick`, tags e commits de tipos diferentes.

```mermaid
gitGraph
    commit id: "inicio"
    commit id: "parser" tag: "v0.1.0"
    branch feat/mermaid
    checkout feat/mermaid
    commit id: "crate"
    commit id: "binding"
    branch fix/cache
    checkout fix/cache
    commit id: "sha256" type: HIGHLIGHT
    commit id: "lru"
    checkout feat/mermaid
    merge fix/cache id: "merge-cache"
    commit id: "preview"
    branch feat/imagens
    checkout feat/imagens
    commit id: "kitty"
    commit id: "png"
    checkout main
    commit id: "docs"
    branch hotfix
    checkout hotfix
    commit id: "tab" type: REVERSE
    commit id: "tab-2"
    checkout main
    merge hotfix tag: "v0.1.1"
    merge feat/mermaid id: "merge-mermaid" tag: "v0.2.0"
    checkout feat/imagens
    commit id: "placeholder"
    checkout main
    merge feat/imagens id: "merge-imagens"
    branch release/0.3
    checkout release/0.3
    commit id: "freeze"
    cherry-pick id: "sha256"
    commit id: "versao"
    checkout main
    commit id: "feature-nova"
    merge release/0.3 tag: "v0.3.0"
    commit id: "pos-release"
```

## journey

```mermaid
journey
    title A jornada de quem abre o preview
    section Descobrir
        Ver o plugin no README de outro projeto: 3: Dev
        Ler o README: 4: Dev
        Comparar com o markview.nvim: 3: Dev
    section Instalar
        Adicionar ao lazy.nvim: 4: Dev
        Rodar :Deckle install: 3: Dev
        Conferir o checkhealth: 5: Dev
    section Usar
        Abrir o preview: 5: Dev, Neovim
        Rolar o documento: 4: Dev
        Ver o diagrama desenhado: 5: Dev, Neovim, merman
        Editar o diagrama: 3: Dev
        Seguir o cursor entre os dois lados: 5: Dev, Neovim
    section Quando algo falha
        Ler a nota sob o bloco: 3: Dev
        Corrigir a sintaxe: 2: Dev
        Abrir uma issue: 1: Dev, Mantenedor
        Receber a correção: 5: Dev, Mantenedor
```

## kanban

```mermaid
kanban
    backlog[Backlog]
        b1[Suporte a imagens SVG]
        b2[Tema claro]
        b3[Exportar o preview]@{ priority: 'Very Low' }
        b4[Mermaid em imagem pelo mmdc]@{ ticket: 'DK-150', priority: 'Low' }
    todo[A fazer]
        t1[Fallback de subgraph]@{ assigned: 'samuka', ticket: 'DK-101', priority: 'High' }
        t2[Showcase do Mermaid]@{ assigned: 'samuka', ticket: 'DK-102', priority: 'Very High' }
        t3[Subir o merman para a 0.10]@{ assigned: 'samuka', ticket: 'DK-103', priority: 'High' }
        t4[Tipos novos no checkhealth]@{ ticket: 'DK-104', priority: 'Low' }
    doing[Em andamento]
        d1[Revisar o ADR-0002]@{ ticket: 'DK-099', priority: 'Low' }
        d2[Medir o preview no kitty]@{ assigned: 'ana', ticket: 'DK-097', priority: 'Very High' }
        d3[Documentar as limitações]@{ assigned: 'ana', ticket: 'DK-098' }
    review[Em revisão]
        r1[Cache de render]@{ assigned: 'ana', ticket: 'DK-088' }
        r2[Perfil compacto]@{ assigned: 'bruno', ticket: 'DK-090' }
    done[Pronto]
        o1[Distribuição]
        o2[Documentação]
        o3[Release v0.3]
        o4[Instalador com checksum]
        o5[Fuzz do parser]
```

## mindmap

Formas de nó (`[ ]`, `( )`, `(( ))`, `)) ((`, `) (`, `{{ }}`), ícones e classes.

```mermaid
mindmap
    root((deckle.nvim))
        Camadas
            [Camada 0]
                Texto
                Tabelas
                Código colorido
                HTML cru
            (Camada 1)
                Mermaid em texto
                ::icon(fa fa-project-diagram)
                14 tipos de diagrama
            ((Camada 2))
                Imagens PNG
                Kitty e ghostty
                Unicode placeholders
        Decisões
            ))ADR-0001((
                Rust nunca chama o Neovim
            )ADR-0002(
                merman em vez de código próprio
            {{ADR-0003}}
                Fonte intocável
            ADR-0004
                Degradação em camadas
            ADR-0005
                Piso do Neovim 0.11
        Riscos
            merman quebra API entre versões
            MSRV 1.95
            Parser aborta com aninhamento fundo
            Layout de texto não roteia tudo
        Ferramentas
            mlua
            treesitter
            mini.test
            stylua
            selene
        Distribuição
            Release com 6 alvos
            Checksum SHA-256
            Cai para o cargo
```

## packet

```mermaid
packet-beta
    0-15: "Porta de origem"
    16-31: "Porta de destino"
    32-63: "Número de sequência"
    64-95: "Número de confirmação"
    96-99: "Offset"
    100-105: "Reservado"
    106-111: "Flags"
    112-127: "Janela"
    128-143: "Checksum"
    144-159: "Ponteiro urgente"
    160-191: "Opções (se houver)"
```

## timeline

```mermaid
timeline
    title A história do deckle.nvim
    section 2026 · Fundação
        Agosto : Ideia e validação (V1 a V8)
               : Decisão sobre o merman
               : ADR-0001 a ADR-0005
        Setembro : Parser e render de texto
                 : Tabelas e código colorido
                 : Cursor sincronizado
    section 2026 · Mermaid
        Outubro : Crate deckle-native
                : Mermaid no preview
                : Imagens por Unicode placeholders
                : Cache por hash do bloco
        Novembro : Distribuição em seis alvos
                 : Documentação
                 : Release v0.3
                 : merman 0.10 e o showcase do Mermaid
    section 2027 · Depois
        Planejado : Tema claro
                  : Camada 3 com o mmdc
```

## treeView

```mermaid
treeView-beta
    "deckle.nvim"
        "lua"
            "deckle"
                "init.lua"
                "config.lua"
                "parse.lua"
                "preview.lua"
                "sync.lua"
                "highlight.lua"
                "health.lua"
                "install.lua"
                "native.lua"
                "render"
                    "init.lua"
                    "mermaid.lua"
                    "code.lua"
                    "table.lua"
                    "heading.lua"
                    "list.lua"
                    "quote.lua"
                "image"
                    "init.lua"
                    "kitty.lua"
                    "png.lua"
        "crates"
            "deckle-native"
                "src"
                    "lib.rs"
                    "render.rs"
                    "binding.rs"
                    "render_tests.rs"
                "tests"
                    "fixtures"
                        "ilza_architecture.mmd"
                        "ilza_modules.mmd"
                "Cargo.toml"
        "docs"
            "adr"
                "0001-rust-isolado.md"
                "0002-merman.md"
            "architecture.md"
            "roadmap.md"
            "validation.md"
        "examples"
            "showcase.md"
            "mermaid.md"
        "scripts"
            "test.sh"
            "test-native.sh"
            "check-merman-version.sh"
        "tests"
            "native"
```

## xychart

Barras e linhas no mesmo gráfico, eixos com rótulo e a orientação horizontal.

```mermaid
xychart-beta
    title "Tempo de render por tamanho do flowchart"
    x-axis "Arestas" [6, 12, 24, 36, 48, 72, 96, 120]
    y-axis "Milissegundos" 0 --> 120
    bar [1, 3, 9, 20, 46, 78, 110, 118]
    line [1, 3, 9, 20, 46, 78, 110, 118]
    line [1, 2, 6, 11, 19, 33, 52, 70]
```

```mermaid
xychart-beta horizontal
    title "Blocos por tipo no showcase"
    x-axis [flowchart, sequence, class, state, er, gantt, gitgraph, journey, kanban, mindmap, packet, timeline, treeView, xy]
    y-axis "Blocos" 0 --> 8
    bar [6, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]
```

## README do ILZA

Dois diagramas reais, copiados sem alteração do README de um projeto (o bug report que
motivou este arquivo): um `flowchart TB` com subgraphs aninhados e `direction` diferentes e um
`graph LR` com subgraphs. O renderer de texto do merman não consegue rotear as arestas que
cruzam as bordas dos grupos (`routes crossing reserved graph geometry`, `unroutable graph
edges`): antes da correção o preview mostrava só o código e essa nota. Agora o deckle desenha
o grafo **sem as bordas dos grupos** (os nós e as arestas ficam) e diz isso numa linha sob o
desenho. São os dois únicos blocos deste arquivo com esse aviso.

```mermaid
flowchart TB
    subgraph Cliente["🖥️ Cliente"]
        FE["Frontend\n(React / Next.js)"]
    end

    subgraph API["⚡ FastAPI — API REST :8000"]
        direction TB
        HEALTH["/health"]
        CORS["CORS Middleware"]
        RATELIMIT["Rate Limit Middleware"]
        DB_MW["DB Session Middleware"]

        subgraph Modules["Módulos da Aplicação"]
            direction LR
            subgraph AuthMod["🔐 Auth Module"]
                AUTH_CTRL["Auth Controller"]
                AUTH_UC["Use Cases\nLogin · Register\nRefresh · Logout\nGet Me"]
                AUTH_DOMAIN["Domain\nUser · Role\nToken Payload\nRefresh Token"]
                AUTH_INFRA["Infrastructure\nBCrypt Hasher\nJWT Token Service\nUser Repository\nRefresh Token Repo"]
            end

            subgraph PatientsMod["👤 Patients Module"]
                PAT_CTRL["Patients Controller"]
                PAT_UC["Use Cases\nGet · List · Update\nFind by CPF\nFind or Create"]
                PAT_DOMAIN["Domain\nPatient Entity\nCPF · Sex VOs"]
                PAT_INFRA["Infrastructure\nPatient Repository\nPessoa Model"]
            end
        end
    end

    subgraph AI["🧠 Domínio IA (ai/)"]
        direction TB

        ENGINE["TriageEngine\n(ITriageEngine)"]

        subgraph Agents["Agentes"]
            direction LR
            TRIAGE_AG["TriageAgent\n(Protocolo Manchester)"]
            SPEC_AG["SpecialistAgent\n(Anamnese Aprofundada)"]
        end

        subgraph AISupport["Suporte IA"]
            direction LR
            PROMPTS["Prompts\nTriage Instructions\nSpecialist Instructions"]
            GUARDRAIL["OpenAI Guardrail\n+ Rules"]
            SESSION["FileSessionManager\n(ISessionManager)"]
            TOOL["Report Tool\n(IReportTool)"]
        end

        DI["DI Factory\ncreate_triage_engine()"]
    end

    subgraph Temporal["⏱️ Temporal.io"]
        direction LR
        TEMPORAL_SRV["Temporal Server\n:7233"]
        TEMPORAL_UI["Temporal UI\n:8233"]
        WORKER["Temporal Worker\nTriageWorkflow"]
    end

    subgraph Infra["🏗️ Infraestrutura"]
        direction LR
        PG[("PostgreSQL 16\nApp DB\n:5432")]
        PG_TEMP[("PostgreSQL 16\nTemporal DB\n:5433")]
        REDIS[("Redis 7\n:6379")]
    end

    subgraph External["☁️ Serviços Externos"]
        direction LR
        OPENAI["OpenAI API\nGPT-5\nGPT-4.1-mini"]
        S3["AWS S3\nRelatórios PDF"]
    end

    %% ── Fluxo Principal ──
    FE -->|"HTTP/REST"| API
    AUTH_CTRL --> AUTH_UC --> AUTH_DOMAIN
    AUTH_UC --> AUTH_INFRA
    PAT_CTRL --> PAT_UC --> PAT_DOMAIN
    PAT_UC --> PAT_INFRA

    %% ── API → IA ──
    API -->|"Triagem Request"| ENGINE
    ENGINE --> TRIAGE_AG
    TRIAGE_AG -->|"Handoff"| SPEC_AG
    TRIAGE_AG --> PROMPTS
    SPEC_AG --> PROMPTS
    SPEC_AG --> TOOL
    ENGINE --> GUARDRAIL
    ENGINE --> SESSION
    DI -->|"Compõe"| ENGINE

    %% ── Temporal ──
    API -->|"Start Workflow"| TEMPORAL_SRV
    TEMPORAL_SRV --> WORKER
    WORKER -->|"Executa"| ENGINE
    TEMPORAL_SRV --> PG_TEMP
    TEMPORAL_UI --> TEMPORAL_SRV

    %% ── Infra ──
    AUTH_INFRA --> PG
    PAT_INFRA --> PG
    AUTH_INFRA -->|"Rate Limit"| REDIS

    %% ── Externos ──
    TRIAGE_AG -->|"LLM Call"| OPENAI
    SPEC_AG -->|"LLM Call"| OPENAI
    GUARDRAIL -->|"Validação"| OPENAI
    TOOL -->|"Upload PDF"| S3

    %% ── Estilos ──
    classDef clientStyle fill:#e3f2fd,stroke:#1565c0,stroke-width:2px,color:#0d47a1
    classDef apiStyle fill:#fff3e0,stroke:#e65100,stroke-width:2px,color:#bf360c
    classDef aiStyle fill:#f3e5f5,stroke:#6a1b9a,stroke-width:2px,color:#4a148c
    classDef temporalStyle fill:#e8f5e9,stroke:#2e7d32,stroke-width:2px,color:#1b5e20
    classDef infraStyle fill:#fce4ec,stroke:#c62828,stroke-width:2px,color:#b71c1c
    classDef extStyle fill:#fff8e1,stroke:#f57f17,stroke-width:2px,color:#e65100

    class FE clientStyle
    class HEALTH,CORS,RATELIMIT,DB_MW,AUTH_CTRL,AUTH_UC,AUTH_DOMAIN,AUTH_INFRA,PAT_CTRL,PAT_UC,PAT_DOMAIN,PAT_INFRA apiStyle
    class ENGINE,TRIAGE_AG,SPEC_AG,PROMPTS,GUARDRAIL,SESSION,TOOL,DI aiStyle
    class TEMPORAL_SRV,TEMPORAL_UI,WORKER temporalStyle
    class PG,PG_TEMP,REDIS infraStyle
    class OPENAI,S3 extStyle
```

```mermaid
graph LR
    subgraph app["app/"]
        direction TB
        APP_PY["app.py\n(create_app)"]

        subgraph shared["shared/"]
            SETTINGS["Settings"]
            DB_CONN["DB Connection"]
            EXCEPTIONS["Domain Exceptions"]
            MIDDLEWARES["CORS · Rate Limit"]
        end

        subgraph auth["modules/auth/"]
            A_PRES["Presentation\nController · DTOs"]
            A_APP["Application\nUse Cases"]
            A_DOMAIN["Domain\nEntities · VOs · Interfaces"]
            A_INFRA["Infrastructure\nRepositories · Services"]
        end

        subgraph patients["modules/patients/"]
            P_PRES["Presentation\nController · DTOs"]
            P_APP["Application\nUse Cases"]
            P_DOMAIN["Domain\nEntities · VOs · Interfaces"]
            P_INFRA["Infrastructure\nRepositories · Models"]
        end
    end

    subgraph ai["ai/"]
        direction TB
        subgraph core["core/ (Interfaces)"]
            I_ENGINE["ITriageEngine"]
            I_RESPONSE["AgentResponse\nSessionState"]
            BASE_AGENT["BaseAgent\nRawAgentResult"]
        end

        subgraph agents["agents/"]
            TRIAGE["TriageAgent"]
            SPECIALIST["SpecialistAgent"]
            TYPES["Response Types"]
        end

        subgraph support["Suporte"]
            PROMPTS_MOD["prompts/"]
            GUARDRAILS_MOD["guardrails/"]
            SESSION_MOD["session/"]
            TOOLS_MOD["tools/"]
        end

        AI_ENGINE["engine.py\nTriageEngine"]
        AI_DI["di.py\nFactory DI"]

        subgraph workflows["workflows/"]
            WF["TriageWorkflow"]
            WK["Worker"]
        end
    end

    A_PRES --> A_APP --> A_DOMAIN
    A_APP --> A_INFRA
    P_PRES --> P_APP --> P_DOMAIN
    P_APP --> P_INFRA

    AI_DI --> AI_ENGINE
    AI_ENGINE --> TRIAGE
    AI_ENGINE --> SPECIALIST
    TRIAGE --> PROMPTS_MOD
    SPECIALIST --> PROMPTS_MOD
    AI_ENGINE --> GUARDRAILS_MOD
    AI_ENGINE --> SESSION_MOD
    SPECIALIST --> TOOLS_MOD
    WF --> AI_ENGINE

    classDef appColor fill:#fff3e0,stroke:#e65100,color:#bf360c
    classDef aiColor fill:#f3e5f5,stroke:#6a1b9a,color:#4a148c
    classDef coreColor fill:#e8eaf6,stroke:#283593,color:#1a237e

    class APP_PY,SETTINGS,DB_CONN,EXCEPTIONS,MIDDLEWARES,A_PRES,A_APP,A_DOMAIN,A_INFRA,P_PRES,P_APP,P_DOMAIN,P_INFRA appColor
    class TRIAGE,SPECIALIST,TYPES,PROMPTS_MOD,GUARDRAILS_MOD,SESSION_MOD,TOOLS_MOD,AI_ENGINE,AI_DI,WF,WK aiColor
    class I_ENGINE,I_RESPONSE,BASE_AGENT coreColor
```

## Degradação esperada

O renderer de texto não cobre todos os tipos. Um `pie` vira código com uma nota sob a
moldura, e só esse bloco: o resto do arquivo não muda. É o único bloco deste arquivo que
deve degradar.

```mermaid
pie title Cobertura do showcase
    "Tipos desenhados" : 14
    "Tipos que degradam" : 1
```
