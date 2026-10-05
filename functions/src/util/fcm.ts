import { FieldValue } from "firebase-admin/firestore";
import { getMessaging, type MulticastMessage } from "firebase-admin/messaging";
import * as logger from "firebase-functions/logger";
import { db } from "../config";

export type PushType =
  | "party_started"
  | "party_joined"
  | "party_kicked"
  | "party_deleted"
  | "loyalty_success"
  | "loyalty_failed"
  | "party_finished";

export interface PushPayload {
  type: PushType;
  partyKey: string;
  title?: string;
  body?: string;
}

const INVALID_TOKEN_CODES = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-argument",
  "messaging/invalid-registration-token",
]);

const MAX_TOKENS_PER_CALL = 500;

/**
 * Sends a push to every FCM token registered in users/{uid}.fcmTokens.
 * Never throws: push failures must not fail the calling function.
 */
export async function sendToUsers(uids: string[], payload: PushPayload): Promise<void> {
  const unique = [...new Set(uids.filter((u) => typeof u === "string" && u.length > 0))];
  if (unique.length === 0) return;

  try {
    const refs = unique.map((uid) => db().doc(`users/${uid}`));
    const snaps = await db().getAll(...refs);

    const tokenOwner = new Map<string, string>();
    for (const snap of snaps) {
      const tokens = snap.get("fcmTokens");
      if (!Array.isArray(tokens)) continue;
      for (const t of tokens) {
        if (typeof t === "string" && t.length > 0) tokenOwner.set(t, snap.id);
      }
    }
    const tokens = [...tokenOwner.keys()];
    if (tokens.length === 0) return;

    const hasNotification = payload.title !== undefined || payload.body !== undefined;
    const invalid: string[] = [];

    for (let i = 0; i < tokens.length; i += MAX_TOKENS_PER_CALL) {
      const batch = tokens.slice(i, i + MAX_TOKENS_PER_CALL);
      const message: MulticastMessage = {
        tokens: batch,
        data: { type: payload.type, partyKey: payload.partyKey },
        android: { priority: "high" },
        apns: {
          headers: { "apns-priority": hasNotification ? "10" : "5" },
          payload: { aps: hasNotification ? { sound: "default" } : { contentAvailable: true } },
        },
      };
      if (hasNotification) {
        message.notification = { title: payload.title, body: payload.body };
      }

      const res = await getMessaging().sendEachForMulticast(message);
      res.responses.forEach((r, idx) => {
        if (!r.success && r.error && INVALID_TOKEN_CODES.has(r.error.code)) {
          invalid.push(batch[idx]);
        }
      });
    }

    if (invalid.length > 0) {
      const byUser = new Map<string, string[]>();
      for (const t of invalid) {
        const uid = tokenOwner.get(t)!;
        byUser.set(uid, [...(byUser.get(uid) ?? []), t]);
      }
      await Promise.all(
        [...byUser.entries()].map(([uid, toks]) =>
          db()
            .doc(`users/${uid}`)
            .update({ fcmTokens: FieldValue.arrayRemove(...toks) })
            .catch((e) => logger.warn("failed to prune fcm tokens", { uid, error: String(e) })),
        ),
      );
    }
  } catch (e) {
    logger.error("sendToUsers failed", { type: payload.type, partyKey: payload.partyKey, error: String(e) });
  }
}
