/**
 * Shared bootstrap. Every module imports this first so that the Admin SDK is
 * initialised and global options are set before any function is defined
 * (regardless of import order).
 */
import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { setGlobalOptions } from "firebase-functions/v2";

export const REGION = "asia-northeast3";

if (getApps().length === 0) {
  initializeApp();
  getFirestore().settings({ ignoreUndefinedProperties: true });
}

setGlobalOptions({ region: REGION, maxInstances: 10 });

export const db = () => getFirestore();
