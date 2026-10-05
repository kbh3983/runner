/**
 * onRunCreated: server-side verification, stats, party results, loyalty progress.
 */
import { db } from "./config";
import { FieldValue, Timestamp, type DocumentData, type DocumentSnapshot, type QuerySnapshot } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { finalizeSession, partyRef, type FinalStatus } from "./sessions";
import { haversine, seoulDate, seoulMonth } from "./util/geo";
import { decodePolyline } from "./util/polyline";

const MAX_SEGMENT_SPEED_MPS = 12;
const SPIKE_RATIO = 0.05;
const MIN_PACE_SEC_PER_KM = 150;
const DISTANCE_TOLERANCE = 0.85;
const LOYALTY_SUCCESS_RATIO = 0.97;
const BEST_PACE_MIN_DISTANCE_M = 1000;

export interface VerificationResult {
  verified: boolean;
  flags: string[];
  serverDistanceM: number;
}

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** Pure verification of a run document (see ARCHITECTURE §5 서버 검증). */
export function verifyRun(run: DocumentData, now = Date.now()): VerificationResult {
  const flags: string[] = [];
  const distanceM = num(run.distanceM) ?? 0;
  const durationMs = num(run.durationMs) ?? 0;
  const startedAt = num(run.startedAt) ?? 0;
  const endedAt = num(run.endedAt) ?? 0;

  const points = typeof run.path === "string" && run.path.length > 0 ? decodePolyline(run.path, 5) : [];
  const breaks = new Set<number>(
    Array.isArray(run.pathBreaks) ? run.pathBreaks.filter((b: unknown) => typeof b === "number") : [],
  );
  const times: unknown[] = Array.isArray(run.pathTimes) ? run.pathTimes : [];
  const hasTimes = times.length === points.length;

  let serverDistanceM = 0;
  let segments = 0;
  let spikes = 0;
  for (let i = 1; i < points.length; i++) {
    if (breaks.has(i)) continue; // gap across a pause is not counted
    const d = haversine(points[i - 1], points[i]);
    serverDistanceM += d;
    if (hasTimes) {
      const t0 = num(times[i - 1]);
      const t1 = num(times[i]);
      if (t0 === null || t1 === null) continue;
      const dt = t1 - t0;
      segments++;
      if (dt > 0 ? d / dt > MAX_SEGMENT_SPEED_MPS : d > MAX_SEGMENT_SPEED_MPS) spikes++;
    }
  }

  if (serverDistanceM < distanceM * DISTANCE_TOLERANCE) flags.push("distance_mismatch");

  if (distanceM > 0) {
    const paceSecPerKm = durationMs / 1000 / (distanceM / 1000);
    if (paceSecPerKm < MIN_PACE_SEC_PER_KM) flags.push("too_fast");
  }

  if (segments > 0 && spikes / segments >= SPIKE_RATIO) flags.push("speed_spike");

  if (endedAt > now + 5 * 60 * 1000 || endedAt < startedAt || durationMs > endedAt - startedAt + 60 * 1000) {
    flags.push("bad_time");
  }

  return { verified: flags.length === 0, flags, serverDistanceM: Math.round(serverDistanceM * 10) / 10 };
}

export const onRunCreated = onDocumentCreated("runs/{runId}", async (event) => {
  const snap = event.data;
  if (!snap) return;
  const initial = snap.data();
  if (initial.verification) return; // already processed

  const runId = event.params.runId;
  const runRef = snap.ref;
  const v = verifyRun(initial);
  const distanceM = num(initial.distanceM) ?? 0;
  const effectiveDistance = v.verified ? distanceM : Math.min(distanceM, v.serverDistanceM);

  // Everything in one transaction, guarded by "verification not yet written",
  // so a retried/duplicated event never double-counts stats or loyalty.
  const decision: { partyKey: string; status: FinalStatus } | null = await db().runTransaction(async (tx) => {
    const runSnap = await tx.get(runRef);
    if (!runSnap.exists) return null;
    const run = runSnap.data()!;
    if (run.verification) return null;

    const ownerId = run.ownerId;
    if (typeof ownerId !== "string" || ownerId.length === 0) {
      logger.warn("run without ownerId", { runId });
      return null;
    }

    // ---- reads
    const userRef = db().doc(`users/${ownerId}`);
    const userSnap = await tx.get(userRef);

    const partyKey = typeof run.partyKey === "string" && run.partyKey.length > 0 ? run.partyKey : null;
    let partySnap: DocumentSnapshot | null = null;
    let resultsSnap: QuerySnapshot | null = null;
    let party: DocumentData | null = null;
    if (run.mode === "group" && partyKey && !partyKey.includes("/")) {
      partySnap = await tx.get(partyRef(partyKey));
      if (partySnap.exists) {
        party = partySnap.data()!;
        const memberIds: unknown = party.memberIds;
        if (!Array.isArray(memberIds) || !memberIds.includes(ownerId)) {
          party = null;
        } else if (party.loyalty !== true && party.status === "running") {
          resultsSnap = await tx.get(partyRef(partyKey).collection("results").select("ownerId"));
        }
      }
    }

    // ---- writes: verification
    const verification = { ...v, checkedAt: FieldValue.serverTimestamp() };
    tx.update(runRef, { verification });

    // ---- writes: user stats
    const durationMs = num(run.durationMs) ?? 0;
    const startedAt = num(run.startedAt) ?? Date.now();
    const endedAt = num(run.endedAt) ?? startedAt;
    const prevStats = (userSnap.get("stats") ?? {}) as Record<string, unknown>;
    const stats: Record<string, unknown> = {
      totalRuns: FieldValue.increment(1),
      totalDistanceM: FieldValue.increment(effectiveDistance),
      totalDurationMs: FieldValue.increment(durationMs),
      lastRunAt: Timestamp.fromMillis(Math.min(endedAt, Date.now())),
    };
    const prevBest = num(prevStats.bestPaceSecPerKm);
    if (v.verified && distanceM >= BEST_PACE_MIN_DISTANCE_M && durationMs > 0) {
      const pace = Math.round(durationMs / 1000 / (distanceM / 1000));
      if (prevBest === null || pace < prevBest) stats.bestPaceSecPerKm = pace;
    }
    if (stats.bestPaceSecPerKm === undefined && prevStats.bestPaceSecPerKm === undefined) {
      stats.bestPaceSecPerKm = null;
    }
    tx.set(userRef, { stats }, { merge: true });

    // ---- writes: monthly stats (Asia/Seoul)
    tx.set(
      userRef.collection("monthlyStats").doc(seoulMonth(startedAt)),
      {
        runs: FieldValue.increment(1),
        distanceM: FieldValue.increment(effectiveDistance),
        durationMs: FieldValue.increment(durationMs),
        days: FieldValue.arrayUnion(seoulDate(startedAt)),
      },
      { merge: true },
    );

    if (!party || !partyKey) return null;

    // ---- writes: party result copy (no memos)
    const result: DocumentData = { ...run, verification };
    delete result.memos;
    tx.set(partyRef(partyKey).collection("results").doc(runId), result);

    if (party.loyalty === true) {
      if (party.status !== "running") return null;
      const progress = (party.loyaltyProgress ?? {}) as { totalM?: number; contributions?: Record<string, number> };
      const contributions = { ...(progress.contributions ?? {}) };
      contributions[ownerId] = (num(contributions[ownerId]) ?? 0) + effectiveDistance;
      const totalM = (num(progress.totalM) ?? 0) + effectiveDistance;
      // Whole-map write: uids like 'kakao:123' never go through dotted paths.
      tx.update(partyRef(partyKey), { loyaltyProgress: { totalM, contributions } });
      const goal = num(party.goalValue) ?? 0;
      if (goal > 0 && totalM >= goal * LOYALTY_SUCCESS_RATIO) return { partyKey, status: "success" };
      return null;
    }

    if (party.status === "running" && resultsSnap) {
      const done = new Set<string>([ownerId]);
      resultsSnap.docs.forEach((d) => {
        const o = d.get("ownerId");
        if (typeof o === "string") done.add(o);
      });
      const memberIds = party.memberIds as string[];
      if (memberIds.every((m) => done.has(m))) return { partyKey, status: "finished" };
    }
    return null;
  });

  logger.info("run verified", { runId, ...v, effectiveDistance });

  if (decision) {
    await finalizeSession(decision.partyKey, decision.status);
  }
});
