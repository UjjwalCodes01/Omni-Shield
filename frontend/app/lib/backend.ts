export const BACKEND_BASE_URL =
  process.env.NEXT_PUBLIC_BACKEND_URL || "https://omni-shield.onrender.com";

export type BackendHealth = {
  service: string;
  status: string;
  time: string;
  chainId: number;
  xcmRouter: string;
  yieldRouter: string;
};

export async function fetchBackendHealth(signal?: AbortSignal): Promise<BackendHealth> {
  const response = await fetch(`${BACKEND_BASE_URL}/health`, {
    method: "GET",
    signal,
  });

  if (!response.ok) {
    throw new Error(`Backend health check failed with status ${response.status}`);
  }

  return response.json();
}
