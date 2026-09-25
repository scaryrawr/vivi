export interface NamedProviderConfig {
  name: string;
  type?: "openai" | "azure" | "anthropic";
  wireApi?: "completions" | "responses";
  baseUrl: string;
  apiKey?: string;
  headers?: Record<string, string>;
}

export interface ProviderModelConfig {
  id: string;
  provider: string;
  wireModel?: string;
  modelId?: string;
  name?: string;
  maxPromptTokens?: number;
  maxContextWindowTokens?: number;
  maxOutputTokens?: number;
  capabilities?: {
    supports?: {
      vision?: boolean;
      toolCalls?: boolean;
      reasoningEffort?: boolean;
    };
  };
}

export interface LocalProviderConfiguration {
  providers: NamedProviderConfig[];
  models: ProviderModelConfig[];
}

export interface DiscoveryEnvironment {
  [key: string]: string | undefined;
}

type FetchImplementation = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

interface LocalProvider {
  provider: NamedProviderConfig;
  models: ProviderModelConfig[];
}

const DEFAULT_CONTEXT_WINDOW_TOKENS = 131_072;
const DEFAULT_MAX_OUTPUT_TOKENS = 32_768;
const DISCOVERY_TIMEOUT_MS = 3_000;

export async function discoverLocalProviders(
  environment: DiscoveryEnvironment = process.env,
  fetchImplementation: FetchImplementation = fetch,
): Promise<LocalProviderConfiguration> {
  const discovered = (
    await Promise.all([
      discoverTagProvider(
        "ollama",
        "Ollama",
        baseUrl(environment.OLLAMA_BASE_URL, "http://localhost:11434"),
        environment.OLLAMA_API_KEY ?? "ollama",
        positiveInteger(environment.OLLAMA_CONTEXT_LENGTH) ?? DEFAULT_CONTEXT_WINDOW_TOKENS,
        fetchImplementation,
      ),
      discoverLmStudio(environment, fetchImplementation),
      discoverOmlx(environment, fetchImplementation),
      discoverTagProvider(
        "osaurus",
        "OSaurus",
        baseUrl(
          environment.OSAURUS_BASE_URL ?? environment.OSARAUS_BASE_URL,
          "http://localhost:1337",
        ),
        environment.OSAURUS_API_KEY ?? environment.OSARAUS_API_KEY ?? "osaurus",
        positiveInteger(environment.OSAURUS_CONTEXT_LENGTH ?? environment.OSARAUS_CONTEXT_LENGTH) ??
          DEFAULT_CONTEXT_WINDOW_TOKENS,
        fetchImplementation,
      ),
      discoverGeniex(environment, fetchImplementation),
    ])
  ).filter((provider): provider is LocalProvider => provider !== undefined);

  return {
    providers: discovered.map(({ provider }) => provider),
    models: discovered.flatMap(({ models }) => models),
  };
}

async function discoverTagProvider(
  name: string,
  displayName: string,
  endpoint: string,
  apiKey: string | undefined,
  contextWindow: number,
  fetchImplementation: FetchImplementation,
): Promise<LocalProvider | undefined> {
  const payload = await fetchJson(displayName, `${endpoint}/api/tags`, apiKey, fetchImplementation);
  if (!isRecord(payload) || !Array.isArray(payload.models)) return undefined;

  return providerConfig(
    name,
    endpoint,
    apiKey,
    payload.models.flatMap((model) => {
      if (!isRecord(model) || typeof model.name !== "string") return [];
      return [
        modelConfig(
          name,
          model.name,
          typeof model.model === "string" ? model.model : model.name,
          contextWindow,
          maxOutputTokens(contextWindow),
        ),
      ];
    }),
  );
}

async function discoverLmStudio(
  environment: DiscoveryEnvironment,
  fetchImplementation: FetchImplementation,
): Promise<LocalProvider | undefined> {
  const name = "lmstudio";
  const endpoint = baseUrl(environment.LMSTUDIO_BASE_URL, "http://localhost:1234");
  const apiKey = environment.LMSTUDIO_API_KEY ?? "lmstudio";
  const payload = await fetchJson(
    "LM Studio",
    `${endpoint}/api/v1/models`,
    apiKey,
    fetchImplementation,
  );
  if (!isRecord(payload) || !Array.isArray(payload.models)) return undefined;

  return providerConfig(
    name,
    endpoint,
    apiKey,
    payload.models.flatMap((model) => {
      if (!isRecord(model) || typeof model.key !== "string") return [];
      const contextWindow =
        positiveInteger(model.max_context_length) ?? DEFAULT_CONTEXT_WINDOW_TOKENS;
      return [
        modelConfig(
          name,
          model.key,
          typeof model.display_name === "string" ? model.display_name : model.key,
          contextWindow,
          maxOutputTokens(contextWindow),
        ),
      ];
    }),
  );
}

async function discoverOmlx(
  environment: DiscoveryEnvironment,
  fetchImplementation: FetchImplementation,
): Promise<LocalProvider | undefined> {
  const name = "omlx";
  const endpoint = baseUrl(environment.OMLX_BASE_URL, "http://localhost:8000");
  const apiKey = environment.OMLX_API_KEY ?? "omlx";
  const payload = await fetchJson(
    "OMLX",
    `${endpoint}/v1/models/status`,
    apiKey,
    fetchImplementation,
  );
  if (!isRecord(payload) || !Array.isArray(payload.models)) return undefined;

  return providerConfig(
    name,
    endpoint,
    apiKey,
    payload.models.flatMap((model) => {
      if (
        !isRecord(model) ||
        typeof model.id !== "string" ||
        (model.model_type !== "llm" && model.model_type !== "vlm")
      ) {
        return [];
      }
      const contextWindow =
        positiveInteger(model.max_context_window) ?? DEFAULT_CONTEXT_WINDOW_TOKENS;
      return [
        modelConfig(
          name,
          model.id,
          typeof model.display_name === "string" ? model.display_name : model.id,
          contextWindow,
          positiveInteger(model.max_tokens) ?? DEFAULT_MAX_OUTPUT_TOKENS,
          model.model_type === "vlm" ? { supports: { vision: true } } : undefined,
        ),
      ];
    }),
  );
}

async function discoverGeniex(
  environment: DiscoveryEnvironment,
  fetchImplementation: FetchImplementation,
): Promise<LocalProvider | undefined> {
  const name = "geniex";
  const endpoint = baseUrl(environment.GENIEX_BASE_URL, "http://127.0.0.1:18181");
  const apiKey = environment.GENIEX_API_KEY ?? "geniex";
  const payload = await fetchJson("GenieX", `${endpoint}/v1/models`, apiKey, fetchImplementation);
  if (!isRecord(payload) || !Array.isArray(payload.data)) return undefined;
  const contextWindow = positiveInteger(environment.GENIEX_CONTEXT_LENGTH) ?? 65_536;

  return providerConfig(
    name,
    endpoint,
    apiKey,
    payload.data.flatMap((model) => {
      if (!isRecord(model) || typeof model.id !== "string") return [];
      return [modelConfig(name, model.id, model.id, contextWindow, maxOutputTokens(contextWindow))];
    }),
  );
}

function providerConfig(
  name: string,
  endpoint: string,
  apiKey: string | undefined,
  models: ProviderModelConfig[],
): LocalProvider | undefined {
  if (models.length === 0) return undefined;
  return {
    provider: {
      name,
      baseUrl: `${endpoint}/v1`,
      apiKey,
      wireApi: "completions",
    },
    models,
  };
}

function modelConfig(
  provider: string,
  id: string,
  name: string,
  maxContextWindowTokens: number,
  maxOutputTokens: number,
  capabilities?: ProviderModelConfig["capabilities"],
): ProviderModelConfig {
  const supports = {
    ...capabilities?.supports,
    reasoningEffort: true,
  };
  return {
    id,
    provider,
    name,
    maxContextWindowTokens,
    maxPromptTokens: maxContextWindowTokens,
    maxOutputTokens,
    capabilities: {
      ...capabilities,
      supports,
    },
  };
}

async function fetchJson(
  provider: string,
  url: string,
  apiKey: string | undefined,
  fetchImplementation: FetchImplementation,
): Promise<unknown> {
  try {
    const response = await fetchImplementation(url, {
      headers: apiKey === undefined ? undefined : { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(DISCOVERY_TIMEOUT_MS),
    });
    if (!response.ok) {
      debug(`${provider} model discovery failed: ${response.status} ${response.statusText}`);
      return undefined;
    }
    return await response.json();
  } catch (error) {
    debug(
      `${provider} model discovery failed: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
    return undefined;
  }
}

function baseUrl(value: string | undefined, fallback: string): string {
  return (value ?? fallback).replace(/\/+$/, "").replace(/\/v1$/, "");
}

function positiveInteger(value: unknown): number | undefined {
  if (typeof value !== "number" && typeof value !== "string") return undefined;
  const parsed = Number.parseInt(String(value), 10);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : undefined;
}

function maxOutputTokens(contextWindow: number): number {
  return Math.min(DEFAULT_MAX_OUTPUT_TOKENS, Math.floor(contextWindow / 4));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function debug(message: string): void {
  if (process.env.VIVI_DEBUG === "1") {
    process.stderr.write(`[vivi] ${message}\n`);
  }
}
