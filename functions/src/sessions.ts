/**
 * Live session lifecycle: finalizeSession, RTDB member trigger, scheduled cleanup.
 */
import { REGION, db } from "./config";
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { getDatabase } from "firebase-admin/database";
import * as logger from "firebase-functions/logger";
import { defineString } from "firebase-functions/params";
import { onValueWritten } from "firebase-functions/v2/database";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { sendToUsers, type PushPayload } from "./util/fcm";

export type FinalStatus = "finished" | "success" | "failed";

/**
 * Location of the default RTDB instance. RTDB triggers must be deployed in the
 * same location as the database instance, which may differ from REGION.
 */
const RTDB_REGION = defineString("RTDB_REGION", {
  default: "us-central1",
  description: "Location of the default Realtime Database instance (e.g. us-central1, asia-southeast1)",
});

const HOUR_MS = 3600 * 1000;
const DAY_MS = 24 * HOUR_MS;

export const liveRef = (partyKey: string) => getDatabase().ref(`liveSessions/${partyKey}`);
export const partyRef = (partyKey: string) => db().doc(`parties/${partyKey}`);

function finalPush(status: FinalStatus, partyKey: string): PushPayload {
  switch (status) {
    case "success":
      return { type: "loyalty_success", partyKey, title: "의리게임 성공! 🎉", body: "모두 함께 목표를 달성했어요" };
    case "failed":
      return { type: "loyalty_failed", partyKey, title: "의리게임 실패 😢", body: "24시간이 지났어요" };
    default:
      return { type: "party_finished", partyKey, title: "파티 러닝 종료", body: "모두의 기록을 확인해보세요" };
  }
}

/**
 * Ends a running party session. Idempotent: does nothing unless the party is
 * currently 'running'. Copies the last RTDB member snapshot into
 * parties/{key}.finalLive, sets status/finishedAt, removes liveSessions/{key}
 * and notifies members. Returns true if this call performed the finalization.
 */
export async function finalizeSession(partyKey: string, status: FinalStatus): Promise<boolean> {
  const ref = partyRef(partyKey);
  const pre = await ref.get();
  if (!pre.exists || pre.get("status") !== "running") return false;

  const live = liveRef(partyKey);
  const membersSnap = await live.child("members").get();
  const finalLive = membersSnap.exists() ? membersSnap.val() : null;

  const memberIds = await db().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists || snap.get("status") !== "running") return null;
    tx.update(ref, {
      status,
      finishedAt: FieldValue.serverTimestamp(),
      finalLive,
    });
    const ids = snap.get("memberIds");
    return Array.isArray(ids) ? (ids as string[]) : [];
  });
  if (memberIds === null) return false;

  try {
    await live.remove();
  } catch (e) {
    logger.error("failed to remove live session", { partyKey, error: String(e) });
  }

  await sendToUsers(memberIds, finalPush(status, partyKey));
  logger.info("session finalized", { partyKey, status });
  return true;
}

/** Deletes a party completely: doc + private/results subcollections + RTDB session. */
export async function deletePartyData(partyKey: string): Promise<void> {
  await db().recursiveDelete(partyRef(partyKey));
  await liveRef(partyKey).remove();
}

interface LiveMember {
  userId?: string;
  status?: string;
  distance?: number;
  baseDistance?: number;
}

interface LiveSession {
  meta?: {
    hostId?: string;
    startAt?: number;
    goalType?: string;
    goalValue?: number | null;
    loyalty?: boolean;
    status?: string;
  };
  allowed?: Record<string, boolean>;
  members?: Record<string, LiveMember>;
}

const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);

/**
 * liveSessions/{key}/members/{uid} written.
 *  - normal party: every allowed uid is FINISHED → finalizeSession('finished')
 *  - loyalty: Σ(baseDistance + distance) km ≥ goal km → meta/status = 'COMPLETED'
 *    (the real success decision comes from verified runs in onRunCreated)
 * Only ever writes meta/status (or deletes the whole session via finalize), so
 * it cannot re-trigger itself in a loop.
 */
export const onLiveMemberWritten = onValueWritten(
  { ref: "liveSessions/{key}/members/{uid}", region: RTDB_REGION },
  async (event) => {
    const key = event.params.key;
    const sessionSnap = await liveRef(key).get();
    if (!sessionSnap.exists()) return;
    const session = sessionSnap.val() as LiveSession;
    const meta = session.meta;
    if (!meta || meta.status !== "RUNNING") return;

    const members = session.members ?? {};

    if (meta.loyalty === true) {
      const goalKm = num(meta.goalValue) / 1000;
      if (goalKm <= 0) return;
      const totalKm = Object.values(members).reduce(
        (sum, m) => sum + num(m?.baseDistance) + num(m?.distance),
        0,
      );
      if (totalKm >= goalKm) {
        await liveRef(key)
          .child("meta/status")
          .transaction((cur) => (cur === "RUNNING" ? "COMPLETED" : undefined));
        logger.info("loyalty live goal reached", { key, totalKm, goalKm });
      }
      return;
    }

    const allowed = Object.keys(session.allowed ?? {}).filter((uid) => session.allowed?.[uid] === true);
    if (allowed.length === 0) return;
    const allFinished = allowed.every((uid) => members[uid]?.status === "FINISHED");
    if (allFinished) {
      await finalizeSession(key, "finished");
    }
  },
);

/**
 * Every 15 minutes:
 *  - loyalty running past loyaltyDeadline → failed (or success if already reached)
 *  - normal running with startAt older than 24h → finished
 *  - waiting parties older than 7 days → deleted
 */
export const cleanupSessions = onSchedule(
  { schedule: "every 15 minutes", timeZone: "Asia/Seoul", region: REGION, timeoutSeconds: 540 },
  async () => {
    const now = Date.now();

    const running = await db().collection("parties").where("status", "==", "running").get();
    for (const doc of running.docs) {
      const p = doc.data();
      try {
        if (p.loyalty === true) {
          const deadline = typeof p.loyaltyDeadline === "number" ? p.loyaltyDeadline : num(p.startAt) + DAY_MS;
          if (now > deadline) {
            const total = num(p.loyaltyProgress?.totalM);
            const goal = num(p.goalValue);
            await finalizeSession(doc.id, goal > 0 && total >= goal * 0.97 ? "success" : "failed");
          }
        } else if (num(p.startAt) < now - DAY_MS) {
          await finalizeSession(doc.id, "finished");
        }
      } catch (e) {
        logger.error("cleanup: finalize failed", { partyKey: doc.id, error: String(e) });
      }
    }

    const staleWaiting = await db()
      .collection("parties")
      .where("status", "==", "waiting")
      .where("createdAt", "<", Timestamp.fromMillis(now - 7 * DAY_MS))
      .get();
    for (const doc of staleWaiting.docs) {
      try {
        await deletePartyData(doc.id);
        logger.info("cleanup: deleted stale waiting party", { partyKey: doc.id });
      } catch (e) {
        logger.error("cleanup: delete failed", { partyKey: doc.id, error: String(e) });
      }
    }
  },
);
