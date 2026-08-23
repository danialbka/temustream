import { ConvexError } from "convex/values";
import type { GenericDatabaseReader } from "convex/server";
import type { DataModel, Id } from "./_generated/dataModel";

const encoder = new TextEncoder();

export async function hashDeviceSecret(secret: string): Promise<string> {
  if (secret.length < 32 || secret.length > 256) {
    throw new ConvexError("Invalid device credential");
  }
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(secret));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

export async function requireProfile(
  db: GenericDatabaseReader<DataModel>,
  deviceSecret: string,
) {
  const secretHash = await hashDeviceSecret(deviceSecret);
  const profile = await db
    .query("profiles")
    .withIndex("by_secret_hash", query => query.eq("secretHash", secretHash))
    .unique();
  if (!profile) throw new ConvexError("Unauthorized device");
  return profile;
}

export function orderedPair(a: Id<"profiles">, b: Id<"profiles">) {
  return a < b
    ? { leftProfileId: a, rightProfileId: b }
    : { leftProfileId: b, rightProfileId: a };
}

export async function areFriends(
  db: GenericDatabaseReader<DataModel>,
  a: Id<"profiles">,
  b: Id<"profiles">,
) {
  const pair = orderedPair(a, b);
  return (await db
    .query("friendships")
    .withIndex("by_pair", query =>
      query.eq("leftProfileId", pair.leftProfileId).eq("rightProfileId", pair.rightProfileId),
    )
    .unique()) !== null;
}

export async function requireActiveParticipant(
  db: GenericDatabaseReader<DataModel>,
  roomId: Id<"rooms">,
  profileId: Id<"profiles">,
) {
  const participant = await db
    .query("roomParticipants")
    .withIndex("by_room_profile", query =>
      query.eq("roomId", roomId).eq("profileId", profileId),
    )
    .unique();
  if (!participant || participant.leftAt !== undefined) {
    throw new ConvexError("Not an active room participant");
  }
  return participant;
}
