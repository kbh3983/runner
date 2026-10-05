import type { LatLng } from "./polyline";

const EARTH_RADIUS_M = 6371008.8;
const toRad = (deg: number) => (deg * Math.PI) / 180;

/** Great-circle distance in meters. */
export function haversine(a: LatLng, b: LatLng): number {
  const dLat = toRad(b[0] - a[0]);
  const dLng = toRad(b[1] - a[1]);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a[0])) * Math.cos(toRad(b[0])) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(s)));
}

/** 'yyyy-MM-dd' in Asia/Seoul (UTC+9, no DST). */
export function seoulDate(epochMs: number): string {
  return new Date(epochMs + 9 * 3600 * 1000).toISOString().slice(0, 10);
}

/** 'yyyy-MM' in Asia/Seoul. */
export function seoulMonth(epochMs: number): string {
  return seoulDate(epochMs).slice(0, 7);
}
