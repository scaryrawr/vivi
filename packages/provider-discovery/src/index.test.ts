import { describe, expect, test } from "bun:test";
import { discoverLocalProviders } from "./index.ts";

describe("discoverLocalProviders", () => {
  test("discovers every supported local provider", async () => {
    const configuration = await discoverLocalProviders(
      {
        OLLAMA_CONTEXT_LENGTH: "8192",
        GENIEX_CONTEXT_LENGTH: "32768",
      },
      async (input) => {
        const url = String(input);
        if (url.endsWith(":11434/api/tags")) {
          return response({ models: [{ name: "qwen", model: "Qwen" }] });
        }
        if (url.endsWith(":1234/api/v1/models")) {
          return response({
            models: [
              {
                key: "lm-model",
                display_name: "LM Model",
                max_context_length: 16_384,
              },
            ],
          });
        }
        if (url.endsWith(":8000/v1/models/status")) {
          return response({
            models: [
              {
                id: "mlx-vlm",
                model_type: "vlm",
                max_context_window: 65_536,
                max_tokens: 16_384,
              },
            ],
          });
        }
        if (url.endsWith(":1337/api/tags")) {
          return response({ models: [{ name: "osaurus-model" }] });
        }
        if (url.endsWith(":18181/v1/models")) {
          return response({ data: [{ id: "geniex-model" }] });
        }
        throw new Error(`unexpected request: ${url}`);
      },
    );

    expect(configuration.providers.map(({ name }) => name)).toEqual([
      "ollama",
      "lmstudio",
      "omlx",
      "osaurus",
      "geniex",
    ]);
    expect(configuration.models).toHaveLength(5);
    expect(configuration.models[2]).toMatchObject({
      id: "mlx-vlm",
      provider: "omlx",
      capabilities: {
        supports: { reasoningEffort: true, vision: true },
      },
    });
    expect(configuration.models[0]).toMatchObject({
      capabilities: { supports: { reasoningEffort: true } },
    });
  });

  test("ignores unavailable providers", async () => {
    const configuration = await discoverLocalProviders({}, async () => {
      throw new Error("connection refused");
    });
    expect(configuration).toEqual({ providers: [], models: [] });
  });

  test("accepts provider URLs ending in /v1 without duplicating the API prefix", async () => {
    const requests: string[] = [];
    const configuration = await discoverLocalProviders(
      { OMLX_BASE_URL: "http://localhost:8000/v1/" },
      async (input) => {
        const url = String(input);
        requests.push(url);
        if (url === "http://localhost:8000/v1/models/status") {
          return response({ models: [{ id: "local", model_type: "llm" }] });
        }
        throw new Error("unavailable");
      },
    );
    expect(requests).toContain("http://localhost:8000/v1/models/status");
    expect(configuration.providers.find(({ name }) => name === "omlx")?.baseUrl).toBe(
      "http://localhost:8000/v1",
    );
  });
});

function response(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    headers: { "Content-Type": "application/json" },
  });
}
