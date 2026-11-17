return {
  {
    kind = "list",
    items = {
      {
        children = {
          {
            kind = "quote",
            children = {
              {
                kind = "paragraph",
                spans = { { kind = "text", text = "citação no nível dois" } },
                src_start = 1,
                src_end = 2,
              },
              {
                kind = "list",
                items = {
                  {
                    children = {
                      {
                        kind = "list",
                        items = {
                          {
                            children = {},
                            spans = { { kind = "text", text = "lista no nível quatro" } },
                            src_start = 4,
                            src_end = 5,
                          },
                        },
                        ordered = false,
                        src_start = 4,
                        src_end = 5,
                      },
                      {
                        kind = "quote",
                        children = {
                          {
                            kind = "paragraph",
                            spans = { { kind = "text", text = "citação no nível cinco" } },
                            src_start = 6,
                            src_end = 7,
                          },
                        },
                        src_start = 6,
                        src_end = 7,
                      },
                    },
                    spans = { { kind = "text", text = "lista no nível três" } },
                    src_start = 3,
                    src_end = 7,
                  },
                },
                ordered = false,
                src_start = 3,
                src_end = 7,
              },
            },
            src_start = 1,
            src_end = 7,
          },
        },
        spans = { { kind = "text", text = "nível um" } },
        src_start = 0,
        src_end = 7,
      },
    },
    ordered = false,
    src_start = 0,
    src_end = 7,
  },
  {
    kind = "quote",
    children = {
      {
        kind = "list",
        items = {
          {
            children = {
              {
                kind = "quote",
                children = {
                  {
                    kind = "paragraph",
                    spans = { { kind = "text", text = "citação dentro dessa lista" } },
                    src_start = 9,
                    src_end = 10,
                  },
                  {
                    kind = "list",
                    items = {
                      {
                        children = {},
                        spans = { { kind = "text", text = "e outra lista mais funda" } },
                        src_start = 11,
                        src_end = 12,
                      },
                    },
                    ordered = false,
                    src_start = 11,
                    src_end = 12,
                  },
                },
                src_start = 9,
                src_end = 12,
              },
            },
            spans = { { kind = "text", text = "lista dentro de citação" } },
            src_start = 8,
            src_end = 12,
          },
        },
        ordered = false,
        src_start = 8,
        src_end = 12,
      },
    },
    src_start = 8,
    src_end = 12,
  },
  {
    kind = "list",
    items = {
      {
        children = {
          {
            kind = "list",
            items = {
              {
                children = {
                  {
                    kind = "quote",
                    children = {
                      {
                        kind = "paragraph",
                        spans = { { kind = "text", text = "e citação" } },
                        src_start = 15,
                        src_end = 16,
                      },
                    },
                    src_start = 15,
                    src_end = 16,
                  },
                },
                spans = { { kind = "text", text = "com sublista" } },
                src_start = 14,
                src_end = 16,
              },
            },
            ordered = false,
            src_start = 14,
            src_end = 16,
          },
        },
        spans = { { kind = "text", text = "ordenada" } },
        src_start = 13,
        src_end = 16,
      },
    },
    ordered = true,
    start = 1,
    src_start = 13,
    src_end = 16,
  },
}
