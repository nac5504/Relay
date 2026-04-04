let apiKey: string | null = null;

export function setApiKey(key: string): void {
  apiKey = key;
}

export function getApiKey(): string {
  if (!apiKey) {
    throw new Error('No API key set. Open Settings in the Relay app to add your Anthropic key.');
  }
  return apiKey;
}

export function hasApiKey(): boolean {
  return apiKey !== null && apiKey.length > 0;
}
