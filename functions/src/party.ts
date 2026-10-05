/**
 * Party management callables. Parties are written only by Cloud Functions.
 */
import { REGION, db } from "./config";
import * as crypto from "crypto";
import type { DecodedIdToken } from "firebase-admin/auth";
import { FieldValue } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { deletePartyData, liveRef, partyRef } from "./sessions";
import { sendToUsers } from "./util/fcm";

const MAX_ACTIVE_HOSTED = 5;
const MAX_JOIN_FAILURES = 10;
const COUNTDOWN_MS = 7000;
const DAY_MS = 24 * 3600 * 1000;

type GoalType = "none" | "distance" | "time";

export interface PartyMember {
  name: string;
  photoUrl: string | null;
  colorIndex: number;
  joinedAt: number;
}

export interface PartyDoc {
  id: string;
  key: string;
  hostId: string;
  hostName: string;
  roomNo: number;
  maxMembers: number;
  goalType: GoalType;
  goalValue: number | null;
  loyalty: boolean;
  status: "waiting" | "running" | "finished" | "success" | "failed";
  memberIds: string[];
  members: Record<string, PartyMember>;
  bannedIds: string[];
  createdAt: FirebaseFirestore.FieldValue | FirebaseFirestore.Timestamp;
  startAt: number | null;
  loyaltyDeadline: number | null;
  loyaltyProgress: { totalM: number; contributions: Record<string, number> };
  finishedAt: FirebaseFirestore.Timestamp | null;
  finalLive: Record<string, unknown> | null;
}

// ------------------------------------------------------------------ helpers

export const toPartyKey = (partyId: string) => partyId.replace(/#/g, "_");

function requireAuth(req: CallableRequest): string {
  if (!req.auth) throw new HttpsError("unauthenticated", "로그인이 필요해요");
  return req.auth.uid;
}

function requireKey(v: unknown, field = "partyKey"): string {
  if (typeof v !== "string" || v.length === 0 || v.length > 300 || /[/.$\[\]]/.test(v)) {
    throw new HttpsError("invalid-argument", `${field} 값이 올바르지 않아요`);
  }
  return v;
}

function hashPassword(salt: string, password: string): string {
  return crypto.createHash("sha256").update(salt + password).digest("hex");
}

function safeEqualHex(a: string, b: string): boolean {
  const ba = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}

/** name/photo from users/{uid}, falling back to auth token claims. */
function profileFrom(
  userData: FirebaseFirestore.DocumentData | undefined,
  token: DecodedIdToken | undefined,
): { name: string; photoUrl: string | null } {
  const tokenName = typeof token?.name === "string" ? token.name : "";
  const tokenPicture = typeof token?.picture === "string" ? token.picture : null;
  const name =
    (typeof userData?.displayName === "string" && userData.displayName.trim()) || tokenName.trim() || "Runner";
  const photoUrl = (typeof userData?.photoUrl === "string" && userData.photoUrl) || tokenPicture || null;
  return { name: name.slice(0, 50), photoUrl };
}

function smallestFreeColor(members: Record<string, PartyMember>): number {
  const used = new Set(Object.values(members).map((m) => m.colorIndex));
  for (let i = 0; i < 10; i++) if (!used.has(i)) return i;
  return 0;
}

function loadParty(snap: FirebaseFirestore.DocumentSnapshot): PartyDoc {
  if (!snap.exists) throw new HttpsError("not-found", "파티를 찾을 수 없어요");
  const p = snap.data() as PartyDoc;
  p.memberIds = Array.isArray(p.memberIds) ? p.memberIds : [];
  p.members = p.members ?? {};
  p.bannedIds = Array.isArray(p.bannedIds) ? p.bannedIds : [];
  return p;
}

// ------------------------------------------------------------- createParty

export const createParty = onCall({ region: REGION }, async (req) => {
  const uid = requireAuth(req);
  const d = (req.data ?? {}) as Record<string, unknown>;

  const maxMembers = d.maxMembers;
  if (typeof maxMembers !== "number" || !Number.isInteger(maxMembers) || maxMembers < 2 || maxMembers > 10) {
    throw new HttpsError("invalid-argument", "최대 인원은 2~10명이어야 해요");
  }

  const goalType = d.goalType as GoalType;
  if (goalType !== "none" && goalType !== "distance" && goalType !== "time") {
    throw new HttpsError("invalid-argument", "목표 종류가 올바르지 않아요");
  }

  let goalValue: number | null = null;
  if (goalType !== "none") {
    const v = d.goalValue;
    if (typeof v !== "number" || !Number.isFinite(v)) {
      throw new HttpsError("invalid-argument", "목표 값이 필요해요");
    }
    if (goalType === "distance" && (v < 100 || v > 200000)) {
      throw new HttpsError("invalid-argument", "목표 거리는 0.1~200km 사이여야 해요");
    }
    if (goalType === "time" && (v < 60 || v > 86400)) {
      throw new HttpsError("invalid-argument", "목표 시간은 1분~24시간 사이여야 해요");
    }
    goalValue = v;
  }

  const loyalty = d.loyalty === true;
  if (loyalty && goalType !== "distance") {
    throw new HttpsError("invalid-argument", "의리게임은 거리 목표에서만 사용할 수 있어요");
  }

  const password = d.password;
  if (typeof password !== "string" || !/^\d{6}$/.test(password)) {
    throw new HttpsError("invalid-argument", "비밀번호는 숫자 6자리여야 해요");
  }

  const salt = crypto.randomBytes(16).toString("hex");
  const passwordHash = hashPassword(salt, password);
  const userRef = db().doc(`users/${uid}`);
  const activeQuery = db()
    .collection("parties")
    .where("hostId", "==", uid)
    .where("status", "in", ["waiting", "running"]);

  return db().runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    const active = await tx.get(activeQuery);
    if (active.size >= MAX_ACTIVE_HOSTED) {
      throw new HttpsError("failed-precondition", `진행 중인 파티는 최대 ${MAX_ACTIVE_HOSTED}개까지 만들 수 있어요`);
    }

    const userData = userSnap.data();
    const counter = typeof userData?.partyCounter === "number" ? userData.partyCounter : 0;
    const roomNo = counter + 1;
    const partyId = `${uid}#${roomNo}`;
    const partyKey = toPartyKey(partyId);
    const host = profileFrom(userData, req.auth!.token);

    const party: PartyDoc = {
      id: partyId,
      key: partyKey,
      hostId: uid,
      hostName: host.name,
      roomNo,
      maxMembers,
      goalType,
      goalValue,
      loyalty,
      status: "waiting",
      memberIds: [uid],
      members: {
        [uid]: { name: host.name, photoUrl: host.photoUrl, colorIndex: 0, joinedAt: Date.now() },
      },
      bannedIds: [],
      createdAt: FieldValue.serverTimestamp(),
      startAt: null,
      loyaltyDeadline: null,
      loyaltyProgress: { totalM: 0, contributions: {} },
      finishedAt: null,
      finalLive: null,
    };

    const ref = partyRef(partyKey);
    tx.set(userRef, { partyCounter: roomNo }, { merge: true });
    tx.create(ref, party);
    tx.create(ref.collection("private").doc("secret"), { salt, passwordHash });
    return { partyId, partyKey };
  });
});

// --------------------------------------------------------------- joinParty

type JoinOutcome =
  | { kind: "joined"; hostId: string; name: string }
  | { kind: "already" }
  | { kind: "wrong" };

export const joinParty = onCall({ region: REGION }, async (req) => {
  const uid = requireAuth(req);
  const d = (req.data ?? {}) as Record<string, unknown>;
  const partyKey = toPartyKey(requireKey(d.partyId, "partyId"));
  const password = d.password;
  if (typeof password !== "string" || password.length === 0 || password.length > 32) {
    throw new HttpsError("invalid-argument", "비밀번호를 입력해주세요");
  }

  const ref = partyRef(partyKey);
  const secretRef = ref.collection("private").doc("secret");
  const attemptsRef = ref.collection("private").doc("attempts");
  const userSnap = await db().doc(`users/${uid}`).get();
  const profile = profileFrom(userSnap.data(), req.auth!.token);

  const outcome: JoinOutcome = await db().runTransaction(async (tx) => {
    const [partySnap, secretSnap, attemptsSnap] = await tx.getAll(ref, secretRef, attemptsRef);
    const party = loadParty(partySnap);

    if (party.bannedIds.includes(uid)) {
      throw new HttpsError("permission-denied", "강퇴된 파티에는 다시 참여할 수 없어요");
    }
    if (party.memberIds.includes(uid)) return { kind: "already" };
    if (party.status !== "waiting") {
      throw new HttpsError("failed-precondition", "러닝이 이미 시작되었어요");
    }

    const counts = (attemptsSnap.get("counts") ?? {}) as Record<string, number>;
    if ((counts[uid] ?? 0) >= MAX_JOIN_FAILURES) {
      throw new HttpsError("resource-exhausted", "시도 횟수를 초과했어요");
    }

    const salt = secretSnap.get("salt");
    const expected = secretSnap.get("passwordHash");
    if (typeof salt !== "string" || typeof expected !== "string") {
      throw new HttpsError("internal", "파티 정보가 손상되었어요");
    }
    if (!safeEqualHex(hashPassword(salt, password), expected)) return { kind: "wrong" };

    if (party.memberIds.length >= party.maxMembers) {
      throw new HttpsError("resource-exhausted", "파티 인원이 가득 찼어요");
    }

    const member: PartyMember = {
      name: profile.name,
      photoUrl: profile.photoUrl,
      colorIndex: smallestFreeColor(party.members),
      joinedAt: Date.now(),
    };
    tx.update(ref, {
      memberIds: [...party.memberIds, uid],
      members: { ...party.members, [uid]: member },
    });
    return { kind: "joined", hostId: party.hostId, name: profile.name };
  });

  if (outcome.kind === "wrong") {
    // Recorded outside the (read-only) transaction so the failure persists.
    await attemptsRef.set(
      { counts: { [uid]: FieldValue.increment(1) }, updatedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );
    throw new HttpsError("permission-denied", "비밀번호가 올바르지 않아요");
  }

  if (outcome.kind === "joined") {
    await sendToUsers([outcome.hostId], {
      type: "party_joined",
      partyKey,
      title: "새 파티원",
      body: `${outcome.name}님이 파티에 참여했어요`,
    });
  }
  return { partyKey };
});

// -------------------------------------------------------------- leaveParty

export const leaveParty = onCall({ region: REGION }, async (req) => {
  const uid = requireAuth(req);
  const partyKey = requireKey((req.data ?? {}).partyKey);
  const ref = partyRef(partyKey);

  await db().runTransaction(async (tx) => {
    const party = loadParty(await tx.get(ref));
    if (party.hostId === uid) {
      throw new HttpsError("failed-precondition", "방장은 나갈 수 없어요. 파티를 삭제해주세요");
    }
    if (!party.memberIds.includes(uid)) return; // idempotent
    if (party.status !== "waiting") {
      throw new HttpsError("failed-precondition", "러닝이 시작된 파티는 나갈 수 없어요");
    }
    const members = { ...party.members };
    delete members[uid];
    tx.update(ref, { memberIds: party.memberIds.filter((m) => m !== uid), members });
  });
  return { ok: true };
});

// -------------------------------------------------------------- kickMember

export const kickMember = onCall({ region: REGION }, async (req) => {
  const uid = requireAuth(req);
  const d = (req.data ?? {}) as Record<string, unknown>;
  const partyKey = requireKey(d.partyKey);
  const target = d.uid;
  if (typeof target !== "string" || target.length === 0) {
    throw new HttpsError("invalid-argument", "uid 값이 올바르지 않아요");
  }
  if (target === uid) throw new HttpsError("invalid-argument", "자기 자신은 강퇴할 수 없어요");
  const ref = partyRef(partyKey);

  const kicked = await db().runTransaction(async (tx) => {
    const party = loadParty(await tx.get(ref));
    if (party.hostId !== uid) throw new HttpsError("permission-denied", "방장만 강퇴할 수 있어요");
    if (party.status !== "waiting") {
      throw new HttpsError("failed-precondition", "대기 중인 파티에서만 강퇴할 수 있어요");
    }
    const wasMember = party.memberIds.includes(target);
    const members = { ...party.members };
    delete members[target];
    tx.update(ref, {
      memberIds: party.memberIds.filter((m) => m !== target),
      members,
      bannedIds: FieldValue.arrayUnion(target),
    });
    return wasMember;
  });

  if (kicked) {
    await sendToUsers([target], {
      type: "party_kicked",
      partyKey,
      title: "파티에서 내보내졌어요",
      body: "방장이 파티에서 내보냈어요",
    });
  }
  return { ok: true };
});

// ------------------------------------------------------------- deleteParty

export const deleteParty = onCall({ region: REGION }, async (req) => {
  const uid = requireAuth(req);
  const partyKey = requireKey((req.data ?? {}).partyKey);
  const party = loadParty(await partyRef(partyKey).get());
  if (party.hostId !== uid) throw new HttpsError("permission-denied", "방장만 파티를 삭제할 수 있어요");

  await deletePartyData(partyKey);

  await sendToUsers(
    party.memberIds.filter((m) => m !== uid),
    { type: "party_deleted", partyKey, title: "파티 삭제", body: `${party.hostName}님이 파티를 삭제했어요` },
  );
  return { ok: true };
});

// -------------------------------------------------------------- startParty

export const startParty = onCall({ region: REGION }, async (req) => {
  const uid = requireAuth(req);
  const partyKey = requireKey((req.data ?? {}).partyKey);
  const ref = partyRef(partyKey);

  const started = await db().runTransaction(async (tx) => {
    const party = loadParty(await tx.get(ref));
    if (party.hostId !== uid) throw new HttpsError("permission-denied", "방장만 시작할 수 있어요");
    if (party.status !== "waiting") {
      throw new HttpsError("failed-precondition", "대기 중인 파티만 시작할 수 있어요");
    }
    const startAt = Date.now() + COUNTDOWN_MS;
    const loyaltyDeadline = party.loyalty ? startAt + DAY_MS : null;
    tx.update(ref, { status: "running", startAt, loyaltyDeadline });
    return { party, startAt };
  });

  const { party, startAt } = started;
  const allowed: Record<string, true> = {};
  for (const m of party.memberIds) allowed[m] = true;

  try {
    await liveRef(partyKey).set({
      meta: {
        hostId: party.hostId,
        startAt,
        goalType: party.goalType,
        goalValue: party.goalValue,
        loyalty: party.loyalty,
        status: "RUNNING",
      },
      allowed,
    });
  } catch (e) {
    // Roll back so the host can retry.
    logger.error("startParty: RTDB write failed, reverting", { partyKey, error: String(e) });
    await ref.update({ status: "waiting", startAt: null, loyaltyDeadline: null });
    throw new HttpsError("internal", "세션을 시작하지 못했어요. 다시 시도해주세요");
  }

  await sendToUsers(
    party.memberIds.filter((m) => m !== uid),
    {
      type: "party_started",
      partyKey,
      title: "같이 뛰기 시작!",
      body: `${party.hostName}님의 파티 러닝이 곧 시작돼요`,
    },
  );
  return { startAt };
});
