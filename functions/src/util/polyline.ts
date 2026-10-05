/**
 * Google encoded polyline algorithm (decode only).
 * https://developers.google.com/maps/documentation/utilities/polylinealgorithm
 */
export type LatLng = [number, number];

export function decodePolyline(encoded: string, precision = 5): LatLng[] {
  const factor = Math.pow(10, precision);
  const points: LatLng[] = [];
  let index = 0;
  let lat = 0;
  let lng = 0;
  const len = encoded.length;

  const next = (): number | null => {
    let result = 0;
    let shift = 0;
    let b: number;
    do {
      if (index >= len) return null; // truncated / malformed input
      b = encoded.charCodeAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20 && shift < 35);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };

  while (index < len) {
    const dLat = next();
    if (dLat === null) break;
    const dLng = next();
    if (dLng === null) break;
    lat += dLat;
    lng += dLng;
    points.push([lat / factor, lng / factor]);
  }
  return points;
}
