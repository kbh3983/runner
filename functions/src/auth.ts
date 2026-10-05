/**
 * Social login → Firebase custom token.
 *  - kakaoLogin / naverLogin : callable, unauthenticated, {accessToken} → {token}
 *  - instagramAuthRedirect   : OAuth redirect_uri, 302 → runtogether://auth?token=...
 */
import { REGION } from "./config";
import { getAuth } from "firebase-admin/auth";
import * as logger from "firebase-functions/logger";
import { defineString } from "firebase-functions/params";
import { HttpsError, onCall } from "firebase-functions/v2/https";

const KAKAO_APP_ID = defineString("KAKAO_APP_ID", { description: "Kakao app ID (numeric)" });

const HTTP_TIMEOUT_MS = 10_000;

type Provider = "kakao" | "naver";

interface HttpResult {
  ok: boolean;
  status: number;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  body: any;
}

async function fetchJson(url: string, init: RequestInit = {}): Promise<HttpResult> {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(HTTP_TIMEOUT_MS) });
  const text = await res.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { raw: text.slice(0, 500) };
  }
  return { ok: res.ok, status: res.status, body };
}

function requireAccessToken(data: unknown): string {
  const t = (data as { accessToken?: unknown } | null)?.accessToken;
  if (typeof t !== "string" || t.length === 0 || t.length > 4096) {
    throw new HttpsError("invalid-argument", "accessToken 이 필요해요");
  }
  return t;
}

/** Creates or updates the Firebase Auth user and returns a custom token. */
async function issueToken(
  uid: string,
  provider: Provider,
  displayName: string | null | undefined,
  photoURL: string | null | undefined,
): Promise<string> {
  const auth = getAuth();
  const props: { displayName?: string; photoURL?: string } = {};
  const name = typeof displayName === "string" ? displayName.trim() : "";
  if (name) props.displayName = name.slice(0, 100);
  if (typeof photoURL === "string" && /^https?:\/\//i.test(photoURL)) props.photoURL = photoURL;

  try {
    if (Object.keys(props).length > 0) {
      await auth.updateUser(uid, props);
    } else {
      await auth.getUser(uid);
    }
  } catch (e) {
    if ((e as { code?: string })?.code === "auth/user-not-found") {
      await auth.createUser({ uid, ...props });
    } else {
      throw e;
    }
  }
  return auth.createCustomToken(uid, { provider });
}

// -------------------------------------------------------------------- Kakao

export const kakaoLogin = onCall({ region: REGION }, async (req) => {
  const accessToken = requireAccessToken(req.data);
  const headers = { Authorization: `Bearer ${accessToken}` };

  const info = await fetchJson("https://kapi.kakao.com/v1/user/access_token_info", { headers });
  if (!info.ok || !info.body) {
    logger.warn("kakao token info failed", { status: info.status, body: info.body });
    throw new HttpsError("unauthenticated", "카카오 인증에 실패했어요");
  }
  const expectedAppId = KAKAO_APP_ID.value();
  if (!expectedAppId) throw new HttpsError("failed-precondition", "KAKAO_APP_ID 가 설정되지 않았어요");
  if (String(info.body.app_id) !== String(expectedAppId)) {
    throw new HttpsError("permission-denied", "다른 앱에서 발급된 카카오 토큰이에요");
  }

  const me = await fetchJson("https://kapi.kakao.com/v2/user/me", { headers });
  if (!me.ok || me.body?.id === undefined || me.body?.id === null) {
    logger.warn("kakao user/me failed", { status: me.status, body: me.body });
    throw new HttpsError("unauthenticated", "카카오 사용자 정보를 가져오지 못했어요");
  }
  if (info.body.id !== undefined && String(info.body.id) !== String(me.body.id)) {
    throw new HttpsError("unauthenticated", "카카오 토큰 정보가 일치하지 않아요");
  }

  const profile = me.body.kakao_account?.profile ?? {};
  const props = me.body.properties ?? {};
  const name: string | undefined = profile.nickname ?? props.nickname;
  const photo: string | undefined = profile.profile_image_url ?? props.profile_image;

  const token = await issueToken(`kakao:${me.body.id}`, "kakao", name, photo);
  return { token };
});

// -------------------------------------------------------------------- Naver

export const naverLogin = onCall({ region: REGION }, async (req) => {
  const accessToken = requireAccessToken(req.data);
  const me = await fetchJson("https://openapi.naver.com/v1/nid/me", {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const r = me.body?.response;
  if (!me.ok || me.body?.resultcode !== "00" || !r?.id) {
    logger.warn("naver nid/me failed", { status: me.status, body: me.body });
    throw new HttpsError("unauthenticated", "네이버 인증에 실패했어요");
  }
  const token = await issueToken(`naver:${r.id}`, "naver", r.nickname ?? r.name, r.profile_image);
  return { token };
});

