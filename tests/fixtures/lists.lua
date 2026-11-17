return {
  {
    kind = "list",
    items = {
      {
        children = {},
        spans = { { kind = "text", text = "um" } },
        src_start = 0,
        src_end = 1,
      },
      {
        children = {
          {
            kind = "list",
            items = {
              {
                children = {},
                spans = { { kind = "text", text = "dois ponto um" } },
                src_start = 2,
                src_end = 3,
              },
              {
                children = {
                  {
                    kind = "list",
                    items = {
                      {
                        children = {},
                        spans = { { kind = "text", text = "profundo" } },
                        src_start = 4,
                        src_end = 5,
                      },
                    },
                    ordered = true,
                    start = 1,
                    src_start = 4,
                    src_end = 5,
                  },
                },
                spans = { { kind = "text", text = "dois ponto dois" } },
                src_start = 3,
                src_end = 5,
              },
            },
            ordered = false,
            src_start = 2,
            src_end = 5,
          },
        },
        spans = { { kind = "text", text = "dois" } },
        src_start = 1,
        src_end = 5,
      },
      {
        children = {},
        spans = { { kind = "text", text = "três" } },
        src_start = 5,
        src_end = 6,
      },
    },
    ordered = false,
    src_start = 0,
    src_end = 6,
  },
  {
    kind = "list",
    items = {
      {
        checked = false,
        children = {},
        spans = { { kind = "text", text = "tarefa aberta" } },
        src_start = 7,
        src_end = 8,
      },
      {
        checked = true,
        children = {},
        spans = { { kind = "text", text = "tarefa feita" } },
        src_start = 8,
        src_end = 9,
      },
      {
        checked = true,
        children = {},
        spans = { { kind = "text", text = "tarefa em maiúscula" } },
        src_start = 9,
        src_end = 10,
      },
    },
    ordered = false,
    src_start = 7,
    src_end = 10,
  },
  {
    kind = "list",
    items = {
      {
        children = {},
        spans = { { kind = "text", text = "estrela" } },
        src_start = 11,
        src_end = 12,
      },
    },
    ordered = false,
    src_start = 11,
    src_end = 12,
  },
  {
    kind = "list",
    items = {
      {
        children = {},
        spans = { { kind = "text", text = "terceiro" } },
        src_start = 13,
        src_end = 14,
      },
      {
        children = {},
        spans = { { kind = "text", text = "quarto" } },
        src_start = 14,
        src_end = 15,
      },
    },
    ordered = true,
    start = 3,
    src_start = 13,
    src_end = 15,
  },
  {
    kind = "list",
    items = {
      {
        children = {},
        spans = { { kind = "text", text = "parêntese" } },
        src_start = 16,
        src_end = 17,
      },
      {
        children = {},
        spans = { { kind = "text", text = "parêntese" } },
        src_start = 17,
        src_end = 18,
      },
    },
    ordered = true,
    start = 1,
    src_start = 16,
    src_end = 18,
  },
  {
    kind = "list",
    items = {
      {
        children = {
          {
            kind = "paragraph",
            spans = { { kind = "text", text = "segundo parágrafo do item" } },
            src_start = 21,
            src_end = 22,
          },
          {
            kind = "code",
            lang = "sh",
            lines = { "echo dentro do item" },
            src_start = 23,
            src_end = 26,
          },
        },
        spans = { { kind = "text", text = "item com vários parágrafos" } },
        src_start = 19,
        src_end = 26,
      },
      {
        children = {},
        spans = {
          { kind = "text", text = "item " },
          { kind = "strong", children = { { kind = "text", text = "solto" } } },
          { kind = "text", text = " com " },
          { kind = "code", text = "código" },
        },
        src_start = 27,
        src_end = 28,
      },
    },
    ordered = false,
    src_start = 19,
    src_end = 28,
  },
}
